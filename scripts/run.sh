#!/usr/bin/env bash
# run.sh — start the claude-code container with flexible options
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
GPU_FLAGS=()
PROJECT_MOUNTS=()
MODE="local"            # "local"  → interactive TTY, claude starts immediately
                        # "remote" → detached, container stays up for SSH access
                        # "auth"   → interactive, runs `claude auth login`, saves token to named volume
IMAGE="${CLAUDE_IMAGE:-localhost/claude-code:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-claude-code}"
CLAUDE_VOLUME="${CLAUDE_VOLUME:-claude-auth}"
SSH_PORT="${SSH_PORT:-2222}"

# ── Help ──────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: scripts/run.sh [OPTIONS]

Options:
  --auth                First-time setup: authenticate Claude and save token to the named volume
  --gpu-nvidia          Pass through NVIDIA GPU(s) via /dev/nvidia* devices
  --gpu-amd             Pass through AMD GPU via /dev/kfd and /dev/dri
  --no-gpu              Run without GPU (default)
  -p, --project PATH    Bind-mount a project directory (repeatable)
  --remote              Headless mode: container stays running for SSH/remote access
  --port PORT           SSH port on localhost (default: 2222)
  --name NAME           Container name (default: claude-code)
  --image IMAGE         Image to use (default: localhost/claude-code:latest)
  -h, --help            Show this help

Environment variables (set these before running):
  ANTHROPIC_API_KEY     Your Anthropic API key (or leave blank and use --auth instead)
  SSH_PUBLIC_KEY        Public key injected into container's authorized_keys
  SSH_PORT, CONTAINER_NAME, CLAUDE_IMAGE, CLAUDE_VOLUME  Override defaults

Examples:
  # First-time: authenticate once, token saved to persistent volume
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
            shift 2 ;;
        --auth)
            MODE="auth"
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

# ── Ensure the auth volume exists ─────────────────────────────────────────
if ! podman volume exists "${CLAUDE_VOLUME}" 2>/dev/null; then
    echo "Creating named volume '${CLAUDE_VOLUME}' for persistent Claude auth..."
    podman volume create "${CLAUDE_VOLUME}"
fi

# ── Build base flags ──────────────────────────────────────────────────────
PODMAN_FLAGS=(
    "--name"    "${CONTAINER_NAME}"
    "--rm"
    # Auth token storage — survives container restarts
    # :z = shared SELinux label (named volumes can be shared between containers)
    "--volume"  "${CLAUDE_VOLUME}:/root/.claude:z"
    # SSH exposed on loopback only — remote access requires an SSH tunnel to the host first
    "--publish"  "127.0.0.1:${SSH_PORT}:2222"
    # Credentials passed as environment variables
    "--env"     "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
    "--env"     "SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}"
)

# Append GPU flags (array may be empty)
if [[ ${#GPU_FLAGS[@]} -gt 0 ]]; then
    PODMAN_FLAGS+=("${GPU_FLAGS[@]}")
fi

# Append project mounts (array may be empty)
if [[ ${#PROJECT_MOUNTS[@]} -gt 0 ]]; then
    PODMAN_FLAGS+=("${PROJECT_MOUNTS[@]}")
fi

# ── Mode-specific flags and command ───────────────────────────────────────
if [[ "${MODE}" == "local" ]]; then
    PODMAN_FLAGS+=("--tty" "--interactive")
    CMD=("claude" "--dangerouslySkipPermissions")
elif [[ "${MODE}" == "auth" ]]; then
    PODMAN_FLAGS+=("--tty" "--interactive")
    CMD=("claude" "auth" "login")
else
    # Detached: container stays running, users SSH in and start claude manually
    PODMAN_FLAGS+=("--detach")
    CMD=("sleep" "infinity")
fi

# ── Print summary ─────────────────────────────────────────────────────────
echo "Starting container '${CONTAINER_NAME}' from image '${IMAGE}'..."
if [[ "${MODE}" == "auth" ]]; then
    echo ""
    echo "  A URL will appear below. Open it in your browser, complete the login,"
    echo "  then paste the code back into this terminal."
    echo "  Your token will be saved to the '${CLAUDE_VOLUME}' volume for all future runs."
    echo ""
fi
if [[ "${MODE}" == "remote" ]]; then
    echo ""
    echo "  SSH into the container:"
    echo "    ssh -p ${SSH_PORT} -i ~/.ssh/id_ed25519 root@localhost"
    echo ""
    echo "  Then start Claude:"
    echo "    claude --dangerouslySkipPermissions"
    echo ""
    echo "  Stop the container:"
    echo "    podman stop ${CONTAINER_NAME}"
    echo ""
fi

# ── Run ───────────────────────────────────────────────────────────────────
exec podman run "${PODMAN_FLAGS[@]}" "${IMAGE}" "${CMD[@]}"
