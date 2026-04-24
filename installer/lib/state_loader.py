"""
state_loader.py — load and validate a Track-B provisioner state file.

Expected JSON schema (subset):
  {
    "slug": "acme-prod",
    "tailscale_ip": "100.x.x.x",
    "static_ip": "1.2.3.4",
    "domain": "acme.example.com",
    "ssh_user": "deployer",
    "ssh_port": 2222,
    "operator_telegram_id": 123456789   # optional — may be missing or null
  }
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


REQUIRED_FIELDS = {"slug", "tailscale_ip", "static_ip", "domain", "ssh_user", "ssh_port"}


@dataclass
class StateFile:
    slug: str
    tailscale_ip: str
    static_ip: str
    domain: str
    ssh_user: str
    ssh_port: int
    operator_telegram_id: Optional[int] = None
    # Carry raw dict for forward-compat (extra fields from Track B)
    raw: dict = field(default_factory=dict, repr=False, compare=False)

    @property
    def webhook_url(self) -> str:
        return f"https://{self.domain}/webhook/telegram"

    @property
    def gateway_url(self) -> str:
        return f"ws://127.0.0.1:18789"


def load_state(path: str | Path) -> StateFile:
    """Load and validate a Track-B state JSON file.

    Raises:
        FileNotFoundError: if the file does not exist.
        ValueError: if required fields are missing or have wrong types.
    """
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"State file not found: {path}")

    with path.open() as fh:
        data: dict = json.load(fh)

    missing = REQUIRED_FIELDS - set(data.keys())
    if missing:
        raise ValueError(f"State file missing required fields: {sorted(missing)}")

    # Type coercion + validation
    try:
        ssh_port = int(data["ssh_port"])
    except (ValueError, TypeError) as exc:
        raise ValueError(f"ssh_port must be an integer, got: {data['ssh_port']!r}") from exc

    operator_id = data.get("operator_telegram_id") or data.get("telegram_operator_id")
    if operator_id is not None:
        try:
            operator_id = int(operator_id)
        except (ValueError, TypeError):
            operator_id = None

    return StateFile(
        slug=str(data["slug"]),
        tailscale_ip=str(data["tailscale_ip"]),
        static_ip=str(data["static_ip"]),
        domain=str(data["domain"]),
        ssh_user=str(data["ssh_user"]),
        ssh_port=ssh_port,
        operator_telegram_id=operator_id,
        raw=data,
    )
