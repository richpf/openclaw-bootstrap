#!/usr/bin/env bash
# =============================================================================
# git-sync.sh — OpenClaw Workspace Git Sync
# Syncs the OpenClaw workspace to a private git repository.
#
# Setup:
#   1. Initialize a git repo in your workspace:
#        cd ~/.openclaw/workspace
#        git init
#        git remote add origin git@github.com:YOUR_ORG/openclaw-workspace.git
#
#   2. Add your SSH deploy key to the repo (read/write access)
#
#   3. Edit WORKSPACE_DIR below if your path differs
#
#   4. Enable with cron (run: crontab -e):
#        0 */6 * * * ~/.openclaw/scripts/git-sync.sh >> ~/.openclaw/logs/git-sync.log 2>&1
# =============================================================================

set -euo pipefail

WORKSPACE_DIR="${HOME}/.openclaw/workspace"
LOG_PREFIX="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] git-sync:"

log()  { echo "${LOG_PREFIX} $*"; }
err()  { echo "${LOG_PREFIX} ERROR: $*" >&2; }

# Ensure workspace exists and is a git repo
if [[ ! -d "$WORKSPACE_DIR/.git" ]]; then
  err "Workspace is not a git repo: ${WORKSPACE_DIR}"
  err "Run: git init && git remote add origin <url>"
  exit 1
fi

cd "$WORKSPACE_DIR"

# Configure git identity if not set
git config user.email > /dev/null 2>&1 || git config user.email "openclaw@$(hostname)"
git config user.name  > /dev/null 2>&1 || git config user.name  "OpenClaw"

# Pull remote changes first (rebase to avoid merge commits)
log "Pulling remote changes..."
if git pull --rebase --autostash origin main 2>&1; then
  log "Pull successful"
else
  err "Pull failed — manual intervention may be needed"
  exit 1
fi

# Stage all changes
git add -A

# Check if there's anything to commit
if git diff --staged --quiet; then
  log "No changes to commit"
  exit 0
fi

# Commit with timestamp
CHANGED_FILES=$(git diff --staged --name-only | wc -l | tr -d ' ')
COMMIT_MSG="auto-sync: ${CHANGED_FILES} file(s) changed [$(date -u +%Y-%m-%dT%H:%M:%SZ)]"

git commit -m "$COMMIT_MSG" 2>&1
log "Committed: ${COMMIT_MSG}"

# Push to remote
if git push origin main 2>&1; then
  log "Pushed to remote successfully"
else
  err "Push failed — check remote access and SSH key"
  exit 1
fi

log "Sync complete"
