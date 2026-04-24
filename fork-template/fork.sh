#!/usr/bin/env bash
# fork.sh — Render an OpenClaw workspace for a new operator from fork.yaml
#
# Usage:
#   ./fork.sh <path-to-fork.yaml> [--out <output-dir>]
#   ./fork.sh -h
#
# Rendering approach: small Python helper (render.py, generated inline).
#   Why Python over envsubst?  fork.yaml is YAML with nested keys (e.g.
#   operator.name, infra.domain).  envsubst only handles flat $VAR-style
#   substitutions, which would require flattening + exporting dozens of env
#   vars.  Python's built-in `str.format_map` on a flat key-value dict is
#   simpler, safer, and keeps the template syntax as {{key}} (Jinja-like,
#   readable, no collision with shell variables).
#
# Requirements: bash, python3, pyyaml (pip install pyyaml — standard on most
#   systems; script checks and gives install hint if missing).
#
set -euo pipefail

# ─── Help ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
OpenClaw Fork Template Renderer

USAGE
  ./fork.sh <fork.yaml> [--out <dir>]
  ./fork.sh -h

ARGUMENTS
  <fork.yaml>     Path to a filled-in fork.yaml (copy of fork.yaml.example)
  --out <dir>     Output directory (default: ./out/<operator-slug>-workspace)
  -h              Show this help

DESCRIPTION
  Renders every *.tmpl file in the fork-template/ directory into the output
  directory with {{placeholders}} substituted from fork.yaml values.
  Non-template files are copied as-is.
  Also produces .env.example and NEXT_STEPS.md in the output directory.

EXAMPLE
  cp fork.yaml.example fork.yaml
  # Edit fork.yaml with real values
  ./fork.sh fork.yaml
  # Output at ./out/<operator-slug>-workspace/
EOF
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

# ─── Args ─────────────────────────────────────────────────────────────────────
YAML_FILE="${1:-}"
OUT_DIR=""
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$YAML_FILE" ]]; then
  echo "ERROR: No fork.yaml path provided. Run './fork.sh -h' for usage." >&2
  exit 1
fi

if [[ ! -f "$YAML_FILE" ]]; then
  echo "ERROR: File not found: $YAML_FILE" >&2
  exit 1
fi

# ─── Check python3 + yaml ─────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required but not found." >&2
  exit 1
fi

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "ERROR: PyYAML not found. Install with: pip install pyyaml  (or: pip3 install pyyaml)" >&2
  exit 1
fi

# ─── Locate template directory ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Validate required fields + compute output path ───────────────────────────
echo "→ Validating fork.yaml..."
OPERATOR_SLUG=$(python3 - "$YAML_FILE" <<'PYEOF'
import sys, yaml, re

with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)

required = [
    # operator.* and assistant.* are now OPTIONAL — collected by first-boot
    # interview if absent. Only infra/git/email/telegram/backup are required.
    ("infra", "aws_region"),
    ("infra", "lightsail_plan"),
    ("infra", "domain"),
    ("infra", "certbot_email"),
    ("git", "github_handle"),
    ("git", "workspace_remote"),
    ("git", "journal_remote"),
    ("email", "gmail_address"),
    ("telegram", "bot_token_env"),
    # telegram.operator_id is OPTIONAL -- auto-detected at first boot from Telegram message
    ("backup", "restic_b2_bucket"),
    ("backup", "restic_password_env"),
]

missing = []
for section, key in required:
    val = cfg.get(section, {}).get(key, "")
    if not val:
        missing.append(f"{section}.{key}")

if missing:
    print(f"ERROR: Missing required fields in fork.yaml:", file=sys.stderr)
    for m in missing:
        print(f"  - {m}", file=sys.stderr)
    sys.exit(1)

# Produce operator slug:
# Prefer seed_from_yaml.operator.name, then operator.name, then domain, then "fork"
seed = cfg.get("seed_from_yaml", {}) or {}
op_name = (seed.get("operator", {}) or {}).get("name", "") or \
          (cfg.get("operator", {}) or {}).get("name", "")
if op_name:
    slug = re.sub(r'[^a-z0-9-]', '', op_name.lower().replace(" ", "-"))
else:
    # Fall back to domain (e.g. "example2.com" -> "example2")
    domain = (cfg.get("infra", {}) or {}).get("domain", "fork")
    slug = re.sub(r'[^a-z0-9-]', '', domain.split(".")[0].lower())
    if not slug:
        slug = "fork"
print(slug)
PYEOF
)

if [[ -z "$OPERATOR_SLUG" ]]; then
  echo "ERROR: Could not compute operator slug from fork.yaml" >&2
  exit 1
fi

echo "   Operator slug: $OPERATOR_SLUG"

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$SCRIPT_DIR/out/${OPERATOR_SLUG}-workspace"
fi

echo "→ Output directory: $OUT_DIR"
mkdir -p "$OUT_DIR"
mkdir -p "$OUT_DIR/references"

# ─── Render templates + copy static files ────────────────────────────────────
echo "→ Rendering templates..."
python3 - "$YAML_FILE" "$SCRIPT_DIR" "$OUT_DIR" "$OPERATOR_SLUG" <<'PYEOF'
import sys, yaml, re, shutil
from pathlib import Path

yaml_path = sys.argv[1]
src_dir   = Path(sys.argv[2])
out_dir   = Path(sys.argv[3])
slug      = sys.argv[4]

with open(yaml_path) as f:
    cfg = yaml.safe_load(f)

# Flatten nested YAML into dot-notation keys, also expose underscore variants
def flatten(d, prefix=""):
    result = {}
    for k, v in d.items():
        full_key = f"{prefix}{k}" if prefix else k
        if isinstance(v, dict):
            result.update(flatten(v, full_key + "_"))
            result.update(flatten(v, full_key + "."))
        elif isinstance(v, list):
            result[full_key] = "\n".join(f"- {item}" for item in v) if v else ""
        elif v is None:
            result[full_key] = ""
        else:
            result[full_key] = str(v)
    return result

flat = flatten(cfg)
flat["operator_slug"] = slug

# Merge seed_from_yaml into flat (operator.*/assistant.* overrides if present)
# This allows fork.yaml to pre-seed persona values and short-circuit interview.
if "seed_from_yaml" in cfg and isinstance(cfg["seed_from_yaml"], dict):
    seed = flatten(cfg["seed_from_yaml"])
    # Remap seed keys: seed_from_yaml.operator.name → operator_name
    flat.update(seed)

# Custom formatter: {{key}} substitution (tolerant of missing keys → leave as-is)
class SafeDict(dict):
    def __missing__(self, key):
        return f"{{{{{key}}}}}"  # leave unresolved placeholders intact

def render(text):
    # Replace {{key}} with values; handle both dot and underscore variants
    def replacer(m):
        key = m.group(1)
        return flat.get(key, flat.get(key.replace(".", "_"), f"{{{{{key}}}}}"))
    return re.sub(r'\{\{([^}]+)\}\}', replacer, text)

# Walk the src template dir
template_dir = src_dir  # templates live alongside fork.sh
# Top-level files/dirs to skip (only matched against first path component
# so nested files like skills/fork-bootstrap/README.md are not affected)
SKIP_TOPLEVEL = {".git", "out", "__pycache__", "fork.sh", "fork.yaml.example",
                  "fork.yaml", "FORK_STRATEGY.md", "README.md", "render.py"}

for src_file in sorted(template_dir.rglob("*")):
    if src_file.is_dir():
        continue
    rel = src_file.relative_to(template_dir)
    # Skip if the TOP-LEVEL component matches (preserves nested READMEs etc.)
    if rel.parts[0] in SKIP_TOPLEVEL:
        continue
    if src_file.name.startswith(".git"):
        continue

    dest_name = rel.name
    dest_rel  = rel.parent / dest_name

    # Strip .tmpl suffix from output filename
    if dest_name.endswith(".tmpl"):
        dest_name = dest_name[:-5]
        dest_rel  = rel.parent / dest_name

    dest_file = out_dir / rel.parent / dest_name
    dest_file.parent.mkdir(parents=True, exist_ok=True)

    if src_file.name.endswith(".tmpl"):
        # Render template
        text = src_file.read_text()
        rendered = render(text)
        dest_file.write_text(rendered)
        print(f"   rendered  {dest_rel}")
    else:
        # Copy as-is (skip fork.sh itself and example yaml)
        shutil.copy2(src_file, dest_file)
        print(f"   copied    {dest_rel}")

PYEOF

# ─── Produce .env.example ────────────────────────────────────────────────────
echo "→ Generating .env.example..."
BOT_TOKEN_ENV=$(python3 -c "
import yaml, sys
with open('$YAML_FILE') as f: c = yaml.safe_load(f)
print(c.get('telegram', {}).get('bot_token_env', 'TELEGRAM_BOT_TOKEN'))
")
RESTIC_ENV=$(python3 -c "
import yaml, sys
with open('$YAML_FILE') as f: c = yaml.safe_load(f)
print(c.get('backup', {}).get('restic_password_env', 'RESTIC_PASSWORD'))
")

cat > "$OUT_DIR/.env.example" <<ENV
# .env.example — Environment variables for this OpenClaw fork
# Copy to .env and fill in real values. NEVER commit .env to git.

# ── LLM API Keys ───────────────────────────────────────────────────────────
ANTHROPIC_API_KEY=sk-ant-...
OPENROUTER_API_KEY=sk-or-...
OPENAI_API_KEY=sk-...
MINIMAX_API_KEY=...
TAVILY_API_KEY=tvly-...

# ── OpenClaw Gateway ────────────────────────────────────────────────────────
GATEWAY_AUTH_TOKEN=<generate-with-openssl-rand-hex-32>

# ── Telegram ────────────────────────────────────────────────────────────────
${BOT_TOKEN_ENV}=<your-telegram-bot-token-from-botfather>

# ── Backup (Restic + Backblaze B2) ──────────────────────────────────────────
${RESTIC_ENV}=<strong-random-passphrase>
B2_ACCOUNT_ID=<backblaze-account-id>
B2_ACCOUNT_KEY=<backblaze-application-key>

# ── Git Sync (SSH) ──────────────────────────────────────────────────────────
# Ensure ~/.ssh/id_ed25519 (or equivalent) is deployed to the Lightsail instance
# and added to GitHub deploy keys for workspace + journal repos.
ENV
echo "   written: .env.example"

# ─── Produce NEXT_STEPS.md ───────────────────────────────────────────────────
echo "→ Generating NEXT_STEPS.md..."
DOMAIN=$(python3 -c "
import yaml
with open('$YAML_FILE') as f: c = yaml.safe_load(f)
print(c.get('infra', {}).get('domain', 'example.com'))
")
REGION=$(python3 -c "
import yaml
with open('$YAML_FILE') as f: c = yaml.safe_load(f)
print(c.get('infra', {}).get('aws_region', 'us-east-1'))
")
PLAN=$(python3 -c "
import yaml
with open('$YAML_FILE') as f: c = yaml.safe_load(f)
print(c.get('infra', {}).get('lightsail_plan', 'medium_2_0'))
")

cat > "$OUT_DIR/NEXT_STEPS.md" <<NEXT
# NEXT_STEPS.md — Deploying This Workspace to Lightsail

Generated by fork.sh from fork.yaml. Follow these steps after rendering.

---

## 1. Provision Lightsail Instance (Phase 2 — not yet scripted)
- Region: **$REGION**
- Plan: **$PLAN**
- OS: Ubuntu 22.04 LTS
- Attach a static IP; note it as \`infra.public_static_ip\` in fork.yaml.
- Open ports: 22 (SSH), 80 (HTTP), 443 (HTTPS), 3000 (OpenClaw gateway).

## 2. Set Up Tailscale
- Install Tailscale on the instance.
- Join the existing Tailnet (or create a new one).
- Note the 100.x.x.x address as \`infra.tailscale_ip\` in fork.yaml.

## 3. Configure DNS
- Point \`$DOMAIN\` A record → static IP from step 1.
- Verify with: \`dig $DOMAIN +short\`

## 4. Package and Upload This Workspace
\`\`\`bash
# From inside the output directory ($(basename "$OUT_DIR")):
tar -czf workspace.tar.gz --exclude='.env' --exclude='*.log' .

# Upload to instance (replace INSTANCE_IP):
scp workspace.tar.gz ubuntu@INSTANCE_IP:/tmp/

# On the instance:
ssh ubuntu@INSTANCE_IP
mkdir -p ~/.openclaw/workspace
cd ~/.openclaw/workspace
tar -xzf /tmp/workspace.tar.gz
\`\`\`

## 5. Install OpenClaw (Phase 3 — not yet scripted)
- Follow the OpenClaw installation runbook for the target instance.
- Supply environment variables from \`.env.example\` → \`.env\`.
- Run: \`openclaw gateway start\`

## 6. Configure Git Sync
- Add SSH deploy key to GitHub repos (workspace + journal).
- Run initial push: \`git -C ~/.openclaw/workspace push -u origin main\`

## 7. Configure Telegram Bot
- Set \`${BOT_TOKEN_ENV}\` in the instance's \`.env\`.
- Test: message the bot and confirm it responds.

## 8. Configure Restic Backup
- Set B2 credentials and \`${RESTIC_ENV}\` in \`.env\`.
- Run: \`restic -r b2:BUCKET init\`
- Test: \`restic -r b2:BUCKET backup ~/.openclaw/workspace\`

---

_Phase 2 (Lightsail provisioner) and Phase 3 (OpenClaw installer) will automate steps 1-5._
NEXT
echo "   written: NEXT_STEPS.md"

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "✅ Fork workspace rendered successfully!"
echo ""
echo "   Output: $OUT_DIR"
echo "   Files:  $(find "$OUT_DIR" -type f | wc -l) files"
echo ""
echo "Next: review $OUT_DIR/NEXT_STEPS.md for deployment instructions."
