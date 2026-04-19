#!/usr/bin/env bash
# =============================================================================
# restic-backup.sh — OpenClaw Restic Backup
# Backs up ~/.openclaw to a Restic repository (S3, B2, SFTP, or local).
#
# Setup:
#   1. Install restic:
#        sudo apt-get install restic
#
#   2. Configure your backup destination below (RESTIC_REPOSITORY)
#      and set the corresponding env vars.
#
#   3. Initialize the repo (first time only):
#        source ~/.openclaw/.backup-env
#        restic init
#
#   4. Enable with cron (run: crontab -e):
#        0 3 * * * ~/.openclaw/scripts/restic-backup.sh >> ~/.openclaw/logs/backup.log 2>&1
#
# Supported backends:
#   Local:  RESTIC_REPOSITORY=/mnt/backup/openclaw
#   S3:     RESTIC_REPOSITORY=s3:s3.amazonaws.com/your-bucket/openclaw
#   B2:     RESTIC_REPOSITORY=b2:your-bucket:openclaw
#   SFTP:   RESTIC_REPOSITORY=sftp:user@host:/path/to/backup
#
# Docs: https://restic.readthedocs.io/
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
BACKUP_SOURCE="${HOME}/.openclaw"
BACKUP_ENV_FILE="${HOME}/.openclaw/.backup-env"
LOG_PREFIX="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] restic-backup:"

# Retention policy
KEEP_DAILY=7      # Keep last 7 daily backups
KEEP_WEEKLY=4     # Keep last 4 weekly backups
KEEP_MONTHLY=3    # Keep last 3 monthly backups

# ── Logging ───────────────────────────────────────────────────────────────────
log()  { echo "${LOG_PREFIX} $*"; }
err()  { echo "${LOG_PREFIX} ERROR: $*" >&2; }

# ── Load environment ──────────────────────────────────────────────────────────
if [[ ! -f "$BACKUP_ENV_FILE" ]]; then
  err "Backup env file not found: ${BACKUP_ENV_FILE}"
  err "Create it with your RESTIC_REPOSITORY and RESTIC_PASSWORD."
  err ""
  err "Example ~/.openclaw/.backup-env:"
  err "  RESTIC_REPOSITORY=s3:s3.amazonaws.com/your-bucket/openclaw"
  err "  RESTIC_PASSWORD=your-strong-passphrase"
  err "  AWS_ACCESS_KEY_ID=your-key-id        # For S3"
  err "  AWS_SECRET_ACCESS_KEY=your-secret    # For S3"
  exit 1
fi

# shellcheck source=/dev/null
source "$BACKUP_ENV_FILE"

# Validate required vars
if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  err "RESTIC_REPOSITORY not set in ${BACKUP_ENV_FILE}"
  exit 1
fi
if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
  err "RESTIC_PASSWORD not set in ${BACKUP_ENV_FILE}"
  exit 1
fi

# ── Check restic is installed ─────────────────────────────────────────────────
if ! command -v restic &>/dev/null; then
  err "restic not installed. Run: sudo apt-get install restic"
  exit 1
fi

# ── Run backup ────────────────────────────────────────────────────────────────
log "Starting backup of ${BACKUP_SOURCE}..."
log "Repository: ${RESTIC_REPOSITORY}"

# Exclude sensitive files that are already backed up elsewhere
# (or that shouldn't be in an offsite backup)
restic backup \
  --verbose \
  --exclude="${BACKUP_SOURCE}/.env" \
  --exclude="${BACKUP_SOURCE}/.backup-env" \
  --exclude="**/.git" \
  --exclude="**/node_modules" \
  --tag "openclaw" \
  --tag "$(hostname)" \
  "$BACKUP_SOURCE"

log "Backup complete"

# ── Prune old backups ─────────────────────────────────────────────────────────
log "Pruning old snapshots (daily=${KEEP_DAILY}, weekly=${KEEP_WEEKLY}, monthly=${KEEP_MONTHLY})..."

restic forget \
  --prune \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --tag "openclaw"

log "Pruning complete"

# ── Verify integrity (weekly, on Sundays) ─────────────────────────────────────
if [[ "$(date +%u)" == "0" ]]; then
  log "Sunday: running integrity check..."
  restic check && log "Integrity check passed" || err "Integrity check FAILED — investigate!"
fi

log "Done"
