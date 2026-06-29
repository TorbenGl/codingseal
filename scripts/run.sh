#!/usr/bin/env bash
# run.sh — start the coding-seal container with flexible options
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
GPU_FLAGS=()
PROJECT_MOUNTS=()
MODE="local"            # "local"  → interactive TTY, claude starts immediately
                        # "remote" → detached, container stays up for SSH access
                        # "auth"   → interactive, runs `claude auth login`, saves token to the auth dir
IMAGE="${CLAUDE_IMAGE:-localhost/coding-seal:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-coding-seal}"
# Persistent auth lives in a FIXED host directory, not a podman named volume.
# Named volumes follow podman's storage root, which the VS Code snap relocates
# into its sandbox (~/snap/code/<rev>/...). That made login land in one volume
# and the next run read a different, empty one. A bind-mount to a stable $HOME
# path is identical whether run.sh is launched from a normal shell or inside the
# VS Code snap, so the login always persists. Override with CLAUDE_AUTH_DIR.
CLAUDE_AUTH_DIR="${CLAUDE_AUTH_DIR:-${HOME}/.codingseal/claude-auth}"
SSH_PORT="${SSH_PORT:-2222}"

# ── Help ──────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: scripts/run.sh [OPTIONS]

Options:
  --auth                First-time setup: log in and save the token to the auth dir
  --setup-token         Generate a long-lived OAuth token to paste into .env (Claude subscription)
  --gpu-nvidia          Pass through NVIDIA GPU(s) via /dev/nvidia* devices
  --gpu-amd             Pass through AMD GPU via /dev/kfd and /dev/dri
  --no-gpu              Run without GPU (default)
  -p, --project PATH    Bind-mount a project directory (repeatable)
  --remote              Headless mode: container stays running for SSH/remote access
  --port PORT           SSH port on localhost (default: 2222)
  --name NAME           Container name (default: coding-seal)
  --image IMAGE         Image to use (default: localhost/coding-seal:latest)
  -h, --help            Show this help

Environment variables (set these before running):
  CLAUDE_CODE_OAUTH_TOKEN  Long-lived token from --setup-token (recommended, subscription)
  ANTHROPIC_API_KEY        A console.anthropic.com API key (alternative to the token)
  SSH_PUBLIC_KEY           Public key injected into container's authorized_keys
  CLAUDE_AUTH_DIR          Host dir for persistent login (default: ~/.codingseal/claude-auth)
  SSH_PORT, CONTAINER_NAME, CLAUDE_IMAGE  Override defaults

Examples:
  # First-time: authenticate once, token saved to ~/.codingseal/claude-auth
  scripts/run.sh --auth

  # Interactive session with one project
  scripts/run.sh -p ~/projects/myapp

  # Multiple projects
  scripts/run.sh -p ~/projects/myapp -p ~/projects/infra

  # Headless (SSH / VS Code Remote)
  scripts/run.sh --remote -p ~/projects/myapp

  # With NVIDIA GPU
  scripts/run.sh --gpu-nvidia -p ~/projects/ml

  # With AMD GPU
  scripts/run.sh --gpu-amd -p ~/projects/ml
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu-nvidia)
            GPU_FLAGS=(
                "--device" "/dev/nvidia0"
                "--device" "/dev/nvidiactl"
                "--device" "/dev/nvidia-uvm"
                "--device" "/dev/nvidia-modeset"
                "--device" "/dev/nvidia-uvm-tools"
            )
            shift ;;
        --gpu-amd)
            GPU_FLAGS=(
                "--device" "/dev/kfd"
                "--device" "/dev/dri"
                "--group-add" "keep-groups"
            )
            shift ;;
        --no-gpu)
            GPU_FLAGS=()
            shift ;;
        -p|--project)
            [[ -z "${2:-}" ]] && { echo "Error: -p requires a path" >&2; exit 1; }
            ABSPATH=$(realpath "$2")
            # :Z = private SELinux label (no-op when SELinux is disabled, correct on Fedora/RHEL)
            PROJECT_MOUNTS+=("--volume" "${ABSPATH}:${ABSPATH}:Z")
            # Start Claude inside the FIRST project so it opens in your code,
            # not the empty /home/coder. Extra -p dirs stay accessible by path.
            [[ -z "${FIRST_PROJECT:-}" ]] && FIRST_PROJECT="${ABSPATH}"
            shift 2 ;;
        --auth)
            MODE="auth"
            shift ;;
        --setup-token)
            MODE="setup-token"
            shift ;;
        --remote)
            MODE="remote"
            shift ;;
        --port)
            SSH_PORT="$2"
            shift 2 ;;
        --name)
            CONTAINER_NAME="$2"
            shift 2 ;;
        --image)
            IMAGE="$2"
            shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# ── Ensure the persistent auth directory exists ───────────────────────────
# A real host directory (not a named volume) so the location never depends on
# podman's storage root — see CLAUDE_AUTH_DIR note above.
mkdir -p "${CLAUDE_AUTH_DIR}"

# ── Build base flags ──────────────────────────────────────────────────────
PODMAN_FLAGS=(
    "--name"    "${CONTAINER_NAME}"
    "--rm"
    # Map your host user (uid 1000) to the container's `coder` user so bind-mounted
    # project files stay owned by you and remain writable inside the container.
    # --user 0 starts the entrypoint as root (to set up sshd + drop to coder);
    # keep-id alone would start as uid 1000 and break that setup.
    "--userns=keep-id"
    "--user"    "0"
    # Auth token storage — a fixed host dir, so login persists across restarts
    # AND across snap/non-snap invocations. :Z applies a private SELinux label
    # (no-op on Ubuntu, correct on Fedora/RHEL).
    "--volume"  "${CLAUDE_AUTH_DIR}:/home/coder/.claude:Z"
    # SSH public key (always passed, entrypoint ignores if empty)
    "--env"     "SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}"
)
# NOTE: the SSH port (2222) is published ONLY in --remote mode (below). Local /
# auth / setup-token sessions run `claude` directly and don't need SSH, so they
# must NOT bind a host port — otherwise a second run (or a leftover container)
# collides with "address already in use" on 127.0.0.1:2222.

# Only pass credentials that are actually set — empty values would prevent
# Claude from falling back to the credentials saved in the volume
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && PODMAN_FLAGS+=("--env" "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && PODMAN_FLAGS+=("--env" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")

# Append GPU flags (array may be empty)
if [[ ${#GPU_FLAGS[@]} -gt 0 ]]; then
    PODMAN_FLAGS+=("${GPU_FLAGS[@]}")
fi

# Append project mounts (array may be empty)
if [[ ${#PROJECT_MOUNTS[@]} -gt 0 ]]; then
    PODMAN_FLAGS+=("${PROJECT_MOUNTS[@]}")
fi

# Open Claude in the first project directory (falls back to /home/coder if no -p)
if [[ -n "${FIRST_PROJECT:-}" ]]; then
    PODMAN_FLAGS+=("--workdir" "${FIRST_PROJECT}")
fi

# ── Mode-specific flags and command ───────────────────────────────────────
if [[ "${MODE}" == "local" ]]; then
    PODMAN_FLAGS+=("--tty" "--interactive")
    CMD=("claude")
elif [[ "${MODE}" == "auth" ]]; then
    PODMAN_FLAGS+=("--tty" "--interactive")
    CMD=("claude" "auth" "login")
elif [[ "${MODE}" == "setup-token" ]]; then
    PODMAN_FLAGS+=("--tty" "--interactive")
    CMD=("claude" "setup-token")
else
    # Detached: container stays running, users SSH in and start claude manually.
    # Only this mode needs the SSH port published on the host loopback.
    PODMAN_FLAGS+=(
        "--detach"
        "--publish" "127.0.0.1:${SSH_PORT}:2222"
    )
    CMD=("sleep" "infinity")
fi

# ── Print summary ─────────────────────────────────────────────────────────
echo "Starting container '${CONTAINER_NAME}' from image '${IMAGE}'..."
if [[ "${MODE}" == "auth" ]]; then
    echo ""
    echo "  A URL will appear below. Open it in your browser, complete the login,"
    echo "  then paste the code back into this terminal."
    echo "  Your login will be saved to: ${CLAUDE_AUTH_DIR}"
    echo ""
fi
if [[ "${MODE}" == "setup-token" ]]; then
    echo ""
    echo "  A URL will appear below. Open it in your browser, complete the login,"
    echo "  then copy the long-lived token that is printed."
    echo "  Add it to your .env as:  CLAUDE_CODE_OAUTH_TOKEN=<token>"
    echo ""
fi
if [[ "${MODE}" == "remote" ]]; then
    echo ""
    echo "  SSH into the container:"
    echo "    ssh -p ${SSH_PORT} -i ~/.ssh/id_ed25519 coder@localhost"
    echo ""
    echo "  Then start Claude:"
    echo "    claude"
    echo ""
    echo "  Stop the container:"
    echo "    podman stop ${CONTAINER_NAME}"
    echo ""
fi

# ── Run ───────────────────────────────────────────────────────────────────
if [[ "${MODE}" == "auth" ]]; then
    # Don't exec — after login we verify the credential file actually landed in
    # the auth dir, so you get immediate confirmation instead of finding out next
    # session that nothing was saved.
    podman run "${PODMAN_FLAGS[@]}" "${IMAGE}" "${CMD[@]}"
    echo ""
    # On Linux, Claude has no OS keychain: it stores the login as a plaintext
    # file ".credentials.json" inside CLAUDE_CONFIG_DIR — which is this host dir.
    # It's a normal directory, so we can just check it directly.
    if [[ -f "${CLAUDE_AUTH_DIR}/.credentials.json" ]]; then
        echo "✅ Login saved to ${CLAUDE_AUTH_DIR}/.credentials.json"
        echo "   Future runs stay logged in — just: scripts/run.sh -p ~/your/project"
    else
        echo "⚠️  No .credentials.json was written to ${CLAUDE_AUTH_DIR}"
        echo "   The login did not complete. Re-run 'scripts/run.sh --auth' and make sure"
        echo "   you paste the code from the browser back into the terminal when prompted."
        echo "   Or use the token method instead:  scripts/run.sh --setup-token"
    fi
    exit 0
fi

exec podman run "${PODMAN_FLAGS[@]}" "${IMAGE}" "${CMD[@]}"
