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
MESSAGE="It's time to backup your vault."
# How long the reminder stays on screen before it counts as ignored.
GIVE_UP_AFTER="${GIVE_UP_AFTER:-3600}"

if [ -z "$SCRIPT_DIR" ]; then
    log "FATAL could not resolve script directory from '$0'"
    exit 1
fi

if [ ! -x "$BACKUP_SCRIPT" ]; then
    log "FATAL $BACKUP_SCRIPT is missing or not executable"
    osascript - "$TITLE" "Backup script missing - see $LOG_FILE" >/dev/null 2>&1 <<'EOF'
on run argv
    display notification (item 2 of argv) with title (item 1 of argv) sound name "Basso"
end run
EOF
    exit 1
fi

# A dialog rather than a notification: native notifications can't run a command when
# clicked, and terminal-notifier (which could) silently shows nothing on recent macOS.
ANSWER=$(osascript - "$TITLE" "$MESSAGE" "$GIVE_UP_AFTER" 2>>"$LOG_FILE" <<'EOF'
on run argv
    set r to display dialog (item 2 of argv) with title (item 1 of argv) ¬
        buttons {"Later", "Back Up Now"} default button "Back Up Now" ¬
        giving up after ((item 3 of argv) as integer)
    if gave up of r then return "timeout"
    return button returned of r
end run
EOF
)

case "$ANSWER" in
"Back Up Now")
    log "OK reminder accepted, starting backup"
    exec "$BACKUP_SCRIPT"
    ;;
"Later")
    log "OK reminder shown, postponed by user"
    ;;
"timeout")
    log "WARN reminder shown but no response within ${GIVE_UP_AFTER}s"
    ;;
*)
    log "ERROR could not show reminder dialog"
    exit 1
    ;;
esac
