# fork-bootstrap — First-Boot Onboarding Skill

An AgentSkill that runs a conversational Telegram interview on the first boot
of a freshly forked OpenClaw instance, collecting operator identity, assistant
persona, mission, comms preferences, and external accounts. All answers are
written in-place into the workspace files.

---

## How It Triggers

On startup (or on any inbound message), the assistant checks:

1. Is `~/.openclaw/workspace/.bootstrap-complete` absent?
2. Do `SOUL.md`, `USER.md`, or `IDENTITY.md` contain any `{{placeholder}}` tokens?

If **either** condition is true, the assistant reads `SKILL.md` → `interview.md`
and begins the onboarding interview.

If **neither** condition is true, this skill is completely inert.

---

## What the Interview Covers

| Group | Topics |
|-------|--------|
| Operator identity | Name, timezone, professional background, top 3 goals |
| Assistant persona | Name, creature description, vibe keywords, emoji avatar |
| Mission | One-sentence north star |
| Comms preferences | Formality, emoji usage, proactivity level, escalation policy |
| Scope boundaries | Off-limits topics/actions, approval style |
| External accounts | GitHub handle, outbound email, preferred domain |

The operator's Telegram ID is auto-detected from the first message.

The full interview takes approximately **5 minutes** over Telegram.

---

## What Happens After

See `post_interview.md` for the full rendering sequence. Summary:

1. All answers written into `SOUL.md`, `USER.md`, `IDENTITY.md`, `MEMORY.md` in-place.
2. Sentinel file `~/.openclaw/workspace/.bootstrap-complete` created.
3. Bootstrap entry appended to `MEMORY.md`.
4. First `journal/YYYY/MM/YYYY-MM-DD.md` entry created.
5. Summary message sent: *"Here's what I know about you — ready to begin?"*

---

## How Bootstrap Is Disabled After First Run

The sentinel file `~/.openclaw/workspace/.bootstrap-complete` acts as a one-way
gate. Once it exists and no `{{placeholders}}` remain in persona files, the skill
will not activate — even across restarts, re-deployments, or gateway restarts.

The sentinel is a plain text file containing the UTC timestamp of when onboarding
completed:

```
2026-04-24T19:33:00.000Z
```

---

## Re-Running the Interview

To start the interview over on an already-bootstrapped instance:

```bash
rm ~/.openclaw/workspace/.bootstrap-complete
```

Then restart OpenClaw (or send any message to the bot). The assistant will detect
the missing sentinel and restart the interview from Q1.1.

**Warning:** Re-running the interview will overwrite the existing persona files.
Back up `SOUL.md`, `USER.md`, and `IDENTITY.md` first if you want to preserve
the current configuration.

---

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Trigger conditions and skill overview (read by assistant) |
| `interview.md` | Full interview script — questions, validation, variable names |
| `write_plan.md` | Mapping table: variable → target file + placeholder |
| `post_interview.md` | Post-interview rendering sequence (Python pseudocode) |
| `README.md` | This file — human documentation |

---

## Notes for Deployers

- This skill is included in every fork bundle by `fork.sh`. No manual installation needed.
- If you pre-fill `seed_from_yaml:` in `fork.yaml`, those fields are already rendered
  at fork time, and the corresponding interview questions are skipped (the placeholder
  tokens won't be present to trigger them).
- The skill assumes Telegram as the comms channel. For other channels (Discord, Slack),
  the interview logic is the same but the message delivery mechanism differs.
