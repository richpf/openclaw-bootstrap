# OpenClaw Fork Template

> Clone an OpenClaw chief-of-staff workspace for a new operator — same patterns, zero contamination.

## Purpose

This directory contains a **parametrized workspace bundle** that replicates the
operational patterns of a mature OpenClaw instance (task routing, model stack,
journal discipline, memory schema, health checks) for a *different* operator,
stripping all app-specific state and personal details.

The fork template is the answer to: _"I want to give someone else the same AI
chief-of-staff setup I have, without leaking my data."_

---

## Quick Start

```bash
# 1. Copy the example config
cp fork-template/fork.yaml.example fork-template/fork.yaml

# 2. Fill in every field (operator details, persona, infra, git, telegram, backup)
$EDITOR fork-template/fork.yaml

# 3. Render the workspace
cd fork-template
./fork.sh fork.yaml

# 4. Inspect output
ls out/<operator-slug>-workspace/

# 5. Follow NEXT_STEPS.md inside the output directory to deploy to Lightsail
```

**What you get in `out/<slug>-workspace/`:**
- All `*.tmpl` files rendered with your values (SOUL.md, USER.md, IDENTITY.md, MEMORY.md)
- Static files copied as-is (AGENTS.md, TOOLS.md, HEARTBEAT.md, references/)
- `.env.example` listing every secret the fork needs
- `NEXT_STEPS.md` explaining how to tar + upload to Lightsail

---

## What Gets Carried vs. Stripped

See [`FORK_STRATEGY.md`](FORK_STRATEGY.md) for the full 3-bucket breakdown
(Carry / Strip / Parametrize) with file-level decisions.

Short version:
- **Carry:** AGENTS.md (task router, model stack), TOOLS.md template, Key Lessons
- **Parametrize:** SOUL.md, USER.md, IDENTITY.md, MEMORY.md, HEARTBEAT.md
- **Strip:** all project data, personal credentials, cron jobs, journals, hardcoded IPs

---

## Relationship to `bootstrap.sh`

| Script | Purpose |
|--------|---------|
| `bootstrap.sh` (root) | Installs OpenClaw on an existing Lightsail instance (Node.js, dependencies, gateway config, systemd). Idempotent. |
| `fork-template/fork.sh` | Renders a workspace bundle for a new operator from `fork.yaml`. Run locally; output is uploaded to a provisioned instance. |

These are complementary:
1. Use `fork.sh` to produce the workspace bundle (local step).
2. Upload the bundle to the Lightsail instance.
3. Use `bootstrap.sh` to install OpenClaw on that instance.

---

## Roadmap

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 1 | Fork template (this directory) — workspace rendering from fork.yaml | ✅ Complete |
| Phase 2 | Lightsail provisioner — automate steps 1-3 of NEXT_STEPS.md (instance creation, static IP, DNS) | ⬜ Planned |
| Phase 3 | OpenClaw installer — automate steps 4-8 (bootstrap, env, git sync, Telegram, backup) | ⬜ Planned |
| Phase 4 | Fork registry — track multiple active forks, shared key billing dashboard | ⬜ Backlog |

---

## Files

```
fork-template/
├── README.md               ← You are here
├── FORK_STRATEGY.md        ← Carry/Strip/Parametrize decisions, blocklist
├── fork.yaml.example       ← Schema + all configurable parameters
├── fork.sh                 ← Renderer: fork.yaml → workspace output
├── .gitignore              ← Excludes out/, .env, logs, node_modules
├── AGENTS.md               ← Task router + model stack (verbatim, generic)
├── TOOLS.md                ← Local notes template (generic)
├── HEARTBEAT.md            ← Health check routines (IPs parametrized)
├── SOUL.md.tmpl            ← Assistant persona template
├── USER.md.tmpl            ← Operator profile template
├── IDENTITY.md.tmpl        ← Assistant identity template
├── MEMORY.md.tmpl          ← Memory index template (generic lessons only)
└── references/
    └── TOOLS.md            ← Model stack reference (generic)
```
