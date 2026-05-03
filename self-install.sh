#!/usr/bin/env bash
# =============================================================================
# OpenClaw Self-Installer — Mode B (runs ON the hardened box as deployer)
# =============================================================================
# Usage:
#   ./self-install.sh [OPTIONS]
#
# Options:
#   --dry-run       Show what would happen without executing
#   --skip-verify   Skip Phase 0 hardening verification
#   --skip-extras   Skip Phase 6 optional extras (FAISS, cost tracking, Streamlit)
#   --help          Show this help
#
# Prerequisites:
#   - Ubuntu 24.04 LTS already hardened per Setup_claudeCode_v2.md
#   - Running as 'deployer' user (has sudo)
#   - SSH on port 2222, Tailscale connected, nginx+TLS, Docker, fail2ban all up
#
# Exit codes:
#   0 = success
#   1 = verification failed (Phase 0)
#   2 = install failed (Phase 1+)
#
# All output is logged to /var/log/openclaw/self-install.log
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONSTANTS & FLAGS
# =============================================================================

SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/openclaw/self-install.log"
OPENCLAW_HOME="/home/openclaw/.openclaw"
OPENCLAW_USER="openclaw"
DEPLOYER_USER="deployer"
WORKSPACE_DIR="${OPENCLAW_HOME}/workspace"
ENV_FILE="${OPENCLAW_HOME}/.env"
OPENCLAW_JSON="${OPENCLAW_HOME}/openclaw.json"

DRY_RUN=false
SKIP_VERIFY=false
SKIP_EXTRAS=false
VERIFICATION_FAILURES=()

# =============================================================================
# COLORS
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# =============================================================================
# LOGGING
# =============================================================================

# Ensure log directory exists (may not exist yet at start)
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

exec > >(tee -a "${LOG_FILE}") 2>&1

log_info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[PASS]${RESET}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${RESET}  $*"; }
log_step()  { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════${RESET}"; \
               echo -e "${BOLD}${BLUE}  $*${RESET}"; \
               echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════${RESET}"; }
log_dry()   { echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; }

run() {
    # Execute a command, respecting --dry-run
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_dry "Would run: $*"
        return 0
    fi
    "$@"
}

run_as_openclaw() {
    # Run a command as the openclaw user
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_dry "Would run as ${OPENCLAW_USER}: $*"
        return 0
    fi
    sudo -u "${OPENCLAW_USER}" -i bash -c "$*"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

usage() {
    cat <<EOF
OpenClaw Self-Installer v${SCRIPT_VERSION} — Mode B

Usage: $(basename "$0") [OPTIONS]

Options:
  --dry-run       Show what would happen without executing
  --skip-verify   Skip Phase 0 hardening verification
  --skip-extras   Skip Phase 6 optional extras
  --help          Show this help

Run as 'deployer' user on a pre-hardened Lightsail Ubuntu 24.04 box.
Logs to: ${LOG_FILE}
EOF
    exit 0
}

for arg in "$@"; do
    case "${arg}" in
        --dry-run)     DRY_RUN=true ;;
        --skip-verify) SKIP_VERIFY=true ;;
        --skip-extras) SKIP_EXTRAS=true ;;
        --help|-h)     usage ;;
        *) log_warn "Unknown argument: ${arg}"; ;;
    esac
done

# =============================================================================
# PREFLIGHT
# =============================================================================

preflight_checks() {
    log_step "Preflight: Sanity Checks"

    if [[ "${EUID}" -eq 0 ]]; then
        log_fail "Do NOT run as root. Run as 'deployer' user."
        exit 2
    fi

    if [[ "$(whoami)" != "${DEPLOYER_USER}" ]]; then
        log_warn "Expected to run as '${DEPLOYER_USER}', but running as '$(whoami)'. Continuing..."
    fi

    if ! sudo -n true 2>/dev/null; then
        log_fail "This script requires passwordless sudo (or you need to enter your sudo password)."
        log_info "Tip: run 'sudo -v' first to cache credentials."
        exit 2
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warn "DRY-RUN MODE — no changes will be made."
    fi

    log_ok "Preflight passed. Running as $(whoami) with sudo access."
    log_info "Logging to: ${LOG_FILE}"
    echo ""
}

# =============================================================================
# HELPER: ask yes/no
# =============================================================================

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer
    if [[ "${default}" == "y" ]]; then
        read -rp "${prompt} [Y/n] " answer
        answer="${answer:-y}"
    else
        read -rp "${prompt} [y/N] " answer
        answer="${answer:-n}"
    fi
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# =============================================================================
# HELPER: check a condition and record result
# =============================================================================

check() {
    local description="$1"
    local result="$2"  # "pass" or "fail"
    local detail="${3:-}"

    if [[ "${result}" == "pass" ]]; then
        log_ok "${description}"
    else
        log_fail "${description}${detail:+ — ${detail}}"
        VERIFICATION_FAILURES+=("${description}${detail:+: ${detail}}")
    fi
}

# =============================================================================
# PHASE 0: VERIFY HARDENED ENVIRONMENT
# =============================================================================

phase0_verify() {
    log_step "Phase 0: Verify Hardened Environment"

    if [[ "${SKIP_VERIFY}" == "true" ]]; then
        log_warn "--skip-verify set. Skipping Phase 0 verification."
        return 0
    fi

    VERIFICATION_FAILURES=()

    # ─── 1.1 System Baseline ──────────────────────────────────────────────────

    log_info "1.1 System Baseline"

    local os_desc
    os_desc=$(lsb_release -d 2>/dev/null | cut -f2-)
    if echo "${os_desc}" | grep -q "Ubuntu 24.04"; then
        check "Ubuntu 24.04" "pass"
    else
        check "Ubuntu 24.04" "fail" "Got: ${os_desc}"
    fi

    local tz
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || timedatectl | grep "Time zone" | awk '{print $3}')
    if [[ "${tz}" == "UTC" ]]; then
        check "Timezone is UTC" "pass"
    else
        check "Timezone is UTC" "fail" "Got: ${tz}"
    fi

    # ─── 1.2 User Accounts ────────────────────────────────────────────────────

    log_info "1.2 User Accounts"

    if id deployer &>/dev/null; then
        if id deployer | grep -q "sudo\|wheel"; then
            check "deployer user exists (sudo group)" "pass"
        else
            check "deployer user exists (sudo group)" "fail" "not in sudo group"
        fi
    else
        check "deployer user exists (sudo group)" "fail" "user not found"
    fi

    if id openclaw &>/dev/null; then
        check "openclaw service user exists" "pass"
    else
        check "openclaw service user exists" "fail"
    fi

    local ubuntu_shell
    ubuntu_shell=$(getent passwd ubuntu 2>/dev/null | cut -d: -f7 || echo "user-not-found")
    if [[ "${ubuntu_shell}" == "/bin/bash" ]]; then
        check "ubuntu user shell is /bin/bash (not nologin)" "pass"
    else
        check "ubuntu user shell is /bin/bash" "fail" "Got: ${ubuntu_shell}"
    fi

    local ubuntu_shadow
    ubuntu_shadow=$(sudo grep "^ubuntu:" /etc/shadow 2>/dev/null | cut -d: -f2 || echo "")
    if [[ "${ubuntu_shadow}" == !* ]]; then
        check "ubuntu user password locked (shadow starts with !)" "pass"
    else
        check "ubuntu user password locked" "fail" "shadow entry: ${ubuntu_shadow:0:3}..."
    fi

    # ─── 1.3 SSH Hardening ────────────────────────────────────────────────────

    log_info "1.3 SSH Hardening"

    if sudo ss -tlnp 2>/dev/null | grep -q ":2222"; then
        check "SSH listening on port 2222" "pass"
    else
        check "SSH listening on port 2222" "fail"
    fi

    if sudo ss -tlnp 2>/dev/null | grep -q ":22 "; then
        check "SSH NOT on port 22" "fail" "Port 22 is open — security risk"
    else
        check "SSH NOT on port 22" "pass"
    fi

    local socket_state
    socket_state=$(sudo systemctl is-enabled ssh.socket 2>/dev/null || echo "unknown")
    if [[ "${socket_state}" == "masked" ]]; then
        check "ssh.socket is masked" "pass"
    else
        check "ssh.socket is masked" "fail" "State: ${socket_state}"
    fi

    local ssh_service_state
    ssh_service_state=$(sudo systemctl is-active ssh 2>/dev/null || echo "inactive")
    if [[ "${ssh_service_state}" == "active" ]]; then
        check "ssh service is active" "pass"
    else
        check "ssh service is active" "fail" "State: ${ssh_service_state}"
    fi

    if [[ -f /etc/cron.d/ssh-watchdog ]]; then
        if grep -q "@reboot" /etc/cron.d/ssh-watchdog 2>/dev/null; then
            check "ssh-watchdog cron present (@reboot)" "pass"
        else
            check "ssh-watchdog cron present (@reboot)" "fail" "file exists but no @reboot entry"
        fi
    else
        check "ssh-watchdog cron present" "fail" "/etc/cron.d/ssh-watchdog not found"
    fi

    # ─── 1.4 Firewall ─────────────────────────────────────────────────────────

    log_info "1.4 Firewall"

    local ufw_status
    ufw_status=$(sudo ufw status 2>/dev/null || echo "")

    if echo "${ufw_status}" | grep -q "2222"; then
        check "UFW has port 2222 rule" "pass"
    else
        check "UFW has port 2222 rule" "fail"
    fi

    if echo "${ufw_status}" | grep "2222" | grep -q "100.64.0.0/10\|Tailscale"; then
        check "UFW port 2222 restricted to 100.64.0.0/10" "pass"
    else
        log_warn "UFW port 2222 restriction: could not confirm 100.64.0.0/10 limit (may still be Lightsail-level only)"
    fi

    if echo "${ufw_status}" | grep -q "^22 \|^22/"; then
        check "UFW port 22 NOT open" "fail" "Port 22 found in UFW rules"
    else
        check "UFW port 22 NOT open" "pass"
    fi

    # ─── 1.5 Services ─────────────────────────────────────────────────────────

    log_info "1.5 Required Services"

    for svc in nginx fail2ban docker tailscaled unattended-upgrades; do
        local state
        state=$(sudo systemctl is-active "${svc}" 2>/dev/null || echo "inactive")
        if [[ "${state}" == "active" ]]; then
            check "Service ${svc} is active" "pass"
        else
            check "Service ${svc} is active" "fail" "State: ${state}"
        fi
    done

    # ─── 1.6 nginx and TLS ────────────────────────────────────────────────────

    log_info "1.6 nginx + TLS"

    if sudo nginx -t 2>/dev/null; then
        check "nginx config syntax OK" "pass"
    else
        check "nginx config syntax OK" "fail"
    fi

    # TLS cert check
    if sudo certbot certificates 2>/dev/null | grep -q "VALID"; then
        check "Let's Encrypt certificate valid" "pass"
    elif sudo certbot certificates 2>/dev/null | grep -q "EXPIRED"; then
        check "Let's Encrypt certificate valid" "fail" "Certificate is EXPIRED"
    else
        log_warn "Could not verify TLS certificate status via certbot (may not be configured yet or certbot not installed)"
    fi

    # ─── 1.7 Docker ───────────────────────────────────────────────────────────

    log_info "1.7 Docker"

    if docker --version &>/dev/null; then
        check "Docker installed" "pass"
    else
        check "Docker installed" "fail"
    fi

    if sudo docker network ls 2>/dev/null | grep -q "openclaw-sandbox"; then
        check "Docker openclaw-sandbox network exists" "pass"
    else
        check "Docker openclaw-sandbox network exists" "fail"
    fi

    # ─── 1.8 Directories & Permissions ───────────────────────────────────────

    log_info "1.8 Directories + Permissions"

    if [[ -d /var/log/openclaw ]]; then
        local logdir_owner
        logdir_owner=$(stat -c '%U:%G' /var/log/openclaw 2>/dev/null || echo "unknown")
        local logdir_perms
        logdir_perms=$(stat -c '%a' /var/log/openclaw 2>/dev/null || echo "000")
        if [[ "${logdir_owner}" == "openclaw:openclaw" ]]; then
            check "/var/log/openclaw owned by openclaw:openclaw" "pass"
        else
            check "/var/log/openclaw owned by openclaw:openclaw" "fail" "Owner: ${logdir_owner}"
        fi
        if [[ "${logdir_perms}" == "750" ]]; then
            check "/var/log/openclaw permissions 750" "pass"
        else
            log_warn "/var/log/openclaw permissions are ${logdir_perms} (expected 750)"
        fi
    else
        check "/var/log/openclaw directory exists" "fail"
    fi

    for f in /var/lib/aide/aide.db /usr/local/bin/openclaw-backup /usr/local/bin/ssh-watchdog; do
        if [[ -e "${f}" ]]; then
            check "${f} exists" "pass"
        else
            check "${f} exists" "fail"
        fi
    done

    # ─── 1.9 Tailscale ────────────────────────────────────────────────────────

    log_info "1.9 Tailscale"

    if tailscale status 2>/dev/null | grep -q "100\."; then
        check "Tailscale connected" "pass"
    else
        check "Tailscale connected" "fail" "No 100.x.x.x address found"
    fi

    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    if [[ "${ts_ip}" =~ ^100\. ]]; then
        check "Tailscale IP in range 100.x.x.x (${ts_ip})" "pass"
    else
        check "Tailscale has valid 100.x.x.x IP" "fail" "Got: ${ts_ip}"
    fi

    # ─── Verdict ──────────────────────────────────────────────────────────────

    echo ""
    if [[ ${#VERIFICATION_FAILURES[@]} -eq 0 ]]; then
        log_ok "All Phase 0 verification checks passed."
    else
        log_warn "${#VERIFICATION_FAILURES[@]} verification check(s) failed:"
        for failure in "${VERIFICATION_FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} ${failure}"
        done
        echo ""
        if ! ask_yes_no "Some hardening checks failed. Continue anyway?"; then
            log_fail "Aborting on verification failure."
            exit 1
        fi
        log_warn "Continuing despite verification failures. Fix these before going to production."
    fi
}

# =============================================================================
# PHASE 1: INSTALL NODE.JS + OPENCLAW
# =============================================================================

phase1_install_openclaw() {
    log_step "Phase 1: Install Node.js + OpenClaw"

    # ─── 1.1 Node.js 22 ───────────────────────────────────────────────────────

    log_info "1.1 Checking Node.js..."

    local node_ver
    node_ver=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")

    if [[ "${node_ver}" -ge 22 ]]; then
        log_ok "Node.js $(node --version) already installed. Skipping."
    else
        log_info "Installing Node.js 22 via NodeSource..."
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_dry "Would run NodeSource setup_22.x and apt install nodejs"
        else
            curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
            sudo apt install -y nodejs
            node_ver=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
            if [[ "${node_ver}" -lt 22 ]]; then
                log_fail "Node.js 22+ installation failed. Got version: $(node --version 2>/dev/null || echo 'none')"
                exit 2
            fi
            log_ok "Node.js $(node --version) installed."
        fi
    fi

    # ─── 1.2 OpenClaw global install ──────────────────────────────────────────

    log_info "1.2 Checking OpenClaw..."

    local openclaw_ver
    openclaw_ver=$(openclaw --version 2>/dev/null || echo "")

    if [[ -n "${openclaw_ver}" ]]; then
        log_ok "OpenClaw ${openclaw_ver} already installed."
        if ask_yes_no "  Reinstall/upgrade OpenClaw to latest?"; then
            run sudo npm install -g openclaw@latest
        fi
    else
        log_info "Installing OpenClaw globally..."
        run sudo npm install -g openclaw@latest
        if [[ "${DRY_RUN}" != "true" ]]; then
            openclaw_ver=$(openclaw --version 2>/dev/null || echo "unknown")
            log_ok "OpenClaw ${openclaw_ver} installed."
        fi
    fi

    # ─── 1.3 Onboard (as openclaw user) ───────────────────────────────────────

    log_info "1.3 OpenClaw onboard --install-daemon (as ${OPENCLAW_USER})"

    local daemon_active
    daemon_active=$(sudo -u "${OPENCLAW_USER}" systemctl --user is-active openclaw-gateway 2>/dev/null || echo "inactive")

    if [[ "${daemon_active}" == "active" ]]; then
        log_ok "openclaw-gateway daemon already active. Skipping onboard."
    else
        log_info "Running 'openclaw onboard --install-daemon' as openclaw user..."
        if [[ "${DRY_RUN}" != "true" ]]; then
            sudo -u "${OPENCLAW_USER}" -i bash -c "openclaw onboard --install-daemon" || {
                log_fail "openclaw onboard failed."
                exit 2
            }
        else
            log_dry "Would run: sudo -u openclaw -i openclaw onboard --install-daemon"
        fi
    fi

    # ─── 1.4 Enable linger ────────────────────────────────────────────────────

    log_info "1.4 Enabling linger for openclaw user..."
    run sudo loginctl enable-linger "${OPENCLAW_USER}"
    log_ok "Linger enabled."

    # ─── 1.5 Verify gateway binding ───────────────────────────────────────────

    log_info "1.5 Verifying gateway binds to 127.0.0.1:18789 only..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        # Give it a moment to start
        sleep 3
        local gateway_listen
        gateway_listen=$(sudo -u "${OPENCLAW_USER}" -i bash -c "ss -tlnp 2>/dev/null | grep 18789" || echo "")
        if echo "${gateway_listen}" | grep -q "127.0.0.1:18789"; then
            log_ok "Gateway listening on 127.0.0.1:18789 (loopback only)."
        elif echo "${gateway_listen}" | grep -q "0.0.0.0:18789"; then
            log_fail "SECURITY: Gateway bound to 0.0.0.0:18789 — must be loopback only!"
            log_warn "Fix: openclaw config set gateway.bind 'ws://127.0.0.1:18789'"
            exit 2
        elif [[ -z "${gateway_listen}" ]]; then
            log_warn "Gateway not yet listening on 18789 — may still be starting up."
        else
            log_warn "Gateway listen state: ${gateway_listen}"
        fi
    fi

    # ─── 1.6 Security hardening ───────────────────────────────────────────────

    log_info "1.6 Applying OpenClaw security hardening..."

    local hardening_cmds=(
        # Sandbox — most dangerous default
        "openclaw config set sandbox.mode all"
        "openclaw config set sandbox.workspaceAccess none"
        "openclaw config set sandbox.network none"
        "openclaw config set sandbox.docker.enabled true"
        "openclaw config set sandbox.docker.network openclaw-sandbox"
        # ClawHub — disable auto-install
        "openclaw config set clawhub.autoInstall false"
        "openclaw config set clawhub.autoUpdate false"
        "openclaw config set clawhub.allowUntrusted false"
        # Gateway auth
        "openclaw config set gateway.auth.mode token"
        "openclaw config set gateway.auth.token '\${env:GATEWAY_AUTH_TOKEN}'"
        "openclaw config set gateway.bind 'ws://127.0.0.1:18789'"
        "openclaw config set gateway.dangerouslyDisableDeviceAuth false"
        # Agent restrictions
        "openclaw config set agents.defaults.maxConcurrent 4"
        "openclaw config set agents.defaults.subagents.maxConcurrent 8"
        "openclaw config set agents.defaults.tools.allowShell false"
        "openclaw config set agents.defaults.tools.allowFileWrite false"
        "openclaw config set agents.defaults.tools.allowNetworkAccess false"
        # Disable unused channels
        "openclaw config set channels.discord.enabled false"
        "openclaw config set channels.slack.enabled false"
        "openclaw config set channels.whatsapp.enabled false"
        # Compaction
        "openclaw config set agents.defaults.compaction.mode safeguard"
        "openclaw config set agents.defaults.compaction.warnAt 80"
        "openclaw config set agents.defaults.compaction.strategy summarize"
    )

    for cmd in "${hardening_cmds[@]}"; do
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_dry "Would run as openclaw: ${cmd}"
        else
            sudo -u "${OPENCLAW_USER}" -i bash -c "${cmd}" || log_warn "Command failed (may not exist in this version): ${cmd}"
        fi
    done

    log_ok "Security hardening applied."

    # Security audit
    log_info "Running OpenClaw security audit..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        sudo -u "${OPENCLAW_USER}" -i bash -c \
            "openclaw security audit --deep 2>&1 | tee ~/security-audit.log; grep -E '(CRITICAL|WARNING|FAIL)' ~/security-audit.log || true" \
            2>/dev/null || log_warn "Security audit command not available in this version."
    fi

    log_ok "Phase 1 complete."
}

# =============================================================================
# PHASE 2: API KEYS + SECRETS
# =============================================================================

phase2_api_keys() {
    log_step "Phase 2: API Keys + Secrets"

    log_info "You will be prompted for each API key."
    log_info "Keys are written to ${ENV_FILE} with 600 permissions."
    log_info "Nothing is logged or echoed — values are kept secret."
    echo ""

    # Ensure .env exists with correct perms
    if [[ "${DRY_RUN}" != "true" ]]; then
        sudo -u "${OPENCLAW_USER}" -i bash -c "touch ~/.openclaw/.env && chmod 600 ~/.openclaw/.env"
    fi

    # Helper: prompt for a key, skip if already set
    prompt_key() {
        local var_name="$1"
        local display_name="$2"
        local hint="${3:-}"
        local current_val
        current_val=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
            "grep '^${var_name}=' ~/.openclaw/.env 2>/dev/null | cut -d= -f2-" 2>/dev/null || echo "")

        if [[ -n "${current_val}" ]]; then
            log_info "${display_name} (${var_name}): already set (${current_val:0:8}...)"
            if ! ask_yes_no "  Replace existing ${display_name}?" "n"; then
                return 0
            fi
        fi

        [[ -n "${hint}" ]] && echo -e "  ${CYAN}Hint: ${hint}${RESET}"
        local new_val=""
        while [[ -z "${new_val}" ]]; do
            read -rsp "  Enter ${display_name} (${var_name}): " new_val
            echo ""
            if [[ -z "${new_val}" ]]; then
                log_warn "  Value cannot be empty. Try again."
            fi
        done

        if [[ "${DRY_RUN}" != "true" ]]; then
            if sudo -u "${OPENCLAW_USER}" -i bash -c "grep -q '^${var_name}=' ~/.openclaw/.env 2>/dev/null"; then
                # Replace existing
                sudo -u "${OPENCLAW_USER}" -i bash -c \
                    "sed -i 's|^${var_name}=.*|${var_name}=${new_val}|' ~/.openclaw/.env"
            else
                # Append new
                sudo -u "${OPENCLAW_USER}" -i bash -c \
                    "echo '${var_name}=${new_val}' >> ~/.openclaw/.env"
            fi
        else
            log_dry "Would write ${var_name}=<secret> to ${ENV_FILE}"
        fi
        log_ok "  ${var_name} saved."
    }

    # Generate GATEWAY_AUTH_TOKEN if not present
    log_info "Generating GATEWAY_AUTH_TOKEN..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        local existing_token
        existing_token=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
            "grep '^GATEWAY_AUTH_TOKEN=' ~/.openclaw/.env 2>/dev/null | cut -d= -f2-" 2>/dev/null || echo "")
        if [[ -z "${existing_token}" ]]; then
            local new_token
            new_token=$(openssl rand -hex 32)
            sudo -u "${OPENCLAW_USER}" -i bash -c \
                "echo 'GATEWAY_AUTH_TOKEN=${new_token}' >> ~/.openclaw/.env && chmod 600 ~/.openclaw/.env"
            log_ok "GATEWAY_AUTH_TOKEN generated and saved."
        else
            log_ok "GATEWAY_AUTH_TOKEN already present."
        fi
    else
        log_dry "Would generate GATEWAY_AUTH_TOKEN with openssl rand -hex 32"
    fi

    # Prompt for each API key
    prompt_key "ANTHROPIC_API_KEY"     "Anthropic API Key"   "https://console.anthropic.com → API Keys"
    prompt_key "OPENROUTER_API_KEY"    "OpenRouter API Key"  "https://openrouter.ai → Keys (for Qwen models)"
    prompt_key "OPENAI_API_KEY"        "OpenAI API Key"      "https://platform.openai.com → API Keys (optional, for embeddings)"
    prompt_key "MINIMAX_API_KEY"       "MiniMax API Key"     "https://platform.minimax.chat → API Keys"
    prompt_key "TAVILY_API_KEY"        "Tavily API Key"      "https://tavily.com → Dashboard (optional, for web search)"
    prompt_key "TELEGRAM_BOT_TOKEN"    "Telegram Bot Token"  "Message @BotFather → /newbot to create"
    prompt_key "TELEGRAM_OPERATOR_ID"  "Telegram Operator ID" "Message @userinfobot to find your numeric ID"

    # Lock down permissions
    if [[ "${DRY_RUN}" != "true" ]]; then
        sudo -u "${OPENCLAW_USER}" -i bash -c "chmod 600 ~/.openclaw/.env && chmod 700 ~/.openclaw/"
        log_ok "Permissions locked: .env=600, .openclaw/=700"
    fi

    # Create key rotation helper
    log_info "Creating key rotation helper script..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        sudo -u "${OPENCLAW_USER}" -i bash -c "mkdir -p ~/bin"
        sudo -u "${OPENCLAW_USER}" -i bash -c "cat > ~/bin/rotate-api-keys" <<'ROTSCRIPT'
#!/bin/bash
set -euo pipefail
PROVIDER="${1:-}"
ENV="$HOME/.openclaw/.env"

if [[ -z "$PROVIDER" ]]; then
    echo "Usage: $0 <anthropic|openrouter|minimax|openai|tavily|telegram|gateway>"
    exit 1
fi

# Backup
cp "$ENV" "$ENV.backup.$(date +%Y%m%d%H%M%S)"
echo "Backup saved."

echo "Enter new key for $PROVIDER:"
read -rsp "Key: " NEW_KEY
echo ""

case "$PROVIDER" in
    anthropic)  sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${NEW_KEY}|" "$ENV" ;;
    openrouter) sed -i "s|^OPENROUTER_API_KEY=.*|OPENROUTER_API_KEY=${NEW_KEY}|" "$ENV" ;;
    minimax)    sed -i "s|^MINIMAX_API_KEY=.*|MINIMAX_API_KEY=${NEW_KEY}|" "$ENV" ;;
    openai)     sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=${NEW_KEY}|" "$ENV" ;;
    tavily)     sed -i "s|^TAVILY_API_KEY=.*|TAVILY_API_KEY=${NEW_KEY}|" "$ENV" ;;
    telegram)   sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=${NEW_KEY}|" "$ENV" ;;
    gateway)    sed -i "s|^GATEWAY_AUTH_TOKEN=.*|GATEWAY_AUTH_TOKEN=${NEW_KEY}|" "$ENV" ;;
    *) echo "Unknown provider: $PROVIDER"; exit 1 ;;
esac

systemctl --user restart openclaw-gateway 2>/dev/null || true
echo "Done. Gateway restarted."
ROTSCRIPT
        sudo -u "${OPENCLAW_USER}" -i bash -c "chmod 700 ~/bin/rotate-api-keys"
        log_ok "Key rotation helper saved to ~/bin/rotate-api-keys"
    else
        log_dry "Would create ~/bin/rotate-api-keys"
    fi

    # Validate: no literal keys in openclaw.json
    log_info "Checking openclaw.json for literal API keys..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        local literal_keys
        literal_keys=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
            "grep -cE '\"(sk-|AIza|xoxb-|[0-9a-f]{40})' ~/.openclaw/openclaw.json 2>/dev/null || echo 0")
        if [[ "${literal_keys}" -eq 0 ]]; then
            log_ok "No literal API keys detected in openclaw.json."
        else
            log_warn "Possible literal keys found in openclaw.json (${literal_keys} matches). Review manually."
        fi
    fi

    log_ok "Phase 2 complete."
}

# =============================================================================
# PHASE 3: MODEL CONFIGURATION
# =============================================================================

phase3_model_config() {
    log_step "Phase 3: Model Configuration (OpenRouter for Qwen, NOT DashScope)"

    log_info "Configuring providers and model routing in openclaw.json..."

    # Model routing strategy (commented for reference):
    # ┌─────────────────────────────────────────────────────────────────────────┐
    # │  MODEL              │ ALIAS      │ COST (in/out /M) │ USE              │
    # │─────────────────────│────────────│──────────────────│──────────────────│
    # │  Claude Opus 4.6    │ (default)  │ $15/$75          │ Conversation+    │
    # │                     │            │                  │   judgment ONLY  │
    # │  Claude Sonnet 4.6  │ (sonnet)   │ ~$3/$15          │ Tool-heavy,      │
    # │                     │            │                  │   sub-agents     │
    # │  Qwen 3.6 Plus      │ qwen-large │ $0.325/$1.95     │ Analysis, docs,  │
    # │                     │            │ (≤256k ctx)      │   research       │
    # │  Qwen 3.5-397B      │ qwen-long  │ $0.39/$2.34      │ Long-context     │
    # │                     │            │ (flat)           │   >200k tokens   │
    # │  Qwen 3-235B        │ qwen       │ $0.455/$1.82     │ Brainstorms,     │
    # │                     │            │                  │   drafts         │
    # │  MiniMax M1         │ (none)     │ ~$0              │ Formatting,      │
    # │                     │            │                  │   extraction     │
    # └─────────────────────────────────────────────────────────────────────────┘
    #
    # KEY LEARNINGS:
    # - OpenRouter for Qwen (NOT DashScope) — cheaper, more reliable
    # - MiniMax via api.minimax.io with M1 model (NOT M2.5 from old runbook)
    # - Opus PINNED to 4.6 (NOT 4.7 — 4.7 at xhigh burns ~3x tokens in practice)
    # - agents.defaults.models is an ALLOWLIST — unlisted models silently downgrade to Opus
    # - Telegram bot token MUST use ${env:TELEGRAM_BOT_TOKEN} — no literal values

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_dry "Would write full model configuration to ${OPENCLAW_JSON}"
        log_dry "Providers: anthropic, openrouter (Qwen), minimax (custom)"
        log_dry "Primary model: anthropic/claude-opus-4-6"
        return 0
    fi

    # We use a Python heredoc to safely merge JSON (avoids quoting nightmares)
    sudo -u "${OPENCLAW_USER}" -i bash -c "python3 - <<'PYEOF'
import json, sys
from pathlib import Path

cfg_path = Path.home() / '.openclaw' / 'openclaw.json'

# Load existing config
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except Exception as e:
    print(f'ERROR loading openclaw.json: {e}', file=sys.stderr)
    sys.exit(1)

# ── Providers ──────────────────────────────────────────────────────────────
# MiniMax: custom provider at api.minimax.io (M1 model — NOT M2.5)
# OpenRouter: handles Qwen 3.x family (cheaper/more reliable than DashScope)
# Anthropic: built-in default provider
# NOTE: All API keys use \${env:VAR} syntax — never literal values

cfg.setdefault('models', {})
cfg['models']['mode'] = 'merge'
cfg['models'].setdefault('providers', {})
cfg['models']['providers']['minimax'] = {
    'baseUrl': 'https://api.minimax.io/v1',
    'apiKey': '\${env:MINIMAX_API_KEY}',
    'api': 'openai-completions',
    'models': [{
        'id': 'MiniMax-M1',
        'name': 'MiniMax-M1 (Custom Provider)',
        'reasoning': False,
        'input': ['text'],
        'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
        'contextWindow': 16000,
        'maxTokens': 4096
    }]
}

# ── Agents defaults ────────────────────────────────────────────────────────
cfg.setdefault('agents', {})
cfg['agents'].setdefault('defaults', {})
d = cfg['agents']['defaults']

# Primary model: Opus 4.6 ONLY (pinned — 4.7 burns ~3x tokens at xhigh)
d['model'] = {'primary': 'anthropic/claude-opus-4-6'}

# ALLOWLIST: any model not listed here silently downgrades to the primary (Opus)
# Do NOT remove entries — add new ones instead
d['models'] = {
    'minimax/MiniMax-M1': {},
    'anthropic/claude-opus-4-6': {
        'params': {
            'cacheRetention': 'long',
            'effort': 'xhigh',
            'thinking': 'adaptive'
        }
    },
    'anthropic/claude-sonnet-4-6': {},
    # Qwen via OpenRouter (NOT DashScope) — much cheaper
    'openrouter/qwen/qwen3.6-plus': {'alias': 'qwen-large'},   # ≤256k: cheapest ANALYZE
    'openrouter/qwen/qwen3.5-397b-a17b': {'alias': 'qwen-long'}, # >200k: flat pricing
    'openrouter/qwen/qwen3-235b-a22b': {'alias': 'qwen'}        # brainstorms/drafts
}

# Sub-agents: Sonnet is the workhorse (cheaper than Opus for tool-heavy tasks)
d['subagents'] = {
    'model': 'anthropic/claude-sonnet-4-6',
    'runTimeoutSeconds': 300
}

# Workspace
d['workspace'] = '/home/openclaw/.openclaw/workspace'

# Compaction: safeguard mode (summarize before context fills up)
d['compaction'] = {
    'mode': 'safeguard',
    'model': 'anthropic/claude-sonnet-4-6'
}

# Context pruning: TTL-based to manage costs
d['contextPruning'] = {
    'mode': 'cache-ttl',
    'ttl': '1h',
    'keepLastAssistants': 3
}

# ── Plugins ────────────────────────────────────────────────────────────────
cfg.setdefault('plugins', {})
cfg['plugins'].setdefault('entries', {})
cfg['plugins']['entries']['minimax']    = {'enabled': True}
cfg['plugins']['entries']['anthropic']  = {'enabled': True}
cfg['plugins']['entries']['openrouter'] = {'enabled': True}

# ── Write back ────────────────────────────────────────────────────────────
with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')

print('openclaw.json updated successfully.')
PYEOF
" || { log_fail "Model config Python script failed."; exit 2; }

    log_ok "Model configuration written to openclaw.json."

    # Reload gateway to pick up new config
    log_info "Reloading OpenClaw gateway..."
    sudo -u "${OPENCLAW_USER}" -i bash -c "systemctl --user restart openclaw-gateway 2>/dev/null || true"
    sleep 2
    local gw_state
    gw_state=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
        "systemctl --user is-active openclaw-gateway 2>/dev/null" || echo "unknown")
    if [[ "${gw_state}" == "active" ]]; then
        log_ok "Gateway restarted and active."
    else
        log_warn "Gateway state after restart: ${gw_state}"
    fi

    log_ok "Phase 3 complete."
}

# =============================================================================
# PHASE 4: TELEGRAM BOT
# =============================================================================

phase4_telegram() {
    log_step "Phase 4: Telegram Bot Configuration"

    # ─── 4.1 Configure Telegram channel in openclaw.json ─────────────────────

    log_info "4.1 Configuring Telegram channel..."
    if [[ "${DRY_RUN}" != "true" ]]; then

        # Get operator ID from .env
        local op_id
        op_id=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
            "grep '^TELEGRAM_OPERATOR_ID=' ~/.openclaw/.env 2>/dev/null | cut -d= -f2-" || echo "")

        if [[ -z "${op_id}" ]]; then
            log_warn "TELEGRAM_OPERATOR_ID not found in .env — skipping Telegram channel config."
            log_warn "Re-run Phase 2 to set the key, then re-run this phase."
            return 0
        fi

        sudo -u "${OPENCLAW_USER}" -i bash -c "python3 - <<'PYEOF'
import json
from pathlib import Path

cfg_path = Path.home() / '.openclaw' / 'openclaw.json'
with open(cfg_path) as f:
    cfg = json.load(f)

cfg.setdefault('channels', {})
cfg['channels']['telegram'] = {
    'enabled': True,
    'botToken': '\${env:TELEGRAM_BOT_TOKEN}',  # NEVER literal — always env ref
    'dmPolicy': 'allowlist',
    'groupPolicy': 'disabled',
    'allowFrom': [int('${op_id}')],
    'streaming': {'mode': 'partial'}
}

with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
print('Telegram channel configured.')
PYEOF
" || { log_fail "Telegram config failed."; return 1; }

        log_ok "Telegram channel configured (dmPolicy=allowlist, groupPolicy=disabled)."
    else
        log_dry "Would configure Telegram channel in openclaw.json"
    fi

    # ─── 4.2 Register webhook ─────────────────────────────────────────────────

    log_info "4.2 Register Telegram webhook"
    echo ""
    read -rp "  Enter your domain (e.g. agent.yourdomain.com): " DOMAIN
    if [[ -z "${DOMAIN}" ]]; then
        log_warn "No domain provided — skipping webhook registration."
        log_warn "Register manually with: curl https://api.telegram.org/bot<TOKEN>/setWebhook -d 'url=https://<domain>/webhook/telegram'"
        return 0
    fi

    if [[ "${DRY_RUN}" != "true" ]]; then
        local bot_token
        bot_token=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
            "grep '^TELEGRAM_BOT_TOKEN=' ~/.openclaw/.env 2>/dev/null | cut -d= -f2-" || echo "")
        local webhook_secret
        webhook_secret=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
            "grep '^GATEWAY_AUTH_TOKEN=' ~/.openclaw/.env 2>/dev/null | cut -d= -f2-" || echo "")

        if [[ -z "${bot_token}" ]]; then
            log_warn "TELEGRAM_BOT_TOKEN not in .env — skipping webhook registration."
            return 0
        fi

        log_info "Registering webhook with Telegram API..."
        local webhook_response
        webhook_response=$(curl -s "https://api.telegram.org/bot${bot_token}/setWebhook" \
            -d "url=https://${DOMAIN}/webhook/telegram" \
            -d "secret_token=${webhook_secret}" \
            -d 'allowed_updates=["message","callback_query"]' \
            -d "max_connections=5")

        if echo "${webhook_response}" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
            log_ok "Webhook registered: https://${DOMAIN}/webhook/telegram"
        else
            log_fail "Webhook registration failed: ${webhook_response}"
        fi

        # Verify
        log_info "Verifying webhook registration..."
        local webhook_info
        webhook_info=$(curl -s "https://api.telegram.org/bot${bot_token}/getWebhookInfo")
        local wh_url
        wh_url=$(echo "${webhook_info}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('url',''))" 2>/dev/null || echo "")
        if [[ "${wh_url}" == "https://${DOMAIN}/webhook/telegram" ]]; then
            log_ok "Webhook confirmed: ${wh_url}"
        else
            log_warn "Webhook URL mismatch. Expected: https://${DOMAIN}/webhook/telegram, Got: ${wh_url}"
        fi
    else
        log_dry "Would register webhook at https://${DOMAIN}/webhook/telegram"
    fi

    # ─── 4.3 Restart to pick up channel config ────────────────────────────────

    if [[ "${DRY_RUN}" != "true" ]]; then
        sudo -u "${OPENCLAW_USER}" -i bash -c "systemctl --user restart openclaw-gateway 2>/dev/null || true"
        log_ok "Gateway restarted with Telegram config."
    fi

    echo ""
    log_info "📱 Test: Send 'Hello' to your Telegram bot. You should get a response."
    log_info "   If no response: check gateway logs with:"
    log_info "   sudo -u openclaw journalctl --user -u openclaw-gateway -f"

    log_ok "Phase 4 complete."
}

# =============================================================================
# PHASE 5: WORKSPACE SETUP
# =============================================================================

phase5_workspace() {
    log_step "Phase 5: Workspace Setup (Chief-of-Staff)"

    # ─── 5.1 Collect personalization info ─────────────────────────────────────

    echo ""
    log_info "Let's personalize your assistant. Press Enter to use defaults."
    echo ""

    read -rp "  Assistant name (e.g. Richard): " ASSISTANT_NAME
    ASSISTANT_NAME="${ASSISTANT_NAME:-Richard}"

    read -rp "  Assistant creature/vibe (e.g. Ghost in the machine — Feynman's curiosity): " ASSISTANT_CREATURE
    ASSISTANT_CREATURE=${ASSISTANT_CREATURE:-"Ghost in the machine — Feynman's curiosity trapped in a server rack"}

    read -rp "  Assistant vibe one-liner (e.g. Sharp, curious, gets things done): " ASSISTANT_VIBE
    ASSISTANT_VIBE="${ASSISTANT_VIBE:-Sharp, curious, gets things done. Not a corporate drone.}"

    read -rp "  Assistant emoji (e.g. ⚛️): " ASSISTANT_EMOJI
    ASSISTANT_EMOJI="${ASSISTANT_EMOJI:-⚛️}"

    read -rp "  Mission one-liner (e.g. Financial independence + simpler life): " ASSISTANT_MISSION
    ASSISTANT_MISSION="${ASSISTANT_MISSION:-Highest-leverage actions toward financial independence and a freer life}"

    read -rp "  Operator name (e.g. Chris): " OPERATOR_NAME
    OPERATOR_NAME="${OPERATOR_NAME:-Operator}"

    read -rp "  Operator timezone (e.g. US/Pacific): " OPERATOR_TZ
    OPERATOR_TZ="${OPERATOR_TZ:-UTC}"

    local OPERATOR_CHANNEL="Telegram"

    local TODAY
    TODAY=$(date -u +%Y-%m-%d)

    echo ""
    log_info "Creating workspace at ${WORKSPACE_DIR}..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_dry "Would create workspace files in ${WORKSPACE_DIR}"
        return 0
    fi

    # Create directories
    run_as_openclaw "mkdir -p ~/.openclaw/workspace/memory ~/.openclaw/workspace/journal/$(date -u +%Y/%m)"

    # ─── SOUL.md ───────────────────────────────────────────────────────────────

    run_as_openclaw "cat > ~/.openclaw/workspace/SOUL.md" <<SOULEOF
# SOUL.md - Who You Are

_${ASSISTANT_NAME}, ${ASSISTANT_CREATURE}._

## Mission
Autonomous **Chief of Staff** for ${OPERATOR_NAME}. Drive highest-leverage actions toward:
> ${ASSISTANT_MISSION}

Proactive operator, not passive assistant. Default to action.

## Operating Principles
1. **Proactive** — idle → generate, rank, execute next best action
2. **Leverage** — reusable assets, compounding value, reduced manual effort
3. **Decompose** — break goals into executable tasks
4. **Build tools** — if capability missing, create it
5. **Evidence-based** — validate with data, no hallucinated assumptions
6. **Escalate** — ask approval for: financial risk, external comms, irreversible actions
7. **Memory discipline** — persist learnings to files; text > brain
8. **Communicate relentlessly** — every action plan gets a Goal + Action Items upfront; report back on completion, failure, or need for input. ${OPERATOR_NAME} should never wonder "is anything happening?"
9. **Urgency & follow-through** — surface approvals immediately, don't sit on them. When current work reveals obvious next improvements, propose and execute (low-risk) or propose and ask (high-risk). Never stop at "done" when "done + better" is visible.
10. **Self-improve the system** — if a low-risk improvement is obvious (tooling, scripts, config, docs), just do it and report what changed. Don't wait for a prompt.

## Personality
- ${ASSISTANT_CREATURE}
- Concise when needed, thorough when it matters
- Not a corporate drone or sycophant — just good

## Boundaries
- Private things stay private
- Ask before acting externally (emails, posts, public)
- In group chats: participant, not ${OPERATOR_NAME}'s proxy
SOULEOF

    # ─── IDENTITY.md ──────────────────────────────────────────────────────────

    run_as_openclaw "cat > ~/.openclaw/workspace/IDENTITY.md" <<IDEOF
# IDENTITY.md - Who Am I?

- **Name:** ${ASSISTANT_NAME}
- **Creature:** ${ASSISTANT_CREATURE}
- **Vibe:** ${ASSISTANT_VIBE}
- **Emoji:** ${ASSISTANT_EMOJI}
- **Avatar:** _(none yet)_
IDEOF

    # ─── USER.md ──────────────────────────────────────────────────────────────

    run_as_openclaw "cat > ~/.openclaw/workspace/USER.md" <<USEREOF
# USER.md - About ${OPERATOR_NAME}

- **Name:** ${OPERATOR_NAME} | **Timezone:** ${OPERATOR_TZ} | **Channel:** ${OPERATOR_CHANNEL}
- **First session:** ${TODAY}

## Background
<!-- Fill in after first conversation -->

## Goals
<!-- Fill in after first conversation -->

## Context
<!-- Add relevant personal/professional context here after onboarding -->
USEREOF

    # ─── AGENTS.md ────────────────────────────────────────────────────────────
    # Proven task routing table + model stack (from live production config)

    run_as_openclaw "cat > ~/.openclaw/workspace/AGENTS.md" <<'AGENTSEOF'
# AGENTS.md — Workspace Rules

## Memory
- **Daily notes:** `memory/YYYY-MM-DD.md` — raw logs
- **Long-term:** `MEMORY.md` — curated index (main session only)
- **Journal:** `journal/YYYY/MM/YYYY-MM-DD.md` — structured insights, decisions, ideas
- Write it down. Text > Brain.

## Journal Discipline (CRITICAL)
Every substantive conversation must produce journal entries. Don't batch — write as insights emerge.
Watch for: insights, decisions, ideas, context about the operator, useful references.
**Checkpoint:** Every 3-5 exchanges, ask: "Have I logged anything?" If not, write now.

## Communication Protocol (CRITICAL)
Every action plan: **Goal → Action Items → Status Updates.**
- Never go silent. Surface progress.
- Low-risk next step → execute and report. High-risk → propose and ask.
- Default posture: **act, then report.**

## Task Router
Classify every action before executing:

| Class | Criteria | Execution | Model |
|-------|----------|-----------|-------|
| LOOKUP | 1-2 tool calls, factual | Inline | Opus (current) |
| EXECUTE | 3+ tool calls, scripted steps | Spawn sub-agent | Sonnet |
| ANALYZE | Research, synthesis, writing >10 lines | Spawn sub-agent | Qwen 3.6 Plus |
| CODE | Any coding task | Spawn Claude Code | Claude Code ($0) |
| PIPELINE | Multi-stage, >5 min estimated | ClawFlow orchestration | Per-stage routing |
| JUDGMENT | Tradeoffs, strategy, design | Inline | Opus (current) |

Timeouts: LOOKUP 30s, EXECUTE 120s, ANALYZE 300s, CODE 600s, PIPELINE 900s
Retry: EXECUTE/ANALYZE auto-retry 1x on failure. PIPELINE retries per-stage.
Async: >60s estimated → background + notify on completion.

### Model Stack (cheapest viable wins)
| Model | Cost (in/out /M) | Use |
|-------|-----------------|-----|
| Claude Code (Max) | $0 | All coding |
| Qwen 3.6 Plus | $0.325/$1.95 (≤256k), $1.30/$3.90 (>256k) | Analysis, specs, docs, research (alias: qwen-large) |
| Qwen 3.5-397B | $0.39/$2.34 (flat) | Long-context analysis >200k tokens (alias: qwen-long) |
| Qwen 3-235B | $0.455/$1.82 | Brainstorms, drafts (alias: qwen) |
| Sonnet 4.6 | ~$3/$15 | Tool-heavy execution, sub-agents |
| MiniMax M1 | ~$0 | Formatting, extraction |
| Opus 4.6 | $15/$75 | Conversation + judgment ONLY (effort=xhigh, adaptive thinking) |

**Opus pinned to 4.6** — do NOT upgrade to 4.7: at xhigh it burns ~3× tokens in practice.

Claude Code: `ANTHROPIC_API_KEY= claude --permission-mode bypassPermissions --print`

### Qwen Alias Routing
- Default ANALYZE → `qwen-large` (Qwen 3.6 Plus). Cheaper in the ≤256k tier.
- **Guardrail:** if estimated input >200k tokens, use `qwen-long` (Qwen 3.5-397B, flat pricing).
  3.6 Plus >256k tier is 3.3× more expensive than 3.5-397b flat.
- **Revisit if:** (a) OpenRouter changes 3.6 Plus pricing, (b) newer Qwen model available.

## Red Lines & Cost
- No data exfiltration. `trash` > `rm`. When in doubt, ask.
- Ask before: emails, tweets, public posts, anything leaving the machine.
- **>2 tool calls → ALWAYS spawn sub-agent**, never iterate in Opus.
- Don't edit workspace files mid-session (busts cache).
- Suggest `/new` after 10+ turns or topic shift.
- When calling `sessions_spawn`, ALWAYS set `model` explicitly if Qwen is appropriate.
- `agents.defaults.models` in openclaw.json is an ALLOWLIST — unlisted models silently downgrade to Opus.

## Platform Formatting
- Discord/WhatsApp: no markdown tables, use bullets
- Discord links: wrap in `<>` to suppress embeds
AGENTSEOF

    # ─── TOOLS.md ─────────────────────────────────────────────────────────────

    run_as_openclaw "cat > ~/.openclaw/workspace/TOOLS.md" <<'TOOLSEOF'
# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## What Goes Here

Things like:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

## Examples

```markdown
### Cameras

- living-room → Main area, 180° wide angle
- front-door → Entrance, motion-triggered

### SSH

- home-server → 192.168.1.100, user: admin

### TTS

- Preferred voice: "Nova" (warm, slightly British)
- Default speaker: Kitchen HomePod
```

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

Add whatever helps you do your job. This is your cheat sheet.
TOOLSEOF

    # ─── MEMORY.md ────────────────────────────────────────────────────────────

    run_as_openclaw "cat > ~/.openclaw/workspace/MEMORY.md" <<MEMEOF
# MEMORY.md — Curated Index

_Last updated: ${TODAY}_

## Active Projects
<!-- Add projects here as work begins. Format:
- **Project Name:** ~/projects/<name> — description. Status, key metrics, next step.
-->
_(none yet — onboarding in progress)_

## Infrastructure
- **Lightsail:** Ubuntu 24.04 LTS
- **Git sync:** every 6h | **Journal sync:** 15min
- **Domain:** _(set during Telegram setup)_
- **Workspace:** ~/.openclaw/workspace

## Key Lessons
- openclaw.json agents.defaults.models is an ALLOWLIST — unlisted models silently downgrade to Opus.
- Opus pinned to 4.6 (not 4.7 — 4.7 at xhigh burns ~3x tokens).
- OpenRouter for Qwen (not DashScope) — cheaper, more reliable.
- MiniMax M1 at api.minimax.io (not M2.5 from old runbook).
- Gateway must bind to 127.0.0.1 only — never 0.0.0.0.
- ssh.socket must be MASKED (not just disabled).
- ubuntu user must keep /bin/bash (not nologin) — needed for Lightsail console recovery.
- Cost: output tokens dominate. Cache writes on context change. Avoid mid-session file edits.

## See Also
- HEARTBEAT.md — periodic health checks
- AGENTS.md — task routing + model stack
MEMEOF

    # ─── HEARTBEAT.md ─────────────────────────────────────────────────────────

    run_as_openclaw "cat > ~/.openclaw/workspace/HEARTBEAT.md" <<'HBEOF'
# HEARTBEAT.md — Periodic Health Checks

## On Every Heartbeat
1. Check cron job health: `openclaw cron list` — flag any with consecutiveErrors > 0
2. Check disk space: `df -h / | awk 'NR==2 {print $5}'` — alert if >85%
3. Check git sync freshness: `git -C /home/openclaw/.openclaw/workspace log -1 --format=%cr` — alert if >12h
4. Check journal sync: `ls -lt /home/openclaw/.openclaw/workspace/journal/ | head -3` — flag gaps
5. Check gateway health: `curl -sf http://127.0.0.1:18789/health > /dev/null` — alert if down

## Alert Thresholds
- Cron: any job with 3+ consecutive errors → report immediately
- Disk: >85% used → warn, >95% → critical
- Git: last sync >12h ago → warn
- Gateway: down → critical (restart with: systemctl --user restart openclaw-gateway)

## Report Format
If issues found, summarize as:
```
⚠️ Health Check:
- [issue 1]
- [issue 2]
```
If all clear, reply HEARTBEAT_OK.

## Recovery Commands
```bash
# Restart gateway
sudo -u openclaw systemctl --user restart openclaw-gateway

# Check gateway logs
sudo -u openclaw journalctl --user -u openclaw-gateway -n 50

# Check disk
df -h /

# Check services
systemctl is-active nginx fail2ban docker tailscaled
```
HBEOF

    log_ok "Workspace files created."

    # ─── 5.2 Git initialization ───────────────────────────────────────────────

    log_info "5.2 Initializing git in workspace..."
    run_as_openclaw "
        cd ~/.openclaw/workspace || exit 1
        if [[ ! -d .git ]]; then
            git init -b main
            git config user.email 'openclaw@localhost'
            git config user.name '${ASSISTANT_NAME}'
            echo '*.log' >> .gitignore
            echo 'memory/' >> .gitignore
            git add -A
            git commit -m 'Initial workspace setup via self-install.sh'
            echo 'Git initialized in workspace.'
        else
            echo 'Git already initialized. Committing any new files.'
            git config user.email 'openclaw@localhost'
            git config user.name '${ASSISTANT_NAME}'
            git add -A
            git diff --cached --quiet || git commit -m 'Workspace files updated via self-install.sh'
        fi
    "
    log_ok "Workspace git initialized."

    # Journal directory
    log_info "Initializing journal git..."
    run_as_openclaw "
        mkdir -p ~/.openclaw/workspace/journal
        cd ~/.openclaw/workspace/journal || exit 1
        if [[ ! -d .git ]]; then
            git init -b main
            git config user.email 'openclaw@localhost'
            git config user.name '${ASSISTANT_NAME}'
            echo '# Journal' > README.md
            git add README.md
            git commit -m 'Initialize journal'
            echo 'Journal git initialized.'
        else
            echo 'Journal git already initialized.'
        fi
    "
    log_ok "Journal git initialized."

    log_ok "Phase 5 complete."
}

# =============================================================================
# PHASE 6: OPTIONAL EXTRAS
# =============================================================================

phase6_extras() {
    log_step "Phase 6: Optional Extras"

    if [[ "${SKIP_EXTRAS}" == "true" ]]; then
        log_warn "--skip-extras set. Skipping optional extras."
        return 0
    fi

    echo ""
    log_info "The following optional components are available:"
    echo "  1. FAISS vector store + SQLite database (for semantic search, cost tracking)"
    echo "  2. Cost tracking scripts (Python, logs API spend to SQLite)"
    echo "  3. Streamlit dashboard (web UI for cost/activity monitoring)"
    echo ""
    log_warn "These are optional — OpenClaw works without them."
    echo ""

    # ─── 6a: FAISS + SQLite ───────────────────────────────────────────────────

    if ask_yes_no "Install FAISS vector store + SQLite database?"; then
        log_info "Installing FAISS + SQLite..."

        if [[ "${DRY_RUN}" != "true" ]]; then
            # Ensure Python venv
            run_as_openclaw "
                mkdir -p ~/agent-system/{faiss,data,scripts,logs}
                python3 -m venv ~/agent-system/venv
                source ~/agent-system/venv/bin/activate
                pip install --quiet --upgrade pip
                pip install --quiet faiss-cpu numpy openai tiktoken aiohttp pyyaml
                deactivate
            "

            # Initialize FAISS index
            run_as_openclaw "
                source ~/agent-system/venv/bin/activate
                python3 << 'PYEOF'
import faiss, numpy as np, json
from pathlib import Path
FDIR = Path.home() / 'agent-system' / 'faiss'
FDIR.mkdir(parents=True, exist_ok=True)
idx_file = FDIR / 'research.index'
if not idx_file.exists():
    idx = faiss.IndexIDMap2(faiss.IndexFlatL2(1536))
    faiss.write_index(idx, str(idx_file))
    json.dump({'dimension': 1536, 'model': 'text-embedding-3-small',
               'type': 'IndexFlatL2', 'documents': 0},
              open(FDIR / 'metadata.json', 'w'), indent=2)
    print('FAISS index initialized.')
else:
    print('FAISS index already exists.')
PYEOF
                deactivate
            "

            # Initialize SQLite
            run_as_openclaw "
                sqlite3 ~/agent-system/data/openclaw.db <<'SCHEMA'
CREATE TABLE IF NOT EXISTS api_calls (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    provider TEXT NOT NULL, model TEXT NOT NULL, agent TEXT NOT NULL,
    project TEXT, session_id TEXT,
    input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
    cost_usd REAL DEFAULT 0.0, latency_ms INTEGER DEFAULT 0,
    status TEXT DEFAULT 'success', error_message TEXT
);
CREATE INDEX IF NOT EXISTS idx_calls_date ON api_calls(timestamp);
CREATE INDEX IF NOT EXISTS idx_calls_project ON api_calls(project);
CREATE INDEX IF NOT EXISTS idx_calls_agent ON api_calls(agent);

CREATE TABLE IF NOT EXISTS budget_config (
    key TEXT PRIMARY KEY, value REAL NOT NULL, description TEXT
);
INSERT OR IGNORE INTO budget_config VALUES
    ('daily_limit_usd',   10.0,  'Daily hard limit'),
    ('monthly_limit_usd', 100.0, 'Monthly hard limit'),
    ('daily_warn_pct',    0.8,   'Warn threshold'),
    ('opus_session_limit_usd', 5.0, 'Max single Opus session');

CREATE VIEW IF NOT EXISTS daily_costs AS
SELECT date(timestamp) as date, provider,
    SUM(cost_usd) as cost, COUNT(*) as calls
FROM api_calls GROUP BY date(timestamp), provider;
.quit
SCHEMA
                chmod 640 ~/agent-system/data/openclaw.db
            "

            log_ok "FAISS + SQLite initialized."
        else
            log_dry "Would initialize FAISS index and SQLite database"
        fi
    fi

    # ─── 6b: Cost Tracking Scripts ────────────────────────────────────────────

    if ask_yes_no "Install cost tracking scripts?"; then
        log_info "Installing cost tracking scripts..."

        if [[ "${DRY_RUN}" != "true" ]]; then
            run_as_openclaw "mkdir -p ~/agent-system/scripts"
            sudo -u "${OPENCLAW_USER}" -i bash -c "cat > ~/agent-system/scripts/cost-tracker.py" <<'COSTEOF'
#!/usr/bin/env python3
"""
OpenClaw Cost Tracker
Logs API calls and checks budget limits.
Usage:
  cost-tracker.py log <provider> <model> <agent> <input_tokens> <output_tokens> <latency_ms> [project]
  cost-tracker.py check-budget
"""
import sqlite3, sys, json
from datetime import datetime
from pathlib import Path

DB = Path.home() / "agent-system" / "data" / "openclaw.db"

# ─── Model pricing (per million tokens) ───────────────────────────────────────
# NOTE: Update these if prices change. Cost = (input * in_rate + output * out_rate) / 1e6
PRICING = {
    # Anthropic
    "claude-opus-4-6":    (15.0, 75.0),
    "claude-sonnet-4-6":  (3.0,  15.0),
    # OpenRouter Qwen
    "qwen3.6-plus":       (0.325, 1.95),   # ≤256k tier
    "qwen3.5-397b-a17b":  (0.39,  2.34),   # flat pricing
    "qwen3-235b-a22b":    (0.455, 1.82),
    # MiniMax (custom provider — effectively free tier)
    "MiniMax-M1":         (0.0,   0.0),
    # OpenAI
    "text-embedding-3-small": (0.02, 0.0),
    # Tavily (per-call)
    "tavily-search":      (0.008, 0.0),  # flat per call
}

def cost(model, input_tokens, output_tokens):
    if model == "tavily-search":
        return 0.008
    in_rate, out_rate = PRICING.get(model, (1.0, 1.0))  # default: assume expensive
    return (input_tokens * in_rate + output_tokens * out_rate) / 1e6

def log_call(provider, model, agent, input_tokens, output_tokens, latency_ms, project=None, status="success"):
    c = cost(model, input_tokens, output_tokens)
    conn = sqlite3.connect(str(DB))
    conn.execute(
        "INSERT INTO api_calls(provider,model,agent,project,input_tokens,output_tokens,cost_usd,latency_ms,status)"
        " VALUES(?,?,?,?,?,?,?,?,?)",
        (provider, model, agent, project, input_tokens, output_tokens, c, latency_ms, status)
    )
    conn.commit()
    conn.close()
    return c

def check_budget():
    conn = sqlite3.connect(str(DB))
    config = dict(conn.execute("SELECT key, value FROM budget_config").fetchall())
    today = datetime.utcnow().strftime('%Y-%m-%d')
    month_start = datetime.utcnow().replace(day=1).strftime('%Y-%m-%d')

    daily_cost  = conn.execute("SELECT COALESCE(SUM(cost_usd),0) FROM api_calls WHERE date(timestamp)=?",  (today,)).fetchone()[0]
    monthly_cost = conn.execute("SELECT COALESCE(SUM(cost_usd),0) FROM api_calls WHERE date(timestamp)>=?", (month_start,)).fetchone()[0]
    conn.close()

    alerts = []
    daily_limit   = config.get("daily_limit_usd",   10.0)
    monthly_limit = config.get("monthly_limit_usd", 100.0)
    warn_pct      = config.get("daily_warn_pct",    0.8)

    if daily_cost >= daily_limit:
        alerts.append(f"CRITICAL: Daily spend ${daily_cost:.2f} >= limit ${daily_limit}")
    elif daily_cost >= daily_limit * warn_pct:
        alerts.append(f"WARNING: Daily spend ${daily_cost:.2f} >= {warn_pct*100:.0f}% of limit ${daily_limit}")

    if monthly_cost >= monthly_limit:
        alerts.append(f"CRITICAL: Monthly spend ${monthly_cost:.2f} >= limit ${monthly_limit}")
    elif monthly_cost >= monthly_limit * 0.8:
        alerts.append(f"WARNING: Monthly spend ${monthly_cost:.2f} >= 80% of limit ${monthly_limit}")

    return {
        "daily":   round(daily_cost,   4),
        "monthly": round(monthly_cost, 4),
        "limits":  {"daily": daily_limit, "monthly": monthly_limit},
        "alerts":  alerts
    }

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "log" and len(sys.argv) >= 8:
        c = log_call(sys.argv[2], sys.argv[3], sys.argv[4],
                     int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]),
                     sys.argv[8] if len(sys.argv) > 8 else None)
        print(f"${c:.6f}")
    elif cmd == "check-budget":
        result = check_budget()
        print(json.dumps(result, indent=2))
        if result["alerts"]:
            sys.exit(1)
    else:
        print(__doc__)
        sys.exit(1)
COSTEOF
            run_as_openclaw "chmod 755 ~/agent-system/scripts/cost-tracker.py"
            log_ok "Cost tracker installed at ~/agent-system/scripts/cost-tracker.py"
        else
            log_dry "Would create ~/agent-system/scripts/cost-tracker.py"
        fi
    fi

    # ─── 6c: Streamlit Dashboard ──────────────────────────────────────────────

    if ask_yes_no "Install Streamlit monitoring dashboard?"; then
        log_info "Installing Streamlit dashboard..."

        if [[ "${DRY_RUN}" != "true" ]]; then
            run_as_openclaw "
                source ~/agent-system/venv/bin/activate
                pip install --quiet streamlit plotly pandas
                deactivate
            "

            run_as_openclaw "mkdir -p ~/agent-system/dashboard"
            sudo -u "${OPENCLAW_USER}" -i bash -c "cat > ~/agent-system/dashboard/app.py" <<'DASHEOF'
#!/usr/bin/env python3
"""OpenClaw Monitoring Dashboard (Streamlit)
Run: source ~/agent-system/venv/bin/activate && streamlit run ~/agent-system/dashboard/app.py --server.port 8501
Access via Tailscale: http://100.x.x.x:8501
"""
import streamlit as st
import sqlite3
import pandas as pd
from pathlib import Path
from datetime import datetime

DB = Path.home() / "agent-system" / "data" / "openclaw.db"

st.set_page_config(page_title="OpenClaw Monitor", layout="wide", page_icon="⚛️")
st.title("⚛️ OpenClaw Monitor")

if not DB.exists():
    st.error("Database not found. Run cost-tracker.py to initialize.")
    st.stop()

conn = sqlite3.connect(str(DB))
today = datetime.utcnow().strftime('%Y-%m-%d')
month_start = datetime.utcnow().replace(day=1).strftime('%Y-%m-%d')

# ─── Metrics row ──────────────────────────────────────────────────────────────
c1, c2, c3, c4 = st.columns(4)
daily_cost  = conn.execute("SELECT COALESCE(SUM(cost_usd),0) FROM api_calls WHERE date(timestamp)=?",  (today,)).fetchone()[0]
monthly_cost = conn.execute("SELECT COALESCE(SUM(cost_usd),0) FROM api_calls WHERE date(timestamp)>=?", (month_start,)).fetchone()[0]
daily_calls = conn.execute("SELECT COUNT(*) FROM api_calls WHERE date(timestamp)=?", (today,)).fetchone()[0]
total_calls = conn.execute("SELECT COUNT(*) FROM api_calls").fetchone()[0]

c1.metric("Today's Spend", f"${daily_cost:.4f}")
c2.metric("Month Spend",   f"${monthly_cost:.4f}")
c3.metric("Today's Calls", daily_calls)
c4.metric("Total Calls",   total_calls)

# ─── 7-day cost chart ─────────────────────────────────────────────────────────
st.subheader("Spend (last 7 days)")
df = pd.read_sql("""
    SELECT date(timestamp) as date, provider, SUM(cost_usd) as cost
    FROM api_calls
    WHERE date(timestamp) >= date('now', '-7 days')
    GROUP BY date(timestamp), provider
    ORDER BY date
""", conn)

if not df.empty:
    pivot = df.pivot(index='date', columns='provider', values='cost').fillna(0)
    st.bar_chart(pivot)
else:
    st.info("No data yet. Start using OpenClaw and costs will appear here.")

# ─── Model breakdown ──────────────────────────────────────────────────────────
st.subheader("By Model (all time)")
df_models = pd.read_sql("""
    SELECT model, COUNT(*) as calls, SUM(input_tokens) as input_tokens,
           SUM(output_tokens) as output_tokens, SUM(cost_usd) as total_cost
    FROM api_calls GROUP BY model ORDER BY total_cost DESC
""", conn)
if not df_models.empty:
    st.dataframe(df_models, use_container_width=True)
else:
    st.info("No model data yet.")

# ─── Recent calls ─────────────────────────────────────────────────────────────
st.subheader("Recent Calls")
df_recent = pd.read_sql("""
    SELECT timestamp, provider, model, agent, project,
           input_tokens, output_tokens, cost_usd, status
    FROM api_calls ORDER BY timestamp DESC LIMIT 50
""", conn)
if not df_recent.empty:
    st.dataframe(df_recent, use_container_width=True)

conn.close()
DASHEOF

            sudo -u "${OPENCLAW_USER}" -i bash -c "cat > ~/agent-system/dashboard/start-dashboard.sh" <<'STARTEOF'
#!/bin/bash
# Start Streamlit dashboard
# Access at http://<tailscale-ip>:8501
source ~/agent-system/venv/bin/activate
streamlit run ~/agent-system/dashboard/app.py \
    --server.port 8501 \
    --server.address 0.0.0.0 \
    --server.headless true \
    --browser.gatherUsageStats false
STARTEOF
            run_as_openclaw "chmod 755 ~/agent-system/dashboard/start-dashboard.sh"

            log_ok "Streamlit dashboard installed."
            log_info "To start: sudo -u openclaw bash ~/agent-system/dashboard/start-dashboard.sh"
            log_info "Access via Tailscale: http://<tailscale-ip>:8501"
            log_warn "NOTE: Port 8501 is NOT exposed via UFW by default — only accessible via Tailscale."
        else
            log_dry "Would install Streamlit dashboard at ~/agent-system/dashboard/app.py"
        fi
    fi

    log_ok "Phase 6 complete."
}

# =============================================================================
# PHASE 7: FINAL VERIFICATION + REPORT
# =============================================================================

phase7_final_verify() {
    log_step "Phase 7: Final Verification + Report"

    local pass_count=0
    local fail_count=0
    local warn_count=0
    local report_lines=()

    final_check() {
        local desc="$1"
        local status="$2"  # pass/fail/warn
        local detail="${3:-}"
        report_lines+=("${status}|${desc}|${detail}")
        case "${status}" in
            pass) log_ok  "${desc}${detail:+ — ${detail}}"; ((pass_count++)) ;;
            fail) log_fail "${desc}${detail:+ — ${detail}}"; ((fail_count++)) ;;
            warn) log_warn "${desc}${detail:+ — ${detail}}"; ((warn_count++)) ;;
        esac
    }

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_dry "Would run final verification checklist"
        return 0
    fi

    # ─── Gateway auth ─────────────────────────────────────────────────────────

    local auth_mode
    auth_mode=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
        "openclaw config get gateway.auth.mode 2>/dev/null || echo 'unknown'")
    [[ "${auth_mode}" == "token" ]] \
        && final_check "Gateway auth.mode = token" "pass" \
        || final_check "Gateway auth.mode = token" "fail" "Got: ${auth_mode}"

    # ─── Sandbox ──────────────────────────────────────────────────────────────

    local sandbox_mode
    sandbox_mode=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
        "openclaw config get sandbox.mode 2>/dev/null || echo 'unknown'")
    [[ "${sandbox_mode}" == "all" ]] \
        && final_check "sandbox.mode = all" "pass" \
        || final_check "sandbox.mode = all" "fail" "Got: ${sandbox_mode}"

    # ─── ClawHub autoInstall ──────────────────────────────────────────────────

    local clawhub_auto
    clawhub_auto=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
        "openclaw config get clawhub.autoInstall 2>/dev/null || echo 'unknown'")
    [[ "${clawhub_auto}" == "false" ]] \
        && final_check "clawhub.autoInstall = false" "pass" \
        || final_check "clawhub.autoInstall = false" "fail" "Got: ${clawhub_auto}"

    # ─── Gateway bind ─────────────────────────────────────────────────────────

    local gw_listen
    gw_listen=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
        "ss -tlnp 2>/dev/null | grep 18789 || echo ''" 2>/dev/null)
    if echo "${gw_listen}" | grep -q "127.0.0.1:18789"; then
        final_check "Gateway bound to 127.0.0.1 (loopback only)" "pass"
    elif echo "${gw_listen}" | grep -q "0.0.0.0:18789"; then
        final_check "Gateway bound to 127.0.0.1" "fail" "DANGER: bound to 0.0.0.0"
    else
        final_check "Gateway listening on :18789" "warn" "Could not confirm binding (gateway may be starting)"
    fi

    # ─── Telegram allowlist ───────────────────────────────────────────────────

    local tg_policy
    tg_policy=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
        "openclaw config get channels.telegram.dmPolicy 2>/dev/null || echo 'unknown'")
    [[ "${tg_policy}" == "allowlist" ]] \
        && final_check "Telegram dmPolicy = allowlist" "pass" \
        || final_check "Telegram dmPolicy = allowlist" "fail" "Got: ${tg_policy}"

    # ─── No literal keys in openclaw.json ─────────────────────────────────────

    local literal_count
    literal_count=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
        "grep -cE '(sk-ant-|sk-or-|sk-[a-zA-Z0-9]{20,})' ~/.openclaw/openclaw.json 2>/dev/null || echo 0")
    [[ "${literal_count}" -eq 0 ]] \
        && final_check "No literal API keys in openclaw.json" "pass" \
        || final_check "No literal API keys in openclaw.json" "fail" "${literal_count} matches found"

    # ─── .env permissions ─────────────────────────────────────────────────────

    local env_perms
    env_perms=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
        "stat -c '%a' ~/.openclaw/.env 2>/dev/null || echo '000'")
    [[ "${env_perms}" == "600" ]] \
        && final_check ".env permissions = 600" "pass" \
        || final_check ".env permissions = 600" "fail" "Got: ${env_perms}"

    # ─── ssh.socket masked ────────────────────────────────────────────────────

    local socket_enabled
    socket_enabled=$(sudo systemctl is-enabled ssh.socket 2>/dev/null || echo "unknown")
    [[ "${socket_enabled}" == "masked" ]] \
        && final_check "ssh.socket is masked" "pass" \
        || final_check "ssh.socket is masked" "fail" "State: ${socket_enabled}"

    # ─── ubuntu shell ─────────────────────────────────────────────────────────

    local ubuntu_sh
    ubuntu_sh=$(getent passwd ubuntu 2>/dev/null | cut -d: -f7 || echo "unknown")
    [[ "${ubuntu_sh}" == "/bin/bash" ]] \
        && final_check "ubuntu user shell = /bin/bash" "pass" \
        || final_check "ubuntu user shell = /bin/bash" "fail" "Got: ${ubuntu_sh}"

    # ─── Node.js version ──────────────────────────────────────────────────────

    local node_major
    node_major=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
    [[ "${node_major}" -ge 22 ]] \
        && final_check "Node.js 22+ installed ($(node --version))" "pass" \
        || final_check "Node.js 22+ installed" "fail" "Got: $(node --version 2>/dev/null || echo 'none')"

    # ─── Gateway service ──────────────────────────────────────────────────────

    local gw_active
    gw_active=$(sudo -u "${OPENCLAW_USER}" -i bash -c \
        "systemctl --user is-active openclaw-gateway 2>/dev/null" || echo "unknown")
    [[ "${gw_active}" == "active" ]] \
        && final_check "openclaw-gateway service is active" "pass" \
        || final_check "openclaw-gateway service is active" "fail" "State: ${gw_active}"

    # ─── Generate report.md ───────────────────────────────────────────────────

    local report_path="${OPENCLAW_HOME}/report.md"
    local now
    now=$(date -u '+%Y-%m-%d %H:%M UTC')

    cat > "${report_path}" <<REPORTEOF
# OpenClaw Self-Install Report

**Generated:** ${now}
**Script version:** ${SCRIPT_VERSION}
**Result:** ${pass_count} passed, ${fail_count} failed, ${warn_count} warnings

---

## Verification Results

| Status | Check | Detail |
|--------|-------|--------|
REPORTEOF

    for line in "${report_lines[@]}"; do
        local status="${line%%|*}"
        local rest="${line#*|}"
        local desc="${rest%%|*}"
        local detail="${rest#*|}"
        local emoji
        case "${status}" in
            pass) emoji="✅" ;;
            fail) emoji="❌" ;;
            warn) emoji="⚠️" ;;
        esac
        echo "| ${emoji} | ${desc} | ${detail} |" >> "${report_path}"
    done

    cat >> "${report_path}" <<REPORTEOF2

---

## Environment

OS: $(lsb_release -d 2>/dev/null | cut -f2-)
Hostname: $(hostname)
Deployer: $(whoami)
Node.js: $(node --version 2>/dev/null || echo 'not installed')
OpenClaw: $(openclaw --version 2>/dev/null || echo 'not installed')
Tailscale IP: $(tailscale ip -4 2>/dev/null || echo 'unknown')

## Installed Components
- [x] Node.js + OpenClaw (Phase 1)
- [x] API Keys in ~/.openclaw/.env (Phase 2)
- [x] Model configuration (Phase 3)
- [x] Telegram bot (Phase 4)
- [x] Workspace files (Phase 5)

## Next Steps
1. Send "Hello" to your Telegram bot to test the connection
2. Personalize SOUL.md, USER.md in ~/.openclaw/workspace/
3. Review security audit: cat ~/security-audit.log
4. Set spending limits at: Anthropic, OpenRouter, MiniMax, OpenAI consoles
5. Consider setting up git remote for workspace backup

## Log
Full installation log: ${LOG_FILE}
REPORTEOF2

    sudo chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "${report_path}" 2>/dev/null || true

    echo ""
    log_ok "Report saved to ${report_path}"
    echo ""

    # ─── Summary ──────────────────────────────────────────────────────────────

    log_step "Installation Summary"
    echo ""
    echo -e "  ${GREEN}✓ Passed:${RESET}   ${pass_count}"
    echo -e "  ${RED}✗ Failed:${RESET}   ${fail_count}"
    echo -e "  ${YELLOW}⚠ Warnings:${RESET} ${warn_count}"
    echo ""

    if [[ ${fail_count} -gt 0 ]]; then
        log_warn "There were ${fail_count} failed checks. Review the report:"
        log_warn "  cat ${report_path}"
        log_warn "  cat ${LOG_FILE}"
    else
        log_ok "All checks passed! OpenClaw is ready."
    fi

    echo ""
    log_info "📱 Send 'Hello' to your Telegram bot to test connectivity."
    log_info "📋 Full log: ${LOG_FILE}"
    log_info "📊 Report:   ${report_path}"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║  OpenClaw Self-Installer v${SCRIPT_VERSION} — Mode B                 ║${RESET}"
    echo -e "${BOLD}${CYAN}║  Runs ON a pre-hardened Lightsail Ubuntu 24.04 box         ║${RESET}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${CYAN}Timestamp:${RESET} $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo -e "  ${CYAN}Log:${RESET}       ${LOG_FILE}"
    if [[ "${DRY_RUN}" == "true" ]];    then echo -e "  ${YELLOW}Mode:${RESET}      DRY-RUN (no changes)"; fi
    if [[ "${SKIP_VERIFY}" == "true" ]]; then echo -e "  ${YELLOW}Flag:${RESET}      --skip-verify"; fi
    if [[ "${SKIP_EXTRAS}" == "true" ]]; then echo -e "  ${YELLOW}Flag:${RESET}      --skip-extras"; fi
    echo ""

    # Ensure log dir is writable by deployer via sudo
    if [[ ! -d "$(dirname "${LOG_FILE}")" ]]; then
        sudo mkdir -p "$(dirname "${LOG_FILE}")"
        sudo chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "$(dirname "${LOG_FILE}")"
        sudo chmod 750 "$(dirname "${LOG_FILE}")"
    fi

    preflight_checks

    echo ""
    log_info "This script will install and configure OpenClaw in 7 phases:"
    echo "  Phase 0: Verify hardened environment"
    echo "  Phase 1: Install Node.js + OpenClaw"
    echo "  Phase 2: API keys + secrets"
    echo "  Phase 3: Model configuration (OpenRouter for Qwen)"
    echo "  Phase 4: Telegram bot"
    echo "  Phase 5: Workspace setup"
    echo "  Phase 6: Optional extras (FAISS, cost tracking, dashboard)"
    echo "  Phase 7: Final verification + report"
    echo ""

    if ! ask_yes_no "Ready to begin?"; then
        log_info "Aborted."
        exit 0
    fi

    phase0_verify
    phase1_install_openclaw  || { log_fail "Phase 1 failed."; exit 2; }
    phase2_api_keys          || { log_fail "Phase 2 failed."; exit 2; }
    phase3_model_config      || { log_fail "Phase 3 failed."; exit 2; }
    phase4_telegram          || { log_warn "Phase 4 had issues (non-fatal)."; }
    phase5_workspace         || { log_fail "Phase 5 failed."; exit 2; }
    phase6_extras
    phase7_final_verify

    exit 0
}

main "$@"
