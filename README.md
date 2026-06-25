<div align="center">
  <img src="codingseal.png" alt="CodingSeal" width="180">

  # CodingSeal — Claude Code in a Podman Container

  *Give Claude Code unrestricted tool access inside a rootless Podman container.
  Your host stays completely isolated. Connect via terminal, VS Code, or from a remote machine.*
</div>

---

**What you get:**
- Claude Code with full permissions inside a container — `rm -rf /` can only hurt the container, never your host
- Persistent authentication — authenticate once with `scripts/run.sh --auth`, token lives in a named volume forever
- VS Code Remote-SSH support — Claude's bash commands run inside the container, not on your host
- Selectable project directories — only the folders you explicitly pass with `-p` are visible to Claude
- Optional GPU passthrough — NVIDIA and AMD both supported

---

```
┌──────────────────────────────────────────────────────────────┐
│                       HOST MACHINE                           │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                PODMAN CONTAINER                        │  │
│  │                                                        │  │
│  │   claude ──► /home/you/projects/myapp     ◄── ─ ─ ┐   │  │
│  │      │       /home/you/projects/lib       ◄── ─ ─ ┤   │  │
│  │      │       /home/you/datasets/          ◄── ─ ─ ┘   │  │
│  │      │                                               │  │  │
│  │   sshd (port 2222) ◄── VS Code Remote-SSH           │  │  │
│  └────────────────────────────────────────────────────────┘  │
│       bind-mounts ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘                 │
│       named volume: claude-auth → ~/.claude/ (token)         │
└──────────────────────────────────────────────────────────────┘
```

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Quick Start](#2-quick-start)
3. [Security Model](#3-security-model)
4. [First-Time Authentication](#4-first-time-authentication)
5. [Mounting Multiple Projects](#5-mounting-multiple-projects)
6. [Connection Modes](#6-connection-modes)
   - [Mode A: Local Interactive Terminal](#mode-a-local-interactive-terminal)
   - [Mode B: VS Code Remote-SSH](#mode-b-vs-code-remote-ssh)
   - [Mode C: Access from a Remote Machine](#mode-c-access-from-a-remote-machine)
7. [GPU Support](#7-gpu-support)
8. [Advanced: Sharing Host Python Packages](#8-advanced-sharing-host-python-packages)
9. [Updating the Image](#9-updating-the-image)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Prerequisites

| Requirement | How to check |
|---|---|
| **Podman >= 4.3** | `podman --version` — install: [podman.io](https://podman.io/docs/installation) |
| **Anthropic account** | [console.anthropic.com](https://console.anthropic.com) |
| **SSH key pair** | `ls ~/.ssh/id_*.pub` — generate: `ssh-keygen -t ed25519` |
| **VS Code** *(optional)* | With [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension |
| **NVIDIA drivers** *(optional)* | Required only for `--gpu-nvidia` — see [Section 7](#7-gpu-support) |

---

## 2. Quick Start

### First time (do this once)

```bash
# 1. Clone and configure
git clone https://github.com/TorbenGl/codingseal.git
cd codingseal
cp .env.example .env
#    Edit .env — set SSH_PUBLIC_KEY to the contents of ~/.ssh/id_ed25519.pub

# 2. Build the image (~5 minutes)
podman build -t claude-code:latest .

# 3. Authenticate Claude (browser flow, token saved permanently)
set -a && source .env && set +a
scripts/run.sh --auth

# 4. Start working
scripts/run.sh -p ~/projects/myproject
```

### Every time after that

```bash
set -a && source .env && set +a
scripts/run.sh -p ~/projects/myproject
# Claude starts immediately — no auth prompt, permissions pre-configured
```

---

## 3. Security Model

### Why `--dangerouslySkipPermissions` is safe here

Claude Code normally prompts before every file write, shell command, and web request. Those prompts are disabled inside this container. This is intentional and safe because:

- Claude can only see directories you explicitly pass with `-p`. Nothing else on your drive is mounted.
- Even if Claude runs `rm -rf /`, it destroys only the container's writable layer. The container exits. Start a new one.
- The container shares your kernel but has no access to host processes, network interfaces beyond the published ports, or the rest of your filesystem.

**The container is the security boundary. Claude's own permission system is redundant here.**

### What Claude cannot do

| Cannot do | Why |
|---|---|
| Read files outside `-p` mounts | Not mounted |
| Access other users' data | User-namespace isolation |
| Persist changes outside project mounts and the auth volume | `--rm` removes the container on exit |
| Reach the host's running processes | PID namespace is separate |

---

## 4. First-Time Authentication

Claude Code needs an Anthropic account token to work. You have two options.

### Option A — Browser login (recommended)

Authenticate once. The token lives in the `claude-auth` named Podman volume and is reused automatically on every subsequent run.

```bash
set -a && source .env && set +a
scripts/run.sh --auth
```

What happens:
1. The container starts and runs `claude auth login`
2. A URL is printed to your terminal
3. Open that URL in your **host browser** (the container has no browser)
4. Complete the Anthropic login flow
5. Paste the code back into the terminal
6. The container exits — your token is saved

The token lives at:
```
~/.local/share/containers/storage/volumes/claude-auth/
```

This is user-scoped on your host — other users on the machine cannot access it. Security is equivalent to storing the token at `~/.claude/` directly on your host.

**Check that authentication worked:**
```bash
scripts/run.sh -p /tmp
# Inside: claude --version   ← should start without asking for auth
```

**Remove saved credentials:**
```bash
podman volume rm claude-auth
```

### Option B — API key (stateless, no login needed)

If you prefer not to use browser login, set your API key in `.env`:

```bash
# In .env:
ANTHROPIC_API_KEY=sk-ant-api03-...
```

The key is passed as an environment variable each run. Nothing is stored in the container.

---

## 5. Mounting Multiple Projects

Pass `-p` once per directory. Use it as many times as you need:

```bash
scripts/run.sh \
  -p ~/projects/myapp \
  -p ~/projects/shared-lib \
  -p ~/projects/infra \
  -p ~/datasets/training-data
```

Each directory is mounted at the **same absolute path** inside the container. If your project is at `/home/alice/projects/myapp` on the host, Claude sees it at `/home/alice/projects/myapp` inside too. This means:

- `git` history, branches, and remotes all work
- Relative imports across your projects work
- Symlinks resolve correctly
- You can open the same directory in VS Code on the host and in the container simultaneously

Claude can read and write all mounted directories. It cannot access anything else.

> **SELinux note (Fedora / RHEL):** The `:Z` label in `run.sh` is already set for you. Never omit it on SELinux-enforcing hosts — you will get `Permission denied` errors on mounts with no obvious cause.

---

## 6. Connection Modes

### Mode A: Local Interactive Terminal

The default. A TTY is allocated and Claude starts immediately.

```bash
set -a && source .env && set +a
scripts/run.sh -p ~/projects/myproject
```

You land directly in `claude --dangerouslySkipPermissions`. Type your task. Claude's bash commands run in the container.

To get a plain shell instead:
```bash
podman run -it --rm \
  --volume claude-auth:/root/.claude:z \
  --publish 127.0.0.1:2222:2222 \
  --env SSH_PUBLIC_KEY \
  --volume ~/projects/myproject:~/projects/myproject:Z \
  localhost/claude-code:latest \
  bash
```

---

### Mode B: VS Code Remote-SSH

This is the most powerful mode. VS Code connects into the running container over SSH. **Everything in VS Code — the terminal, extensions, language servers, and Claude Code itself — runs inside the container.**

#### Why this is important

When VS Code's Remote-SSH connects to the container, it installs **VS Code Server** inside the container. From that point on:

| VS Code feature | Where it runs |
|---|---|
| Integrated terminal | Container bash |
| Claude Code extension | Inside the container |
| Claude's Bash tool | Container process — **not your host** |
| File operations Claude performs | Your mounted project dirs only |
| Language servers (Pylance, etc.) | Inside the container |

This is exactly what you want: Claude operates in a sandboxed environment with no ability to affect your host.

#### Step-by-step setup

**Step 1 — Start the container in remote mode**

```bash
set -a && source .env && set +a
scripts/run.sh --remote -p ~/projects/myproject
```

Output:
```
Starting container 'claude-code'...

  SSH into the container:
    ssh -p 2222 -i ~/.ssh/id_ed25519 root@localhost

  Then start Claude:
    claude --dangerouslySkipPermissions

  Stop the container:
    podman stop claude-code
```

**Step 2 — Add the container to your SSH config**

```bash
cat >> ~/.ssh/config << 'EOF'

Host claude-container
    HostName 127.0.0.1
    Port 2222
    User root
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
```

> `StrictHostKeyChecking no` is safe here because the connection is loopback-only. The SSH host key changes when a new container starts — this setting avoids the warning.

**Step 3 — Connect with VS Code**

1. Open the Command Palette: `Ctrl+Shift+P` (Linux/Windows) or `Cmd+Shift+P` (Mac)
2. Run: **Remote-SSH: Connect to Host...**
3. Select **claude-container**
4. VS Code opens a new window. On the first connection it installs VS Code Server inside the container — this takes about 30 seconds.

**Step 4 — Install Claude Code on the remote**

In the new VS Code window (which is now running inside the container):
1. Open the Extensions panel (`Ctrl+Shift+X`)
2. Search for **Claude Code**
3. Click **Install in SSH: claude-container**

On subsequent connections, the extension is already installed.

**Step 5 — Verify you are inside the container**

Open the integrated terminal (`` Ctrl+` ``):

```bash
# These confirm you are in the container, not on your host:
hostname          # prints a short container ID hash
which claude      # /usr/local/bin/claude — the container's installation
ls ~/projects/    # your mounted project directories
```

**Step 6 — Start Claude**

From the VS Code integrated terminal:

```bash
claude
# or if you want to be explicit:
claude --dangerouslySkipPermissions
```

From this point on, every bash command Claude runs executes as a container process. Claude cannot touch your host filesystem beyond what is mounted.

**Step 7 — Stop the container when done**

```bash
podman stop claude-code
```

---

### Mode C: Access from a Remote Machine

The SSH port is bound to `127.0.0.1` only — it is not reachable directly from other machines. To connect from a separate computer, tunnel through the host first.

**Option 1 — SSH tunnel (two terminals)**

On your local machine:
```bash
# Terminal 1: keep this running — it forwards local port 2222 to the container
ssh -N -L 2222:localhost:2222 youruser@your-workstation-ip

# Terminal 2: connect to the container through the tunnel
ssh -p 2222 -i ~/.ssh/id_ed25519 root@localhost
```

**Option 2 — ProxyJump (one step, works with VS Code)**

Add to your local `~/.ssh/config`:

```
Host your-workstation
    HostName your-workstation-ip
    User youruser

Host claude-remote
    HostName 127.0.0.1
    Port 2222
    User root
    IdentityFile ~/.ssh/id_ed25519
    ProxyJump your-workstation
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

Then in VS Code's Remote-SSH: connect to `claude-remote`. VS Code hops through your workstation into the container transparently.

---

## 7. GPU Support

### NVIDIA

Requirements: NVIDIA drivers installed on the host. No additional container toolkit needed.

```bash
scripts/run.sh --gpu-nvidia -p ~/projects/ml-project
```

This passes `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`, `/dev/nvidia-modeset`, `/dev/nvidia-uvm-tools` into the container.

> `/dev/nvidia-caps/` files are **not** needed for compute workloads (only for MIG mode).

To verify GPU access inside the container:
```bash
# Inside the container:
apt-get install -y nvidia-utils-550   # match your driver version
nvidia-smi
```

**CDI (future-proof, Podman 5.0+)**

If you have `/etc/cdi/nvidia.yaml` (from `nvidia-ctk cdi generate`), add this to `~/.config/containers/containers.conf`:

```toml
[engine]
cdi_spec_dirs = ["/etc/cdi"]
```

Then use `--device nvidia.com/gpu=all` instead of `--gpu-nvidia`. This is the preferred interface going forward.

### AMD

Requirements: ROCm-compatible AMD GPU and drivers.

```bash
scripts/run.sh --gpu-amd -p ~/projects/ml-project
```

Passes `--device /dev/kfd --device /dev/dri` with `--group-add keep-groups` so the container inherits your host user's `render` and `video` group memberships.

To verify:
```bash
# Inside the container:
apt-get install -y rocm-smi
rocm-smi
```

### No GPU

Default — no flag needed:
```bash
scripts/run.sh -p ~/projects/myproject
```

---

## 8. Advanced: Sharing Host Python Packages

If you have a large Python environment on your host and want to avoid reinstalling packages in the container, mount your host's site-packages read-only.

> This works reliably only when the host and container use the **same OS and Python version**. This repo uses `ubuntu:24.04` as the base — if your host is also Ubuntu 24.04, native `.so` extensions are ABI-compatible.

```bash
# Find your host site-packages paths
python3 -c "import site; print('\n'.join(site.getsitepackages()))"

# Add to the run command
podman run -it --rm \
  --volume claude-auth:/root/.claude:z \
  --publish 127.0.0.1:2222:2222 \
  --env ANTHROPIC_API_KEY \
  --env SSH_PUBLIC_KEY \
  --volume ~/projects/myproject:~/projects/myproject:Z \
  --volume /usr/lib/python3/dist-packages:/mnt/host-python/dist-packages:ro,Z \
  --volume ~/.local/lib/python3.12/site-packages:/mnt/host-python/user-packages:ro,Z \
  --env PYTHONPATH=/mnt/host-python/dist-packages:/mnt/host-python/user-packages \
  localhost/claude-code:latest \
  claude --dangerouslySkipPermissions
```

Packages installed with `uv pip install` inside the container go into the container's own layer and don't affect your host.

---

## 9. Updating the Image

**Full update** (base OS + Node.js + Claude Code + uv):
```bash
podman build --pull=newer -t claude-code:latest .
```

**Custom Python version:**
```bash
podman build --build-arg PYTHON_VERSION=3.11 -t claude-code:py311 .
CLAUDE_IMAGE=localhost/claude-code:py311 scripts/run.sh -p ~/projects/myproject
```

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `claude` asks to authenticate on every run | No saved token | Run `scripts/run.sh --auth` once, then future runs read from the `claude-auth` volume |
| `claude` exits with "Please authenticate" | Named volume was deleted | `podman volume ls \| grep claude-auth` — if missing, run `--auth` again |
| `ssh: connect to host localhost port 2222: Connection refused` | Container not running or sshd didn't start | `podman ps`; `podman logs claude-code` for sshd errors |
| `Permission denied (publickey)` via SSH | Wrong key or key not injected | Check `SSH_PUBLIC_KEY` is set; `podman exec claude-code cat /root/.ssh/authorized_keys` |
| VS Code says "Cannot connect to remote" | Container not running | Start with `scripts/run.sh --remote -p ...` first |
| Claude Code extension runs on local, not inside container | Extension not installed on the remote | Extensions panel → Claude Code → "Install in SSH: claude-container" |
| Claude's bash commands run on your host | VS Code not connected to container | Check VS Code title bar shows `[SSH: claude-container]` |
| `claude: command not found` | PATH issue | `which claude` inside container; rebuild if missing |
| Project files appear owned by a large UID | Expected with rootless Podman | Container root (uid 0) can still read/write them — cosmetic only |
| `Permission denied` on project files | SELinux denying the mount | The `:Z` flag in `run.sh` handles this — verify you are using `run.sh` not a manual command |
| NVIDIA GPU not visible inside container | Devices not passed through | Use `--gpu-nvidia`; verify `ls -l /dev/nvidia*` on host shows your devices |
| AMD GPU not visible | Group membership issue | `--gpu-amd` includes `--group-add keep-groups`; check `/dev/kfd` exists on host |
| `claude auth login` URL doesn't open a browser | Container has no display | This is expected — copy the URL, paste it into your **host** browser |
| VS Code keeps disconnecting | Missing SSH keepalive | `sshd_config` already sets `ClientAliveInterval 30`; check your local `~/.ssh/config` too |

---

## Repository layout

```
codingseal/
├── codingseal.png            ← Project logo
├── README.md                 ← This tutorial
├── Containerfile             ← ubuntu:24.04 + Node LTS + Claude Code + uv + Python + sshd
├── entrypoint.sh             ← Container startup: injects SSH key, starts sshd, runs CMD
├── .env.example              ← Copy to .env and fill in your credentials
├── scripts/
│   └── run.sh                ← Wrapper: --auth, --gpu-nvidia/amd, -p PATH, --remote
└── config/
    ├── sshd_config           ← Port 2222, key-only auth, VS Code keepalive
    └── claude-settings.json  ← dangerouslySkipPermissions + full allow list
```
