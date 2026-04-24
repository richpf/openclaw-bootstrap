"""
step_runner.py — structured step execution with logging and resume support.

Steps are callables that receive a StepContext and return a StepResult.
The runner logs progress as JSON-lines to a log file and supports
--resume-from <STEP_ID> to skip already-completed steps.
"""

from __future__ import annotations

import enum
import json
import sys
import time
import traceback
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

class StepStatus(str, enum.Enum):
    PENDING = "pending"
    RUNNING = "running"
    SUCCESS = "success"
    FAILED = "failed"
    SKIPPED = "skipped"
    DRY_RUN = "dry_run"


@dataclass
class StepResult:
    step_id: str
    status: StepStatus
    message: str = ""
    details: Dict[str, Any] = field(default_factory=dict)
    elapsed_ms: float = 0.0

    @property
    def ok(self) -> bool:
        return self.status in (StepStatus.SUCCESS, StepStatus.SKIPPED, StepStatus.DRY_RUN)


@dataclass
class StepContext:
    """Passed to every step callable."""
    slug: str
    dry_run: bool
    log_path: Path
    ssh: Any  # SSHClient — typed as Any to avoid circular import
    state: Any  # StateFile
    bundle_path: Path
    keys: Dict[str, str] = field(default_factory=dict)
    scratch: Dict[str, Any] = field(default_factory=dict)  # shared state between steps


StepFn = Callable[[StepContext], StepResult]


@dataclass
class Step:
    id: str           # e.g. "A_preflight"
    label: str        # human-readable
    fn: StepFn


# ---------------------------------------------------------------------------
# Logger
# ---------------------------------------------------------------------------

class StepLogger:
    """Writes JSON-line structured logs and echoes to stdout."""

    def __init__(self, log_path: Path, verbose: bool = True):
        log_path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = log_path.open("a", buffering=1)
        self._verbose = verbose

    def write(self, event: dict) -> None:
        event.setdefault("ts", datetime.now(timezone.utc).isoformat())
        line = json.dumps(event)
        self._fh.write(line + "\n")
        if self._verbose:
            level = event.get("level", "INFO")
            msg = event.get("msg", "")
            step = event.get("step", "")
            prefix = f"[{step}] " if step else ""
            print(f"  {level:7s} {prefix}{msg}", flush=True)

    def info(self, msg: str, **kw: Any) -> None:
        self.write({"level": "INFO", "msg": msg, **kw})

    def warn(self, msg: str, **kw: Any) -> None:
        self.write({"level": "WARNING", "msg": msg, **kw})

    def error(self, msg: str, **kw: Any) -> None:
        self.write({"level": "ERROR", "msg": msg, **kw})

    def step_start(self, step: Step) -> None:
        self.write({"level": "STEP", "event": "start", "step": step.id, "msg": step.label})

    def step_end(self, result: StepResult) -> None:
        icon = "✓" if result.ok else "✗"
        self.write({
            "level": "STEP",
            "event": "end",
            "step": result.step_id,
            "status": result.status.value,
            "elapsed_ms": round(result.elapsed_ms),
            "msg": f"{icon} {result.message}",
        })

    def close(self) -> None:
        self._fh.close()


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

class StepRunner:
    """
    Runs a list of Step objects in order, with:
    - resume-from support (skip steps before resume_from)
    - dry-run threading
    - structured logging
    - per-step timing
    """

    def __init__(
        self,
        steps: List[Step],
        context: StepContext,
        log_path: Path,
        resume_from: Optional[str] = None,
        verbose: bool = True,
    ):
        self.steps = steps
        self.ctx = context
        self.logger = StepLogger(log_path, verbose=verbose)
        self.resume_from = resume_from
        self.results: List[StepResult] = []

    def run(self) -> List[StepResult]:
        """Execute all steps. Returns list of StepResult."""
        skipping = self.resume_from is not None
        step_ids = [s.id for s in self.steps]

        if skipping and self.resume_from not in step_ids:
            raise ValueError(
                f"--resume-from '{self.resume_from}' not found. "
                f"Valid step IDs: {step_ids}"
            )

        self.logger.info(
            f"Starting installation for slug='{self.ctx.slug}'",
            dry_run=self.ctx.dry_run,
            resume_from=self.resume_from,
        )

        for step in self.steps:
            # Handle resume
            if skipping:
                if step.id == self.resume_from:
                    skipping = False
                else:
                    result = StepResult(
                        step_id=step.id,
                        status=StepStatus.SKIPPED,
                        message=f"Skipped (resuming from {self.resume_from})",
                    )
                    self.results.append(result)
                    self.logger.step_end(result)
                    continue

            self.logger.step_start(step)
            t0 = time.monotonic()

            try:
                result = step.fn(self.ctx)
                result.elapsed_ms = (time.monotonic() - t0) * 1000
            except Exception as exc:
                tb = traceback.format_exc()
                self.logger.error(tb, step=step.id)
                result = StepResult(
                    step_id=step.id,
                    status=StepStatus.FAILED,
                    message=f"Unhandled exception: {exc}",
                    elapsed_ms=(time.monotonic() - t0) * 1000,
                )

            self.logger.step_end(result)
            self.results.append(result)

            if not result.ok:
                self.logger.error(
                    f"Step {step.id} failed — aborting. "
                    f"Re-run with --resume-from {step.id} to retry.",
                    step=step.id,
                )
                break

        self.logger.close()
        return self.results

    def summary(self) -> dict:
        """Return a summary dict of step outcomes."""
        return {
            "slug": self.ctx.slug,
            "steps": [
                {
                    "id": r.step_id,
                    "status": r.status.value,
                    "message": r.message,
                    "elapsed_ms": round(r.elapsed_ms),
                }
                for r in self.results
            ],
            "failed": [r.step_id for r in self.results if r.status == StepStatus.FAILED],
            "all_ok": all(r.ok for r in self.results),
        }
