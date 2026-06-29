FROM ubuntu:24.04

# Use ARG so DEBIAN_FRONTEND doesn't leak into the running container's environment
ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# ── System packages ────────────────────────────────────────────────────────
# util-linux (provides setpriv, used to drop to the coder user) is already in base.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        openssh-server \
        tini \
        procps \
    && rm -rf /var/lib/apt/lists/*

# ── Non-root user ──────────────────────────────────────────────────────────
# Claude Code's bypass-permissions mode refuses to run as root. Running as a
# normal user is the canonical fix: the guard (getuid()===0) never fires.
# uid/gid 1000 matches a typical host user; combined with `--userns=keep-id`
# in run.sh it keeps bind-mounted project files owned by you and writable.
# (ubuntu:24.04 ships a default `ubuntu` user at uid/gid 1000 — remove it first.)
# `-p '*'` leaves the account password-less but UNLOCKED: useradd's default `!`
# marks it locked, and with `UsePAM no` sshd refuses key login to locked accounts.
# Password login stays impossible (PasswordAuthentication no in sshd_config).
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupadd -g 1000 coder && \
    useradd -m -u 1000 -g 1000 -s /bin/bash -p '*' coder

# ── Node.js LTS (via NodeSource) ──────────────────────────────────────────
# ubuntu:24.04 ships Node 18; NodeSource gives Node 22 (current LTS).
# Claude Code requires Node >= 18.
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code CLI (global, world-readable — usable by any user) ──────────
RUN npm install -g @anthropic-ai/claude-code

# ── uv + Python in SHARED locations (reachable by the non-root user) ───────
# The default installer drops uv under /root (mode 700); coder couldn't read it.
# Install uv into /usr/local/bin and the managed Python into /opt/uv/python,
# both world-readable, so coder uses the same toolchain.
ENV UV_INSTALL_DIR=/usr/local/bin \
    UV_PYTHON_INSTALL_DIR=/opt/uv/python
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

ARG PYTHON_VERSION=3.12
RUN uv python install ${PYTHON_VERSION} && \
    UV_PYTHON=$(uv python find ${PYTHON_VERSION}) && \
    ln -sf "${UV_PYTHON}" /usr/local/bin/python3 && \
    ln -sf /usr/local/bin/python3 /usr/local/bin/python && \
    chmod -R a+rX /opt/uv

# ── SSH server setup ───────────────────────────────────────────────────────
RUN mkdir -p /run/sshd && chmod 0755 /run/sshd

# ── Claude Code config ─────────────────────────────────────────────────────
# CLAUDE_CONFIG_DIR makes Claude store ALL of its state — settings.json,
# .claude.json (onboarding/trust/projects), credentials, and sessions — in
# this single directory. run.sh bind-mounts the host folder ~/.codingseal/claude-auth
# here at runtime, so everything persists across container restarts (no re-login,
# no wizard).
ENV HOME=/home/coder \
    CLAUDE_CONFIG_DIR=/home/coder/.claude
RUN mkdir -p /home/coder/.claude

# ── Copy runtime files ─────────────────────────────────────────────────────
COPY config/sshd_config       /etc/ssh/sshd_config
# settings.json is saved to two places: /home/coder/.claude/ is shadowed by the
# mounted host auth folder at runtime, so /etc/claude-settings.json is the
# persistent backup that entrypoint.sh restores from on every start.
COPY config/claude-settings.json /home/coder/.claude/settings.json
COPY config/claude-settings.json /etc/claude-settings.json
COPY entrypoint.sh            /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown -R coder:coder /home/coder

# ── Workspace ──────────────────────────────────────────────────────────────
WORKDIR /home/coder

EXPOSE 2222

# tini as PID 1 (runs as root: sshd needs it). entrypoint.sh starts sshd, then
# drops to the coder user for the Claude process.
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["bash"]
