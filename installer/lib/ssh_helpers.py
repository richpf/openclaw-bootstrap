"""
ssh_helpers.py — thin paramiko wrapper with an injectable mock transport.

Design:
  - SSHClient wraps paramiko but accepts an optional transport kwarg.
  - Pass a MockSSHTransport instance in tests to avoid real SSH.
  - All results return SSHResult(rc, stdout, stderr).
  - SFTP upload is handled via upload_file() / upload_dir().
"""

from __future__ import annotations

import io
import os
import stat
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional, Protocol


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------

@dataclass
class SSHResult:
    rc: int
    stdout: str
    stderr: str
    elapsed_ms: float = 0.0

    @property
    def ok(self) -> bool:
        return self.rc == 0

    def check(self, msg: str = "") -> "SSHResult":
        """Raise RuntimeError if rc != 0."""
        if not self.ok:
            detail = self.stderr.strip() or self.stdout.strip()
            raise RuntimeError(f"{msg}: rc={self.rc} — {detail}".strip(": "))
        return self


# ---------------------------------------------------------------------------
# Transport protocol (implemented by real paramiko and mock)
# ---------------------------------------------------------------------------

class _Transport(Protocol):
    def run(self, cmd: str, timeout: int = 30) -> SSHResult: ...
    def upload_file(self, local: Path, remote: str, mode: int = 0o644) -> None: ...
    def upload_dir(self, local: Path, remote: str) -> None: ...
    def close(self) -> None: ...


# ---------------------------------------------------------------------------
# Real paramiko transport
# ---------------------------------------------------------------------------

class _ParamikoTransport:
    """Wraps a live paramiko SSHClient."""

    def __init__(self, client: Any):
        self._client = client

    def run(self, cmd: str, timeout: int = 60) -> SSHResult:
        t0 = time.monotonic()
        stdin, stdout, stderr = self._client.exec_command(cmd, timeout=timeout)
        rc = stdout.channel.recv_exit_status()
        out = stdout.read().decode(errors="replace")
        err = stderr.read().decode(errors="replace")
        elapsed = (time.monotonic() - t0) * 1000
        return SSHResult(rc=rc, stdout=out, stderr=err, elapsed_ms=elapsed)

    def upload_file(self, local: Path, remote: str, mode: int = 0o644) -> None:
        sftp = self._client.open_sftp()
        try:
            sftp.put(str(local), remote)
            sftp.chmod(remote, mode)
        finally:
            sftp.close()

    def upload_dir(self, local: Path, remote: str) -> None:
        """Recursively upload a local directory to a remote path."""
        sftp = self._client.open_sftp()
        try:
            _sftp_mkdir_p(sftp, remote)
            for item in sorted(local.rglob("*")):
                rel = item.relative_to(local)
                rpath = f"{remote}/{rel.as_posix()}"
                if item.is_dir():
                    _sftp_mkdir_p(sftp, rpath)
                else:
                    sftp.put(str(item), rpath)
                    sftp.chmod(rpath, 0o644)
        finally:
            sftp.close()

    def close(self) -> None:
        self._client.close()


def _sftp_mkdir_p(sftp: Any, path: str) -> None:
    parts = path.lstrip("/").split("/")
    current = "" if path.startswith("/") else "."
    for part in parts:
        current = f"{current}/{part}" if current else part
        try:
            sftp.stat(current)
        except IOError:
            sftp.mkdir(current)


# ---------------------------------------------------------------------------
# Mock transport (for tests)
# ---------------------------------------------------------------------------

class MockSSHTransport:
    """
    Injectable mock for unit tests.

    Usage::

        mock = MockSSHTransport()
        mock.register("uname -r", SSHResult(0, "5.15.0", ""))
        client = SSHClient.from_transport(mock)
        result = client.run("uname -r")
        assert result.stdout == "5.15.0"
    """

    def __init__(self):
        self._registry: dict[str, SSHResult] = {}
        self._default: SSHResult = SSHResult(0, "", "")
        self.calls: list[str] = []
        self.uploads: list[tuple[str, str]] = []  # (local, remote)

    def register(self, cmd: str, result: SSHResult) -> "MockSSHTransport":
        """Register an exact command → result mapping."""
        self._registry[cmd] = result
        return self

    def register_prefix(self, prefix: str, result: SSHResult) -> "MockSSHTransport":
        """Register a prefix match (checked after exact)."""
        self._registry[f"__prefix__{prefix}"] = result
        return self

    def set_default(self, result: SSHResult) -> "MockSSHTransport":
        self._default = result
        return self

    def run(self, cmd: str, timeout: int = 60) -> SSHResult:
        self.calls.append(cmd)
        if cmd in self._registry:
            return self._registry[cmd]
        for key, val in self._registry.items():
            if key.startswith("__prefix__") and cmd.startswith(key[10:]):
                return val
        return self._default

    def upload_file(self, local: Path, remote: str, mode: int = 0o644) -> None:
        self.uploads.append((str(local), remote))

    def upload_dir(self, local: Path, remote: str) -> None:
        self.uploads.append((str(local), remote))

    def close(self) -> None:
        pass


# ---------------------------------------------------------------------------
# Public SSHClient
# ---------------------------------------------------------------------------

class SSHClient:
    """
    High-level SSH client.  Constructed via factory methods or from_transport().

    Parameters
    ----------
    transport: _Transport
        Any object implementing run/upload_file/upload_dir/close.
    dry_run: bool
        If True, commands are logged but not executed.
    """

    def __init__(self, transport: Any, dry_run: bool = False):
        self._transport = transport
        self.dry_run = dry_run
        self.command_log: list[str] = []

    # ------------------------------------------------------------------
    # Factory: real paramiko connection
    # ------------------------------------------------------------------

    @classmethod
    def connect(
        cls,
        host: str,
        port: int,
        username: str,
        key_filename: Optional[str] = None,
        timeout: int = 15,
        dry_run: bool = False,
    ) -> "SSHClient":
        """Open a real SSH connection via paramiko."""
        try:
            import paramiko
        except ImportError as exc:
            raise ImportError("paramiko is required: pip install paramiko") from exc

        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        connect_kwargs: dict[str, Any] = dict(
            hostname=host,
            port=port,
            username=username,
            timeout=timeout,
            allow_agent=True,
            look_for_keys=True,
        )
        if key_filename:
            connect_kwargs["key_filename"] = key_filename
        client.connect(**connect_kwargs)
        return cls(_ParamikoTransport(client), dry_run=dry_run)

    # ------------------------------------------------------------------
    # Factory: inject mock/custom transport
    # ------------------------------------------------------------------

    @classmethod
    def from_transport(cls, transport: Any, dry_run: bool = False) -> "SSHClient":
        return cls(transport, dry_run=dry_run)

    # ------------------------------------------------------------------
    # Core operations
    # ------------------------------------------------------------------

    def run(self, cmd: str, timeout: int = 60, check: bool = False) -> SSHResult:
        self.command_log.append(cmd)
        if self.dry_run:
            return SSHResult(0, f"[dry-run] {cmd}", "", 0.0)
        result = self._transport.run(cmd, timeout=timeout)
        if check and not result.ok:
            raise RuntimeError(
                f"Command failed (rc={result.rc}): {cmd}\n{result.stderr.strip()}"
            )
        return result

    def sudo(self, cmd: str, timeout: int = 60, check: bool = True) -> SSHResult:
        return self.run(f"sudo {cmd}", timeout=timeout, check=check)

    def sudo_as(self, user: str, cmd: str, timeout: int = 60, check: bool = True) -> SSHResult:
        return self.run(f"sudo -u {user} -i {cmd}", timeout=timeout, check=check)

    def upload_file(self, local: Path, remote: str, mode: int = 0o644) -> None:
        if self.dry_run:
            return
        self._transport.upload_file(local, remote, mode)

    def upload_dir(self, local: Path, remote: str) -> None:
        if self.dry_run:
            return
        self._transport.upload_dir(local, remote)

    def close(self) -> None:
        self._transport.close()

    def __enter__(self) -> "SSHClient":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()
