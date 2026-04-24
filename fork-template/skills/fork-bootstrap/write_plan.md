# write_plan.md — Interview Answer → File Mapping

Full mapping table: each interview question → which file(s) and which
placeholder(s) it resolves. After the interview, use this table to
drive the rendering step in `post_interview.md`.

---

## Mapping Table

| Question ID | Variable | Target File(s) | Placeholder(s) Replaced |
|-------------|----------|----------------|------------------------|
| Q1.1 | `operator_name` | `USER.md`, `SOUL.md` | `{{operator_name}}` (all occurrences) |
| Q1.2 | `operator_timezone` | `USER.md` | `{{operator_timezone}}` |
| Q1.3 | `operator_background` | `USER.md` | `{{operator_background}}` |
| Q1.4 | `operator_goals` | `USER.md` | `{{operator_goals}}` |
| Q2.1 | `assistant_name` | `SOUL.md`, `IDENTITY.md` | `{{assistant_name}}` (all occurrences) |
| Q2.2 | `assistant_creature` | `SOUL.md`, `IDENTITY.md` | `{{assistant_creature}}` (all occurrences) |
| Q2.3 | `assistant_vibe` | `IDENTITY.md` | `{{assistant_vibe}}` |
| Q2.4 | `assistant_emoji` | `IDENTITY.md` | `{{assistant_emoji}}` |
| Q3.1 | `assistant_mission_oneliner` | `SOUL.md` | `{{assistant_mission_oneliner}}` |
| Q4.1 | `comms_formality` | `SOUL.md` | Append to Personality section |
| Q4.2 | `comms_emoji` | `SOUL.md` | Append to Personality section |
| Q4.3 | `comms_proactivity` | `SOUL.md` | Refine Operating Principles bullet 1 |
| Q4.4 | `comms_escalation_policy` | `SOUL.md` | Augment Boundaries section |
| Q5.1 | `scope_off_limits` | `SOUL.md` | Append to Boundaries section (if non-empty / non-"none") |
| Q5.2 | `scope_approval_style` | `SOUL.md` | Add approval style note to Boundaries section |
| Q6.1 | `ext_github_handle` | `MEMORY.md` | `{{git_github_handle}}` |
| Q6.2 | `ext_email` | `MEMORY.md` | `{{email_gmail_address}}` |
| Q6.3 | `ext_domain` | `MEMORY.md` | `{{infra_domain}}` |
| Q6.4 (auto) | `telegram_operator_id` | `USER.md` | Append to metadata comment block |
| (auto) | `operator_first_session` | `USER.md` | `{{operator_first_session}}` ← set to today's date (YYYY-MM-DD) |
| (auto) | `operator_channel` | `USER.md` | `{{operator_channel}}` ← "telegram" (hardcoded for Telegram forks) |

---

## Notes

### Placeholders not covered by interview

These placeholders remain unresolved until infra is set up. Leave them in place
or replace with a sensible default:

| Placeholder | Source | Default |
|-------------|--------|---------|
| `{{infra_public_static_ip}}` | Provisioned in Phase 2 | _(blank)_ |
| `{{infra_tailscale_ip}}` | Set up post-deployment | _(blank)_ |
| `{{infra_service_health_url}}` | Optional | _(blank)_ |
| `{{git_workspace_remote}}` | Set in fork.yaml infra | _(blank)_ |
| `{{git_journal_remote}}` | Set in fork.yaml infra | _(blank)_ |
| `{{backup_restic_b2_bucket}}` | Set in fork.yaml backup | _(blank)_ |

These are infra-tier values that come from the fork provisioner (fork.yaml
`infra`, `git`, `backup` sections), not from the operator interview.

### Comms preference fields (Q4.1–Q4.4, Q5.1–Q5.2)

These don't replace `{{placeholders}}` — they are added to SOUL.md as
structured text in the appropriate sections. The post_interview script
does a regex-based section update (not a simple string replace).

### Goals formatting

`operator_goals` should be rendered as a bulleted Markdown list:
```
- Goal one
- Goal two
- Goal three
```
If the operator wrote them as numbered list or prose, normalize to bullets.

### operator_first_session

Always set automatically to today's ISO date (`date +%Y-%m-%d`) — never ask
the operator for this.

### telegram_operator_id

Extracted from the Telegram `message.from.id` field in the update that started
the interview. Log it to the USER.md metadata comment block for reference:
```markdown
<!-- telegram_operator_id: 123456789 -->
```
