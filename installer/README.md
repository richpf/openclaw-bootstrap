# OpenClaw Installer

End-to-end installer for a fork of the Richard chief-of-staff OpenClaw
deployment, given a provisioned Lightsail box (Track B) and a rendered
workspace bundle (Track A).

---

## Prerequisites

| What | Where it comes from |
|------|---------------------|
| Lightsail state file (`state.json`) | `provisioner/state/{slug}.json` — Track B output |
| Workspace bundle (`{slug}-workspace/`) | `fork-template/out/{slug}-workspace/` — Track A output |
| SSH access via Tailscale | Box hardened by Track B cloud-init |
| Python 3.9+ with `paramiko` | `pip install -r requirements.txt` |

Install Python dependencies:

```bash
pip install paramiko requests
```

---

## Basic Usage

```bash
python3 installer/install_openclaw.py \
  provisioner/state/acme-prod.json \
  fork-template/out/acme-prod-workspace/
```

The installer will:
1. Connect via SSH (Tailscale IP, port 2222, as `deployer`)
2. Prompt you for API keys (securely via `getpass`)
3. Execute 13 idempotent steps (A → M)
4. Save a log + report in `installer/state/`

---

## Options

| Flag | Description |
|------|-------------|
| `--dry-run` | Simulate all steps without executing |
| `--skip-keys-prompt` | Read keys from file instead of prompting |
| `--keys-file PATH` | Path to `keys.env` file (default: `keys.env`) |
| `--resume-from STEP_ID` | Skip steps before STEP_ID |
| `--openclaw-npm-package PKG` | Override npm package (default: `openclaw@latest`) |
| `--ssh-key PATH` | Path to SSH private key |
| `--quiet` | Reduce verbosity |

---

## Step IDs

| ID | Description |
|----|-------------|
| `A_preflight` | SSH reachable, sudo works, hardening sentinel present |
| `B_nodejs` | Install Node.js 22+ via NodeSource |
| `C_openclaw_install` | Install OpenClaw globally (`npm install -g openclaw@latest`) |
| `D_upload_bundle` | Upload workspace bundle to `/home/openclaw/.openclaw/workspace/` |
| `E_onboard` | Run `openclaw onboard`, enable linger |
| `F_secrets` | Collect API keys, write `.env` (mode 600) |
| `G_hardening` | Apply 20+ openclaw security config settings |
| `H_providers` | Configure Anthropic + OpenRouter (Qwen) + optional providers |
| `I_telegram` | Configure Telegram channel, register webhook |
| `J_storage` | Initialize FAISS index + SQLite schema |
| `K_audit` | Run `openclaw security audit --deep` |
| `L_smoke_test` | Gateway smoke test (round-trip latency) |
| `M_report` | Generate human-readable report |

---

## Recovering from Mid-Install Failures

If an install fails at step `G_hardening`, re-run with:

```bash
python3 installer/install_openclaw.py \
  provisioner/state/acme-prod.json \
  fork-template/out/acme-prod-workspace/ \
  --resume-from G_hardening \
  --skip-keys-prompt \
  --keys-file keys.env
```

Every step is **idempotent** — it checks whether its work is already done
before executing. Re-running any step is safe.

---

## Non-Interactive / CI Usage

Create a `keys.env` file (never commit this):

```bash
# keys.env — keep out of version control
ANTHROPIC_API_KEY=sk-ant-...
OPENROUTER_API_KEY=sk-or-...
TELEGRAM_BOT_TOKEN=123456:ABC...
OPENAI_API_KEY=sk-...          # optional
TAVILY_API_KEY=tvly-...        # optional
```

Then run:

```bash
python3 installer/install_openclaw.py \
  provisioner/state/acme-prod.json \
  fork-template/out/acme-prod-workspace/ \
  --skip-keys-prompt \
  --keys-file keys.env
```

---

## Logs and Reports

| File | Description |
|------|-------------|
| `installer/state/install-{slug}-{ts}.log` | JSON-line structured log |
| `installer/state/install-{slug}.report.md` | Human-readable summary |

The log file supports tail-following during install:
```bash
tail -f installer/state/install-acme-prod-*.log | python3 -c \
  'import sys,json; [print(json.loads(l).get("msg","")) for l in sys.stdin]'
```

---

## Architecture Notes

- **OpenClaw npm package**: The installer defaults to `openclaw@latest`.
  If the published package name differs, override with `--openclaw-npm-package`.
  > ⚠ **Open question**: confirm the npm package name. The parent host uses
  > `openclaw` but the package may be `@openclaw/cli`. Update `DEFAULT_NPM_PACKAGE`
  > in `install_openclaw.py` if needed.

- **Qwen via OpenRouter**: Provider config uses `https://openrouter.ai/api/v1`
  with `OPENROUTER_API_KEY`. DashScope/Alibaba is NOT used.

- **fork.yaml.used**: The installer looks for `{bundle}/fork.yaml.used`.
  `fork.sh` should copy the resolved YAML into the bundle as `fork.yaml.used`.
  If missing, a warning is printed but install continues.

- **operator_telegram_id**: If the state file omits this field, the installer
  skips the test DM and prints instructions for the operator to DM the bot first.

---

## Directory Structure

```
installer/
├── install_openclaw.py      # Main CLI
├── README.md                # This file
├── lib/
│   ├── __init__.py
│   ├── state_loader.py      # Load/validate Track-B state JSON
│   ├── ssh_helpers.py       # SSHClient + MockSSHTransport
│   ├── key_validators.py    # Anthropic/OpenRouter/Telegram validation
│   └── step_runner.py       # Step framework, logging, resume
├── tests/
│   ├── test_installer.py    # pytest test suite (30+ tests)
│   └── fixtures/
│       ├── state.json           # Example state file
│       └── install_dry_run.expected.log  # Dry-run transcript snapshot
└── state/                   # Generated logs and reports (gitignored)
```
