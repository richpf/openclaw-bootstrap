# SKILL.md — fork-bootstrap

## Metadata
- **name:** fork-bootstrap
- **location:** skills/fork-bootstrap/SKILL.md

## Description

First-boot onboarding interview for a freshly forked OpenClaw instance. Guides
a new operator through identity, persona, mission, comms preferences, scope
boundaries, and external accounts via a conversational Telegram interview.
Writes all answers into the workspace files in place, then marks bootstrap
as complete.

**Trigger conditions (match ANY):**
1. The workspace file `SOUL.md`, `USER.md`, or `IDENTITY.md` still contains
   one or more `{{placeholder}}` tokens (i.e. fork.sh rendered them but the
   interview has not yet completed).
2. The sentinel file `~/.openclaw/workspace/.bootstrap-complete` is absent.

**DO NOT use this skill on instances where onboarding is already complete.**
If `.bootstrap-complete` exists and no `{{placeholder}}` tokens remain in the
persona files, this skill must not activate.

---

## When the Skill Activates

The main agent checks for bootstrap completeness on startup (or on any inbound
message to a fresh instance). The check is:

```bash
COMPLETE_FLAG="$HOME/.openclaw/workspace/.bootstrap-complete"
SOUL="$HOME/.openclaw/workspace/SOUL.md"
USER_FILE="$HOME/.openclaw/workspace/USER.md"
IDENTITY="$HOME/.openclaw/workspace/IDENTITY.md"

if [[ ! -f "$COMPLETE_FLAG" ]] || grep -qE '\{\{[^}]+\}\}' "$SOUL" "$USER_FILE" "$IDENTITY" 2>/dev/null; then
  # Bootstrap not complete → trigger this skill
fi
```

If triggered, read and follow `interview.md` (in this skill directory).

---

## After the Interview

Follow `post_interview.md` (in this skill directory) to:
1. Write all collected answers into workspace files.
2. Create the `.bootstrap-complete` sentinel.
3. Write a welcome MEMORY.md entry.
4. Initialize the first journal entry.
5. Post the "kit complete" summary to the operator.

---

## Re-running the Interview

To re-run onboarding on an already-bootstrapped instance:

```bash
rm ~/.openclaw/workspace/.bootstrap-complete
# Restart OpenClaw or send any message to the bot
```

The assistant will detect missing sentinel and restart the interview from step 1.

---

## Files in This Skill

| File | Purpose |
|------|---------|
| `SKILL.md` | This file — trigger conditions and overview |
| `interview.md` | Ordered interview questions with prompt text, validation, and target mappings |
| `write_plan.md` | Full mapping: question → file + placeholder |
| `post_interview.md` | Post-interview rendering, sentinel creation, memory + journal init |
| `README.md` | Human-facing documentation |
