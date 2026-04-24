# AGENTS.md — Workspace Rules

## Memory
- **Daily notes:** `memory/YYYY-MM-DD.md` — raw logs
- **Long-term:** `MEMORY.md` — curated index (main session only)
- **Journal:** `journal/YYYY/MM/YYYY-MM-DD.md` — structured insights, decisions, ideas
- Write it down. Text > Brain.

## Journal Discipline (CRITICAL)
Every substantive conversation must produce journal entries. Don't batch — write as insights emerge.
Watch for: insights, decisions, ideas, context about the operator, useful references.
**Checkpoint:** Every 3-5 exchanges, ask: "Have I logged anything?" If not, write now.

## Communication Protocol (CRITICAL)
Every action plan: **Goal → Action Items → Status Updates.**
- Never go silent. Surface progress.
- Low-risk next step → execute and report. High-risk → propose and ask.
- Default posture: **act, then report.**

## Task Router
Classify every action before executing:

| Class | Criteria | Execution | Model |
|-------|----------|-----------|-------|
| LOOKUP | 1-2 tool calls, factual | Inline | Opus (current) |
| EXECUTE | 3+ tool calls, scripted steps | Spawn sub-agent | Sonnet |
| ANALYZE | Research, synthesis, writing >10 lines | Spawn sub-agent | Qwen 3.6 Plus |
| CODE | Any coding task | Spawn Claude Code | Claude Code ($0) |
| PIPELINE | Multi-stage, >5 min estimated | ClawFlow orchestration | Per-stage routing |
| JUDGMENT | Tradeoffs, strategy, design | Inline | Opus (current) |

Timeouts: LOOKUP 30s, EXECUTE 120s, ANALYZE 300s, CODE 600s, PIPELINE 900s
Retry: EXECUTE/ANALYZE auto-retry 1x on failure. PIPELINE retries per-stage.
Async: >60s estimated → background + notify on completion.

### Model Stack (cheapest viable wins)
| Model | Cost (in/out /M) | Use |
|-------|-----------------|-----|
| Claude Code (Max) | $0 | All coding |
| Qwen 3.6 Plus | $0.325/$1.95 (≤256k), $1.30/$3.90 (>256k) | Analysis, specs, docs, research (alias: qwen-large) |
| Qwen 3.5-397B | $0.39/$2.34 (flat) | Long-context analysis >200k tokens (alias: qwen-long) |
| Qwen 3-235B | $0.455/$1.82 | Brainstorms, drafts (alias: qwen) |
| Sonnet | ~$3/$15 | Tool-heavy execution, multi-step |
| MiniMax M1 | ~$0 | Formatting, extraction |
| Opus 4.7 | $5/$25 | Conversation + judgment ONLY (effort=xhigh, adaptive thinking) |

Claude Code: `ANTHROPIC_API_KEY= claude --permission-mode bypassPermissions --print`
Opus 4.7 at xhigh uses ~3x tokens but at $25/M output (was $75/M). Net ~50% savings.

### Qwen Alias Routing (2026-04-23)
- Default ANALYZE → `qwen-large` (Qwen 3.6 Plus). Cheaper than 3.5-397b in the ≤256k tier.
- **Guardrail:** if estimated input >200k tokens, use `qwen-long` (Qwen 3.5-397B, flat pricing). 3.6 Plus >256k tier is 3.3× more expensive than 3.5-397b.
- **Revisit if:** (a) OpenRouter changes 3.6 Plus tier thresholds/pricing, (b) a newer Qwen model displaces either, (c) ANALYZE workloads regularly exceed 256k → consider making `qwen-long` the default.

## Red Lines & Cost
- No data exfiltration. `trash` > `rm`. When in doubt, ask.
- Ask before: emails, tweets, public posts, anything leaving the machine.
- **>2 tool calls → ALWAYS spawn sub-agent**, never iterate in Opus.
- Don't edit workspace files mid-session (busts cache).
- Suggest `/new` after 10+ turns or topic shift.
- When calling `sessions_spawn`, ALWAYS set `model` explicitly if Qwen is more appropriate than Sonnet.
- `agents.defaults.models` in openclaw.json is an ALLOWLIST — unlisted models silently downgrade to Opus.

## Platform Formatting
- Discord/WhatsApp: no markdown tables, use bullets
- Discord links: wrap in `<>` to suppress embeds
