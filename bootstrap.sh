#!/usr/bin/env bash
# =============================================================================
# OpenClaw Bootstrap Script
# Replicates a production-ready OpenClaw setup on Ubuntu 24.04 LTS
# =============================================================================
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/openclaw-bootstrap/main/bootstrap.sh | bash
#   -- OR --
#   git clone https://github.com/YOUR_ORG/openclaw-bootstrap.git
#   cd openclaw-bootstrap && bash bootstrap.sh [OPTIONS]
#
# Options:
#   --dry-run          Show what would be done without making changes
#   --skip-hardening   Skip SSH/UFW/fail2ban security hardening
#   --skip-swap        Skip swap file creation
#   --swap-size SIZE   Swap size in GB (default: 1)
#   --user NAME        OpenClaw system user (default: openclaw)
#   --help             Show this help
# =============================================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Logging ──────────────────────────────────────────────────────────────────
LOG_FILE="/tmp/openclaw-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()     { echo -e "${GREEN}[✓]${RESET} $*"; }
info()    { echo -e "${BLUE}[→]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; }
section() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}"; }
dry()     { echo -e "${YELLOW}[DRY-RUN]${RESET} Would: $*"; }

# ── Defaults ─────────────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_HARDENING=false
SKIP_SWAP=false
SWAP_SIZE_GB=1
OPENCLAW_USER="openclaw"
OPENCLAW_PORT=18789
OPENCLAW_DIR=""   # resolved after user is known
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument Parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=true ;;
    --skip-hardening) SKIP_HARDENING=true ;;
    --skip-swap)      SKIP_SWAP=true ;;
    --swap-size)      SWAP_SIZE_GB="$2"; shift ;;
    --user)           OPENCLAW_USER="$2"; shift ;;
    --help|-h)
      grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
      exit 0 ;;
    *) warn "Unknown option: $1" ;;
  esac
  shift
done

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root (use sudo)."
  exit 1
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
cat <<'BANNER'
   ___                  _____ _
  / _ \ _ __   ___ _ _ / ____| | __ ___      __
 | | | | '_ \ / _ \ '_ \ |    | |/ _` \ \ /\ / /
 | |_| | |_) |  __/ | | | |___| | (_| |\ V  V /
  \___/| .__/ \___|_| |_|\____|_|\__,_| \_/\_/
       |_|          Bootstrap Installer
BANNER
echo -e "${RESET}"

if $DRY_RUN; then
  warn "DRY-RUN MODE — no changes will be made\n"
fi

echo -e "Log: ${CYAN}$LOG_FILE${RESET}\n"

# =============================================================================
# SECTION 1: Pre-flight checks
# =============================================================================
section "Pre-flight Checks"

# Check Ubuntu 24.04
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "24.04" ]]; then
    warn "This script targets Ubuntu 24.04. Detected: ${ID} ${VERSION_ID}"
    read -rp "Continue anyway? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { error "Aborted."; exit 1; }
  else
    log "Ubuntu 24.04 confirmed"
  fi
else
  warn "Cannot detect OS. Proceeding anyway."
fi

# Check internet connectivity
if ! curl -sf --max-time 5 https://registry.npmjs.org/ > /dev/null; then
  error "No internet connectivity. Please check your network."
  exit 1
fi
log "Internet connectivity OK"

# Check existing SSH keys for current user (safety check before hardening)
SUDO_USER_HOME=""
if [[ -n "${SUDO_USER:-}" ]]; then
  SUDO_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi
ROOT_KEYS_EXIST=false
if [[ -f /root/.ssh/authorized_keys ]] && [[ -s /root/.ssh/authorized_keys ]]; then
  ROOT_KEYS_EXIST=true
fi

# =============================================================================
# SECTION 2: Create openclaw user
# =============================================================================
section "User Setup"

OPENCLAW_DIR="/home/${OPENCLAW_USER}/.openclaw"

if id "$OPENCLAW_USER" &>/dev/null; then
  log "User '${OPENCLAW_USER}' already exists"
else
  if $DRY_RUN; then
    dry "Create user '${OPENCLAW_USER}' with home directory"
  else
    useradd -m -s /bin/bash -c "OpenClaw AI Agent" "$OPENCLAW_USER"
    log "Created user '${OPENCLAW_USER}'"
  fi
fi

OPENCLAW_HOME=$(getent passwd "$OPENCLAW_USER" | cut -d: -f6 || echo "/home/${OPENCLAW_USER}")

# Enable lingering for user systemd (survives logout)
if $DRY_RUN; then
  dry "Enable systemd lingering for '${OPENCLAW_USER}'"
else
  loginctl enable-linger "$OPENCLAW_USER" 2>/dev/null || true
  log "Systemd lingering enabled for '${OPENCLAW_USER}'"
fi

# Create .openclaw config directory
if $DRY_RUN; then
  dry "mkdir -p ${OPENCLAW_HOME}/.openclaw/workspace"
else
  mkdir -p "${OPENCLAW_HOME}/.openclaw/workspace"
  chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "${OPENCLAW_HOME}/.openclaw"
  log "Created OpenClaw directories"
fi

# =============================================================================
# SECTION 3: System updates & dependencies
# =============================================================================
section "System Updates & Dependencies"

if $DRY_RUN; then
  dry "apt-get update && apt-get upgrade -y"
  dry "apt-get install -y curl git jq unzip ca-certificates gnupg"
else
  info "Updating package lists..."
  apt-get update -qq
  info "Installing system dependencies..."
  apt-get install -y -qq \
    curl git jq unzip ca-certificates gnupg \
    build-essential lsb-release software-properties-common \
    2>/dev/null
  log "System dependencies installed"
fi

# =============================================================================
# SECTION 4: Node.js 22.x via NodeSource
# =============================================================================
section "Node.js 22.x"

NODE_INSTALLED=false
if command -v node &>/dev/null; then
  NODE_VER=$(node --version 2>/dev/null | grep -oP '\d+' | head -1)
  if [[ "${NODE_VER:-0}" -ge 22 ]]; then
    log "Node.js $(node --version) already installed"
    NODE_INSTALLED=true
  else
    warn "Node.js $(node --version) found, need v22+. Will upgrade."
  fi
fi

if ! $NODE_INSTALLED; then
  if $DRY_RUN; then
    dry "Install Node.js 22.x via NodeSource"
  else
    info "Adding NodeSource repository for Node.js 22.x..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>/dev/null
    apt-get install -y -qq nodejs
    log "Node.js $(node --version) installed"
  fi
fi

# =============================================================================
# SECTION 5: Swap file
# =============================================================================
section "Swap File"

if $SKIP_SWAP; then
  info "Skipping swap (--skip-swap)"
elif swapon --show | grep -q .; then
  log "Swap already configured:"
  swapon --show
else
  SWAP_FILE="/swapfile"
  SWAP_SIZE_MB=$((SWAP_SIZE_GB * 1024))
  if $DRY_RUN; then
    dry "Create ${SWAP_SIZE_GB}GB swap at ${SWAP_FILE}"
  else
    info "Creating ${SWAP_SIZE_GB}GB swap file..."
    fallocate -l "${SWAP_SIZE_GB}G" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" -q
    swapon "$SWAP_FILE"
    # Persist across reboots
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
      echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
    fi
    # Tune swappiness for server workloads
    sysctl -w vm.swappiness=10 > /dev/null
    if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
      echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi
    log "Swap file created: ${SWAP_SIZE_GB}GB (swappiness=10)"
  fi
fi

# =============================================================================
# SECTION 6: Security Hardening
# =============================================================================
section "Security Hardening"

if $SKIP_HARDENING; then
  warn "Skipping security hardening (--skip-hardening)"
else

  # ── SSH Hardening ───────────────────────────────────────────────────────────
  info "Hardening SSH..."

  # Safety check: ensure we have a way back in
  if ! $ROOT_KEYS_EXIST && [[ -z "${SUDO_USER:-}" ]]; then
    warn "No SSH authorized_keys found for root."
    warn "Disabling password auth without a key could lock you out!"
    read -rp "Have you verified you have SSH key access? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || {
      warn "Skipping SSH hardening for safety."
      SKIP_SSH=true
    }
  fi

  SSHD_CONFIG="/etc/ssh/sshd_config"
  if [[ "${SKIP_SSH:-false}" != "true" ]]; then
    if $DRY_RUN; then
      dry "Set PasswordAuthentication no, PermitRootLogin no, PubkeyAuthentication yes"
    else
      # Backup original config
      cp -n "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d)" 2>/dev/null || true

      # Apply hardening settings
      sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
      sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
      sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"

      # Add settings if not present
      grep -q '^PasswordAuthentication' "$SSHD_CONFIG" || echo 'PasswordAuthentication no' >> "$SSHD_CONFIG"
      grep -q '^PermitRootLogin'        "$SSHD_CONFIG" || echo 'PermitRootLogin no'        >> "$SSHD_CONFIG"
      grep -q '^PubkeyAuthentication'   "$SSHD_CONFIG" || echo 'PubkeyAuthentication yes'  >> "$SSHD_CONFIG"

      # Validate config before reloading
      if sshd -t 2>/dev/null; then
        systemctl reload sshd
        log "SSH hardened: key-only auth, root login disabled"
      else
        error "sshd config test failed — restoring backup"
        cp "${SSHD_CONFIG}.bak.$(date +%Y%m%d)" "$SSHD_CONFIG"
      fi
    fi
  fi

  # ── UFW Firewall ─────────────────────────────────────────────────────────────
  info "Configuring UFW firewall..."
  if $DRY_RUN; then
    dry "ufw: allow SSH (22), deny all incoming, allow loopback"
  else
    if ! command -v ufw &>/dev/null; then
      apt-get install -y -qq ufw
    fi
    ufw --force reset > /dev/null
    ufw default deny incoming  > /dev/null
    ufw default allow outgoing > /dev/null
    ufw allow ssh               > /dev/null
    # Allow loopback for OpenClaw gateway (loopback-only by default)
    ufw allow in on lo           > /dev/null
    ufw --force enable           > /dev/null
    log "UFW enabled: SSH allowed, all other incoming denied"
  fi

  # ── fail2ban ─────────────────────────────────────────────────────────────────
  info "Installing fail2ban..."
  if $DRY_RUN; then
    dry "Install and configure fail2ban for SSH protection"
  else
    apt-get install -y -qq fail2ban
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
EOF
    systemctl enable --now fail2ban > /dev/null
    log "fail2ban installed and configured"
  fi

  # ── Unattended Upgrades ───────────────────────────────────────────────────────
  info "Enabling unattended security upgrades..."
  if $DRY_RUN; then
    dry "Install unattended-upgrades and enable automatic security patches"
  else
    apt-get install -y -qq unattended-upgrades update-notifier-common
    dpkg-reconfigure -plow unattended-upgrades <<< $'1\n' 2>/dev/null || \
      printf '1\n' | dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
    log "Unattended security upgrades enabled"
  fi

fi  # end SKIP_HARDENING

# =============================================================================
# SECTION 7: Install OpenClaw
# =============================================================================
section "Installing OpenClaw"

if command -v openclaw &>/dev/null; then
  CURRENT_VER=$(openclaw --version 2>/dev/null || echo "unknown")
  log "OpenClaw already installed: ${CURRENT_VER}"
  read -rp "Reinstall/upgrade? [y/N] " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    if $DRY_RUN; then
      dry "npm install -g openclaw"
    else
      npm install -g openclaw
      log "OpenClaw updated: $(openclaw --version 2>/dev/null)"
    fi
  fi
else
  if $DRY_RUN; then
    dry "npm install -g openclaw"
  else
    info "Installing OpenClaw from npm..."
    npm install -g openclaw
    log "OpenClaw installed: $(openclaw --version 2>/dev/null)"
  fi
fi

# =============================================================================
# SECTION 8: API Keys & Environment
# =============================================================================
section "API Keys & Environment"

ENV_FILE="${OPENCLAW_HOME}/.openclaw/.env"

if [[ -f "$ENV_FILE" ]]; then
  log ".env file already exists at ${ENV_FILE}"
  read -rp "Re-configure API keys? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { info "Skipping key configuration."; SKIP_KEYS=true; }
fi

if [[ "${SKIP_KEYS:-false}" != "true" ]]; then
  echo ""
  echo -e "${BOLD}Enter your API keys (press Enter to skip optional ones):${RESET}"
  echo ""

  # Required
  while true; do
    read -rsp "  ANTHROPIC_API_KEY (required, starts with sk-ant-): " ANTHROPIC_KEY
    echo ""
    if [[ -n "$ANTHROPIC_KEY" ]]; then
      break
    fi
    warn "Anthropic API key is required for OpenClaw to function."
  done

  # Optional keys
  read -rsp "  OPENROUTER_API_KEY (optional, for Qwen/other models): " OPENROUTER_KEY; echo ""
  read -rsp "  OPENAI_API_KEY (optional, for Whisper/embeddings): " OPENAI_KEY; echo ""
  read -rsp "  MINIMAX_API_KEY (optional): " MINIMAX_KEY; echo ""

  # Generate gateway token if not provided
  GATEWAY_TOKEN=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p | tr -d '\n')

  if $DRY_RUN; then
    dry "Write API keys to ${ENV_FILE}"
  else
    mkdir -p "$(dirname "$ENV_FILE")"
    cat > "$ENV_FILE" <<ENVFILE
# OpenClaw Environment Variables
# Generated by bootstrap.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Keep this file private — never commit to version control

ANTHROPIC_API_KEY=${ANTHROPIC_KEY}
OPENROUTER_API_KEY=${OPENROUTER_KEY:-}
OPENAI_API_KEY=${OPENAI_KEY:-}
MINIMAX_API_KEY=${MINIMAX_KEY:-}

# Gateway authentication token (auto-generated)
# Used by clients connecting to the OpenClaw gateway
GATEWAY_AUTH_TOKEN=${GATEWAY_TOKEN}
ENVFILE
    chmod 600 "$ENV_FILE"
    chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "$ENV_FILE"
    log "API keys saved to ${ENV_FILE}"
    echo -e "\n  ${YELLOW}Gateway Token:${RESET} ${GATEWAY_TOKEN}"
    echo -e "  ${YELLOW}Save this — you'll need it to connect clients.${RESET}\n"
  fi
fi

# =============================================================================
# SECTION 9: OpenClaw Configuration
# =============================================================================
section "OpenClaw Configuration"

CONFIG_FILE="${OPENCLAW_HOME}/.openclaw/openclaw.json"

if [[ -f "$CONFIG_FILE" ]]; then
  log "openclaw.json already exists"
  read -rp "Overwrite with template? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { info "Keeping existing config."; SKIP_CONFIG=true; }
fi

if [[ "${SKIP_CONFIG:-false}" != "true" ]]; then
  TEMPLATE_FILE="${SCRIPT_DIR}/openclaw.template.json"
  if [[ ! -f "$TEMPLATE_FILE" ]]; then
    warn "Template not found at ${TEMPLATE_FILE} — downloading..."
    if $DRY_RUN; then
      dry "Download openclaw.template.json"
    else
      curl -fsSL "https://raw.githubusercontent.com/YOUR_ORG/openclaw-bootstrap/main/openclaw.template.json" \
        -o "$TEMPLATE_FILE" 2>/dev/null || {
          error "Could not download template. Please provide openclaw.template.json manually."
          exit 1
        }
    fi
  fi

  if $DRY_RUN; then
    dry "Copy template to ${CONFIG_FILE}"
  else
    cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "$CONFIG_FILE"
    log "OpenClaw config written to ${CONFIG_FILE}"
    info "Edit ${CONFIG_FILE} to customize your setup."
  fi
fi

# Copy workspace templates if present
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
WORKSPACE_DIR="${OPENCLAW_HOME}/.openclaw/workspace"

if [[ -d "$TEMPLATES_DIR" ]]; then
  if $DRY_RUN; then
    dry "Copy workspace templates to ${WORKSPACE_DIR}"
  else
    for tmpl in "${TEMPLATES_DIR}"/*.example; do
      [[ -f "$tmpl" ]] || continue
      dest="${WORKSPACE_DIR}/$(basename "${tmpl%.example}")"
      if [[ ! -f "$dest" ]]; then
        cp "$tmpl" "$dest"
        info "  Copied template: $(basename "$dest")"
      fi
    done
    chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "$WORKSPACE_DIR"
    log "Workspace templates installed"
  fi
fi

# =============================================================================
# SECTION 10: Systemd User Service
# =============================================================================
section "Systemd User Service"

SERVICE_DIR="${OPENCLAW_HOME}/.config/systemd/user"
SERVICE_FILE="${SERVICE_DIR}/openclaw-gateway.service"

if $DRY_RUN; then
  dry "Create systemd user service at ${SERVICE_FILE}"
else
  mkdir -p "$SERVICE_DIR"

  cat > "$SERVICE_FILE" <<SYSTEMD
[Unit]
Description=OpenClaw Gateway
Documentation=https://openclaw.dev
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${OPENCLAW_HOME}/.openclaw/.env
ExecStart=$(command -v openclaw) gateway start --foreground
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

# Hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
SYSTEMD

  chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "$SERVICE_DIR"

  # Reload and enable as the openclaw user
  export XDG_RUNTIME_DIR="/run/user/$(id -u "$OPENCLAW_USER")"
  sudo -u "$OPENCLAW_USER" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus" \
    systemctl --user daemon-reload 2>/dev/null || true

  sudo -u "$OPENCLAW_USER" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    systemctl --user enable openclaw-gateway 2>/dev/null || true

  log "Systemd user service installed and enabled"
fi

# =============================================================================
# SECTION 11: Start OpenClaw Gateway
# =============================================================================
section "Starting OpenClaw Gateway"

if $DRY_RUN; then
  dry "Start openclaw-gateway service as user '${OPENCLAW_USER}'"
else
  UID_OPENCLAW=$(id -u "$OPENCLAW_USER")
  XDG_RUNTIME_DIR="/run/user/${UID_OPENCLAW}"

  # Ensure runtime dir exists (lingering might not be active yet)
  if [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
    warn "XDG_RUNTIME_DIR not yet available. You may need to log in as '${OPENCLAW_USER}' to start the service."
    info "Manual start: sudo -u ${OPENCLAW_USER} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} systemctl --user start openclaw-gateway"
  else
    sudo -u "$OPENCLAW_USER" \
      XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
      systemctl --user start openclaw-gateway 2>/dev/null && \
      log "OpenClaw gateway started" || \
      warn "Service start failed — try: sudo -u ${OPENCLAW_USER} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} systemctl --user start openclaw-gateway"
  fi
fi

# =============================================================================
# SECTION 12: Optional — Tailscale
# =============================================================================
section "Tailscale (Optional)"

read -rp "Install Tailscale for secure remote access? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  if command -v tailscale &>/dev/null; then
    log "Tailscale already installed: $(tailscale --version | head -1)"
  elif $DRY_RUN; then
    dry "Install Tailscale via install.tailscale.com"
  else
    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    log "Tailscale installed"
    echo ""
    info "Run the following to authenticate:"
    echo -e "  ${CYAN}sudo tailscale up${RESET}"
  fi
fi

# =============================================================================
# SECTION 13: Optional — Maintenance Cron Jobs
# =============================================================================
section "Maintenance Cron Jobs (Optional)"

echo ""
echo "The following optional cron jobs are available:"
echo "  1) Git workspace sync (every 6 hours)"
echo "  2) Restic backup (nightly at 03:00 UTC)"
echo ""
read -rp "Install maintenance cron job templates? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  CRON_DIR="${OPENCLAW_HOME}/.openclaw/scripts"
  if $DRY_RUN; then
    dry "Copy maintenance scripts to ${CRON_DIR}"
  else
    mkdir -p "$CRON_DIR"

    # Copy from templates if available
    if [[ -d "${SCRIPT_DIR}/templates/scripts" ]]; then
      cp "${SCRIPT_DIR}/templates/scripts/"*.sh "$CRON_DIR/" 2>/dev/null || true
      chmod +x "${CRON_DIR}/"*.sh 2>/dev/null || true
      chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "$CRON_DIR"
    fi

    log "Maintenance scripts copied to ${CRON_DIR}"
    echo ""
    warn "To enable, add to crontab with: sudo -u ${OPENCLAW_USER} crontab -e"
    echo ""
    echo "  # Git workspace sync every 6 hours"
    echo "  0 */6 * * * ${CRON_DIR}/git-sync.sh >> /home/${OPENCLAW_USER}/.openclaw/logs/git-sync.log 2>&1"
    echo ""
    echo "  # Restic backup nightly at 03:00 UTC"
    echo "  0 3 * * * ${CRON_DIR}/restic-backup.sh >> /home/${OPENCLAW_USER}/.openclaw/logs/backup.log 2>&1"
  fi
fi

# =============================================================================
# DONE
# =============================================================================
section "Bootstrap Complete"

echo ""
echo -e "${GREEN}${BOLD}OpenClaw has been bootstrapped successfully!${RESET}"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo ""
echo "  1. ${CYAN}Edit your config:${RESET}"
echo "       ${OPENCLAW_HOME}/.openclaw/openclaw.json"
echo ""
echo "  2. ${CYAN}Connect a messaging channel:${RESET}"
echo "       openclaw channel add telegram   # or discord, slack, etc."
echo ""
echo "  3. ${CYAN}Set up your workspace files:${RESET}"
echo "       ${OPENCLAW_HOME}/.openclaw/workspace/"
echo "       Edit SOUL.md, AGENTS.md, USER.md to personalize your assistant"
echo ""
echo "  4. ${CYAN}Check gateway status:${RESET}"
echo "       sudo -u ${OPENCLAW_USER} XDG_RUNTIME_DIR=/run/user/\$(id -u ${OPENCLAW_USER}) systemctl --user status openclaw-gateway"
echo ""
echo "  5. ${CYAN}View logs:${RESET}"
echo "       sudo -u ${OPENCLAW_USER} journalctl --user -u openclaw-gateway -f"
echo ""
echo -e "${YELLOW}Full log saved to: ${LOG_FILE}${RESET}"
echo ""
