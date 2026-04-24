#!/usr/bin/env python3
"""
orchestrate_fork.py — End-to-end OpenClaw fork orchestrator.

Sequences three tracks:
  1. Track A — fork.sh: render workspace bundle from fork.yaml template
  2. Track B — provision_lightsail.py: provision Lightsail box
  3. Track C — install_openclaw.py: install OpenClaw on the provisioned box

Usage:
    python3 orchestrate_fork.py <fork.yaml> [--dry-run] [--skip-confirm]
                                [--skip-provision] [--skip-install]
                                [--state-file PATH] [--bundle-dir PATH]
                                [--keys-file PATH]

Options:
    --dry-run           Thread dry-run through all sub-scripts.
    --skip-confirm      Skip Y/n gates (useful in CI).
    --skip-provision    Skip Track B (assume box already provisioned).
    --skip-install      Skip Track C (stop after provisioning).
    --state-file PATH   Use existing state file (skip/override Track B output).
    --bundle-dir PATH   Use existing bundle dir (skip/override Track A output).
    --keys-file PATH    Keys file for installer (skip interactive prompts).
    --slug SLUG         Override slug (default: derived from fork.yaml).

Transcript saved to: state/orchestrate-{slug}.log
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
FORK_TEMPLATE_DIR = SCRIPT_DIR / "fork-template"
PROVISIONER_DIR = SCRIPT_DIR / "provisioner"
INSTALLER_DIR = SCRIPT_DIR / "installer"
STATE_DIR = SCRIPT_DIR / "state"


# ---------------------------------------------------------------------------
# Transcript logger
# ---------------------------------------------------------------------------

class Transcript:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = path.open("a", buffering=1)
        self._path = path

    def log(self, msg: str, level: str = "INFO") -> None:
        ts = datetime.now(timezone.utc).isoformat()
        line = f"[{ts}] [{level}] {msg}"
        self._fh.write(line + "\n")
        print(line, flush=True)

    def info(self, msg: str) -> None:
        self.log(msg, "INFO")

    def warn(self, msg: str) -> None:
        self.log(msg, "WARN")

    def error(self, msg: str) -> None:
        self.log(msg, "ERROR")

    def section(self, title: str) -> None:
        sep = "=" * 64
        self.log(f"\n{sep}\n  {title}\n{sep}")

    def close(self) -> None:
        self._fh.close()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def confirm(prompt: str, skip: bool = False) -> bool:
    """Prompt Y/n. Return True to continue, False to abort."""
    if skip:
        print(f"  [auto-confirm] {prompt} → Y")
        return True
    while True:
        ans = input(f"\n  {prompt} [Y/n]: ").strip().lower()
        if ans in ("y", "yes", ""):
            return True
        if ans in ("n", "no"):
            return False


def run_phase(
    label: str,
    cmd: list[str],
    transcript: Transcript,
    dry_run: bool = False,
    capture: bool = False,
) -> tuple[int, str]:
    """Run a subprocess phase, streaming output to transcript."""
    transcript.section(f"Phase: {label}")
    transcript.info(f"Command: {' '.join(cmd)}")

    if dry_run:
        transcript.info(f"[DRY RUN] Would execute: {' '.join(cmd)}")
        return 0, ""

    t0 = time.monotonic()
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    output_lines = []
    for line in proc.stdout:
        line = line.rstrip()
        transcript.log(line, "OUT")
        if capture:
            output_lines.append(line)

    rc = proc.wait()
    elapsed = time.monotonic() - t0
    transcript.info(f"Phase '{label}' exited rc={rc} in {elapsed:.1f}s")
    return rc, "\n".join(output_lines)


def derive_slug_from_yaml(fork_yaml: Path) -> str:
    """Extract slug from fork.yaml (simple grep, no YAML parser required)."""
    if not fork_yaml.exists():
        return "openclaw-fork"
    for line in fork_yaml.read_text().splitlines():
        line = line.strip()
        if line.startswith("slug:"):
            val = line.split(":", 1)[1].strip().strip('"').strip("'")
            if val:
                return val
    return "openclaw-fork"


# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="End-to-end OpenClaw fork orchestrator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("fork_yaml", help="Path to fork.yaml configuration")
    parser.add_argument("--dry-run", action="store_true",
                        help="Simulate all phases without executing")
    parser.add_argument("--skip-confirm", action="store_true",
                        help="Auto-confirm all Y/n gates")
    parser.add_argument("--skip-provision", action="store_true",
                        help="Skip Track B (box already provisioned)")
    parser.add_argument("--skip-install", action="store_true",
                        help="Skip Track C (stop after provisioning)")
    parser.add_argument("--state-file", default=None,
                        help="Use existing state JSON file")
    parser.add_argument("--bundle-dir", default=None,
                        help="Use existing workspace bundle directory")
    parser.add_argument("--keys-file", default=None,
                        help="Keys file for installer (enables --skip-keys-prompt)")
    parser.add_argument("--slug", default=None,
                        help="Override slug (default: from fork.yaml)")
    return parser.parse_args(argv)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    args = parse_args(argv)

    fork_yaml = Path(args.fork_yaml)
    if not fork_yaml.exists() and not args.dry_run:
        print(f"ERROR: fork.yaml not found: {fork_yaml}", file=sys.stderr)
        return 1

    slug = args.slug or derive_slug_from_yaml(fork_yaml)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    transcript_path = STATE_DIR / f"orchestrate-{slug}.log"
    transcript = Transcript(transcript_path)

    transcript.section("OpenClaw Fork Orchestrator")
    transcript.info(f"slug={slug}")
    transcript.info(f"fork_yaml={fork_yaml}")
    transcript.info(f"dry_run={args.dry_run}")
    transcript.info(f"transcript={transcript_path}")

    if args.dry_run:
        print("\n  *** DRY RUN — no changes will be made ***\n")

    # -----------------------------------------------------------------------
    # Phase 1: Track A — fork.sh
    # -----------------------------------------------------------------------

    bundle_dir: Path | None = None

    if args.bundle_dir:
        bundle_dir = Path(args.bundle_dir)
        transcript.info(f"Using pre-rendered bundle: {bundle_dir}")
    else:
        fork_sh = FORK_TEMPLATE_DIR / "fork.sh"
        if not fork_sh.exists() and not args.dry_run:
            transcript.error(f"fork.sh not found at {fork_sh}")
            return 1

        if not confirm(
            f"Phase 1: Render workspace bundle from {fork_yaml.name}?",
            skip=args.skip_confirm
        ):
            transcript.warn("Phase 1 aborted by operator.")
            return 0

        rc, out = run_phase(
            "Track A — fork.sh",
            ["bash", str(fork_sh), str(fork_yaml)],
            transcript,
            dry_run=args.dry_run,
        )

        if rc != 0 and not args.dry_run:
            transcript.error(f"fork.sh failed (rc={rc})")
            return 1

        # Discover output bundle
        out_dir = FORK_TEMPLATE_DIR / "out"
        if args.dry_run:
            bundle_dir = out_dir / f"{slug}-workspace"
            bundle_dir.mkdir(parents=True, exist_ok=True)
        else:
            candidates = sorted(out_dir.glob(f"{slug}-workspace"), key=lambda p: p.stat().st_mtime)
            if not candidates:
                # Fallback: any workspace dir
                candidates = sorted(out_dir.glob("*-workspace"), key=lambda p: p.stat().st_mtime)
            if not candidates:
                transcript.error(f"Could not find rendered bundle in {out_dir}/")
                return 1
            bundle_dir = candidates[-1]

        transcript.info(f"Bundle: {bundle_dir}")

    # -----------------------------------------------------------------------
    # Phase 2: Track B — provision_lightsail.py
    # -----------------------------------------------------------------------

    state_file: Path | None = None

    if args.state_file:
        state_file = Path(args.state_file)
        transcript.info(f"Using existing state file: {state_file}")
    elif args.skip_provision:
        transcript.info("Skipping Track B (--skip-provision)")
        # Look for any existing state file for this slug
        candidates = list((PROVISIONER_DIR / "state").glob(f"{slug}.json"))
        if candidates:
            state_file = candidates[0]
            transcript.info(f"Found state file: {state_file}")
        else:
            transcript.error(
                f"--skip-provision set but no state file found for slug={slug}. "
                f"Pass --state-file explicitly."
            )
            return 1
    else:
        provision_script = PROVISIONER_DIR / "provision_lightsail.py"
        if not provision_script.exists() and not args.dry_run:
            transcript.error(f"provision_lightsail.py not found at {provision_script}")
            return 1

        if not confirm(
            f"Phase 2: Provision Lightsail box for slug={slug}?",
            skip=args.skip_confirm
        ):
            transcript.warn("Phase 2 aborted by operator.")
            return 0

        provision_cmd = [sys.executable, str(provision_script), str(fork_yaml)]
        if args.dry_run:
            provision_cmd.append("--dry-run")

        rc, _ = run_phase(
            "Track B — provision_lightsail.py",
            provision_cmd,
            transcript,
            dry_run=False,  # let the provisioner handle its own dry-run flag
        )

        if rc != 0 and not args.dry_run:
            transcript.error(f"Provisioner failed (rc={rc})")
            return 1

        # Locate state file
        state_candidates = sorted(
            (PROVISIONER_DIR / "state").glob(f"{slug}.json"),
            key=lambda p: p.stat().st_mtime
        )
        if args.dry_run:
            # In dry-run, create a fake state file if provisioner didn't
            fake_state = STATE_DIR / f"{slug}-dry-run.json"
            fake_state.write_text(json.dumps({
                "slug": slug,
                "tailscale_ip": "100.64.0.2",
                "static_ip": "1.2.3.4",
                "domain": f"{slug}.example.com",
                "ssh_user": "deployer",
                "ssh_port": 2222,
            }, indent=2))
            state_file = fake_state
        elif state_candidates:
            state_file = state_candidates[-1]
        else:
            transcript.error(f"No state file found after provisioning for slug={slug}")
            return 1

        transcript.info(f"State file: {state_file}")

    # -----------------------------------------------------------------------
    # Phase 3: Track C — install_openclaw.py
    # -----------------------------------------------------------------------

    if args.skip_install:
        transcript.info("Skipping Track C (--skip-install)")
    else:
        install_script = INSTALLER_DIR / "install_openclaw.py"
        if not install_script.exists():
            transcript.error(f"install_openclaw.py not found at {install_script}")
            return 1

        if not confirm(
            f"Phase 3: Install OpenClaw on {slug}?",
            skip=args.skip_confirm
        ):
            transcript.warn("Phase 3 aborted by operator.")
            return 0

        install_cmd = [
            sys.executable, str(install_script),
            str(state_file),
            str(bundle_dir),
        ]
        if args.dry_run:
            install_cmd.append("--dry-run")
        if args.keys_file:
            install_cmd += ["--skip-keys-prompt", "--keys-file", args.keys_file]

        rc, _ = run_phase(
            "Track C — install_openclaw.py",
            install_cmd,
            transcript,
            dry_run=False,  # installer handles its own dry-run flag
        )

        if rc != 0 and not args.dry_run:
            transcript.error(f"Installer failed (rc={rc})")
            transcript.info(
                f"To retry the install:\n"
                f"  python3 {install_script} {state_file} {bundle_dir} "
                f"--resume-from <FAILED_STEP>"
            )
            return 1

    # -----------------------------------------------------------------------
    # Done
    # -----------------------------------------------------------------------

    transcript.section("Orchestration Complete")
    transcript.info(f"slug={slug}")
    if state_file:
        transcript.info(f"state={state_file}")
    if bundle_dir:
        transcript.info(f"bundle={bundle_dir}")
    transcript.info(f"transcript={transcript_path}")

    report_path = INSTALLER_DIR / "state" / f"install-{slug}.report.md"
    if report_path.exists():
        transcript.info(f"Report: {report_path}")
        print("\n" + report_path.read_text())
    else:
        transcript.info("DM the bot in Telegram to activate it.")

    transcript.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
