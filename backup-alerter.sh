#!/bin/zsh
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
export SCRIPT_DIR
export ENV_FILE="$SCRIPT_DIR/.env"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

BACKUP_SCRIPT="$SCRIPT_DIR/bw-backup.sh"
LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/bw-backup-alerter.log}"
mkdir -p "$(dirname -- "$LOG_FILE")" 2>/dev/null
touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG_FILE"
}

TITLE="Minimalistic Bitwarden Backup Reminder"
MESSAGE="It's time to backup your vault. Click to start the backup process"

if [ -z "$SCRIPT_DIR" ]; then
    log "FATAL could not resolve script directory from '$0'"
    exit 1
fi

if [ ! -x "$BACKUP_SCRIPT" ]; then
    log "FATAL $BACKUP_SCRIPT is missing or not executable"
    command -v terminal-notifier >/dev/null 2>&1 &&
        terminal-notifier -title "$TITLE" \
            -message "Backup script missing - see $LOG_FILE" -sound Basso
    exit 1
fi

EXEC_CMD="\"$BACKUP_SCRIPT\""

if command -v terminal-notifier >/dev/null 2>&1; then
    if terminal-notifier -title "$TITLE" -message "$MESSAGE" -execute "$EXEC_CMD"; then
        log "OK reminder sent (clickable)"
    else
        log "ERROR terminal-notifier failed"
        exit 1
    fi
elif osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\"" >/dev/null 2>&1; then
    log "OK reminder sent (not clickable: terminal-notifier not installed)"
else
    log "ERROR no notifier available"
    exit 1
fi
