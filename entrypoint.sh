#!/usr/bin/env bash
set -euo pipefail

# Runs as root (PID 1 via tini): sets up sshd + the coder home, then drops to
# the non-root `coder` user for the Claude process.

CODER_HOME=/home/coder
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${CODER_HOME}/.claude}"

# ── 1. SSH public key injection ────────────────────────────────────────────
# Pass your public key at runtime via: --env SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    mkdir -p "${CODER_HOME}/.ssh"
    echo "${SSH_PUBLIC_KEY}" >> "${CODER_HOME}/.ssh/authorized_keys"
    chmod 700 "${CODER_HOME}/.ssh"
    chmod 600 "${CODER_HOME}/.ssh/authorized_keys"
    chown -R coder:coder "${CODER_HOME}/.ssh"
fi

# ── 2. SSH host key generation (idempotent) ────────────────────────────────
ssh-keygen -A 2>/dev/null || true

# ── 3. Make Claude's env reach SSH / VS Code sessions ─────────────────────
# sshd starts sessions with a clean environment, so neither the container ENV
# nor `podman run --env` values reach `claude` when run over SSH / VS Code
# Remote-SSH. sshd's `SetEnv` directive is the one mechanism that applies to
# ALL session types (interactive, login, and `ssh host cmd` exec sessions that
# skip /etc/profile). We build a single SetEnv line — including any runtime
# credential — and inject it before sshd starts. sshd_config comes fresh from
# the image each run, so this never accumulates.
#   CLAUDE_CONFIG_DIR       → read settings/credentials from the persistent volume
#   CLAUDE_CODE_OAUTH_TOKEN → from `claude setup-token` (subscription, recommended)
#   ANTHROPIC_API_KEY       → a console.anthropic.com API key
SETENV_LINE="SetEnv CLAUDE_CONFIG_DIR=${CLAUDE_DIR}"
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && SETENV_LINE+=" CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}"
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && SETENV_LINE+=" ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
printf '\n%s\n' "${SETENV_LINE}" >> /etc/ssh/sshd_config

# ── 4. Start sshd in the background ───────────────────────────────────────
# tini (PID 1) will reap any zombie children sshd creates.
/usr/sbin/sshd -f /etc/ssh/sshd_config -D &

# ── 5. Always restore settings.json from the baked-in backup ─────────────
# The claude-auth volume mounts over the config dir and shadows the image's
# settings.json. Always copy from /etc/claude-settings.json so our config
# (theme, bypassPermissions mode, skipDangerousModePermissionPrompt) is active.
mkdir -p "${CLAUDE_DIR}"
cp /etc/claude-settings.json "${CLAUDE_DIR}/settings.json"

# ── 6. Suppress first-run wizards in .claude.json ─────────────────────────
# Claude tracks onboarding/trust state in .claude.json. We force these flags on
# (merging, never clobbering saved credentials) so a fresh volume never shows
# the theme picker or the "do you trust this folder?" dialog. Trust is keyed by
# project path and Claude walks UP the tree, so granting "/" trusts every
# mounted directory.
python3 - "${CLAUDE_DIR}/.claude.json" <<'PY'
import json, os, sys
path = sys.argv[1]
data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}
data["hasCompletedOnboarding"] = True
projects = data.setdefault("projects", {})
projects.setdefault("/", {})["hasTrustDialogAccepted"] = True
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY

# ── 7. Hand the config dir to coder ───────────────────────────────────────
# The mounted host auth folder may appear owned by root/other; make sure coder
# owns its whole config dir so Claude can read/write settings, credentials and
# sessions.
chown -R coder:coder "${CLAUDE_DIR}"

# ── 8. Export credentials for the local CMD (only if actually set) ─────────
# Empty values would block Claude from falling back to credentials saved in the
# volume. SSH sessions get these via the SetEnv line above instead.
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && export CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN}"
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"

# ── 9. Drop to the coder user and hand off to CMD ─────────────────────────
# setpriv preserves the environment (CLAUDE_CONFIG_DIR + exported credentials),
# unlike `su`/`runuser`. As a non-root user, Claude's bypass-permissions mode
# runs with no prompt and no IS_SANDBOX trick.
exec setpriv --reuid coder --regid coder --init-groups "$@"
