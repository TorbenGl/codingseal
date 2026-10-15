#!/usr/bin/env bash
# update.sh — rebuild the CodingSeal image on a newer Claude Code.
#
#   1. resolve the target version (newest on npm unless one is given)
#   2. stop every container running from the image
#   3. keep the current image as :previous, so a bad build can be undone
#   4. rebuild with CLAUDE_CODE_VERSION set — a changed build arg invalidates
#      the npm layer, so the cached old install is NOT reused
#   5. verify `claude --version`, then delete the old image
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
IMAGE="${CLAUDE_IMAGE:-localhost/coding-seal:latest}"
PREVIOUS="${IMAGE%:*}:previous"

usage() {
    cat <<'EOF'
Usage: scripts/update.sh [VERSION] [--check] [--keep-previous]

  VERSION          Claude Code version to install (default: newest on npm)
  --check          Only report the installed and newest versions; change nothing
  --keep-previous  Keep the old image as localhost/coding-seal:previous afterwards
  -h, --help       Show this help
EOF
    exit 0
}

VERSION=""
check_only=0
keep_previous=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)         check_only=1; shift ;;
        --keep-previous) keep_previous=1; shift ;;
        -h|--help)       usage ;;
        -*)              echo "Unknown option: $1" >&2; exit 1 ;;
        *)               VERSION="$1"; shift ;;
    esac
done

if [[ -z "${VERSION}" ]]; then
    VERSION="$(curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')" \
        || { echo "Error: could not reach the npm registry." >&2; exit 1; }
fi

installed="—"
if podman image exists "${IMAGE}"; then
    installed="$(podman run --rm "${IMAGE}" claude --version 2>/dev/null | awk '{print $1}')"
fi
echo "Claude Code  installed ${installed}  →  target ${VERSION}"
(( check_only )) && exit 0

# ── Stop everything running from the image ───────────────────────────────
stopped=()
while read -r c; do
    [[ -n "${c}" ]] && stopped+=("${c}")
done < <(podman ps -a --filter "ancestor=${IMAGE}" --format '{{.Names}}')
for c in ${stopped[@]+"${stopped[@]}"}; do
    podman stop -t 10 "${c}" >/dev/null 2>&1 || true
    podman rm -f "${c}" >/dev/null 2>&1 || true
    echo "  ⏹  stopped ${c}"
done

# ── Rebuild, with a rollback point ───────────────────────────────────────
# Only roll back to a :previous made in THIS run — a stale one from an earlier
# update must never be restored over a fresh build.
have_previous=0
if podman image exists "${IMAGE}"; then
    podman tag "${IMAGE}" "${PREVIOUS}"
    have_previous=1
fi
rollback() {
    if (( have_previous )); then
        echo "↩  Rolling back to the previous image." >&2
        podman tag "${PREVIOUS}" "${IMAGE}" || true
    else
        echo "No previous image to roll back to (fresh build)." >&2
    fi
    exit 1
}

podman build --pull=newer \
    --build-arg "CLAUDE_CODE_VERSION=${VERSION}" \
    --tag "${IMAGE}" \
    "${REPO_DIR}" || rollback

got="$(podman run --rm "${IMAGE}" claude --version 2>&1 | awk '{print $1}')"
if [[ "${got}" != "${VERSION}" ]]; then
    echo "❌ Image reports Claude Code '${got}', expected ${VERSION}." >&2
    rollback
fi
echo ""
echo "  ✅ claude --version → ${got}"

if (( ! keep_previous )); then
    podman rmi "${PREVIOUS}" >/dev/null 2>&1 || true
    podman image prune -f >/dev/null
    echo "  🧹 removed the old image and its cached layers"
fi

if [[ ${#stopped[@]} -gt 0 ]]; then
    echo ""
    echo "Stopped for the update: ${stopped[*]} — start them again with scripts/run.sh"
fi
