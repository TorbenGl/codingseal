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

# ── Baked-in MCP servers (stdio) ───────────────────────────────────────────
# Installed globally so `npx -y <pkg>` resolves them offline/instantly at
# runtime. run.sh registers these as user-scope MCP servers in ~/.claude.json:
#   @upstash/context7-mcp                          → up-to-date library docs (Context7)
#   @modelcontextprotocol/server-sequential-thinking → step-by-step reasoning scaffold
# (The GitHub MCP server is remote — https://api.githubcopilot.com/mcp/ — so it
# needs nothing baked here; run.sh adds it only when a PAT is provided.)
RUN npm install -g @upstash/context7-mcp @modelcontextprotocol/server-sequential-thinking

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
# Bake the host keys at build time — stable across container starts, so no
# "host key changed" warnings — and pre-create coder's .ssh dir (mode 700). In
# --ssh mode, run.sh bind-mounts your public key to authorized_keys inside it.
RUN mkdir -p /run/sshd && chmod 0755 /run/sshd && \
    ssh-keygen -A && \
    install -d -m 700 -o coder -g coder /home/coder/.ssh

# ── Claude Code config ─────────────────────────────────────────────────────
# CLAUDE_CONFIG_DIR makes Claude store ALL of its state — settings.json,
# .claude.json (onboarding/trust/projects), credentials, and sessions — in this
# single directory. run.sh bind-mounts the host folder ~/.codingseal/claude-auth
# here at runtime AND seeds settings.json + .claude.json into it, so every run is
# wizard-free and stays logged in. Nothing config-related is baked into the image
# (the bind-mount would shadow it anyway) — run.sh is the single source of truth.
ENV HOME=/home/coder \
    CLAUDE_CONFIG_DIR=/home/coder/.claude
RUN install -d -o coder -g coder /home/coder/.claude

# ── Copy runtime files ─────────────────────────────────────────────────────
COPY config/sshd_config       /etc/ssh/sshd_config
RUN chown -R coder:coder /home/coder

# ── Workspace ──────────────────────────────────────────────────────────────
WORKDIR /home/coder

EXPOSE 2222

# tini as PID 1 (reaps zombies; runs sshd as root in --ssh mode). run.sh supplies
# the per-mode command (claude / claude remote-control / sshd) and the user: the
# default is `coder` (uid 1000) via --userns=keep-id, and --ssh overrides with
# --user 0 so sshd can start (the SSH *login* is still the coder user).
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["claude"]
