# FORK_STRATEGY.md — How OpenClaw Forks Work

## The 3-Bucket Model

Every file in a source OpenClaw workspace falls into exactly one bucket:

| Bucket | Definition | Action |
|--------|-----------|--------|
| **CARRY** | Generic operational patterns, frameworks, lessons — valuable regardless of operator or project | Copy verbatim (or near-verbatim) into fork-template |
| **STRIP** | App-specific state, personal details, project data, credentials, cron jobs — zero value and active contamination risk for a new operator | Delete entirely; do NOT include in fork-template |
| **PARAMETRIZE** | Structural scaffolds that must exist but contain operator-specific values (name, domain, timezone, persona, etc.) | Convert to `*.tmpl` with `{{placeholder}}` syntax; rendered by fork.sh at fork time |

---

## File-Level Decisions (Source: Richard's workspace)

### CARRY (verbatim or near-verbatim)
| File | Bucket | Notes |
|------|--------|-------|
| `AGENTS.md` | CARRY | Task router, model stack, red lines — fully generic. One substitution: "context about Chris" → "context about the operator" to pass sanity checks. |
| `TOOLS.md` | CARRY | The generic "what goes here" template section is fully reusable. Chris's specific device/SSH entries were already in an Examples block — kept as illustrative examples only. |
| `references/TOOLS.md` | CARRY (scrubbed) | Model stack is generic. Removed hardcoded IPs and personal handles; replaced with `{{placeholders}}`. |

### PARAMETRIZE (converted to templates)
| File | Bucket | Placeholders |
|------|--------|-------------|
| `SOUL.md` → `SOUL.md.tmpl` | PARAMETRIZE | `{{assistant_name}}`, `{{assistant_creature}}`, `{{operator_name}}`, `{{assistant_mission_oneliner}}` |
| `USER.md` → `USER.md.tmpl` | PARAMETRIZE | `{{operator_name}}`, `{{operator_timezone}}`, `{{operator_channel}}`, `{{operator_first_session}}`, `{{operator_background}}`, `{{operator_goals}}` |
| `IDENTITY.md` → `IDENTITY.md.tmpl` | PARAMETRIZE | `{{assistant_name}}`, `{{assistant_creature}}`, `{{assistant_vibe}}`, `{{assistant_emoji}}` |
| `MEMORY.md` → `MEMORY.md.tmpl` | PARAMETRIZE | Infrastructure section uses `{{infra_*}}`, `{{git_*}}`, `{{email_*}}`, `{{backup_*}}` placeholders. Key Lessons carried (generic). Active Projects section empty. |
| `HEARTBEAT.md` | PARAMETRIZE | Removed hardcoded Tailscale IP (`100.91.112.22`) and Mission Control URL; replaced with `{{infra_service_health_url}}`. Removed `journal/2026/` hardcoded year. |

### STRIP (not included in fork-template)
| Item | Reason |
|------|--------|
| Active Projects (MQRI, Athena, Ship Pipeline, Venture Engine, ChatCommerce, Agentmon) | Operator-specific. No value and active contamination for a new operator. |
| Mission Control URL + EC2 IPs | Infrastructure-specific to Richard's instance. |
| Execution Roadmap | Operator-specific milestones. |
| Best Practices (GTM closed-loop section) | Contains operator-specific policy with references to specific projects. |
| Infrastructure section details (richpf, rich20260330, specific IPs, Fly.io org, B2 bucket name) | All operator-specific credentials and handles. |
| `journal/` directory | Personal session logs — private to operator. |
| `memory/*.md` daily notes | Session-specific raw logs. |
| `references/MEMORY-archive.md` | Full historical memory — operator-specific. |
| `references/TASKS.md` | Legacy task list — operator-specific. |
| `references/Prior_Inventions_Disclosure.md` | Personally sensitive document. |
| `scripts/` directory | Contains operator-specific automation (newsletter cron prompts, etc.). |
| `pipelines/`, `workstreams/`, `specs/`, `designs/`, `research/` | Project-specific artifacts. |
| `mqri-docs/` | Project-specific. |
| `projects/` symlinks/refs | Operator-specific project directories. |
| Cron jobs | Operator-specific — must be configured fresh (newsletters, git sync schedule). |
| Telegram bot token | Per-fork secret — must be a new bot registered with BotFather. |
| GitHub handle (richpf) | Personal. New fork needs its own GitHub account/repos. |
| Gmail address (rich20260330) | Personal. New fork needs its own Gmail with app password. |
| Fly.io org and apps | Operator-specific cloud resources. |
| Backup B2 bucket | Operator-specific. |

---

## Architecture Note: What We're Carrying vs. the 14-Agent Runbook

The runbook at `/tmp/openclaw-setup/OpenClaw_Complete_Runbook_v2.md` describes a
14-agent "Mission Control" architecture with multiple specialized Lightsail instances,
EC2 for persistent apps, and a complex orchestration layer.

**We are NOT replicating that architecture here.**

This fork template carries Richard's **chief-of-staff + skill-stack** pattern:
- Single Lightsail instance (openclaw-orchestrator)
- OpenClaw gateway running there
- Claude Code for development tasks
- Skills (coding-agent, gh-issues, weather, etc.) as the capability layer
- Operator-facing via Telegram (or chosen channel)

The 14-agent architecture is a potential Phase 4+ evolution. Phase 1 (this template)
gives a new operator the same foundational patterns that make Richard effective,
without the complexity they haven't earned yet.

---

## Human Decision Points (Cannot Be Scripted)

These must be answered by the person creating a fork — they are inherently human choices:

1. **Who is the operator?** Name, background, goals, timezone, channel preference.
2. **What is the assistant's persona?** Name, vibe/creature description, emoji, mission statement.
3. **What domain?** Must be registered before provisioning. DNS must be configured post-provision.
4. **What Telegram bot?** Create a new bot via @BotFather. Get the token. Get the operator's Telegram ID.
5. **What GitHub account?** Create private repos for workspace + journal. Set up SSH deploy keys.
6. **What Gmail?** Create a new Gmail account for this fork. Generate an app password.
7. **Shared or separate LLM keys?** Set `llm_keys.shared_from_parent` accordingly.
8. **What Backblaze B2 bucket?** Create it, set up application keys.
9. **What Lightsail plan?** Depends on operator's expected workload.

---

## DO NOT Carry (Explicit Blocklist)

The following must NEVER appear in fork-template content:
- Project names: MQRI, Athena, Ship Pipeline, Venture Engine, ChatCommerce, Agentmon
- Personal names: the original operator's real name (only `{{operator_name}}` placeholder)
- GitHub handles from the source instance
- Gmail addresses from the source instance
- API keys or tokens of any kind
- Telegram bot tokens
- Domain names from the source instance
- Fly.io app names or org names
- Hardcoded IP addresses (Tailscale, EC2, Lightsail)
- Cron job definitions (newsletter schedules, git sync, backup schedules)
- Session journals or daily memory logs
- Backup bucket names from the source instance
- Any `richpf`/`rich*` identifiers
