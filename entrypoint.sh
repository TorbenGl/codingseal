#!/usr/bin/env bash
set -euo pipefail

# ── 1. SSH public key injection ────────────────────────────────────────────
# Pass your public key at runtime via: --env SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
# The key is appended so you can also pre-bake keys into a derived image.
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "${SSH_PUBLIC_KEY}" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# ── 2. SSH host key generation (idempotent) ────────────────────────────────
# Generates keys only if they don't already exist (e.g. from a persistent volume).
# Suppresses the "generating key" message on repeated starts.
ssh-keygen -A 2>/dev/null || true

# ── 3. Start sshd in the background ───────────────────────────────────────
# tini (PID 1) will reap any zombie children sshd creates.
/usr/sbin/sshd -f /etc/ssh/sshd_config -D &

# ── 4. Make ANTHROPIC_API_KEY available to child processes ─────────────────
# Claude Code reads this env var directly. If it is empty, Claude falls back
# to ~/.claude/.credentials.json (populated by `claude auth login`).
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

# ── 5. Hand off to CMD ─────────────────────────────────────────────────────
exec "$@"
