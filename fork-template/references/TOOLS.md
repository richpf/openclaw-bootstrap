# TOOLS.md - Model Stack & Infrastructure

## Model Routing (cheapest viable wins)
| Tier | Model | Cost (in/out per M) | Use For |
|------|-------|-------------------|---------|
| Code | Claude Code (Max plan, free) | $0 | ALL coding — `ANTHROPIC_API_KEY= claude --permission-mode bypassPermissions --print` |
| Analysis | Qwen 3.6 Plus | $0.325/$1.95 (≤256k) | DEFAULT for execution: specs, scripts, docs, analysis (alias: qwen-large) |
| Analysis-XL | Qwen 3.5-397B | $0.39/$2.34 (flat) | Long-context >200k tokens (alias: qwen-long) |
| Explore | Qwen 3-235B | $0.455/$1.82 | Brainstorming, draft analysis (alias: qwen) |
| Structured | Minimax M1 | ~$0 | Formatting, extraction |
| Flagship | Opus 4.7 | $5/$25 | Conversation, judgment ONLY (effort=xhigh, adaptive thinking) |

**Key:** If writing >10 lines of content → delegate. >2 tool calls → spawn sub-agent.

## Code Fallback (if Claude Code OAuth down)
Minimax M1 (clear spec) → Sonnet API (complex/exploratory). Never API-Sonnet when OAuth works.

## API Keys
- OpenRouter: `OPENROUTER_API_KEY` env
- Anthropic: `ANTHROPIC_API_KEY` env
- Minimax: `MINIMAX_API_KEY` env, base `https://api.minimax.io/v1`
- Tavily: `TAVILY_API_KEY` env
- Qwen: set max_tokens ≥ 2000, include system prompt with date

## Infrastructure (fill after provisioning)
- Lightsail public IP: {{infra_public_static_ip}}
- Tailscale IP: {{infra_tailscale_ip}}
- Domain: {{infra_domain}}
- Git sync: every 6h, Restic backup: nightly 03:00 UTC
