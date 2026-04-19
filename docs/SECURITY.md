# Security Model & Hardening Guide

This document describes the security architecture of a bootstrapped OpenClaw instance and provides guidance for additional hardening.

## Threat Model

We're protecting against:
1. **Unauthorized access to the AI agent** (someone else controlling your assistant)
2. **API key theft** (exposing Anthropic/OpenAI keys)
3. **Server compromise** (SSH brute force, vulnerability exploitation)
4. **Data exfiltration** (workspace files, conversation history)

We are NOT trying to protect against:
- Nation-state adversaries
- Physical server access
- Zero-day vulnerabilities in Ubuntu core

## Default Security Posture

### Network Layer
```
Internet → UFW (deny all incoming except SSH 22) → Server
```
- All inbound ports blocked except SSH (22)
- OpenClaw gateway binds to `127.0.0.1` only — not reachable from internet
- Outbound connections allowed (needed for API calls to Anthropic, etc.)

### SSH Layer
- Password authentication: **disabled**
- Root login: **disabled**  
- Public key authentication: **required**
- fail2ban: bans IPs after 5 failed attempts, 1-hour ban duration

### Application Layer
- OpenClaw runs as unprivileged `openclaw` user
- API keys stored in `~/.openclaw/.env` (mode 600 — owner read-only)
- Gateway requires token authentication
- Tools run with configurable security profiles

## Tailscale (Strongly Recommended)

For accessing OpenClaw remotely, Tailscale is far superior to exposing ports:

```bash
# Install
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Your server gets a stable Tailscale IP (e.g., 100.x.x.x)
# Access from anywhere via your Tailscale network
```

**Benefits of Tailscale:**
- Zero open ports on the internet (SSH can be blocked too once Tailscale is set up)
- WireGuard-based encryption for all traffic
- MagicDNS for stable hostnames
- Works through firewalls/NAT
- Free for personal use (up to 100 devices)

Once Tailscale is configured, you can further tighten UFW:
```bash
# Allow SSH only from Tailscale network
sudo ufw delete allow ssh
sudo ufw allow in on tailscale0 to any port 22
sudo ufw reload
```

## Hardening Checklist

### Essential (done by bootstrap.sh)
- [x] SSH key-only auth
- [x] Root login disabled
- [x] UFW firewall enabled
- [x] fail2ban installed
- [x] Unattended security upgrades
- [x] Non-root application user
- [x] API keys in 600-mode file

### Recommended
- [ ] Tailscale for remote access
- [ ] SSH on non-standard port (reduces log noise)
- [ ] Disable IPv6 if not needed
- [ ] Regular `apt-get upgrade` cadence
- [ ] Backup encryption with Restic

### Advanced
- [ ] AppArmor profile for OpenClaw
- [ ] Audit logging with auditd
- [ ] Log shipping to external SIEM
- [ ] Port knocking for SSH

## SSH Hardening Details

The bootstrap configures `/etc/ssh/sshd_config` with:

```
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
```

Additional hardening you can add manually:

```
# Use strong ciphers only
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Limit auth attempts
MaxAuthTries 3
MaxSessions 3

# Disable unused features
X11Forwarding no
AllowTcpForwarding no
GatewayPorts no

# Restrict to specific users
AllowUsers openclaw YOUR_ADMIN_USER
```

After any sshd_config change, always test before reloading:
```bash
sudo sshd -t && sudo systemctl reload sshd
```

## Secrets Management

### What's stored where

| Secret | Location | Mode | Notes |
|--------|----------|------|-------|
| API keys | `~/.openclaw/.env` | 600 | Never commit |
| Gateway token | `~/.openclaw/.env` | 600 | Auto-generated |
| SSH private key | Your local machine | 600 | Never on server |
| Backup passphrase | `~/.openclaw/.backup-env` | 600 | Separate from .env |

### Best practices
- Rotate `GATEWAY_AUTH_TOKEN` if you suspect exposure: update `.env` and restart gateway
- Use separate API keys per service/environment when possible
- Anthropic allows multiple API keys — use a dedicated key for your server
- Enable spending limits on your API dashboard

## Monitoring

### What to watch

```bash
# Fail2ban activity
sudo fail2ban-client status sshd

# UFW blocked connections
sudo grep "UFW BLOCK" /var/log/ufw.log | tail -20

# Auth log for SSH attempts
sudo grep "Failed password\|Invalid user" /var/log/auth.log | tail -20

# OpenClaw gateway logs
sudo -u openclaw journalctl --user -u openclaw-gateway -n 50
```

### Alerting

Consider adding heartbeat checks that alert on:
- High failed SSH attempt rate
- Disk space > 85%
- Gateway down
- Unusual outbound traffic patterns

See `templates/HEARTBEAT.md.example` for a starting point.

## Incident Response

### If you suspect compromise

1. **Rotate all API keys immediately** — Anthropic, OpenRouter, OpenAI dashboards
2. **Revoke and regenerate GATEWAY_AUTH_TOKEN** in `.env`, restart gateway
3. **Review auth logs**: `sudo grep -E "(Accepted|Failed)" /var/log/auth.log`
4. **Check for unauthorized SSH keys**: `cat ~/.ssh/authorized_keys`
5. **Review running processes**: `ps aux | grep -v "\["`
6. **Check for new users**: `grep -v nologin /etc/passwd`
7. **Consider rebuilding** from a fresh Lightsail snapshot

### If locked out of SSH

If you've locked yourself out (common mistake when hardening):
- **Lightsail**: Use the browser-based SSH console in the Lightsail dashboard
- **Other VPS**: Check for emergency console/recovery mode
- Recovery: `sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config && sudo systemctl restart sshd`
