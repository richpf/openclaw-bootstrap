#!/usr/bin/env python3
"""
provision_lightsail.py — OpenClaw Lightsail Provisioner
========================================================
Automates Sections 1–13 of the Lightsail hardening runbook end-to-end.

Usage:
    python3 provision_lightsail.py <fork.yaml> [options]

Options:
    --dry-run          Print planned API calls without hitting AWS
    --aws-profile      AWS profile name (default: "default")
    --skip-dns         Skip Route 53 DNS record creation
    --verbose          Enable verbose logging
    --region           AWS region override (default: from fork.yaml or us-west-2)

See provisioner/README.md for full documentation.
"""

from __future__ import annotations

import argparse
import base64
import json
import logging
import os
import platform
import socket
import sys
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import yaml

# Lazy imports for optional heavy deps (boto3, jinja2, paramiko)
# These are checked at runtime so dry-run works without AWS creds.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

LIGHTSAIL_BLUEPRINT = "ubuntu_24_04"
LIGHTSAIL_PLAN_DEFAULT = "medium_2_0"
AWS_REGION_DEFAULT = "us-west-2"
SSH_PORT_INITIAL = 22
SSH_PORT_HARDENED = 2222
TAILSCALE_AUTH_KEY_MIN_LEN = 20
TAILSCALE_AUTH_KEY_PREFIX = "tskey-auth-"

# Lightsail firewall: initial (pre-Tailscale), then tightened post-boot
FIREWALL_INITIAL = [
    {"fromPort": 22, "toPort": 22, "protocol": "tcp"},   # removed post-boot
    {"fromPort": 80, "toPort": 80, "protocol": "tcp"},
    {"fromPort": 443, "toPort": 443, "protocol": "tcp"},
]
FIREWALL_FINAL = [
    {"fromPort": 80, "toPort": 80, "protocol": "tcp"},
    {"fromPort": 443, "toPort": 443, "protocol": "tcp"},
]

BOOT_POLL_INTERVAL = 15   # seconds between status polls
BOOT_POLL_MAX = 60        # max poll attempts (~15 min)
SSH_POLL_INTERVAL = 10
SSH_POLL_MAX = 30
CLOUD_INIT_POLL_INTERVAL = 30
CLOUD_INIT_POLL_MAX = 40  # up to 20 min for heavy install

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log = logging.getLogger("provisioner")


def setup_logging(verbose: bool) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    fmt = "%(asctime)s [%(levelname)s] %(message)s"
    logging.basicConfig(level=level, format=fmt, datefmt="%H:%M:%S")


# ---------------------------------------------------------------------------
# fork.yaml schema
# ---------------------------------------------------------------------------

REQUIRED_FIELDS: list[tuple[str, str]] = [
    ("infra.aws_region", "infra"),
    ("infra.lightsail_plan", "infra"),
    ("infra.domain", "infra"),
    ("infra.certbot_email", "infra"),
    ("infra.tailscale_auth_key_env", "infra"),
    ("git.github_handle", "git"),
    ("git.workspace_remote", "git"),
    ("git.journal_remote", "git"),
    ("email.gmail_address", "email"),
    ("backup.restic_b2_bucket", "backup"),
    ("backup.restic_password_env", "backup"),
]

OPTIONAL_FIELDS_WITH_DEFAULTS = {
    "infra.ssh_pubkey_path": "~/.ssh/id_ed25519.pub",
    "infra.deployer_pubkey_path": "",
    "infra.slug": "",   # derived from github_handle if not set
}


def load_fork_yaml(path: Path) -> dict[str, Any]:
    """Load and validate fork.yaml. Raises ValueError on missing required fields."""
    with open(path) as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise ValueError(f"fork.yaml must be a YAML mapping, got {type(data).__name__!r}")
    return data


def get_nested(data: dict, dotpath: str, default: Any = None) -> Any:
    """Traverse nested dict using dotted key path."""
    parts = dotpath.split(".")
    cur = data
    for part in parts:
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def validate_fork_yaml(data: dict) -> list[str]:
    """Return list of validation error messages (empty = valid)."""
    if not isinstance(data, dict):
        raise ValueError(f"validate_fork_yaml expects a dict, got {type(data).__name__!r}")
    errors: list[str] = []
    for dotpath, section in REQUIRED_FIELDS:
        val = get_nested(data, dotpath)
        if val is None or val == "":
            errors.append(f"Missing required field: {dotpath}")
    return errors


def resolve_config(data: dict) -> dict[str, Any]:
    """Flatten fork.yaml into a flat config dict used throughout the script."""
    infra = data.get("infra", {})
    git_ = data.get("git", {})
    email_ = data.get("email", {})
    backup_ = data.get("backup", {})

    github_handle = get_nested(data, "git.github_handle", "")
    slug = infra.get("slug") or github_handle.lower().replace("-", "").replace("_", "")[:16]

    return {
        "slug": slug,
        "aws_region": infra.get("aws_region", AWS_REGION_DEFAULT),
        "lightsail_plan": infra.get("lightsail_plan", LIGHTSAIL_PLAN_DEFAULT),
        "domain": infra.get("domain", ""),
        "certbot_email": infra.get("certbot_email", ""),
        "tailscale_auth_key_env": infra.get("tailscale_auth_key_env", "TAILSCALE_AUTH_KEY"),
        "ssh_pubkey_path": infra.get("ssh_pubkey_path", "~/.ssh/id_ed25519.pub"),
        "deployer_pubkey_path": infra.get("deployer_pubkey_path", ""),
        "github_handle": github_handle,
        "workspace_remote": get_nested(data, "git.workspace_remote", ""),
        "journal_remote": get_nested(data, "git.journal_remote", ""),
        "gmail_address": get_nested(data, "email.gmail_address", ""),
        "restic_b2_bucket": get_nested(data, "backup.restic_b2_bucket", ""),
        "restic_password_env": get_nested(data, "backup.restic_password_env", "RESTIC_PASSWORD"),
        # derived
        "instance_name": f"openclaw-{slug}",
        "keypair_name": f"openclaw-{slug}",
        "static_ip_name": f"openclaw-{slug}-ip",
        "parent_hostname": platform.node(),
    }


# ---------------------------------------------------------------------------
# Jinja2 cloud-init rendering
# ---------------------------------------------------------------------------

def render_cloud_init(cfg: dict[str, Any], operator_pubkey: str,
                      deployer_pubkey: str = "") -> str:
    """Render cloud_init.yaml.j2 with the given config values."""
    from jinja2 import Environment, FileSystemLoader, StrictUndefined

    template_dir = Path(__file__).parent
    env = Environment(
        loader=FileSystemLoader(str(template_dir)),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )
    tpl = env.get_template("cloud_init.yaml.j2")
    return tpl.render(
        slug=cfg["slug"],
        domain=cfg["domain"],
        certbot_email=cfg["certbot_email"],
        tailscale_auth_key="{{ TAILSCALE_AUTH_KEY }}",   # placeholder; real key injected at launch
        operator_pubkey=operator_pubkey,
        deployer_pubkey=deployer_pubkey,
    )


def render_cloud_init_with_key(cfg: dict[str, Any], operator_pubkey: str,
                               tailscale_auth_key: str,
                               deployer_pubkey: str = "") -> str:
    """Render with real Tailscale key (used for actual deployment)."""
    from jinja2 import Environment, FileSystemLoader, StrictUndefined

    template_dir = Path(__file__).parent
    env = Environment(
        loader=FileSystemLoader(str(template_dir)),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )
    tpl = env.get_template("cloud_init.yaml.j2")
    return tpl.render(
        slug=cfg["slug"],
        domain=cfg["domain"],
        certbot_email=cfg["certbot_email"],
        tailscale_auth_key=tailscale_auth_key,
        operator_pubkey=operator_pubkey,
        deployer_pubkey=deployer_pubkey,
    )


# ---------------------------------------------------------------------------
# State file model
# ---------------------------------------------------------------------------

@dataclass
class ProvisionState:
    slug: str
    instance_name: str
    static_ip: str = ""
    tailscale_ip: str = ""
    keypair_name: str = ""
    aws_region: str = ""
    domain: str = ""
    ssh_fingerprint: str = ""
    timestamp_start: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    timestamp_complete: str = ""
    runbook_sections_complete: list[str] = field(default_factory=list)
    aws_instance_arn: str = ""
    aws_static_ip_name: str = ""
    lightsail_plan: str = ""
    parent_hostname: str = ""

    def save(self, state_dir: Path) -> Path:
        state_dir.mkdir(parents=True, exist_ok=True)
        out = state_dir / f"{self.slug}.json"
        with open(out, "w") as f:
            json.dump(asdict(self), f, indent=2)
        return out

    @classmethod
    def load(cls, path: Path) -> "ProvisionState":
        with open(path) as f:
            d = json.load(f)
        return cls(**d)


# ---------------------------------------------------------------------------
# AWS / Lightsail helpers
# ---------------------------------------------------------------------------

class LightsailProvisioner:
    """
    Wraps boto3 Lightsail + Route53 calls.
    In dry-run mode, records planned calls instead of executing them.
    """

    def __init__(self, cfg: dict[str, Any], aws_profile: str,
                 dry_run: bool = False, skip_dns: bool = False,
                 verbose: bool = False):
        self.cfg = cfg
        self.dry_run = dry_run
        self.skip_dns = skip_dns
        self.verbose = verbose
        self.planned_calls: list[str] = []   # dry-run log
        self.state = ProvisionState(
            slug=cfg["slug"],
            instance_name=cfg["instance_name"],
            keypair_name=cfg["keypair_name"],
            aws_region=cfg["aws_region"],
            domain=cfg["domain"],
            aws_static_ip_name=cfg["static_ip_name"],
            lightsail_plan=cfg["lightsail_plan"],
            parent_hostname=cfg["parent_hostname"],
        )

        if not dry_run:
            import boto3
            session = boto3.Session(profile_name=aws_profile, region_name=cfg["aws_region"])
            self._ls = session.client("lightsail")
            self._r53 = session.client("route53")
        else:
            self._ls = None
            self._r53 = None

    # ── helpers ──────────────────────────────────────────────────────

    def _record(self, call: str) -> None:
        self.planned_calls.append(call)
        log.info("[DRY-RUN] %s", call)

    def _ls_call(self, method: str, **kwargs) -> Any:
        """Execute or record a Lightsail API call."""
        call_str = f"lightsail.{method}({json.dumps(kwargs, default=str)})"
        if self.dry_run:
            self._record(call_str)
            return {}
        return getattr(self._ls, method)(**kwargs)

    def _r53_call(self, method: str, **kwargs) -> Any:
        call_str = f"route53.{method}({json.dumps(kwargs, default=str)})"
        if self.dry_run:
            self._record(call_str)
            return {}
        return getattr(self._r53, method)(**kwargs)

    # ── Step A: Preflight ────────────────────────────────────────────

    def preflight(self, tailscale_auth_key: str, operator_pubkey: str) -> None:
        log.info("━━ Step A: Preflight checks")

        # AWS credentials
        if self.dry_run:
            self._record("sts.get_caller_identity() → validate AWS creds")
        else:
            import boto3
            sts = boto3.client("sts", region_name=self.cfg["aws_region"])
            identity = sts.get_caller_identity()
            log.info("  AWS account: %s / IAM: %s", identity["Account"], identity["Arn"])

        # Region availability
        self._ls_call("get_regions")

        # Confirm Lightsail blueprint exists
        if not self.dry_run:
            resp = self._ls.get_blueprints()
            ids = [b["blueprintId"] for b in resp.get("blueprints", [])]
            if LIGHTSAIL_BLUEPRINT not in ids:
                raise RuntimeError(f"Blueprint {LIGHTSAIL_BLUEPRINT!r} not found in region {self.cfg['aws_region']}")
            log.info("  Blueprint %s: ✓", LIGHTSAIL_BLUEPRINT)

            # Confirm plan exists
            resp = self._ls.get_bundles()
            plan_ids = [b["bundleId"] for b in resp.get("bundles", [])]
            if self.cfg["lightsail_plan"] not in plan_ids:
                raise RuntimeError(f"Lightsail plan {self.cfg['lightsail_plan']!r} not found")
            log.info("  Plan %s: ✓", self.cfg["lightsail_plan"])
        else:
            self._record(f"lightsail.get_blueprints() → verify {LIGHTSAIL_BLUEPRINT} exists")
            self._record(f"lightsail.get_bundles() → verify {self.cfg['lightsail_plan']} exists")

        # Domain zone in Route 53
        if not self.skip_dns:
            self._r53_call("list_hosted_zones_by_name",
                           DNSName=self.cfg["domain"],
                           MaxItems="1")
            log.info("  Route53 zone check for %s: queued", self.cfg["domain"])

        # Tailscale auth key validation
        if not tailscale_auth_key:
            raise ValueError("Tailscale auth key is empty — set the env var or pass it explicitly")
        if not tailscale_auth_key.startswith(TAILSCALE_AUTH_KEY_PREFIX):
            raise ValueError(
                f"Tailscale auth key does not start with {TAILSCALE_AUTH_KEY_PREFIX!r}. "
                "Verify this is an auth key (not an API key)."
            )
        if len(tailscale_auth_key) < TAILSCALE_AUTH_KEY_MIN_LEN:
            raise ValueError("Tailscale auth key looks truncated (too short)")
        log.info("  Tailscale auth key: format OK (prefix=%s, length=%d)",
                 TAILSCALE_AUTH_KEY_PREFIX, len(tailscale_auth_key))

        # SSH pubkey
        if not operator_pubkey:
            raise ValueError("Operator SSH public key is empty")
        if not (operator_pubkey.startswith("ssh-") or operator_pubkey.startswith("ecdsa-")):
            raise ValueError("Operator SSH pubkey doesn't look like an OpenSSH public key")
        log.info("  Operator pubkey: OK (%s...)", operator_pubkey[:30])

        log.info("  Preflight: ✓")
        self.state.runbook_sections_complete.append("preflight")

    # ── Step B: Key pair ─────────────────────────────────────────────

    def create_keypair(self) -> str:
        """Create or reuse Lightsail SSH keypair. Returns public key."""
        log.info("━━ Step B: SSH key pair → %s", self.cfg["keypair_name"])
        if self.dry_run:
            self._record(f"lightsail.get_key_pair(keyPairName={self.cfg['keypair_name']!r})")
            self._record(f"lightsail.create_key_pair(keyPairName={self.cfg['keypair_name']!r})")
            self.state.runbook_sections_complete.append("keypair")
            return "ssh-ed25519 DRY-RUN-KEY"

        try:
            resp = self._ls.get_key_pair(keyPairName=self.cfg["keypair_name"])
            log.info("  Key pair already exists: %s", self.cfg["keypair_name"])
            return resp["keyPair"].get("publicKey", "")
        except self._ls.exceptions.NotFoundException:
            resp = self._ls.create_key_pair(keyPairName=self.cfg["keypair_name"])
            kp = resp["keyPair"]
            # Save private key locally — operator may want it for emergency access
            priv_path = Path.home() / ".ssh" / f"lightsail-{self.cfg['keypair_name']}.pem"
            priv_path.write_text(resp["privateKeyBase64"])
            priv_path.chmod(0o400)
            log.info("  Created key pair. Private key saved to: %s", priv_path)
            self.state.runbook_sections_complete.append("keypair")
            return kp.get("publicKey", "")

    # ── Step C: Instance ─────────────────────────────────────────────

    def launch_instance(self, user_data: str) -> None:
        log.info("━━ Step C: Launch instance → %s", self.cfg["instance_name"])
        tags = [
            {"key": "Project", "value": "OpenClaw"},
            {"key": "Fork", "value": self.cfg["slug"]},
            {"key": "Parent", "value": self.cfg["parent_hostname"]},
        ]

        if self.dry_run:
            self._record(
                f"lightsail.get_instance(instanceName={self.cfg['instance_name']!r}) → idempotency check"
            )
            self._record(
                f"lightsail.create_instances("
                f"instanceNames=[{self.cfg['instance_name']!r}], "
                f"availabilityZone={self.cfg['aws_region']}a, "
                f"blueprintId={LIGHTSAIL_BLUEPRINT!r}, "
                f"bundleId={self.cfg['lightsail_plan']!r}, "
                f"keyPairName={self.cfg['keypair_name']!r}, "
                f"tags={json.dumps(tags)}, "
                f"userData=<cloud_init_yaml len={len(user_data)}>)"
            )
            self.state.runbook_sections_complete.append("instance")
            return

        # Idempotency: check if already exists
        try:
            resp = self._ls.get_instance(instanceName=self.cfg["instance_name"])
            inst = resp["instance"]
            log.info("  Instance already exists (state=%s)", inst["state"]["name"])
            self.state.aws_instance_arn = inst.get("arn", "")
            self.state.runbook_sections_complete.append("instance")
            return
        except self._ls.exceptions.NotFoundException:
            pass

        resp = self._ls.create_instances(
            instanceNames=[self.cfg["instance_name"]],
            availabilityZone=f"{self.cfg['aws_region']}a",
            blueprintId=LIGHTSAIL_BLUEPRINT,
            bundleId=self.cfg["lightsail_plan"],
            keyPairName=self.cfg["keypair_name"],
            userData=user_data,
            tags=tags,
        )
        log.info("  Instance creation initiated")
        self.state.runbook_sections_complete.append("instance")

    # ── Step D: Static IP ────────────────────────────────────────────

    def allocate_static_ip(self) -> str:
        log.info("━━ Step D: Static IP → %s", self.cfg["static_ip_name"])
        if self.dry_run:
            self._record(f"lightsail.get_static_ip(staticIpName={self.cfg['static_ip_name']!r})")
            self._record(f"lightsail.allocate_static_ip(staticIpName={self.cfg['static_ip_name']!r})")
            self._record(
                f"lightsail.attach_static_ip("
                f"staticIpName={self.cfg['static_ip_name']!r}, "
                f"instanceName={self.cfg['instance_name']!r})"
            )
            self.state.static_ip = "203.0.113.100"  # RFC5737 doc address for dry-run
            self.state.runbook_sections_complete.append("static_ip")
            return self.state.static_ip

        # Check if already allocated
        try:
            resp = self._ls.get_static_ip(staticIpName=self.cfg["static_ip_name"])
            ip = resp["staticIp"]["ipAddress"]
            log.info("  Static IP already allocated: %s", ip)
            # Attach if not already attached
            if resp["staticIp"].get("attachedTo") != self.cfg["instance_name"]:
                self._ls.attach_static_ip(
                    staticIpName=self.cfg["static_ip_name"],
                    instanceName=self.cfg["instance_name"],
                )
                log.info("  Attached to %s", self.cfg["instance_name"])
            self.state.static_ip = ip
            self.state.runbook_sections_complete.append("static_ip")
            return ip
        except self._ls.exceptions.NotFoundException:
            pass

        self._ls.allocate_static_ip(staticIpName=self.cfg["static_ip_name"])
        resp = self._ls.get_static_ip(staticIpName=self.cfg["static_ip_name"])
        ip = resp["staticIp"]["ipAddress"]
        self._ls.attach_static_ip(
            staticIpName=self.cfg["static_ip_name"],
            instanceName=self.cfg["instance_name"],
        )
        log.info("  Static IP: %s → attached to %s", ip, self.cfg["instance_name"])
        self.state.static_ip = ip
        self.state.runbook_sections_complete.append("static_ip")
        return ip

    # ── Step E: Firewall ─────────────────────────────────────────────

    def set_firewall(self, rules: list[dict]) -> None:
        label = "initial" if len(rules) == 3 else "final (tightened)"
        log.info("━━ Step E: Firewall → %s", label)
        port_rules = [
            {
                "fromPort": r["fromPort"],
                "toPort": r["toPort"],
                "protocol": r["protocol"],
                "cidrs": ["0.0.0.0/0"],
            }
            for r in rules
        ]
        self._ls_call(
            "put_instance_public_ports",
            portInfos=port_rules,
            instanceName=self.cfg["instance_name"],
        )
        log.info("  Firewall rules set: %s", [f"{r['fromPort']}/{r['protocol']}" for r in rules])
        self.state.runbook_sections_complete.append(f"firewall_{label.split()[0]}")

    # ── Step F: Route 53 DNS ─────────────────────────────────────────

    def set_dns(self, ip: str) -> None:
        if self.skip_dns:
            log.info("━━ Step F: DNS → SKIPPED (--skip-dns)")
            return
        log.info("━━ Step F: Route 53 DNS → %s + www.%s → %s",
                 self.cfg["domain"], self.cfg["domain"], ip)

        if self.dry_run:
            self._record(
                f"route53.list_hosted_zones_by_name(DNSName={self.cfg['domain']!r}) → get zone ID"
            )
            self._record(
                f"route53.change_resource_record_sets("
                f"HostedZoneId=<zone_id>, "
                f"Changes=[A {self.cfg['domain']} → {ip}, A www.{self.cfg['domain']} → {ip}])"
            )
            self.state.runbook_sections_complete.append("dns")
            return

        # Find hosted zone
        resp = self._r53.list_hosted_zones_by_name(DNSName=self.cfg["domain"], MaxItems="5")
        zones = [z for z in resp.get("HostedZones", [])
                 if z["Name"].rstrip(".") == self.cfg["domain"].rstrip(".")]
        if not zones:
            raise RuntimeError(f"No Route 53 hosted zone found for domain: {self.cfg['domain']}")
        zone_id = zones[0]["Id"].split("/")[-1]

        changes = []
        for name in [self.cfg["domain"], f"www.{self.cfg['domain']}"]:
            changes.append({
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": name,
                    "Type": "A",
                    "TTL": 300,
                    "ResourceRecords": [{"Value": ip}],
                },
            })
        self._r53.change_resource_record_sets(
            HostedZoneId=zone_id,
            ChangeBatch={"Comment": f"OpenClaw provisioner — {self.cfg['slug']}", "Changes": changes},
        )
        log.info("  DNS records upserted in zone %s", zone_id)
        self.state.runbook_sections_complete.append("dns")

    # ── Step G: Wait for boot ────────────────────────────────────────

    def wait_for_boot(self) -> None:
        log.info("━━ Step G: Wait for instance to reach running state")
        if self.dry_run:
            self._record(
                f"lightsail.get_instance(instanceName={self.cfg['instance_name']!r}) "
                f"→ poll until state=running"
            )
            self._record(
                f"socket.connect({self.state.static_ip}:{SSH_PORT_INITIAL}) → wait for SSH"
            )
            log.info("  [DRY-RUN] Would poll for running state and SSH availability")
            self.state.runbook_sections_complete.append("boot_wait")
            return

        for attempt in range(1, BOOT_POLL_MAX + 1):
            resp = self._ls.get_instance(instanceName=self.cfg["instance_name"])
            state = resp["instance"]["state"]["name"]
            log.info("  [%d/%d] Instance state: %s", attempt, BOOT_POLL_MAX, state)
            if state == "running":
                break
            time.sleep(BOOT_POLL_INTERVAL)
        else:
            raise TimeoutError("Instance did not reach 'running' state in time")

        # Wait for SSH port 22 to be reachable
        ip = self.state.static_ip
        log.info("  Waiting for SSH on %s:%d ...", ip, SSH_PORT_INITIAL)
        for attempt in range(1, SSH_POLL_MAX + 1):
            try:
                with socket.create_connection((ip, SSH_PORT_INITIAL), timeout=5):
                    log.info("  SSH reachable after %d attempts", attempt)
                    break
            except (socket.timeout, ConnectionRefusedError, OSError):
                time.sleep(SSH_POLL_INTERVAL)
        else:
            raise TimeoutError(f"SSH on {ip}:{SSH_PORT_INITIAL} did not become available")
        self.state.runbook_sections_complete.append("boot_wait")

    # ── Step H: Wait for cloud-init ──────────────────────────────────

    def wait_for_cloud_init(self, operator_pubkey: str) -> None:
        """
        Poll for the cloud-init sentinel file via SSH.

        Implementation choice: paramiko over subprocess.
        Rationale: paramiko is a pure-Python SSH library that gives us structured
        stdout/stderr without shell-escaping issues, avoids the need for the `ssh`
        binary to be in PATH (important in CI/Docker), and makes the SSH fingerprint
        available for capture. subprocess + ssh would work but adds env coupling.
        """
        log.info("━━ Step H: Wait for cloud-init to complete")
        if self.dry_run:
            self._record(
                f"paramiko.SSHClient.connect({self.state.static_ip}:{SSH_PORT_INITIAL}, "
                f"username=ubuntu) → poll /var/lib/cloud/instance/boot-finished"
            )
            log.info("  [DRY-RUN] Would poll for sentinel file /var/lib/cloud/instance/boot-finished")
            self.state.runbook_sections_complete.append("cloud_init_wait")
            return

        import paramiko

        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        # Load the operator private key
        key_path = Path(self.cfg["ssh_pubkey_path"]).expanduser()
        priv_key_path = key_path.with_suffix("")
        if priv_key_path.exists():
            priv_key = paramiko.Ed25519Key.from_private_key_file(str(priv_key_path))
        else:
            raise RuntimeError(
                f"Private key not found at {priv_key_path}. "
                "The cloud-init user-data injects the operator pubkey; "
                "the matching private key must be available locally."
            )

        sentinel = "/var/lib/cloud/instance/boot-finished"
        log.info("  Polling cloud-init sentinel (may take 10–15 min)...")

        for attempt in range(1, CLOUD_INIT_POLL_MAX + 1):
            try:
                ssh.connect(
                    self.state.static_ip,
                    port=SSH_PORT_INITIAL,
                    username="ubuntu",
                    pkey=priv_key,
                    timeout=15,
                    banner_timeout=30,
                )
                # Capture host fingerprint on first connect
                if not self.state.ssh_fingerprint:
                    transport = ssh.get_transport()
                    if transport:
                        host_key = transport.get_remote_server_key()
                        self.state.ssh_fingerprint = base64.b64encode(
                            host_key.asbytes()
                        ).decode()

                stdin, stdout, stderr = ssh.exec_command(
                    f"test -f {sentinel} && echo OK || echo WAIT"
                )
                result = stdout.read().decode().strip()
                ssh.close()

                if result == "OK":
                    log.info("  cloud-init complete after %d polls", attempt)
                    self.state.runbook_sections_complete.append("cloud_init_wait")
                    return
                log.info("  [%d/%d] cloud-init still running...", attempt, CLOUD_INIT_POLL_MAX)
            except Exception as e:
                log.debug("  SSH attempt %d failed: %s", attempt, e)

            time.sleep(CLOUD_INIT_POLL_INTERVAL)

        raise TimeoutError("cloud-init did not complete in time")

    # ── Step I: Retrieve Tailscale IP ────────────────────────────────

    def retrieve_tailscale_ip(self) -> str:
        """
        Retrieve the Tailscale IP from the remote host via SSH.
        The Tailscale API approach requires a separate API key scope;
        SSH is simpler and doesn't require additional credentials.
        """
        log.info("━━ Step I: Retrieve Tailscale IP")
        if self.dry_run:
            self._record(
                f"paramiko.SSHClient.connect({self.state.static_ip}:{SSH_PORT_INITIAL}) → "
                f"run: tailscale ip -4"
            )
            ts_ip = "100.64.1.100"
            self.state.tailscale_ip = ts_ip
            log.info("  [DRY-RUN] Tailscale IP: %s", ts_ip)
            self.state.runbook_sections_complete.append("tailscale_ip")
            return ts_ip

        import paramiko

        priv_key_path = Path(self.cfg["ssh_pubkey_path"]).expanduser().with_suffix("")
        priv_key = paramiko.Ed25519Key.from_private_key_file(str(priv_key_path))

        for attempt in range(1, 12):
            try:
                ssh = paramiko.SSHClient()
                ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                ssh.connect(
                    self.state.static_ip,
                    port=SSH_PORT_INITIAL,
                    username="ubuntu",
                    pkey=priv_key,
                    timeout=15,
                )
                _, stdout, _ = ssh.exec_command("tailscale ip -4 2>/dev/null || echo ''")
                ts_ip = stdout.read().decode().strip()
                ssh.close()
                if ts_ip and ts_ip.startswith("100."):
                    log.info("  Tailscale IP: %s", ts_ip)
                    self.state.tailscale_ip = ts_ip
                    self.state.runbook_sections_complete.append("tailscale_ip")
                    return ts_ip
                log.info("  [%d/12] Tailscale not yet assigned, retrying...", attempt)
            except Exception as e:
                log.debug("  Tailscale IP retrieval attempt %d: %s", attempt, e)
            time.sleep(20)

        raise TimeoutError("Could not retrieve Tailscale IP after multiple attempts")

    # ── Step J: Post-boot verification ───────────────────────────────

    def verify_post_boot(self) -> dict[str, bool]:
        """SSH into box and confirm hardening applied correctly."""
        log.info("━━ Step J: Post-boot verification")
        checks = {
            "deployer_exists": False,
            "ssh_on_2222": False,
            "ssh_on_22_closed": False,
            "ufw_active": False,
            "ssh_socket_masked": False,
            "watchdog_cron_exists": False,
        }

        if self.dry_run:
            for k in checks:
                self._record(f"SSH verify: {k}")
                checks[k] = True
            self.state.runbook_sections_complete.append("post_boot_verify")
            return checks

        import paramiko

        priv_key_path = Path(self.cfg["ssh_pubkey_path"]).expanduser().with_suffix("")
        priv_key = paramiko.Ed25519Key.from_private_key_file(str(priv_key_path))

        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect(
            self.state.static_ip,
            port=SSH_PORT_INITIAL,
            username="ubuntu",
            pkey=priv_key,
            timeout=15,
        )

        def run(cmd: str) -> str:
            _, stdout, _ = ssh.exec_command(cmd)
            return stdout.read().decode().strip()

        checks["deployer_exists"] = "deployer" in run("id deployer 2>/dev/null || echo ''")
        checks["ssh_on_2222"] = "2222" in run("ss -tlnp | grep sshd || echo ''")
        checks["ssh_on_22_closed"] = ":22 " not in run("ss -tlnp | grep ':22 ' || echo ''")
        checks["ufw_active"] = "active" in run("ufw status | head -1")
        checks["ssh_socket_masked"] = "masked" in run("systemctl status ssh.socket | grep -i masked || echo ''")
        checks["watchdog_cron_exists"] = "@reboot" in run("cat /etc/cron.d/ssh-watchdog 2>/dev/null || echo ''")

        ssh.close()

        all_ok = all(checks.values())
        if all_ok:
            log.info("  Post-boot verification: all checks PASSED ✓")
        else:
            failed = [k for k, v in checks.items() if not v]
            log.warning("  Post-boot verification: FAILED checks: %s", failed)

        self.state.runbook_sections_complete.append("post_boot_verify")
        return checks

    # ── Step K: Tighten firewall ─────────────────────────────────────

    def tighten_firewall(self) -> None:
        log.info("━━ Step K: Tighten Lightsail firewall (remove port 22)")
        self.set_firewall(FIREWALL_FINAL)
        msg = (
            "🔒 Port 22 removed from Lightsail public firewall.\n"
            "   SSH remains accessible via Tailscale on port 2222.\n"
            "   Lightsail browser console (ubuntu user) remains as backup."
        )
        log.info("  %s", msg)
        self.state.runbook_sections_complete.append("firewall_tightened")

    # ── Step L: Emit state file ──────────────────────────────────────

    def save_state(self, state_dir: Path) -> Path:
        log.info("━━ Step L: Save state file")
        self.state.timestamp_complete = datetime.now(timezone.utc).isoformat()
        out = self.state.save(state_dir)
        log.info("  State written to: %s", out)
        return out

    # ── Step M: Final report ─────────────────────────────────────────

    def final_report(self, state_path: Path) -> None:
        log.info("━━ Step M: Provisioning complete")
        s = self.state
        print("\n" + "=" * 60)
        print(f"  OpenClaw Lightsail Provisioner — DONE")
        print("=" * 60)
        print(f"  Instance:      {s.instance_name}")
        print(f"  Static IP:     {s.static_ip}")
        print(f"  Tailscale IP:  {s.tailscale_ip}")
        print(f"  Domain:        {s.domain}")
        print(f"  Region:        {s.aws_region}")
        print(f"  Sections done: {', '.join(s.runbook_sections_complete)}")
        print(f"  State file:    {state_path}")
        print()
        print("  ── Next step ──────────────────────────────────────────")
        print(f"  python3 install_openclaw.py state/{s.slug}.json")
        print()
        print("  ── SSH access ─────────────────────────────────────────")
        if s.tailscale_ip:
            print(f"  ssh -p 2222 deployer@{s.tailscale_ip}")
        print(f"  (public SSH port 22 removed — Tailscale required)")
        print("=" * 60 + "\n")


# ---------------------------------------------------------------------------
# Main entrypoint
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="OpenClaw Lightsail Provisioner — automates Sections 1–13 of the hardening runbook",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("fork_yaml", help="Path to fork.yaml")
    p.add_argument("--dry-run", action="store_true",
                   help="Print planned API calls without hitting AWS")
    p.add_argument("--aws-profile", default="default",
                   help="AWS profile name (default: default)")
    p.add_argument("--skip-dns", action="store_true",
                   help="Skip Route 53 DNS record creation")
    p.add_argument("--verbose", action="store_true",
                   help="Enable verbose logging")
    p.add_argument("--region", default="",
                   help="AWS region override (overrides fork.yaml infra.aws_region)")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    setup_logging(args.verbose)

    fork_yaml_path = Path(args.fork_yaml).expanduser().resolve()
    if not fork_yaml_path.exists():
        log.error("fork.yaml not found: %s", fork_yaml_path)
        return 1

    # ── Load + validate fork.yaml ────────────────────────────────────
    log.info("Loading fork.yaml: %s", fork_yaml_path)
    raw = load_fork_yaml(fork_yaml_path)
    errors = validate_fork_yaml(raw)
    if errors:
        log.error("fork.yaml validation failed:")
        for e in errors:
            log.error("  • %s", e)
        return 1

    cfg = resolve_config(raw)
    if args.region:
        cfg["aws_region"] = args.region

    if args.dry_run:
        log.info("═══ DRY-RUN MODE — no AWS calls will be made ═══")

    log.info("Config: slug=%s  domain=%s  region=%s  plan=%s",
             cfg["slug"], cfg["domain"], cfg["aws_region"], cfg["lightsail_plan"])

    # ── Read Tailscale auth key from env ─────────────────────────────
    ts_key_env = cfg["tailscale_auth_key_env"]
    tailscale_auth_key = os.environ.get(ts_key_env, "")
    if args.dry_run and not tailscale_auth_key:
        tailscale_auth_key = f"{TAILSCALE_AUTH_KEY_PREFIX}DRYRUN-PLACEHOLDER-KEY-12345"
        log.info("  [DRY-RUN] Using placeholder Tailscale auth key")

    # ── Read operator SSH pubkey ─────────────────────────────────────
    pubkey_path = Path(cfg["ssh_pubkey_path"]).expanduser()
    if pubkey_path.exists():
        operator_pubkey = pubkey_path.read_text().strip()
    elif args.dry_run:
        operator_pubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA DRY-RUN-OPERATOR-KEY deployer@dryrun"
        log.info("  [DRY-RUN] Pubkey not found at %s — using placeholder", pubkey_path)
    else:
        log.error("Operator SSH pubkey not found: %s", pubkey_path)
        return 1

    # Optional deployer pubkey (for CI/automation)
    deployer_pubkey = ""
    if cfg.get("deployer_pubkey_path"):
        dp = Path(cfg["deployer_pubkey_path"]).expanduser()
        if dp.exists():
            deployer_pubkey = dp.read_text().strip()

    # ── Render cloud-init ────────────────────────────────────────────
    log.info("Rendering cloud_init.yaml.j2 ...")
    try:
        if args.dry_run:
            user_data = render_cloud_init(cfg, operator_pubkey, deployer_pubkey)
        else:
            user_data = render_cloud_init_with_key(
                cfg, operator_pubkey, tailscale_auth_key, deployer_pubkey
            )
        log.info("  cloud-init rendered: %d bytes", len(user_data))
    except Exception as e:
        log.error("Failed to render cloud-init: %s", e)
        return 1

    # ── Print cloud-init in dry-run ──────────────────────────────────
    if args.dry_run:
        print("\n" + "─" * 60)
        print("CLOUD-INIT USER DATA (would be uploaded to Lightsail):")
        print("─" * 60)
        # Print first 80 lines to keep output manageable
        lines = user_data.splitlines()
        for line in lines[:80]:
            print(line)
        if len(lines) > 80:
            print(f"  ... ({len(lines) - 80} more lines) ...")
        print("─" * 60 + "\n")

    # ── Provisioner ──────────────────────────────────────────────────
    state_dir = Path(__file__).parent / "state"
    p = LightsailProvisioner(
        cfg=cfg,
        aws_profile=args.aws_profile,
        dry_run=args.dry_run,
        skip_dns=args.skip_dns,
        verbose=args.verbose,
    )

    try:
        # A. Preflight
        p.preflight(tailscale_auth_key, operator_pubkey)

        # B. Key pair
        p.create_keypair()

        # C. Instance
        p.launch_instance(user_data)

        # D. Static IP
        p.allocate_static_ip()

        # E. Initial firewall
        p.set_firewall(FIREWALL_INITIAL)

        # F. DNS
        p.set_dns(p.state.static_ip)

        # G. Wait for boot
        p.wait_for_boot()

        # H. Wait for cloud-init
        p.wait_for_cloud_init(operator_pubkey)

        # I. Tailscale IP
        p.retrieve_tailscale_ip()

        # J. Post-boot verification
        checks = p.verify_post_boot()

        # K. Tighten firewall
        p.tighten_firewall()

        # L. State file
        state_path = p.save_state(state_dir)

        # M. Final report
        p.final_report(state_path)

    except (ValueError, RuntimeError) as e:
        log.error("Provisioning failed: %s", e)
        # Save partial state
        p.save_state(state_dir)
        return 1
    except KeyboardInterrupt:
        log.warning("Interrupted — saving partial state")
        p.save_state(state_dir)
        return 130

    # Print dry-run summary
    if args.dry_run:
        print("\n" + "═" * 60)
        print(f"DRY-RUN SUMMARY — {len(p.planned_calls)} planned API calls:")
        print("═" * 60)
        for i, call in enumerate(p.planned_calls, 1):
            print(f"  {i:2d}. {call}")
        print("═" * 60 + "\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
