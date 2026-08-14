#!/bin/bash
set -euo pipefail

if [ $# -ne 8 ]; then
    echo "Usage: $0 VAULT_DIR BACKUPS_DIR DEFAULT_BRANCH MAX_BUNDLES LOG_FILE NOTIFY_SUCCESS NOTIFICATIONS_ENABLED RUN_TYPE" >&2
    exit 1
fi

VAULT_DIR="$1"
BACKUPS_DIR="$2"
DEFAULT_BRANCH="$3"
MAX_BUNDLES="$4"
LOG_FILE="$5"
NOTIFY_SUCCESS="$6"
NOTIFICATIONS_ENABLED="$7"
RUN_TYPE="$8"

VAULT_NAME="$(basename "$VAULT_DIR")"

case "$RUN_TYPE" in
    manual) RUN_TYPE_LABEL="M" ;;
    scheduled) RUN_TYPE_LABEL="S" ;;
esac

log() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [$(printf '%-6s' "$RUN_TYPE_LABEL")] $1" >> "$LOG_FILE"
}

notify() {
    if [ "$NOTIFICATIONS_ENABLED" = "true" ]; then
        osascript -e "display notification with title \"Vault Backup\" subtitle \"$1\"" > /dev/null 2>&1 || true
    fi
}

notify_success() {
    if [ "$NOTIFY_SUCCESS" = "true" ]; then
        notify "'$VAULT_NAME' backed up."
    fi
}

notify_error() {
    notify "Backup failed for '$VAULT_NAME'. See logs for details."
}

if [ ! -d "$VAULT_DIR" ]; then
    log "🚫 error: vault directory not found: $VAULT_DIR"
    notify_error
    exit 1
fi

cd "$VAULT_DIR"

# only ever back up the default branch
CURRENT_REF="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_REF" != "$DEFAULT_BRANCH" ]; then
    log "🚫 error: not on '$DEFAULT_BRANCH' branch, skipping backup"
    notify_error
    exit 1
fi

# commit any pending changes so they're included in the bundle
if [ -n "$(git status --porcelain)" ]; then
    git add -A
    if ! git commit -m "auto-backup: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" > /dev/null; then
        log "🚫 error: commit failed, skipping backup"
        notify_error
        exit 1
    fi
    log "committed pending changes"
fi

# skip the backup entirely if a bundle for the current commit already exists
CURRENT_SHA_SHORT="$(git rev-parse --short HEAD)"
if ls "$BACKUPS_DIR/$VAULT_NAME"-*-"$CURRENT_SHA_SHORT".bundle >/dev/null 2>&1; then
    log "no changes since last backup, skipping backup"
    exit 0
fi

BUNDLE_NAME="$VAULT_NAME-$(date -u '+%Y%m%dT%H%M%SZ')-$CURRENT_SHA_SHORT.bundle"
BUNDLE_PATH="$BACKUPS_DIR/$BUNDLE_NAME"

if ! git bundle create "$BUNDLE_PATH" --all > /dev/null; then
    log "🚫 error: bundle creation failed, skipping backup"
    notify_error
    rm -f "$BUNDLE_PATH"
    exit 1
fi

if ! git bundle verify "$BUNDLE_PATH" > /dev/null 2>&1; then
    log "🚫 error: bundle verification failed, skipping backup"
    notify_error
    rm -f "$BUNDLE_PATH"
    exit 1
fi
log "created bundle: $BUNDLE_NAME"

# keep only the $MAX_BUNDLES latest bundles, prune the rest
cd "$BACKUPS_DIR"
ls -r "$VAULT_NAME"-*.bundle 2>/dev/null | tail -n +$((MAX_BUNDLES + 1)) | while read -r old_bundle; do
    rm -f "$old_bundle"
    log "pruned old bundle: $old_bundle"
done

log "backup run completed successfully"
notify_success
