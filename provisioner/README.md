# OpenClaw Lightsail Provisioner

Automates Sections 1–13 of the [hardening runbook](../docs/SECURITY.md) for a fresh Amazon Lightsail Ubuntu 24.04 instance. Outputs a state file (`state/{slug}.json`) that feeds Track C (OpenClaw software install).

---

## What it does

| Step | Runbook Section | Description |
|------|----------------|-------------|
| A    | Preflight      | Validate AWS creds, Lightsail blueprint/plan, Route53 zone, Tailscale key format |
| B    | —              | Create/reuse Lightsail SSH keypair `openclaw-{slug}` |
| C    | S1–S2          | Launch instance with cloud-init user-data (hardening baked in) |
| D    | S0             | Allocate + attach static IP |
| E    | S4             | Set initial Lightsail firewall (22/80/443 open) |
| F    | —              | Upsert Route 53 A records (`domain` + `www.domain`) |
| G    | —              | Poll until instance is `running` + SSH is reachable |
| H    | S1–S13         | Wait for cloud-init to finish (polls `/var/lib/cloud/instance/boot-finished`) |
| I    | S5             | Read Tailscale IP via SSH (`tailscale ip -4`) |
| J    | S13            | Post-boot verification: deployer user, SSH on 2222, UFW, watchdog cron, masked socket |
| K    | S4             | Tighten Lightsail firewall: remove public port 22, leave 80/443 only |
| L    | —              | Write `state/{slug}.json` (feeds Track C) |
| M    | —              | Print final report with next-step command |

### What it does NOT do

- **OpenClaw software install** — that is Track C (`install_openclaw.py state/{slug}.json`)
- **Backblaze B2 restic repo init** — requires B2 creds, done post-install
- **Telegram bot setup** — first-boot interview handles it
- **Push to git** — operator must push after review

---

## Requirements

```bash
# Python 3.10+ required
pip install -r requirements.txt
```

Or use a venv:
```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

---

## Required environment variables

| Variable                        | Description |
|---------------------------------|-------------|
| `TAILSCALE_AUTH_KEY`            | Tailscale auth key (format: `tskey-auth-...`). Generate at https://login.tailscale.com/admin/settings/keys — use **one-off** reusable auth key. |
| AWS credentials                 | Either via `~/.aws/credentials` profile, or standard `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars. |

The env var name is read from `infra.tailscale_auth_key_env` in fork.yaml (default: `TAILSCALE_AUTH_KEY`).

---

## Usage

### 1. Copy and fill in fork.yaml

```bash
cp tests/fixtures/fork.sample.yaml my-fork.yaml
# Edit my-fork.yaml — fill in domain, email, git remotes, etc.
```

### 2. Dry run (safe — no AWS calls)

```bash
export TAILSCALE_AUTH_KEY="tskey-auth-YOUR-KEY"
python3 provision_lightsail.py my-fork.yaml --dry-run --skip-dns
```

The dry-run prints:
- The full cloud-init YAML that would be uploaded
- Every planned API call (boto3 / Route53 / SSH)
- A state file written to `state/{slug}.json`

### 3. Live run

```bash
export TAILSCALE_AUTH_KEY="tskey-auth-YOUR-KEY"
python3 provision_lightsail.py my-fork.yaml [--aws-profile myprofile] [--skip-dns]
```

Takes ~15–20 minutes (cloud-init installs Docker, Tailscale, certbot, etc.).

---

## fork.yaml schema additions (provisioner-specific)

The provisioner reads the standard fork.yaml schema plus two new fields under `infra`:

```yaml
infra:
  tailscale_auth_key_env: "TAILSCALE_AUTH_KEY"   # REQUIRED: env var holding the auth key
  ssh_pubkey_path: "~/.ssh/id_ed25519.pub"        # OPTIONAL: operator pubkey path (default shown)
  deployer_pubkey_path: ""                         # OPTIONAL: additional pubkey for CI/automation
  slug: "myinstance"                               # OPTIONAL: derived from git.github_handle if omitted
```

---

## Security safeguards baked into cloud-init

The cloud-init template explicitly implements three safeguards learned from a prior lockout incident:

1. **`systemctl mask ssh.socket`** — creates a `/dev/null` symlink that survives `openssh-server` package updates (a plain `disable` can be reversed by `unattended-upgrades`).

2. **`passwd -l ubuntu`** (not `usermod -s /usr/sbin/nologin ubuntu`) — locks the ubuntu password but preserves the `/bin/bash` shell. The Lightsail browser console connects as `ubuntu` on port 22 via an internal AWS path — setting `nologin` blocks this last-resort recovery path.

3. **SSH watchdog cron** (`@reboot root sleep 30 && /usr/local/bin/ssh-watchdog`) — on every reboot, verifies SSH is listening on port 2222. If not, re-masks the socket and restarts the SSH service. Logs to `/var/log/openclaw/ssh-watchdog.log`.

---

## Recovering from common failures

### Tailscale auth key expired or invalid

**Symptom:** Tailscale does not come up during cloud-init; `tailscale ip -4` returns empty.

**Recovery:**
1. Generate a new auth key at https://login.tailscale.com/admin/settings/keys
2. SSH into the instance via Lightsail browser console (`ubuntu` user, port 22)
3. `sudo tailscale up --authkey=tskey-auth-NEW-KEY --hostname=openclaw-{slug}`
4. Verify: `tailscale ip -4` returns a `100.x.x.x` address

### DNS propagation slow

**Symptom:** certbot fails because the domain doesn't resolve yet.

**Recovery:** certbot will fail silently in cloud-init. After propagation (~5 min to ~48 hr depending on registrar):
```bash
ssh -p 2222 deployer@<tailscale-ip>
sudo certbot --nginx -d your.domain -d www.your.domain --non-interactive --agree-tos -m you@example.com --redirect
sudo systemctl reload nginx
```

### cloud-init hang

**Symptom:** Step H (`wait_for_cloud_init`) times out after ~20 minutes.

**Recovery:**
1. SSH in as `ubuntu` on port 22 (browser console if needed)
2. Check: `sudo tail -f /var/log/cloud-init-output.log`
3. Look for the last successful step, then resume manually
4. Common causes: `aideinit` is slow (~5 min on large filesystems), Docker GPG fetch timeout

### Instance unreachable post-hardening

**Symptom:** Can't SSH on port 2222 after provisioning completes.

**Recovery** (in order):
1. Check Lightsail browser console → connect as `ubuntu`
2. Run: `sudo /usr/local/bin/ssh-watchdog`
3. Check: `sudo systemctl status ssh.socket` — must show `masked`
4. Check: `sudo ss -tlnp | grep 2222` — must show listener
5. If Tailscale is down: `sudo systemctl restart tailscaled`

---

## State file format

`state/{slug}.json` is written after successful provisioning:

```json
{
  "slug": "myinstance",
  "instance_name": "openclaw-myinstance",
  "static_ip": "1.2.3.4",
  "tailscale_ip": "100.64.x.x",
  "keypair_name": "openclaw-myinstance",
  "aws_region": "us-west-2",
  "domain": "example.com",
  "ssh_fingerprint": "...",
  "timestamp_start": "2026-04-24T00:00:00+00:00",
  "timestamp_complete": "2026-04-24T00:18:42+00:00",
  "runbook_sections_complete": ["preflight", "keypair", "instance", ...],
  "aws_instance_arn": "arn:aws:lightsail:us-west-2:...",
  "aws_static_ip_name": "openclaw-myinstance-ip",
  "lightsail_plan": "medium_2_0",
  "parent_hostname": "openclaw-orchestrator"
}
```

---

## Running tests

```bash
cd provisioner
pytest tests/ -v
```

All 50 tests pass, no live AWS calls made. The snapshot test (`test_matches_expected_snapshot`) writes `tests/fixtures/cloud_init.expected.yaml` on first run, then diffs against it on subsequent runs.

---

## Files

```
provisioner/
├── provision_lightsail.py       # Main CLI
├── cloud_init.yaml.j2           # Jinja2 cloud-init template (S1–S13)
├── requirements.txt             # Python dependencies
├── README.md                    # This file
├── state/                       # State files (git-ignored — contain IPs)
│   └── {slug}.json
└── tests/
    ├── __init__.py
    ├── test_provisioner.py       # 50 pytest tests
    └── fixtures/
        ├── fork.sample.yaml      # Sample fork config for dry-run
        ├── cloud_init.expected.yaml  # Snapshot fixture (generated on first run)
        └── dry_run.expected.log  # Dry-run transcript for regression testing
```
