# Troubleshooting Guide

Common issues and their solutions for OpenClaw deployments.

---

## Table of Contents

- [Gateway Issues](#gateway-issues)
- [Node.js & npm Issues](#nodejs--npm-issues)
- [SSH & Access Issues](#ssh--access-issues)
- [Messaging Channel Issues](#messaging-channel-issues)
- [API Key Issues](#api-key-issues)
- [Systemd Service Issues](#systemd-service-issues)
- [Memory & Performance](#memory--performance)
- [Firewall Issues](#firewall-issues)

---

## Gateway Issues

### Gateway won't start

**Symptoms:** `systemctl --user status openclaw-gateway` shows `failed`

**Check logs first:**
```bash
sudo -u openclaw journalctl --user -u openclaw-gateway -n 50
```

**Common causes:**

1. **Missing or invalid API key**
   ```bash
   sudo -u openclaw cat /home/openclaw/.openclaw/.env
   # Verify ANTHROPIC_API_KEY starts with sk-ant-
   ```

2. **Port already in use**
   ```bash
   ss -tlnp | grep 18789
   # If something else is on 18789, change the port in openclaw.json
   ```

3. **Bad JSON in openclaw.json**
   ```bash
   sudo -u openclaw cat /home/openclaw/.openclaw/openclaw.json | python3 -m json.tool
   # Will show syntax errors
   ```
   Note: Remove any `//` comments from the JSON file (standard JSON doesn't support comments)

4. **Environment file not found**
   ```bash
   ls -la /home/openclaw/.openclaw/.env
   # Must exist and be readable by the openclaw user
   ```

### Gateway starts but doesn't respond

```bash
# Test locally
curl -v http://127.0.0.1:18789/health

# Check if it's actually binding
ss -tlnp | grep 18789
```

### Gateway crashes after a few hours

Usually memory pressure on small instances:
```bash
free -h
# If memory is nearly full, add/increase swap
# See: bootstrap.sh --swap-size 2
```

---

## Node.js & npm Issues

### `openclaw: command not found`

```bash
# Check if npm global bin is in PATH
npm config get prefix
# Usually /usr/local or /usr

# Check where openclaw was installed
which openclaw || find /usr -name "openclaw" 2>/dev/null

# Add to PATH if needed (add to ~/.bashrc)
export PATH="$(npm config get prefix)/bin:$PATH"
```

### Node.js version too old

```bash
node --version  # Need v22+

# Reinstall via NodeSource
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
sudo apt-get install -y nodejs
```

### npm permission errors during install

```bash
# Avoid using sudo with npm install -g when possible
# If needed, fix npm prefix permissions:
sudo chown -R $(whoami) $(npm config get prefix)/lib/node_modules
sudo chown -R $(whoami) $(npm config get prefix)/bin
```

---

## SSH & Access Issues

### Locked out after running bootstrap

**Use Lightsail's browser SSH console:**
1. Go to AWS Lightsail dashboard
2. Click your instance → Connect tab
3. Use "Connect using SSH" browser terminal

Once in:
```bash
# Temporarily re-enable password auth
sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

Then fix your SSH key setup before re-hardening.

### SSH key rejected

```bash
# On your local machine:
ssh-add -l  # List loaded keys
ssh-add ~/.ssh/your_key  # Add key

# Check server authorized_keys
cat /home/openclaw/.ssh/authorized_keys

# Permissions must be correct
chmod 700 /home/openclaw/.ssh
chmod 600 /home/openclaw/.ssh/authorized_keys
chown -R openclaw:openclaw /home/openclaw/.ssh
```

### SSH connection times out

```bash
# Check if UFW is blocking you
sudo ufw status

# Ensure SSH is allowed
sudo ufw allow ssh

# Check if fail2ban banned your IP
sudo fail2ban-client status sshd
# Unban: sudo fail2ban-client set sshd unbanip YOUR_IP
```

---

## Messaging Channel Issues

### Telegram bot not responding

1. **Verify bot token is correct** — get from @BotFather
2. **Check you messaged the bot directly** (not a channel/group it's not configured for)
3. **Confirm your user ID is allowed:**
   ```bash
   # Find your Telegram user ID via @userinfobot
   # Then check openclaw.json channels config
   ```
4. **Check gateway is running and channel is enabled:**
   ```bash
   sudo -u openclaw journalctl --user -u openclaw-gateway -n 30
   # Look for channel connection messages
   ```

### Discord bot offline

1. Verify the bot token in your config
2. Ensure the bot has the correct intents enabled in Discord Developer Portal
3. Check gateway logs for connection errors

### Channel connected but messages don't send

```bash
# Check for rate limiting or API errors in logs
sudo -u openclaw journalctl --user -u openclaw-gateway --since "10 minutes ago"
```

---

## API Key Issues

### `Authentication error` / `Invalid API key`

```bash
# View current env (keys partially shown)
sudo -u openclaw bash -c 'source ~/.openclaw/.env && echo "ANTHROPIC: ${ANTHROPIC_API_KEY:0:20}..."'

# Test Anthropic key directly
curl -s https://api.anthropic.com/v1/models \
  -H "x-api-key: YOUR_KEY" \
  -H "anthropic-version: 2023-06-01" | python3 -m json.tool
```

### Model not available

If you see "model not in allowlist" errors:
```bash
# Check your allowlist in openclaw.json
grep -A 10 '"allowlist"' /home/openclaw/.openclaw/openclaw.json
```

Models not in the allowlist silently downgrade to the primary model. Make sure the model string matches exactly.

### API rate limits

- Anthropic: Check your tier at console.anthropic.com
- Reduce concurrent sub-agents if hitting limits
- Consider using cheaper models for sub-agent work

---

## Systemd Service Issues

### Service won't enable/start as user

**Symptom:** `Failed to connect to bus: No such file or directory`

This happens when the XDG_RUNTIME_DIR isn't available yet:

```bash
# Ensure lingering is enabled
sudo loginctl enable-linger openclaw

# Check if runtime dir exists
ls /run/user/$(id -u openclaw)
# If it doesn't exist, log out and back in, or reboot

# Manual start with explicit env:
sudo -u openclaw \
  XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  systemctl --user start openclaw-gateway
```

### Service starts but exits immediately

```bash
# Check full logs including startup errors
sudo -u openclaw journalctl --user -u openclaw-gateway -n 100

# Try running manually to see error directly
sudo -u openclaw bash -c '
  source ~/.openclaw/.env
  openclaw gateway start --foreground
'
```

### Service file changes not applied

```bash
sudo -u openclaw \
  XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  systemctl --user daemon-reload

sudo -u openclaw \
  XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  systemctl --user restart openclaw-gateway
```

---

## Memory & Performance

### Out of memory / OOM kills

```bash
# Check current memory and swap
free -h
swapon --show

# Check for OOM events
sudo dmesg | grep -i "out of memory\|oom"

# Add swap if needed
sudo fallocate -l 2G /swapfile2
sudo chmod 600 /swapfile2
sudo mkswap /swapfile2
sudo swapon /swapfile2
echo '/swapfile2 none swap sw 0 0' | sudo tee -a /etc/fstab
```

### High CPU usage

```bash
# Check what's using CPU
top -u openclaw
# or
ps aux --sort=-%cpu | head -20

# OpenClaw sub-agents spawn processes — this is normal during active tasks
# Persistent high CPU may indicate a stuck agent loop
sudo -u openclaw journalctl --user -u openclaw-gateway -n 50
```

### Disk space issues

```bash
df -h /
du -sh /home/openclaw/.openclaw/*/

# Common culprits:
# - Workspace files: ~/.openclaw/workspace/
# - Logs: check journal size
sudo journalctl --disk-usage
# Vacuum old logs
sudo journalctl --vacuum-time=30d
```

---

## Firewall Issues

### UFW blocking legitimate traffic

```bash
# Check UFW status
sudo ufw status verbose

# View UFW log
sudo tail -f /var/log/ufw.log

# Temporarily disable to test if UFW is the issue
sudo ufw disable
# (remember to re-enable: sudo ufw enable)

# Allow a specific port
sudo ufw allow 8080/tcp
```

### Tailscale not connecting through UFW

```bash
# Allow Tailscale interface
sudo ufw allow in on tailscale0
sudo ufw reload

# Or add the Tailscale subnet
sudo ufw allow from 100.64.0.0/10
```

---

## Getting More Help

1. **Check the OpenClaw docs:** https://openclaw.dev/docs
2. **Review full bootstrap log:** `/tmp/openclaw-bootstrap.log`
3. **Enable verbose gateway logging** in `openclaw.json`:
   ```json
   "logging": { "level": "debug" }
   ```
4. **File an issue** on the bootstrap repo with your log output (redact API keys!)
