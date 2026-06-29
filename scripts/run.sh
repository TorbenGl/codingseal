#!/usr/bin/env bash
# run.sh — start the coding-seal container with flexible options
set -euo pipefail

# Locate the repo so we can seed Claude's config from config/ (this script lives
# in <repo>/scripts/).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SETTINGS_SRC="${REPO_DIR}/config/claude-settings.json"

# ── Defaults ──────────────────────────────────────────────────────────────
GPU_FLAGS=()
PROJECT_MOUNTS=()
MODE="local"            # "local"          → interactive TTY, `claude` starts immediately
                        # "remote-control" → foreground `claude remote-control`, so
                        #                     claude.ai/code + the Claude app can drive this env
                        # "ssh"            → detached; SSH / VS Code Remote-SSH into the container
                        # "auth"           → interactive `claude auth login`, saves login to the auth dir
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

# Mutually exclusive mode requests (a container runs ONE command).
want_auth=0
want_rc=0
want_ssh=0

# ── Help ──────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: scripts/run.sh [OPTIONS]

Options:
  --auth                One-time login: runs `claude auth login` and saves the
                        credential to the auth dir (this is the only auth method)
  --gpu-nvidia          Pass through NVIDIA GPU(s) via /dev/nvidia* devices
  --gpu-amd             Pass through AMD GPU via /dev/kfd and /dev/dri
  --no-gpu              Run without GPU (default)
  -p, --project PATH    Bind-mount a project directory (repeatable)
  --remote-control, --rc
                        Remote Control: run `claude remote-control` (detached, in the
                        background) so claude.ai/code and the Claude mobile app can
                        drive this environment; get the URL via `podman logs`
  --ssh                 Headless: container stays running for SSH / VS Code Remote-SSH
  --port PORT           SSH port on localhost, used by --ssh (default: 2222)
  --name NAME           Container name (default: coding-seal)
  --image IMAGE         Image to use (default: localhost/coding-seal:latest)
  -h, --help            Show this help

Authentication:
  Log in once with `scripts/run.sh --auth`. The login is saved in the host folder
  (CLAUDE_AUTH_DIR) and reused on every run. Remote Control needs this full login —
  long-lived tokens and API keys are not supported.

Environment variables (set these before running):
  SSH_PUBLIC_KEY           Public key injected into the container's authorized_keys (--ssh)
  CLAUDE_AUTH_DIR          Host dir for persistent login (default: ~/.codingseal/claude-auth)
  SSH_PORT, CONTAINER_NAME, CLAUDE_IMAGE  Override defaults

Examples:
  # First-time: log in once, saved to ~/.codingseal/claude-auth
  scripts/run.sh --auth

  # Interactive session with one project
  scripts/run.sh -p ~/projects/myapp

  # Multiple projects
  scripts/run.sh -p ~/projects/myapp -p ~/projects/infra

  # Remote Control — drive this container from claude.ai/code or the Claude app
  scripts/run.sh --rc -p ~/projects/myapp

  # Headless SSH / VS Code Remote-SSH
  scripts/run.sh --ssh -p ~/projects/myapp

  # Both ways at once: start with --ssh, then SSH in and run `claude remote-control`
  scripts/run.sh --ssh -p ~/projects/myapp

  # With NVIDIA GPU
  scripts/run.sh --gpu-nvidia -p ~/projects/ml
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
            want_auth=1
            shift ;;
        --remote-control|--rc)
            want_rc=1
            shift ;;
        --ssh)
            want_ssh=1
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

# ── Resolve the (exclusive) mode ───────────────────────────────────────────
# --ssh and --rc can't be combined: a container runs ONE command. To reach one
# container both ways, start with --ssh and run `claude remote-control` yourself
# inside the SSH session — it works over SSH (outbound HTTPS, reads the volume
# login, config dir set via sshd SetEnv).
if (( want_ssh && want_rc )); then
    echo "Error: --ssh and --remote-control can't be combined (a container runs one command)." >&2
    echo "  To use both, start with --ssh, then:" >&2
    echo "    ssh -p ${SSH_PORT} -i ~/.ssh/id_ed25519 coder@localhost" >&2
    echo "    claude remote-control      # run this inside the SSH session" >&2
    exit 1
fi
if (( want_auth + want_rc + want_ssh > 1 )); then
    echo "Error: choose only one of --auth, --remote-control, --ssh." >&2
    exit 1
fi
(( want_auth )) && MODE="auth"
(( want_rc ))   && MODE="remote-control"
(( want_ssh ))  && MODE="ssh"

# Fail fast on missing prerequisites before touching the auth dir.
if [[ "${MODE}" == "ssh" && -z "${SSH_PUBLIC_KEY:-}" ]]; then
    echo "Error: --ssh needs SSH_PUBLIC_KEY set (your ~/.ssh/id_ed25519.pub contents)." >&2
    echo "  Add it to .env, then: set -a && source .env && set +a" >&2
    exit 1
fi

# ── Seed the persistent auth dir (host-side; no container entrypoint) ──────
# A real host directory (not a named volume) so the location never depends on
# podman's storage root — see CLAUDE_AUTH_DIR note above. We seed it from the
# host because this dir is bind-mounted over /home/coder/.claude and would
# otherwise shadow anything baked into the image:
#   • settings.json — policy (bypassPermissions, allow list, theme/tui). Always
#     refreshed from config/, so the suppression flags are guaranteed active.
#   • .claude.json  — onboarding + trust state, seeded only if absent so a fresh
#     dir never shows the theme picker or "trust this folder?" dialog. Claude
#     maintains the file afterward (it never clears these flags).
mkdir -p "${CLAUDE_AUTH_DIR}"
[[ -f "${SETTINGS_SRC}" ]] || { echo "Error: missing ${SETTINGS_SRC}" >&2; exit 1; }
cp "${SETTINGS_SRC}" "${CLAUDE_AUTH_DIR}/settings.json"
if [[ ! -f "${CLAUDE_AUTH_DIR}/.claude.json" ]]; then
    printf '%s\n' '{"hasCompletedOnboarding":true,"projects":{"/":{"hasTrustDialogAccepted":true}}}' \
        > "${CLAUDE_AUTH_DIR}/.claude.json"
fi

# ── Register the built-in MCP servers (user scope) ─────────────────────────
# Merge into the seeded .claude.json's top-level `mcpServers` (user scope) so
# they load in every project and every mode (local / --rc / manual claude over
# --ssh) with no approval prompt. Idempotent: existing keys are preserved.
#   context7            — up-to-date library docs (stdio, baked in the image)
#   sequential-thinking — reasoning scaffold (stdio, baked in the image)
#   github              — remote endpoint, added ONLY when a PAT is provided
# Optional credentials come from the environment (i.e. your .env):
#   CONTEXT7_API_KEY                higher Context7 rate limits (works without it)
#   GITHUB_PERSONAL_ACCESS_TOKEN    enables the GitHub MCP server (Bearer header)
if command -v python3 >/dev/null 2>&1; then
    CONTEXT7_API_KEY="${CONTEXT7_API_KEY:-}" \
    GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}" \
    python3 - "${CLAUDE_AUTH_DIR}/.claude.json" <<'PY'
import json, os, sys
path = sys.argv[1]
ctx_key = os.environ.get("CONTEXT7_API_KEY", "").strip()
gh_pat  = os.environ.get("GITHUB_PERSONAL_ACCESS_TOKEN", "").strip()

data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}

servers = data.setdefault("mcpServers", {})

ctx_args = ["-y", "@upstash/context7-mcp"]
if ctx_key:
    ctx_args += ["--api-key", ctx_key]
servers["context7"] = {"command": "npx", "args": ctx_args}

servers["sequential-thinking"] = {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"],
}

if gh_pat:
    servers["github"] = {
        "type": "http",
        "url": "https://api.githubcopilot.com/mcp/",
        "headers": {"Authorization": "Bearer " + gh_pat},
    }
else:
    servers.pop("github", None)

with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
else
    echo "⚠️  python3 not found on host — skipping MCP server setup." >&2
    echo "    Add them yourself inside the container, e.g.:" >&2
    echo "      claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp" >&2
fi

# ── Build base flags ──────────────────────────────────────────────────────
PODMAN_FLAGS=(
    "--name"    "${CONTAINER_NAME}"
    "--rm"
    # Map your host user (uid 1000) to the container's `coder` user so bind-mounted
    # project files stay owned by you and the seeded config dir is writable. With
    # bare keep-id the container runs AS coder (uid 1000) — no root, so Claude's
    # bypass-permissions mode runs with no prompt and no IS_SANDBOX trick. Only
    # --ssh adds `--user 0` (below), because sshd needs root to start.
    "--userns=keep-id"
    # Persistent login + seeded config. :Z applies a private SELinux label
    # (no-op on Ubuntu, correct on Fedora/RHEL).
    "--volume"  "${CLAUDE_AUTH_DIR}:/home/coder/.claude:Z"
)

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
elif [[ "${MODE}" == "remote-control" ]]; then
    # Remote Control: expose THIS container's environment to claude.ai/code and
    # the Claude mobile app. Outbound HTTPS only — Claude registers with the API
    # and polls for work — so there's NO inbound port and no --publish.
    #
    # Run DETACHED with no TTY: `claude remote-control` is a server ("no local
    # interactive session"), and the start prompts ("really start?" / "same dir?")
    # only appear when it's attached to a TTY. Headless + `--spawn same-dir` makes
    # it start straight away with no prompts. The session URL goes to the logs
    # (podman logs) and the session is listed by --name at claude.ai/code.
    RC_NAME="${CONTAINER_NAME}"
    [[ -n "${FIRST_PROJECT:-}" ]] && RC_NAME="$(basename -- "${FIRST_PROJECT}")"
    PODMAN_FLAGS+=("--detach")
    CMD=("claude" "remote-control" "--spawn" "same-dir" "--name" "${RC_NAME}")
else
    # MODE == "ssh": detached, container stays running; you SSH in (as coder,
    # with your own key) and start claude. sshd needs root, so override keep-id's
    # default user with --user 0 here only — the SSH *login* is still coder. Your
    # public key (validated above) is bind-mounted to authorized_keys; host keys
    # are baked into the image.
    SSH_KEY_FILE="$(dirname -- "${CLAUDE_AUTH_DIR}")/authorized_keys"
    printf '%s\n' "${SSH_PUBLIC_KEY}" > "${SSH_KEY_FILE}"
    chmod 600 "${SSH_KEY_FILE}"
    PODMAN_FLAGS+=(
        "--user"    "0"
        "--detach"
        "--publish" "127.0.0.1:${SSH_PORT}:2222"
        "--volume"  "${SSH_KEY_FILE}:/home/coder/.ssh/authorized_keys:ro,Z"
    )
    CMD=("/usr/sbin/sshd" "-D" "-e")
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
if [[ "${MODE}" == "remote-control" ]]; then
    echo ""
    echo "  Remote Control — drive this environment from claude.ai/code or the Claude app."
    echo "  The container runs in the BACKGROUND; this terminal returns to you."
    if [[ ! -f "${CLAUDE_AUTH_DIR}/.credentials.json" ]]; then
        echo ""
        echo "  ⚠️  No login found at ${CLAUDE_AUTH_DIR}/.credentials.json."
        echo "     Remote Control needs a full claude.ai login. Run this once first:"
        echo "       scripts/run.sh --auth"
    fi
    echo ""
fi
if [[ "${MODE}" == "ssh" ]]; then
    echo ""
    echo "  SSH into the container (your own key, the coder account):"
    echo "    ssh -p ${SSH_PORT} -i ~/.ssh/id_ed25519 coder@localhost"
    echo ""
    echo "  Then start Claude:        claude"
    echo "  …or drive it from the web: claude remote-control"
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
    if [[ -f "${CLAUDE_AUTH_DIR}/.credentials.json" ]]; then
        echo "✅ Login saved to ${CLAUDE_AUTH_DIR}/.credentials.json"
        echo "   Future runs stay logged in — just: scripts/run.sh -p ~/your/project"
    else
        echo "⚠️  No .credentials.json was written to ${CLAUDE_AUTH_DIR}"
        echo "   The login did not complete. Re-run 'scripts/run.sh --auth' and make sure"
        echo "   you paste the code from the browser back into the terminal when prompted."
    fi
    exit 0
fi

if [[ "${MODE}" == "remote-control" ]]; then
    # Detached: podman prints the container ID and returns. Tell the user how to
    # reach the session (the URL is in the logs once Claude connects).
    podman run "${PODMAN_FLAGS[@]}" "${IMAGE}" "${CMD[@]}"
    echo ""
    echo "✅ '${CONTAINER_NAME}' is running in the background."
    echo "   Session URL / status:  podman logs -f ${CONTAINER_NAME}"
    echo "   …or open claude.ai/code and pick the session named '${RC_NAME}'."
    echo "   Stop it:               podman stop ${CONTAINER_NAME}"
    exit 0
fi

exec podman run "${PODMAN_FLAGS[@]}" "${IMAGE}" "${CMD[@]}"
