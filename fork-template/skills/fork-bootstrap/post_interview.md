# post_interview.md — Post-Interview Processing

After the operator answers the final question (Q6.3 or Q6.1 if Q6.2-Q6.3 are
skipped as "none"), run the following steps in order. Do NOT send the summary
message until all steps are complete.

---

## Step 0: Collect Auto-Detected Values

Before rendering, ensure these values are set (they don't come from questions):

```python
import datetime, os

answers["operator_first_session"] = datetime.date.today().isoformat()
answers["operator_channel"]       = "telegram"
# telegram_operator_id already collected from message context
```

---

## Step 1: Render Placeholders into Workspace Files

Use Python `re.sub` to replace `{{key}}` tokens in the target files.

```python
import re, os

WORKSPACE = os.path.expanduser("~/.openclaw/workspace")

# Files that contain {{placeholders}} from the identity/persona groups
TARGET_FILES = {
    "USER.md":     ["operator_name", "operator_timezone", "operator_channel",
                    "operator_first_session", "operator_background", "operator_goals"],
    "SOUL.md":     ["operator_name", "assistant_name", "assistant_creature",
                    "assistant_mission_oneliner"],
    "IDENTITY.md": ["assistant_name", "assistant_creature", "assistant_vibe",
                    "assistant_emoji"],
    "MEMORY.md":   ["git_github_handle", "email_gmail_address", "infra_domain"],
}

def replace_placeholders(text, answers):
    def replacer(m):
        key = m.group(1)
        return answers.get(key, f"{{{{{key}}}}}")  # leave unresolved if missing
    return re.sub(r'\{\{([^}]+)\}\}', replacer, text)

for filename, keys in TARGET_FILES.items():
    path = os.path.join(WORKSPACE, filename)
    if not os.path.exists(path):
        continue
    with open(path) as f:
        content = f.read()
    rendered = replace_placeholders(content, answers)
    with open(path, "w") as f:
        f.write(rendered)
    print(f"  ✓ Rendered {filename}")
```

### Comms & Scope Preferences (SOUL.md section updates)

These answers don't replace tokens — they are appended to the Personality
and Boundaries sections of SOUL.md:

```python
soul_path = os.path.join(WORKSPACE, "SOUL.md")
with open(soul_path) as f:
    soul = f.read()

# Append comms preferences to Personality section
comms_bullets = []
if answers.get("comms_formality"):
    comms_bullets.append(f"- **Formality:** {answers['comms_formality']}")
if answers.get("comms_emoji"):
    comms_bullets.append(f"- **Emoji usage:** {answers['comms_emoji']}")
if answers.get("comms_proactivity"):
    comms_bullets.append(f"- **Proactivity:** {answers['comms_proactivity']}")

if comms_bullets:
    soul = re.sub(
        r'(## Personality\n)',
        r'\1' + "\n".join(comms_bullets) + "\n",
        soul
    )

# Append scope boundaries to Boundaries section
scope_bullets = []
if answers.get("comms_escalation_policy") and answers["comms_escalation_policy"].lower() != "default":
    scope_bullets.append(f"- **Escalation policy:** {answers['comms_escalation_policy']}")
if answers.get("scope_approval_style"):
    scope_bullets.append(f"- **Approval style:** {answers['scope_approval_style']}")
if answers.get("scope_off_limits") and answers["scope_off_limits"].lower() not in ("none", ""):
    scope_bullets.append(f"- **Off-limits:** {answers['scope_off_limits']}")

if scope_bullets:
    soul = re.sub(
        r'(## Boundaries\n)',
        r'\1' + "\n".join(scope_bullets) + "\n",
        soul
    )

with open(soul_path, "w") as f:
    f.write(soul)
print("  ✓ Updated SOUL.md with comms/scope preferences")
```

### Telegram ID annotation in USER.md

```python
user_path = os.path.join(WORKSPACE, "USER.md")
with open(user_path) as f:
    user = f.read()

telegram_id = answers.get("telegram_operator_id", "unknown")
annotation = f"\n<!-- telegram_operator_id: {telegram_id} -->\n"
if "telegram_operator_id" not in user:
    with open(user_path, "a") as f:
        f.write(annotation)
print("  ✓ Annotated USER.md with Telegram operator ID")
```

---

## Step 2: Create Bootstrap Sentinel

```python
sentinel = os.path.join(WORKSPACE, ".bootstrap-complete")
with open(sentinel, "w") as f:
    f.write(datetime.datetime.utcnow().isoformat() + "\n")
print("  ✓ Created .bootstrap-complete sentinel")
```

---

## Step 3: Write Welcome MEMORY.md Entry

Append a dated onboarding summary to the `Active Projects` section of MEMORY.md
(or prepend if that section is empty). Do NOT overwrite existing content.

```python
memory_path = os.path.join(WORKSPACE, "MEMORY.md")
today = datetime.date.today().isoformat()

bootstrap_entry = f"""
## Bootstrap Log

- **Onboarding completed:** {today}
- **Operator:** {answers.get('operator_name', 'unknown')}
- **Assistant persona:** {answers.get('assistant_name', 'unknown')} — {answers.get('assistant_creature', '')}
- **Mission:** {answers.get('assistant_mission_oneliner', '')}
- **Comms:** formality={answers.get('comms_formality', 'balanced')}, emoji={answers.get('comms_emoji', 'normal')}, proactivity={answers.get('comms_proactivity', 'balanced')}
"""

with open(memory_path) as f:
    memory = f.read()

if "## Bootstrap Log" not in memory:
    memory = memory + "\n" + bootstrap_entry
    with open(memory_path, "w") as f:
        f.write(memory)
    print("  ✓ Wrote Bootstrap Log to MEMORY.md")
```

---

## Step 4: Initialize First Journal Entry

```python
import pathlib

today = datetime.date.today()
year  = today.strftime("%Y")
month = today.strftime("%m")
datestr = today.isoformat()

journal_dir = pathlib.Path(WORKSPACE) / "journal" / year / month
journal_dir.mkdir(parents=True, exist_ok=True)
journal_file = journal_dir / f"{datestr}.md"

if not journal_file.exists():
    journal_content = f"""# Journal — {datestr}

## Bootstrap Session

**Operator:** {answers.get('operator_name', 'unknown')}
**Assistant:** {answers.get('assistant_name', 'unknown')} ({answers.get('assistant_emoji', '')})
**Mission:** {answers.get('assistant_mission_oneliner', '')}

### What I Learned About the Operator

{answers.get('operator_background', '(no background provided)')}

### Goals

{answers.get('operator_goals', '(none listed)')}

### Decisions Made

- Assistant persona selected and written to SOUL.md, IDENTITY.md
- Comms preferences configured in SOUL.md
- Bootstrap sentinel created at .bootstrap-complete
- First journal entry initialized

---
"""
    journal_file.write_text(journal_content)
    print(f"  ✓ Created first journal entry: {journal_file}")
```

---

## Step 5: Post Summary to Operator

Build and send this message (via the normal assistant reply channel):

```
✅ Setup complete. Here's what I know about you:

**You:** {operator_name}, {operator_timezone}
**Background:** {operator_background_short}  ← first sentence only
**Goals:**
{operator_goals_formatted}

**Me:** I'm {assistant_name} — {assistant_creature} {assistant_emoji}
**Mission:** {assistant_mission_oneliner}
**My style:** {comms_formality} tone, {comms_emoji} emoji, {comms_proactivity} on proactivity.

I'm ready to work. What's the first thing you want to tackle?
```

Where:
- `operator_background_short` = first sentence of `operator_background` (split on `. `)
- `operator_goals_formatted` = bulleted list from `operator_goals`
- All fields pulled from the `answers` dict

After sending this message, the skill is complete. Normal operation begins.

---

## Error Handling

If any file write fails:
1. Log the error to the console (do not silently swallow).
2. Do NOT create the sentinel file — let the interview retry on next boot.
3. Tell the operator: "I hit a snag setting up — try restarting the bot and
   messaging me again. Your answers are saved and I'll pick up where we left off."
   (Note: answer persistence across restarts is not currently implemented;
   the interview will restart from Q1.1. Track this as a known limitation.)
