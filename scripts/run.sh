#!/usr/bin/env bash
# run.sh — start the coding-seal container with flexible options
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
GPU_FLAGS=()
PROJECT_MOUNTS=()
MODE="local"            # "local"  → interactive TTY, claude starts immediately
                        # "remote" → Remote Control: foreground, runs `claude remote-control`
                        #            so claude.ai/code + the Claude app can drive this env
                        # "ssh"    → detached, container stays up for SSH / VS Code Remote-SSH
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
  --remote              Remote Control: run `claude remote-control` so claude.ai/code
                        and the Claude mobile app can drive this environment
                        (needs a full claude.ai login — run --auth first)
  --ssh                 Headless mode: container stays running for SSH / VS Code Remote-SSH
  --port PORT           SSH port on localhost, used by --ssh (default: 2222)
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

  # Remote Control — drive this container from claude.ai/code or the Claude app
  scripts/run.sh --remote -p ~/projects/myapp

  # Headless SSH / VS Code Remote-SSH
  scripts/run.sh --ssh -p ~/projects/myapp

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
        --ssh)
            MODE="ssh"
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
# NOTE: the SSH port (2222) is published ONLY in --ssh mode (below). All other
# modes (local / remote-control / auth / setup-token) run `claude` directly and
# don't need SSH, so they must NOT bind a host port — otherwise a second run (or
# a leftover container) collides with "address already in use" on 127.0.0.1:2222.

# Only pass credentials that are actually set — empty values would prevent
# Claude from falling back to the credentials saved in the volume.
# EXCEPTION: Remote Control (--remote) rejects inference-only credentials. A
# CLAUDE_CODE_OAUTH_TOKEN (from --setup-token) or an ANTHROPIC_API_KEY cannot
# establish a Remote Control session — it needs the full-scope claude.ai login
# saved by --auth (the .credentials.json in the auth dir). If we passed a token,
# Claude would pick it over the saved login and remote-control would fail with
# "requires a full-scope login token", so in remote mode we deliberately skip them.
if [[ "${MODE}" != "remote" ]]; then
    [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && PODMAN_FLAGS+=("--env" "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && PODMAN_FLAGS+=("--env" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
fi

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
elif [[ "${MODE}" == "remote" ]]; then
    # Remote Control: expose THIS container's environment to claude.ai/code and
    # the Claude mobile app. The connection is outbound HTTPS only — Claude
    # registers with the Anthropic API and polls for work — so there's NO inbound
    # port and no --publish. Runs in the foreground with a TTY so the session URL
    # (and the spacebar QR code) are visible; the process must stay alive to host
    # the session, so stopping it ends the remote session.
    PODMAN_FLAGS+=("--tty" "--interactive")
    CMD=("claude" "remote-control")
else
    # MODE == "ssh": detached, container stays running, you SSH in and start
    # claude manually (e.g. via VS Code Remote-SSH). Only this mode needs the SSH
    # port published on the host loopback.
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
    echo "  Remote Control — drive this environment from claude.ai/code or the Claude app."
    echo "  A session URL appears below (press spacebar for a QR code). Keep this"
    echo "  process running; stopping it ends the remote session."
    echo ""
    echo "  Remote Control needs a full claude.ai login — a CLAUDE_CODE_OAUTH_TOKEN or"
    echo "  ANTHROPIC_API_KEY won't work, so they are NOT passed in this mode."
    if [[ ! -f "${CLAUDE_AUTH_DIR}/.credentials.json" ]]; then
        echo ""
        echo "  ⚠️  No login found at ${CLAUDE_AUTH_DIR}/.credentials.json."
        echo "     Run 'scripts/run.sh --auth' once first, then retry."
    fi
    echo ""
fi
if [[ "${MODE}" == "ssh" ]]; then
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
