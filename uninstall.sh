#!/usr/bin/env bash
# =============================================================================
# OpenClaw Uninstall Script
# Cleanly removes OpenClaw from a system installed via bootstrap.sh
# =============================================================================
# Usage: sudo bash uninstall.sh [--purge] [--keep-data] [--user NAME]
#
# Options:
#   --purge      Also remove Node.js, UFW, fail2ban (system-level tools)
#   --keep-data  Preserve ~/.openclaw data (keys, workspace, logs)
#   --user NAME  OpenClaw user to remove (default: openclaw)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${GREEN}[✓]${RESET} $*"; }
info()    { echo -e "${BLUE}[→]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; }
section() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}"; }

PURGE=false
KEEP_DATA=false
OPENCLAW_USER="openclaw"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge)     PURGE=true ;;
    --keep-data) KEEP_DATA=true ;;
    --user)      OPENCLAW_USER="$2"; shift ;;
    *) warn "Unknown option: $1" ;;
  esac
  shift
done

if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root (use sudo)."
  exit 1
fi

echo -e "${BOLD}${RED}"
echo "  OpenClaw Uninstaller"
echo -e "${RESET}"
warn "This will remove OpenClaw from your system."
[[ "$KEEP_DATA" == "false" ]] && warn "All data in ~/.openclaw will be PERMANENTLY DELETED."
echo ""
read -rp "Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

# =============================================================================
section "Stopping Services"
# =============================================================================

if id "$OPENCLAW_USER" &>/dev/null; then
  UID_OPENCLAW=$(id -u "$OPENCLAW_USER" 2>/dev/null || echo "")
  if [[ -n "$UID_OPENCLAW" ]]; then
    XDG_RUNTIME_DIR="/run/user/${UID_OPENCLAW}"
    sudo -u "$OPENCLAW_USER" \
      XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
      systemctl --user stop openclaw-gateway 2>/dev/null && log "Gateway service stopped" || true
    sudo -u "$OPENCLAW_USER" \
      XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
      systemctl --user disable openclaw-gateway 2>/dev/null || true
  fi
fi
log "Services stopped"

# =============================================================================
section "Removing Systemd Service"
# =============================================================================

if id "$OPENCLAW_USER" &>/dev/null; then
  OPENCLAW_HOME=$(getent passwd "$OPENCLAW_USER" | cut -d: -f6)
  SERVICE_FILE="${OPENCLAW_HOME}/.config/systemd/user/openclaw-gateway.service"
  if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    log "Systemd service file removed"
  fi
fi

# =============================================================================
section "Removing OpenClaw npm Package"
# =============================================================================

if command -v openclaw &>/dev/null; then
  npm uninstall -g openclaw 2>/dev/null && log "OpenClaw npm package removed" || warn "Could not remove npm package"
else
  info "OpenClaw not found in PATH"
fi

# =============================================================================
section "Disabling Lingering"
# =============================================================================

if id "$OPENCLAW_USER" &>/dev/null; then
  loginctl disable-linger "$OPENCLAW_USER" 2>/dev/null || true
  log "Systemd lingering disabled"
fi

# =============================================================================
section "Removing User Data"
# =============================================================================

if $KEEP_DATA; then
  info "Keeping data (--keep-data). Files preserved."
else
  if id "$OPENCLAW_USER" &>/dev/null; then
    OPENCLAW_HOME=$(getent passwd "$OPENCLAW_USER" | cut -d: -f6)
    if [[ -d "${OPENCLAW_HOME}/.openclaw" ]]; then
      rm -rf "${OPENCLAW_HOME}/.openclaw"
      log "Removed ${OPENCLAW_HOME}/.openclaw"
    fi
  fi
fi

# =============================================================================
section "Removing System User"
# =============================================================================

if id "$OPENCLAW_USER" &>/dev/null; then
  read -rp "Delete system user '${OPENCLAW_USER}' and home directory? [y/N] " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    userdel -r "$OPENCLAW_USER" 2>/dev/null || userdel "$OPENCLAW_USER" 2>/dev/null || true
    log "User '${OPENCLAW_USER}' removed"
  else
    info "User '${OPENCLAW_USER}' kept"
  fi
fi

# =============================================================================
section "Optional: Remove System Tools"
# =============================================================================

if $PURGE; then
  warn "Purging system-level tools (Node.js, UFW, fail2ban)..."
  read -rp "This may affect other applications. Continue? [y/N] " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    apt-get remove --purge -y nodejs fail2ban 2>/dev/null || true
    log "System tools removed"
    warn "UFW was NOT removed automatically — disable manually if needed: ufw disable"
  fi
else
  info "System tools (Node.js, UFW, fail2ban) kept. Use --purge to remove them."
fi

# =============================================================================
section "Done"
# =============================================================================

echo ""
log "OpenClaw has been uninstalled."
if $KEEP_DATA; then
  info "Data preserved at: $(getent passwd "$OPENCLAW_USER" 2>/dev/null | cut -d: -f6 || echo "~")/.openclaw"
fi
echo ""
