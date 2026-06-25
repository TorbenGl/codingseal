FROM ubuntu:24.04

# Use ARG so DEBIAN_FRONTEND doesn't leak into the running container's environment
ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# ── System packages ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        openssh-server \
        sudo \
        tini \
        procps \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js LTS (via NodeSource) ──────────────────────────────────────────
# ubuntu:24.04 ships Node 18; NodeSource gives Node 22 (current LTS).
# Claude Code requires Node >= 18.
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code CLI ────────────────────────────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code

# ── uv (standalone binary, official installer) ────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# ── Python via uv ─────────────────────────────────────────────────────────
# Override at build time: podman build --build-arg PYTHON_VERSION=3.11 .
ARG PYTHON_VERSION=3.12
RUN uv python install ${PYTHON_VERSION}

# Symlink the uv-managed Python into PATH so `python3` and `python` work everywhere
RUN UV_PYTHON=$(uv python find ${PYTHON_VERSION}) && \
    ln -sf "${UV_PYTHON}" /usr/local/bin/python3 && \
    ln -sf /usr/local/bin/python3 /usr/local/bin/python

# ── SSH server setup ───────────────────────────────────────────────────────
RUN mkdir -p /run/sshd && chmod 0755 /run/sshd

# ── Claude Code config ─────────────────────────────────────────────────────
# This directory is replaced at runtime by the named volume `claude-auth`,
# which persists auth tokens across container restarts.
RUN mkdir -p /root/.claude

# ── Copy runtime files ─────────────────────────────────────────────────────
COPY config/sshd_config       /etc/ssh/sshd_config
COPY config/claude-settings.json /root/.claude/settings.json
COPY entrypoint.sh            /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Workspace ──────────────────────────────────────────────────────────────
RUN mkdir -p /workspace
WORKDIR /workspace

EXPOSE 2222

# tini as PID 1: reaps zombie processes that sshd forks, propagates signals cleanly
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["bash"]
