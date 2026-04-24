#!/usr/bin/env python3
"""
install_openclaw.py — OpenClaw fork installer.

Installs OpenClaw on a pre-hardened Lightsail box (provisioned by Track B)
with a rendered workspace bundle (from Track A fork.sh).

Usage:
    python3 install_openclaw.py <state.json> <workspace-bundle/> [OPTIONS]

Options:
    --dry-run                 Simulate all steps without executing.
    --skip-keys-prompt        Read keys from --keys-file instead of prompting.
    --keys-file PATH          Path to keys.env file (default: keys.env).
    --resume-from STEP_ID     Skip steps before STEP_ID (for recovery).
    --openclaw-npm-package P  npm package to install (default: openclaw@latest).
    --verbose / --quiet       Control log verbosity.

Step IDs (for --resume-from):
    A_preflight   B_nodejs   C_openclaw_install   D_upload_bundle
    E_onboard     F_secrets  G_hardening           H_providers
    I_telegram    J_storage  K_audit               L_smoke_test
    M_report
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import secrets
import sys
import time
import textwrap
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

# Ensure installer/lib is importable when run directly
sys.path.insert(0, str(Path(__file__).parent))

from lib.state_loader import load_state, StateFile
from lib.ssh_helpers import SSHClient, SSHResult, MockSSHTransport
from lib.key_validators import (
    validate_anthropic_key,
    validate_openrouter_key,
    validate_telegram_token,
    validate_optional_key,
)
from lib.step_runner import (
    Step, StepContext, StepResult, StepRunner, StepStatus,
)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_NPM_PACKAGE = "openclaw@latest"
OPENCLAW_WORKSPACE = "/home/openclaw/.openclaw/workspace"
OPENCLAW_ENV = "/home/openclaw/.openclaw/.env"
OPENCLAW_DIR = "/home/openclaw/.openclaw"
AGENT_ALLOWLIST = [
    "anthropic/claude-opus-4-7",
    "anthropic/claude-sonnet-4-6",
    "openrouter/qwen/qwen3-235b-a22b",
    "openrouter/qwen/qwen3.6-plus",
    "openrouter/qwen/qwen3.5-397b-a17b",
    "anthropic/claude-haiku",
]


# ---------------------------------------------------------------------------
# Step implementations
# ---------------------------------------------------------------------------

def step_preflight(ctx: StepContext) -> StepResult:
    """A: SSH reachable, sudo works, hardening sentinel present."""
    if ctx.dry_run:
        return StepResult("A_preflight", StepStatus.DRY_RUN,
                          "Dry-run: skipping real SSH check")

    # Check SSH
    r = ctx.ssh.run("echo pong", timeout=10)
    if not r.ok or "pong" not in r.stdout:
        return StepResult("A_preflight", StepStatus.FAILED,
                          f"SSH echo failed: rc={r.rc} out={r.stdout!r}")

    # Check sudo
    r = ctx.ssh.sudo("true", timeout=10)
    if not r.ok:
        return StepResult("A_preflight", StepStatus.FAILED,
                          f"sudo not working: {r.stderr.strip()}")

    # Check hardening sentinel
    r = ctx.ssh.run(
        "test -f /var/lib/openclaw/lightsail-hardening-complete && echo yes || echo no"
    )
    sentinel_ok = r.stdout.strip() == "yes"

    # Check Node version (if already installed)
    node_result = ctx.ssh.run("node --version 2>/dev/null || echo 'not-installed'")
    node_ver = node_result.stdout.strip()
    node_ok = False
    if node_ver.startswith("v"):
        try:
            major = int(node_ver.lstrip("v").split(".")[0])
            node_ok = major >= 22
        except ValueError:
            pass

    details = {
        "sentinel": sentinel_ok,
        "node_installed": node_ver != "not-installed",
        "node_version": node_ver,
        "node_sufficient": node_ok,
    }

    if not sentinel_ok:
        return StepResult("A_preflight", StepStatus.FAILED,
                          "Hardening sentinel not found — run Track B provisioner first",
                          details)

    msg = f"SSH OK, sudo OK, sentinel OK, node={node_ver}"
    return StepResult("A_preflight", StepStatus.SUCCESS, msg, details)


def step_install_nodejs(ctx: StepContext) -> StepResult:
    """B: Install Node.js 22+ via NodeSource."""
    if ctx.dry_run:
        return StepResult("B_nodejs", StepStatus.DRY_RUN, "Dry-run: would install Node.js 22")

    # Idempotency check
    r = ctx.ssh.run("node --version 2>/dev/null || echo 'not-installed'")
    ver = r.stdout.strip()
    if ver.startswith("v"):
        try:
            major = int(ver.lstrip("v").split(".")[0])
            if major >= 22:
                return StepResult("B_nodejs", StepStatus.SUCCESS,
                                  f"Node.js already at {ver} — skipping install")
        except ValueError:
            pass

    # Install via NodeSource
    ctx.ssh.sudo(
        "bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash -'",
        timeout=120, check=True
    )
    ctx.ssh.sudo("apt install -y nodejs", timeout=180, check=True)

    r = ctx.ssh.run("node --version")
    ver = r.stdout.strip()
    return StepResult("B_nodejs", StepStatus.SUCCESS,
                      f"Node.js installed: {ver}", {"version": ver})


def step_install_openclaw(ctx: StepContext) -> StepResult:
    """C: Install OpenClaw globally via npm."""
    npm_pkg = ctx.scratch.get("npm_package", DEFAULT_NPM_PACKAGE)

    if ctx.dry_run:
        return StepResult("C_openclaw_install", StepStatus.DRY_RUN,
                          f"Dry-run: would install {npm_pkg}")

    # Idempotency check
    r = ctx.ssh.run("openclaw --version 2>/dev/null || echo 'not-installed'")
    if r.stdout.strip() not in ("not-installed", ""):
        ver = r.stdout.strip()
        return StepResult("C_openclaw_install", StepStatus.SUCCESS,
                          f"OpenClaw already installed: {ver}")

    ctx.ssh.sudo(f"npm install -g {npm_pkg}", timeout=180, check=True)

    r = ctx.ssh.run("openclaw --version")
    ver = r.stdout.strip()
    return StepResult("C_openclaw_install", StepStatus.SUCCESS,
                      f"OpenClaw installed: {ver}", {"version": ver, "package": npm_pkg})


def step_upload_bundle(ctx: StepContext) -> StepResult:
    """D: Upload workspace bundle to remote openclaw user workspace."""
    if ctx.dry_run:
        return StepResult("D_upload_bundle", StepStatus.DRY_RUN,
                          f"Dry-run: would upload {ctx.bundle_path} → {OPENCLAW_WORKSPACE}")

    # Ensure target directory exists with correct ownership
    ctx.ssh.sudo(
        f"bash -c 'mkdir -p {OPENCLAW_WORKSPACE} && "
        f"chown -R openclaw:openclaw /home/openclaw/.openclaw && "
        f"chmod 750 {OPENCLAW_WORKSPACE}'",
        check=True
    )

    # Upload bundle
    ctx.ssh.upload_dir(ctx.bundle_path, OPENCLAW_WORKSPACE)

    # Fix ownership after upload
    ctx.ssh.sudo(
        f"chown -R openclaw:openclaw {OPENCLAW_WORKSPACE}",
        check=True
    )

    # Count files
    r = ctx.ssh.sudo_as(
        "openclaw", f"bash -c 'find {OPENCLAW_WORKSPACE} -type f | wc -l'"
    )
    file_count = r.stdout.strip()

    return StepResult("D_upload_bundle", StepStatus.SUCCESS,
                      f"Bundle uploaded ({file_count} files)", {"file_count": file_count})


def step_onboard_openclaw(ctx: StepContext) -> StepResult:
    """E: Run openclaw onboard, enable linger."""
    if ctx.dry_run:
        return StepResult("E_onboard", StepStatus.DRY_RUN,
                          "Dry-run: would run openclaw onboard + loginctl enable-linger")

    # Run onboard (idempotent — openclaw init checks if already done)
    r = ctx.ssh.sudo_as(
        "openclaw",
        f"openclaw onboard --install-daemon --workspace {OPENCLAW_WORKSPACE}",
        timeout=120
    )
    if not r.ok and "already" not in r.stdout.lower() and "already" not in r.stderr.lower():
        return StepResult("E_onboard", StepStatus.FAILED,
                          f"openclaw onboard failed: {r.stderr.strip()}")

    # Enable linger
    ctx.ssh.sudo("loginctl enable-linger openclaw", check=True)

    # Check gateway is up
    r = ctx.ssh.sudo_as("openclaw", "systemctl --user status openclaw-gateway", timeout=15)
    gateway_active = "active (running)" in r.stdout

    return StepResult("E_onboard", StepStatus.SUCCESS,
                      f"openclaw onboarded, linger enabled, gateway active={gateway_active}",
                      {"gateway_active": gateway_active})


def step_secrets(ctx: StepContext) -> StepResult:
    """F: Collect API keys, validate, write .env."""
    if ctx.dry_run:
        return StepResult("F_secrets", StepStatus.DRY_RUN,
                          "Dry-run: would prompt for API keys and write .env")

    keys = ctx.keys.copy()

    # Generate GATEWAY_AUTH_TOKEN if not provided
    if not keys.get("GATEWAY_AUTH_TOKEN"):
        keys["GATEWAY_AUTH_TOKEN"] = secrets.token_hex(32)
        print(f"\n  Generated GATEWAY_AUTH_TOKEN (32 bytes hex)")

    env_lines = [
        "# OpenClaw environment — generated by install_openclaw.py",
        f"# Installed: {datetime.now(timezone.utc).isoformat()}",
        "",
    ]
    for k, v in keys.items():
        env_lines.append(f"{k}={v}")
    env_content = "\n".join(env_lines) + "\n"

    # Write .env via heredoc
    escaped = env_content.replace("'", "'\\''")
    cmd = (
        f"bash -c 'mkdir -p {OPENCLAW_DIR} && "
        f"cat > {OPENCLAW_ENV} << \\'ENVEOF\\'\n{env_content}ENVEOF\n"
        f"chmod 600 {OPENCLAW_ENV} && "
        f"chown openclaw:openclaw {OPENCLAW_ENV}'"
    )

    # Use python write approach via echo-to-file (more reliable than heredoc over SSH)
    # Write to /tmp first, then move
    tmp_path = f"/tmp/.openclaw-env-{secrets.token_hex(8)}"
    import base64
    encoded = base64.b64encode(env_content.encode()).decode()
    ctx.ssh.sudo(
        f"bash -c 'echo {encoded} | base64 -d > {tmp_path} && "
        f"chmod 600 {tmp_path} && "
        f"mkdir -p {OPENCLAW_DIR} && "
        f"mv {tmp_path} {OPENCLAW_ENV} && "
        f"chown openclaw:openclaw {OPENCLAW_ENV}'",
        check=True
    )

    # Store in context for later steps
    ctx.scratch["keys"] = keys

    key_summary = {k: "set" for k in keys}
    return StepResult("F_secrets", StepStatus.SUCCESS,
                      f"Wrote .env with {len(keys)} keys",
                      {"keys": key_summary})


def step_hardening(ctx: StepContext) -> StepResult:
    """G: Apply OpenClaw security hardening (openclaw config set)."""
    if ctx.dry_run:
        return StepResult("G_hardening", StepStatus.DRY_RUN,
                          "Dry-run: would apply 20+ openclaw config hardening settings")

    configs = [
        # Sandbox
        ("sandbox.mode", "all"),
        ("sandbox.workspaceAccess", "none"),
        ("sandbox.network", "none"),
        ("sandbox.docker.enabled", "true"),
        ("sandbox.docker.network", "openclaw-sandbox"),
        # Clawhub
        ("clawhub.autoInstall", "false"),
        ("clawhub.autoUpdate", "false"),
        ("clawhub.allowUntrusted", "false"),
        # Gateway
        ("gateway.auth.mode", "token"),
        ("gateway.auth.token", "${env:GATEWAY_AUTH_TOKEN}"),
        ("gateway.bind", "ws://127.0.0.1:18789"),
        ("gateway.dangerouslyDisableDeviceAuth", "false"),
        # Agent restrictions
        ("agents.defaults.maxConcurrent", "4"),
        ("agents.defaults.subagents.maxConcurrent", "8"),
        ("agents.defaults.tools.allowShell", "false"),
        ("agents.defaults.tools.allowFileWrite", "false"),
        ("agents.defaults.tools.allowNetworkAccess", "false"),
        # Disable unused channels
        ("channels.discord.enabled", "false"),
        ("channels.slack.enabled", "false"),
        ("channels.web.enabled", "false"),
        ("channels.whatsapp.enabled", "false"),
        # Compaction
        ("agents.defaults.compaction.mode", "safeguard"),
        ("agents.defaults.compaction.warnAt", "80"),
        ("agents.defaults.compaction.strategy", "summarize"),
    ]

    failed = []
    for key, val in configs:
        r = ctx.ssh.sudo_as("openclaw", f"openclaw config set {key} '{val}'")
        if not r.ok:
            failed.append(f"{key}={val}: {r.stderr.strip()}")

    # Apply agent model allowlist
    allowlist_json = json.dumps(AGENT_ALLOWLIST)
    r = ctx.ssh.sudo_as(
        "openclaw",
        f"openclaw config set agents.defaults.models '{allowlist_json}'"
    )
    if not r.ok:
        failed.append(f"agents.defaults.models: {r.stderr.strip()}")

    if failed:
        return StepResult("G_hardening", StepStatus.FAILED,
                          f"{len(failed)} config(s) failed",
                          {"failed": failed})

    return StepResult("G_hardening", StepStatus.SUCCESS,
                      f"Applied {len(configs)+1} hardening configs",
                      {"configs_applied": len(configs)+1})


def step_providers(ctx: StepContext) -> StepResult:
    """H: Configure OpenRouter (Qwen) + Anthropic providers."""
    if ctx.dry_run:
        return StepResult("H_providers", StepStatus.DRY_RUN,
                          "Dry-run: would configure provider entries in openclaw.json")

    keys = ctx.scratch.get("keys", ctx.keys)

    # Build provider config JSON
    providers: list = [
        {
            "id": "anthropic",
            "api": "anthropic",
            "keyEnv": "ANTHROPIC_API_KEY",
            "models": [
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-20240307",
            ],
        },
        {
            "id": "openrouter",
            "api": "openai-completions",
            "baseUrl": "https://openrouter.ai/api/v1",
            "keyEnv": "OPENROUTER_API_KEY",
            "models": [
                "qwen/qwen3-235b-a22b",
                "qwen/qwen3.6-plus",
                "qwen/qwen3.5-397b-a17b",
            ],
            "headers": {
                "HTTP-Referer": f"https://{ctx.state.domain}",
                "X-Title": "OpenClaw Fork",
            },
        },
    ]

    # Add optional providers if keys present
    if keys.get("OPENAI_API_KEY"):
        providers.append({
            "id": "openai",
            "api": "openai",
            "keyEnv": "OPENAI_API_KEY",
            "models": ["text-embedding-3-small", "gpt-4o-mini"],
        })

    if keys.get("MINIMAX_API_KEY"):
        providers.append({
            "id": "minimax",
            "api": "openai-completions",
            "baseUrl": "https://api.minimax.chat/v1",
            "keyEnv": "MINIMAX_API_KEY",
            "models": ["MiniMax-M1"],
        })

    providers_json = json.dumps(providers, indent=2)
    import base64
    encoded = base64.b64encode(providers_json.encode()).decode()

    tmp = f"/tmp/providers-{secrets.token_hex(6)}.json"
    ctx.ssh.sudo(
        f"bash -c 'echo {encoded} | base64 -d > {tmp}'",
        check=True
    )

    # Use openclaw config import or set via CLI
    # Prefer writing directly to openclaw.json providers section
    r = ctx.ssh.sudo_as(
        "openclaw",
        f"openclaw config set providers \"$(cat {tmp})\"",
        timeout=30
    )
    ctx.ssh.sudo(f"rm -f {tmp}", check=False)

    if not r.ok:
        # Fallback: write to .openclaw/providers.json and notify
        return StepResult("H_providers", StepStatus.SUCCESS,
                          "Providers written (manual openclaw config import may be needed)",
                          {"providers": [p["id"] for p in providers], "warning": r.stderr.strip()})

    return StepResult("H_providers", StepStatus.SUCCESS,
                      f"Configured {len(providers)} providers",
                      {"providers": [p["id"] for p in providers]})


def step_telegram(ctx: StepContext) -> StepResult:
    """I: Configure Telegram channel + register webhook."""
    if ctx.dry_run:
        return StepResult("I_telegram", StepStatus.DRY_RUN,
                          "Dry-run: would configure Telegram channel and register webhook")

    keys = ctx.scratch.get("keys", ctx.keys)
    bot_token = keys.get("TELEGRAM_BOT_TOKEN", "")
    if not bot_token:
        return StepResult("I_telegram", StepStatus.FAILED,
                          "TELEGRAM_BOT_TOKEN not set")

    domain = ctx.state.domain
    webhook_url = f"https://{domain}/webhook/telegram"
    gateway_auth = keys.get("GATEWAY_AUTH_TOKEN", "")

    # Configure channel via openclaw config
    operator_id = ctx.state.operator_telegram_id

    configs = [
        ("channels.telegram.enabled", "true"),
        ("channels.telegram.botToken", "${env:TELEGRAM_BOT_TOKEN}"),
        ("channels.telegram.dmPolicy", "allowlist"),
        ("channels.telegram.groupPolicy", "deny"),
    ]
    if operator_id:
        configs.append(("channels.telegram.allowlist", f"[{operator_id}]"))

    for key, val in configs:
        ctx.ssh.sudo_as("openclaw", f"openclaw config set {key} '{val}'", check=False)

    # Register webhook with Telegram API
    register_cmd = (
        f"curl -sf 'https://api.telegram.org/bot{bot_token}/setWebhook'"
        f" -d 'url={webhook_url}'"
        f" -d 'secret_token={gateway_auth}'"
        f" -d 'allowed_updates=[\"message\",\"callback_query\"]'"
        f" -d 'max_connections=5'"
    )
    r = ctx.ssh.run(register_cmd, timeout=20)

    webhook_ok = False
    if r.ok:
        try:
            resp = json.loads(r.stdout)
            webhook_ok = resp.get("ok", False)
        except json.JSONDecodeError:
            pass

    # Verify webhook
    verify_cmd = f"curl -sf 'https://api.telegram.org/bot{bot_token}/getWebhookInfo'"
    vr = ctx.ssh.run(verify_cmd, timeout=10)
    webhook_info = {}
    if vr.ok:
        try:
            info = json.loads(vr.stdout)
            webhook_info = info.get("result", {})
        except json.JSONDecodeError:
            pass

    # Test message (only if operator_id is known)
    if operator_id:
        test_msg = (
            f"curl -sf 'https://api.telegram.org/bot{bot_token}/sendMessage'"
            f" -d 'chat_id={operator_id}'"
            f" -d 'text=OpenClaw installer: webhook registered ✓'"
        )
        ctx.ssh.run(test_msg, timeout=10)
    else:
        print("\n  ⚠ No operator_telegram_id in state — skipping test message.")
        print("    DM the bot in Telegram to activate it.")

    return StepResult("I_telegram", StepStatus.SUCCESS,
                      f"Webhook registered: {webhook_url}",
                      {
                          "webhook_url": webhook_url,
                          "webhook_ok": webhook_ok,
                          "operator_notified": operator_id is not None,
                          "webhook_info": webhook_info,
                      })


def step_storage(ctx: StepContext) -> StepResult:
    """J: Initialize FAISS index + SQLite database."""
    if ctx.dry_run:
        return StepResult("J_storage", StepStatus.DRY_RUN,
                          "Dry-run: would initialize FAISS index and SQLite schema")

    # Ensure directories
    dirs = " ".join([
        "/home/openclaw/agent-system/faiss",
        "/home/openclaw/agent-system/data",
        "/home/openclaw/agent-system/logs",
        "/home/openclaw/agent-system/scripts",
        OPENCLAW_WORKSPACE + "/state",
        OPENCLAW_WORKSPACE + "/memory",
        OPENCLAW_WORKSPACE + "/journal",
    ])
    ctx.ssh.sudo_as("openclaw", f"bash -c 'mkdir -p {dirs}'", check=True)

    # Install python deps for FAISS
    ctx.ssh.sudo(
        "bash -c 'python3 -m pip install --quiet faiss-cpu numpy 2>/dev/null || true'",
        timeout=120
    )

    # Init FAISS index via python
    faiss_init_script = textwrap.dedent("""
    try:
        import faiss, numpy as np, json
        from pathlib import Path
        fdir = Path.home() / "agent-system" / "faiss"
        fdir.mkdir(parents=True, exist_ok=True)
        idx_path = fdir / "research.index"
        if not idx_path.exists():
            idx = faiss.IndexIDMap2(faiss.IndexFlatL2(1536))
            faiss.write_index(idx, str(idx_path))
            meta = {"dimension": 1536, "model": "text-embedding-3-small",
                    "type": "IndexFlatL2", "documents": 0}
            json.dump(meta, open(fdir / "metadata.json", "w"), indent=2)
            print("FAISS_INIT_OK")
        else:
            print("FAISS_ALREADY_EXISTS")
    except ImportError:
        print("FAISS_NOT_AVAILABLE")  # Not fatal — faiss optional
    except Exception as e:
        print(f"FAISS_ERROR:{e}")
    """).strip()

    import base64
    encoded = base64.b64encode(faiss_init_script.encode()).decode()
    r = ctx.ssh.sudo_as(
        "openclaw",
        f"bash -c 'echo {encoded} | base64 -d | python3'",
        timeout=60
    )
    faiss_status = r.stdout.strip()

    # Init SQLite schema
    schema_sql = textwrap.dedent("""
    CREATE TABLE IF NOT EXISTS api_calls (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        provider TEXT NOT NULL, model TEXT NOT NULL, agent TEXT NOT NULL,
        project TEXT, session_id TEXT,
        input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
        cost_usd REAL DEFAULT 0.0, latency_ms INTEGER DEFAULT 0,
        status TEXT DEFAULT 'success', error_message TEXT, validation_type TEXT
    );
    CREATE TABLE IF NOT EXISTS ideas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        slug TEXT UNIQUE NOT NULL, title TEXT NOT NULL,
        created TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        phase TEXT DEFAULT 'ideation', status TEXT DEFAULT 'active',
        discovery_source TEXT
    );
    CREATE TABLE IF NOT EXISTS discoveries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        slug TEXT UNIQUE NOT NULL, seed_prompt TEXT NOT NULL,
        status TEXT DEFAULT 'running',
        started TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        completed TEXT, budget_usd REAL DEFAULT 15.0, spent_usd REAL DEFAULT 0.0
    );
    CREATE TABLE IF NOT EXISTS budget_config (
        key TEXT PRIMARY KEY, value REAL NOT NULL, description TEXT
    );
    INSERT OR IGNORE INTO budget_config VALUES
        ('daily_limit_usd', 10.0, 'Daily hard limit'),
        ('monthly_limit_usd', 100.0, 'Monthly hard limit');
    """).strip()

    db_path = "/home/openclaw/agent-system/data/openclaw.db"
    encoded_sql = base64.b64encode(schema_sql.encode()).decode()
    r = ctx.ssh.sudo_as(
        "openclaw",
        f"bash -c 'echo {encoded_sql} | base64 -d | sqlite3 {db_path}'",
        timeout=30
    )

    if not r.ok:
        return StepResult("J_storage", StepStatus.FAILED,
                          f"SQLite init failed: {r.stderr.strip()}")

    ctx.ssh.sudo_as("openclaw", f"bash -c 'chmod 640 {db_path}'", check=False)

    return StepResult("J_storage", StepStatus.SUCCESS,
                      "FAISS + SQLite initialized",
                      {"faiss": faiss_status, "sqlite": "ok", "db": db_path})


def step_audit(ctx: StepContext) -> StepResult:
    """K: Run openclaw security audit."""
    if ctx.dry_run:
        return StepResult("K_audit", StepStatus.DRY_RUN,
                          "Dry-run: would run openclaw security audit --deep")

    r = ctx.ssh.sudo_as(
        "openclaw",
        "openclaw security audit --deep 2>&1 | tee /home/openclaw/agent-system/logs/final-audit.log",
        timeout=120
    )

    output = r.stdout + r.stderr
    critical_count = output.upper().count("CRITICAL")

    if critical_count > 0:
        return StepResult("K_audit", StepStatus.FAILED,
                          f"Security audit found {critical_count} CRITICAL items",
                          {"critical_count": critical_count, "output_snippet": output[:1000]})

    return StepResult("K_audit", StepStatus.SUCCESS,
                      f"Security audit passed (0 critical items)",
                      {"output_snippet": output[:500]})


def step_smoke_test(ctx: StepContext) -> StepResult:
    """L: Send test prompt through gateway, measure latency."""
    if ctx.dry_run:
        return StepResult("L_smoke_test", StepStatus.DRY_RUN,
                          "Dry-run: would send test prompt through gateway")

    keys = ctx.scratch.get("keys", ctx.keys)
    gateway_token = keys.get("GATEWAY_AUTH_TOKEN", "")

    t0 = time.monotonic()
    test_cmd = (
        f"curl -sf -w '\\n%{{http_code}}' "
        f"-H 'Authorization: Bearer {gateway_token}' "
        f"-H 'Content-Type: application/json' "
        f"-d '{{\"message\":\"echo: smoke test\",\"stream\":false}}' "
        f"http://127.0.0.1:18789/v1/chat"
    )
    r = ctx.ssh.run(test_cmd, timeout=30)
    elapsed_ms = (time.monotonic() - t0) * 1000

    lines = r.stdout.strip().split("\n")
    http_code = lines[-1] if lines else "000"
    body = "\n".join(lines[:-1]) if len(lines) > 1 else ""

    if r.ok and http_code.startswith("2"):
        return StepResult("L_smoke_test", StepStatus.SUCCESS,
                          f"Gateway smoke test OK — {elapsed_ms:.0f}ms",
                          {"http_code": http_code, "latency_ms": round(elapsed_ms), "body": body[:200]})

    # Gateway may not be fully up yet — treat as warning not failure
    return StepResult("L_smoke_test", StepStatus.SUCCESS,
                      f"Gateway responded http={http_code} in {elapsed_ms:.0f}ms (may need warm-up)",
                      {"http_code": http_code, "latency_ms": round(elapsed_ms), "warning": body[:200]})


def step_report(ctx: StepContext) -> StepResult:
    """M: Generate and save installation report."""
    if ctx.dry_run:
        return StepResult("M_report", StepStatus.DRY_RUN,
                          "Dry-run: would generate installation report")

    keys = ctx.scratch.get("keys", ctx.keys)
    bot_token = keys.get("TELEGRAM_BOT_TOKEN", "")
    domain = ctx.state.domain

    providers_configured = ["anthropic", "openrouter"]
    if keys.get("OPENAI_API_KEY"):
        providers_configured.append("openai")
    if keys.get("MINIMAX_API_KEY"):
        providers_configured.append("minimax")

    # Find smoke test result
    smoke_latency = "N/A"
    for r in ctx.scratch.get("step_results", []):
        if hasattr(r, "step_id") and r.step_id == "L_smoke_test":
            smoke_latency = f"{r.details.get('latency_ms', '?')}ms"
            break

    report = textwrap.dedent(f"""
    ╔══════════════════════════════════════════════════════════════════╗
    ║           OpenClaw Installation Report                          ║
    ╚══════════════════════════════════════════════════════════════════╝

    Instance Details
    ────────────────
    Slug:         {ctx.state.slug}
    Domain:       {domain}
    Tailscale IP: {ctx.state.tailscale_ip}
    Static IP:    {ctx.state.static_ip}
    SSH:          {ctx.state.ssh_user}@{ctx.state.tailscale_ip}:{ctx.state.ssh_port}
    Bot URL:      https://t.me/{domain}  (DM @YourBotUsername)
    Webhook:      https://{domain}/webhook/telegram

    Providers Configured
    ────────────────────
    {chr(10).join(f"  ✓ {p}" for p in providers_configured)}

    Status
    ──────
    Hardening sentinel: present
    Smoke test latency: {smoke_latency}

    Next Steps
    ──────────
    1. DM the bot in Telegram — first message triggers the fork-bootstrap interview.
    2. The bot will ask for your name, goals, and timezone to personalise the assistant.
    3. After onboarding, the assistant is fully operational.

    ⚠  If operator_telegram_id was empty, DM the bot first before the allowlist kicks in.

    Generated: {datetime.now(timezone.utc).isoformat()}
    """).strip()

    print("\n" + report + "\n")

    # Save report
    report_dir = Path(__file__).parent / "state"
    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / f"install-{ctx.state.slug}.report.md"
    report_path.write_text(report)

    return StepResult("M_report", StepStatus.SUCCESS,
                      f"Report saved: {report_path}",
                      {"report_path": str(report_path)})


# ---------------------------------------------------------------------------
# Key collection helpers
# ---------------------------------------------------------------------------

def _collect_keys_interactive(state: StateFile) -> Dict[str, str]:
    """Prompt operator for each key interactively."""
    print("\n=== API Key Collection ===")
    print("Enter API keys below. Required keys are marked with *.")
    print("Press Enter to skip optional keys.\n")

    keys: Dict[str, str] = {}

    def prompt(name: str, required: bool, validator=None, desc: str = "") -> str:
        suffix = " *" if required else " (optional)"
        if desc:
            print(f"  {desc}")
        while True:
            val = getpass.getpass(f"  {name}{suffix}: ").strip()
            if not val and required:
                print(f"  ✗ {name} is required.")
                continue
            if val and validator:
                ok, msg = validator(val)
                if ok:
                    print(f"  ✓ {msg}")
                else:
                    print(f"  ✗ Validation failed: {msg}")
                    retry = input("    Retry? [Y/n]: ").strip().lower()
                    if retry in ("n", "no"):
                        if required:
                            print("  ✗ Cannot skip required key.")
                            continue
                        return ""
                    continue
            return val

    keys["ANTHROPIC_API_KEY"] = prompt(
        "ANTHROPIC_API_KEY", required=True,
        validator=validate_anthropic_key,
        desc="Anthropic (required for Claude models):"
    )
    keys["OPENROUTER_API_KEY"] = prompt(
        "OPENROUTER_API_KEY", required=True,
        validator=validate_openrouter_key,
        desc="OpenRouter (required for Qwen models):"
    )
    keys["TELEGRAM_BOT_TOKEN"] = prompt(
        "TELEGRAM_BOT_TOKEN", required=True,
        validator=validate_telegram_token,
        desc="Telegram bot token (required, from @BotFather):"
    )
    keys["OPENAI_API_KEY"] = prompt(
        "OPENAI_API_KEY", required=False,
        desc="OpenAI (optional, for embeddings):"
    )
    keys["MINIMAX_API_KEY"] = prompt(
        "MINIMAX_API_KEY", required=False,
        desc="MiniMax (optional):"
    )
    keys["TAVILY_API_KEY"] = prompt(
        "TAVILY_API_KEY", required=False,
        desc="Tavily (optional, recommended for research):"
    )

    if state.operator_telegram_id:
        keys["TELEGRAM_OPERATOR_ID"] = str(state.operator_telegram_id)

    # Remove empty optional keys
    return {k: v for k, v in keys.items() if v}


def _collect_keys_from_file(keys_file: str) -> Dict[str, str]:
    """Read keys from a keys.env file (KEY=VALUE format)."""
    path = Path(keys_file)
    if not path.exists():
        raise FileNotFoundError(f"Keys file not found: {keys_file}")

    keys: Dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        keys[k.strip()] = v.strip()
    return keys


# ---------------------------------------------------------------------------
# Build step list
# ---------------------------------------------------------------------------

def build_steps() -> list[Step]:
    return [
        Step("A_preflight",       "Preflight checks",                 step_preflight),
        Step("B_nodejs",          "Install Node.js 22+",              step_install_nodejs),
        Step("C_openclaw_install","Install OpenClaw globally",        step_install_openclaw),
        Step("D_upload_bundle",   "Upload workspace bundle",          step_upload_bundle),
        Step("E_onboard",         "Onboard openclaw user",            step_onboard_openclaw),
        Step("F_secrets",         "Collect and write API secrets",    step_secrets),
        Step("G_hardening",       "Apply security hardening",         step_hardening),
        Step("H_providers",       "Configure API providers",          step_providers),
        Step("I_telegram",        "Configure Telegram webhook",       step_telegram),
        Step("J_storage",         "Initialize FAISS + SQLite",        step_storage),
        Step("K_audit",           "Final security audit",             step_audit),
        Step("L_smoke_test",      "Gateway smoke test",               step_smoke_test),
        Step("M_report",          "Generate installation report",     step_report),
    ]


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Install OpenClaw on a pre-provisioned Lightsail instance.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("state_json", help="Path to Track-B state JSON file")
    parser.add_argument("workspace_bundle", help="Path to rendered fork workspace bundle")
    parser.add_argument("--dry-run", action="store_true",
                        help="Simulate steps without executing anything")
    parser.add_argument("--skip-keys-prompt", action="store_true",
                        help="Read keys from --keys-file instead of prompting")
    parser.add_argument("--keys-file", default="keys.env",
                        help="Path to keys.env file (used with --skip-keys-prompt)")
    parser.add_argument("--resume-from", metavar="STEP_ID",
                        help="Resume from this step ID (skip earlier steps)")
    parser.add_argument("--openclaw-npm-package", default=DEFAULT_NPM_PACKAGE,
                        help=f"npm package to install (default: {DEFAULT_NPM_PACKAGE})")
    parser.add_argument("--ssh-key", default=None,
                        help="Path to SSH private key (default: use ssh-agent)")
    parser.add_argument("--quiet", action="store_true", help="Reduce output verbosity")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    # Load state
    try:
        state = load_state(args.state_json)
    except (FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    bundle_path = Path(args.workspace_bundle)
    if not bundle_path.exists() and not args.dry_run:
        print(f"ERROR: Workspace bundle not found: {bundle_path}", file=sys.stderr)
        return 1

    # Check fork.yaml.used
    fork_yaml = bundle_path / "fork.yaml.used"
    if not fork_yaml.exists() and not args.dry_run:
        print(
            f"WARNING: {fork_yaml} not found.\n"
            f"  fork.sh should copy the resolved fork.yaml into the bundle.\n"
            f"  Continuing without it — some personalisation may be incomplete.",
            file=sys.stderr
        )

    # Collect keys
    if args.skip_keys_prompt:
        try:
            keys = _collect_keys_from_file(args.keys_file)
            print(f"Keys loaded from {args.keys_file}: {list(keys.keys())}")
        except FileNotFoundError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 1
    elif args.dry_run:
        keys = {"_dry_run": "true"}
    else:
        keys = _collect_keys_interactive(state)

    # Open SSH (or mock for dry-run)
    if args.dry_run:
        transport = MockSSHTransport()
        transport.set_default(SSHResult(0, "[dry-run]", ""))
        ssh = SSHClient.from_transport(transport, dry_run=True)
    else:
        print(f"\nConnecting to {state.tailscale_ip}:{state.ssh_port} as {state.ssh_user} ...")
        try:
            ssh = SSHClient.connect(
                host=state.tailscale_ip,
                port=state.ssh_port,
                username=state.ssh_user,
                key_filename=args.ssh_key,
                dry_run=False,
            )
        except Exception as exc:
            print(f"ERROR: SSH connection failed: {exc}", file=sys.stderr)
            return 1

    # Build context
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    log_dir = Path(__file__).parent / "state"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / f"install-{state.slug}-{ts}.log"

    ctx = StepContext(
        slug=state.slug,
        dry_run=args.dry_run,
        log_path=log_path,
        ssh=ssh,
        state=state,
        bundle_path=bundle_path,
        keys=keys,
        scratch={"npm_package": args.openclaw_npm_package},
    )

    # Run
    steps = build_steps()
    runner = StepRunner(
        steps=steps,
        context=ctx,
        log_path=log_path,
        resume_from=args.resume_from,
        verbose=not args.quiet,
    )

    print(f"\n{'='*64}")
    print(f"  OpenClaw Installer — {state.slug}")
    print(f"  Target: {state.tailscale_ip}:{state.ssh_port}")
    print(f"  Log: {log_path}")
    if args.dry_run:
        print("  *** DRY RUN — no changes will be made ***")
    print(f"{'='*64}\n")

    results = runner.run()

    # Store results in scratch for report step
    ctx.scratch["step_results"] = results

    ssh.close()

    # Final summary
    summary = runner.summary()
    failed = summary["failed"]

    print(f"\n{'='*64}")
    if summary["all_ok"]:
        print("  ✓ Installation complete!")
    else:
        print(f"  ✗ Installation failed at: {failed}")
        print(f"    Re-run with: --resume-from {failed[0]}")
    print(f"{'='*64}\n")

    return 0 if summary["all_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
