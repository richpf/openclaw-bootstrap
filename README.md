# OpenClaw Bootstrap

> **Deploy a production-ready AI agent on a fresh Ubuntu 24.04 server in minutes.**

OpenClaw is a self-hosted AI assistant gateway that connects large language models to your messaging apps (Telegram, Discord, Slack, etc.) with full tool execution, persistent memory, and sub-agent orchestration.

This repo automates the complete setup process — from raw server to fully running assistant.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [What It Does](#what-it-does)
- [Post-Install Setup](#post-install-setup)
- [Configuration](#configuration)
- [Maintenance](#maintenance)
- [Cost Estimates](#cost-estimates)
- [Security Model](#security-model)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)

---

## Prerequisites

### Server
- **AWS Lightsail** (or any Ubuntu 24.04 VPS)
- Minimum: **2GB RAM, 1 vCPU** (Lightsail $10/mo plan)
- Recommended: **4GB RAM** if running multiple sub-agents concurrently
- Fresh Ubuntu 24.04 LTS install

### You'll Need
- SSH access to the server (key-based)
- An **Anthropic API key** (required) — [console.anthropic.com](https://console.anthropic.com)
- Optional: OpenRouter, OpenAI, or MiniMax API keys for additional models
- A messaging bot token for your preferred channel (Telegram, Discord, etc.)

### Local Machine
- SSH client
- Your SSH private key configured

---

## Quick Start

**Option A — One-liner (from the internet):**

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/openclaw-bootstrap/main/bootstrap.sh \
  | sudo bash
```

**Option B — Clone and run (recommended — lets you inspect first):**

```bash
git clone https://github.com/YOUR_ORG/openclaw-bootstrap.git
cd openclaw-bootstrap
sudo bash bootstrap.sh
```

**Option C — Dry run (see what would happen without making changes):**

```bash
sudo bash bootstrap.sh --dry-run
```

---

## What It Does

The bootstrap script runs through these stages automatically:

### 1. Pre-flight Checks
- Verifies Ubuntu 24.04
- Confirms internet connectivity
- Checks for existing SSH authorized keys (safety gate before hardening)

### 2. User Setup
- Creates a dedicated `openclaw` system user (non-root)
- Enables `loginctl linger` so the user's systemd services survive logout
- Creates `~/.openclaw/workspace/` directory structure

### 3. System Updates & Dependencies
- Runs `apt-get update && upgrade`
- Installs: `curl`, `git`, `jq`, `build-essential`, `ca-certificates`

### 4. Node.js 22.x
- Adds the official NodeSource repository
- Installs Node.js 22.x LTS (skips if already at v22+)

### 5. Swap File
- Creates a 1GB swap file (configurable with `--swap-size N`)
- Sets `vm.swappiness=10` for server workloads
- Persists in `/etc/fstab`

### 6. Security Hardening
- **SSH**: Disables password auth and root login (key-only)
- **UFW**: Blocks all incoming except SSH; allows loopback
- **fail2ban**: Bans IPs after 5 failed SSH attempts (1h ban, 10m window)
- **unattended-upgrades**: Automatic security patches

> ⚠️ The script checks for existing SSH authorized keys before hardening. If none are found, it asks for confirmation to prevent lockout.

### 7. OpenClaw Installation
- Installs OpenClaw globally via `npm install -g openclaw`
- Idempotent: prompts before reinstalling if already present

### 8. API Keys
- Prompts for API keys interactively (input hidden)
- Writes to `~/.openclaw/.env` (chmod 600)
- Auto-generates a secure `GATEWAY_AUTH_TOKEN` if not provided

### 9. Configuration
- Copies `openclaw.template.json` → `~/.openclaw/openclaw.json`
- Copies workspace template files (SOUL.md, AGENTS.md, etc.)

### 10. Systemd Service
- Creates `~/.config/systemd/user/openclaw-gateway.service`
- Enables auto-start on boot (via lingering)

### 11. Start Gateway
- Starts the OpenClaw gateway service
- Verifies it's running

### 12. Tailscale (Optional)
- Offers to install Tailscale for secure remote access
- You authenticate separately with `sudo tailscale up`

### 13. Maintenance Scripts (Optional)
- Offers to install cron job templates for workspace sync and backups

---

## Post-Install Setup

### 1. Connect a Messaging Channel

```bash
# SSH into your server as the openclaw user
sudo -u openclaw -i

# Add Telegram bot
openclaw channel add telegram

# Or add Discord
openclaw channel add discord

# Or Slack
openclaw channel add slack
```

Follow the interactive prompts to enter your bot token and configure allowed users.

### 2. Customize Your Assistant

Edit the workspace files to personalize your assistant's behavior:

```bash
nano /home/openclaw/.openclaw/workspace/SOUL.md      # Personality & mission
nano /home/openclaw/.openclaw/workspace/AGENTS.md    # Operational rules
nano /home/openclaw/.openclaw/workspace/USER.md      # Info about you
nano /home/openclaw/.openclaw/workspace/IDENTITY.md  # Agent identity
```

See the `templates/` directory for example content.

### 3. Edit Config

```bash
nano /home/openclaw/.openclaw/openclaw.json
```

Key settings to review:
- `model` — your primary LLM
- `models.allowlist` — which models sub-agents can use
- `heartbeat` — periodic health check schedule
- `workspace.path` — should match your actual path

### 4. Restart After Config Changes

```bash
sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  systemctl --user restart openclaw-gateway
```

---

## Configuration

### openclaw.json

See [`openclaw.template.json`](./openclaw.template.json) for the full config with inline documentation.

Key sections:

| Section | Purpose |
|---------|---------|
| `model` | Primary LLM (default: Claude Opus) |
| `models.allowlist` | Allowed models (unlisted → silently downgrade) |
| `gateway` | Port, bind address, auth mode |
| `channels` | Messaging integrations |
| `tools` | Execution profile and security level |
| `heartbeat` | Periodic health check config |
| `compaction` | Context compression settings |
| `context.pruning` | How old messages age out |

### Environment Variables (`.env`)

| Variable | Required | Purpose |
|----------|----------|---------|
| `ANTHROPIC_API_KEY` | ✅ Yes | Claude models |
| `OPENROUTER_API_KEY` | No | Qwen, Mistral, and other models via OpenRouter |
| `OPENAI_API_KEY` | No | Whisper transcription, embeddings |
| `MINIMAX_API_KEY` | No | MiniMax M1 model |
| `GATEWAY_AUTH_TOKEN` | Auto | Generated if not set; used by client apps |

---

## Maintenance

### Check Gateway Status

```bash
sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  systemctl --user status openclaw-gateway
```

### View Logs

```bash
# Live log tail
sudo -u openclaw journalctl --user -u openclaw-gateway -f

# Last 100 lines
sudo -u openclaw journalctl --user -u openclaw-gateway -n 100
```

### Update OpenClaw

```bash
sudo npm install -g openclaw
sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  systemctl --user restart openclaw-gateway
```

### Workspace Git Sync

If you want your workspace files backed up to a private git repo:

```bash
cd /home/openclaw/.openclaw/workspace
git init
git remote add origin git@github.com:YOUR_ORG/openclaw-workspace.git
```

Then enable the cron template: see `templates/scripts/git-sync.sh`

### Backups with Restic

See `templates/scripts/restic-backup.sh` for a template that backs up:
- `~/.openclaw/` (config, workspace, logs)
- To any Restic-compatible backend (S3, B2, local, SFTP)

---

## Cost Estimates

### Infrastructure (AWS Lightsail)

| Plan | RAM | CPU | Storage | Cost/mo |
|------|-----|-----|---------|---------|
| Minimum | 2GB | 1 vCPU | 60GB SSD | ~$10 |
| Recommended | 4GB | 2 vCPU | 80GB SSD | ~$20 |
| Heavy use | 8GB | 2 vCPU | 160GB SSD | ~$40 |

### API Costs (highly usage-dependent)

| Provider | Model | Input | Output |
|----------|-------|-------|--------|
| Anthropic | Claude Opus 4.6 | $15/M | $75/M |
| Anthropic | Claude Sonnet 4.5 | $3/M | $15/M |
| OpenRouter | Qwen 3-235B | $0.07/M | $0.10/M |
| OpenRouter | MiniMax M1 | ~$0 | ~$0 |

**Typical monthly API spend:** $20–$100 depending on usage volume.

**Cost optimization tips:**
- Use `sonnet` for sub-agents (10-25x cheaper than Opus)
- Use `qwen` models for analysis/research tasks (100x cheaper)
- Enable context pruning to reduce token waste
- Set heartbeat to a cheaper model

---

## Security Model

```
Internet
    │
    ▼
[ UFW Firewall ]
    │  Block all incoming except:
    │  • SSH (port 22) — key-only auth
    │
    ▼
[ Ubuntu 24.04 Server ]
    │
    ├─ fail2ban watches SSH logs
    │  Bans IPs after 5 failed attempts
    │
    ├─ openclaw user (non-root)
    │  Runs gateway on 127.0.0.1:18789
    │  Token auth required for all requests
    │
    └─ Tailscale (optional)
       Encrypted mesh VPN for remote access
       Eliminates need for public port exposure
```

**Key security properties:**
- Gateway is loopback-only by default — not reachable from internet
- All API keys stored in `~/.openclaw/.env` (owner-read-only, 600)
- SSH hardened to key-only (no passwords, no root)
- Automatic security patches via unattended-upgrades
- fail2ban mitigates brute-force attempts

For deeper hardening options, see [`docs/SECURITY.md`](./docs/SECURITY.md).

---

## Troubleshooting

See [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md) for detailed solutions.

**Quick checks:**

```bash
# Is the gateway running?
sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  systemctl --user status openclaw-gateway

# Check gateway logs for errors
sudo -u openclaw journalctl --user -u openclaw-gateway -n 50

# Test gateway locally
curl -s http://127.0.0.1:18789/health

# Check Node.js version
node --version  # should be v22.x

# Check openclaw version
openclaw --version
```

---

## Uninstall

```bash
# Remove OpenClaw (keeps system tools)
sudo bash uninstall.sh

# Remove everything including Node.js, fail2ban
sudo bash uninstall.sh --purge

# Remove but keep ~/.openclaw data
sudo bash uninstall.sh --keep-data
```

---

## Contributing

Pull requests welcome. Please:
- Test changes on a fresh Ubuntu 24.04 instance
- Keep the script idempotent
- Don't include any real credentials or personal identifiers

## License

MIT — see [LICENSE](./LICENSE)
