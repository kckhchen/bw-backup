#!/bin/zsh

# Automated Bitwarden Backup Script

umask 077
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
SCRIPT_DIR=${0:a:h}
ENV_FILE="$SCRIPT_DIR/.env"
ATTEMPT=1
SESSION_RETRY=0
MAX_SESSION_RETRY=3
REAUTH_HAPPENED=0
SYNC_WARNING=""

KC_SERVICE_ID="bw-backup-clientid"
KC_SERVICE_SECRET="bw-backup-clientsecret"

# source variables from .env
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    osascript -e 'display dialog ".env file is missing. Process aborted." with title "Minimalistic Bitwarden Backup Tool" buttons {"OK"} default button "OK" with icon stop' >/dev/null 2>&1
fi

# set default values if not found in .env
: ${LOG_FILE:="$HOME/Library/Logs/bw-backup.log"}
: ${BACKUP_DIR:="$HOME/Backups/Bitwarden"}
: ${MAX_ATTEMPTS:=5}
: ${KEEP_LAST_N:=3}
: ${BW_SERVER:=""}
: ${SAFETY_PHRASE:=""}

log_message() {
    local LOG_LEVEL="$1"
    local MESSAGE="$2"
    local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$TIMESTAMP] [$LOG_LEVEL] $MESSAGE" | tee -a "$LOG_FILE"
}

mkdir -p "${LOG_FILE:h}" 2>/dev/null
touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null
log_message "INFO" "----------New bakcup session starts----------"

# helper functions

die_gui() {
    local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$TIMESTAMP] [FATAL] $1" >>"$LOG_FILE"
    osascript - "$1" <<'EOF' >/dev/null 2>&1
on run argv
    display dialog (item 1 of argv) with title "Minimalistic Bitwarden Backup Tool" ¬
        buttons {"OK"} default button "OK" with icon stop
end run
EOF
    exit 1
}

kill_spinner() {
    [ -n "$1" ] || return
    [[ "$(ps -p "$1" -o comm= 2>/dev/null)" == *osascript* ]] && kill "$1" 2>/dev/null
}

# Native notification. terminal-notifier relies on the deprecated NSUserNotification
# API, which on recent macOS reports success but never displays anything.
notify() {
    local title="$1" msg="$2"
    osascript - "$title" "$msg" >/dev/null 2>&1 <<'EOF'
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
EOF
}

bw_field() {
    printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null
}

kc_get() {
    security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null
}

# "2026-09-10T14:13:13.817Z" -> "2026-09-10 22:13" in local time (falls back to input)
iso_to_local() {
    local s="${1%%.*}" epoch
    s="${s%Z}"
    epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$s" "+%s" 2>/dev/null) || { printf '%s' "$1"; return; }
    date -r "$epoch" "+%Y-%m-%d %H:%M"
}

# whole days between an ISO timestamp and now (empty on parse failure)
iso_age_days() {
    local s="${1%%.*}" epoch
    s="${s%Z}"
    epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$s" "+%s" 2>/dev/null) || return 1
    echo $(( ($(date +%s) - epoch) / 86400 ))
}

# map bw sync output to a concrete fix the user can act on
sync_hint() {
    local out="$1"
    case "$out" in
    *"not logged in"*|*unauthenticated*|*Unauthorized*|*401*|*invalid_grant*|*"Access token"*|*"refresh token"*|*expired*)
        echo "Your CLI login token has expired or was revoked.
In Terminal run:
    bw logout
then run bw-backup again. It will re-login from your Keychain.
If that also fails, your API key may have been rotated. Run ./setup.sh."
        ;;
    *ENOTFOUND*|*EAI_AGAIN*|*ECONNREFUSED*|*ECONNRESET*|*ETIMEDOUT*|*"fetch failed"*|*getaddrinfo*|*"Network error"*|*"network"*|*certificate*|*"self signed"*)
        echo "The Bitwarden server could not be reached.
Check your internet connection, VPN, firewall or proxy${BW_SERVER:+, and confirm that $BW_SERVER is reachable}."
        ;;
    *429*|*"Too Many Requests"*|*"rate limit"*|*"Slow down"*)
        echo "The Bitwarden server is rate-limiting this client.
Wait a few minutes and run bw-backup again."
        ;;
    *"50"[0-9]*|*"Service Unavailable"*|*"Bad Gateway"*|*"Gateway Timeout"*|*maintenance*)
        echo "The Bitwarden server returned an error.
Check https://status.bitwarden.com and try again later."
        ;;
    *"Vault is locked"*|*"session"*)
        echo "The CLI session was rejected.
In Terminal run:
    bw lock
then run bw-backup again."
        ;;
    *)
        echo "Cause not recognised. The most reliable fix is to reset the CLI login:
    bw logout
then run bw-backup again. If it keeps failing, check the log at
    $LOG_FILE"
        ;;
    esac
}

CLEANED=0
cleanup() {
    [ "$CLEANED" -eq 1 ] && return 0
    CLEANED=1
    kill_spinner "${SPINNER_PID:-}"
    kill_spinner "${BACKUP_PID:-}"
    [ -n "${TMP_FILE:-}" ] && rm -f "$TMP_FILE" 2>/dev/null
    unset BW_PASSWORD BW_SESSION BW_CLIENTID BW_CLIENTSECRET
    bw lock >/dev/null 2>&1
    log_message "INFO" "----------cleanup done----------"
    return 0
}
trap cleanup EXIT INT TERM

# preflight checks
command -v bw >/dev/null 2>&1 || die_gui "Bitwarden CLI not found. Install it with: brew install bitwarden-cli"
command -v osascript >/dev/null 2>&1 || die_gui "osascript missing."

# log setup
log_message "INFO" "bw version: $(bw --version 2>&1)"

if [[ ! "$KEEP_LAST_N" =~ ^[0-9]+$ ]] || [ "$KEEP_LAST_N" -lt 1 ]; then
    echo "Invalid KEEP_LAST_N ('$KEEP_LAST_N'), falling back to 3." >>"$LOG_FILE"
    KEEP_LAST_N=3
fi
if [[ ! "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$MAX_ATTEMPTS" -lt 1 ]; then
    echo "Invalid MAX_ATTEMPTS ('$MAX_ATTEMPTS'), falling back to 5." >>"$LOG_FILE"
    MAX_ATTEMPTS=5
fi

mkdir -p "$BACKUP_DIR" 2>/dev/null || die_gui "Cannot create backup directory: $BACKUP_DIR"
chmod 700 "$BACKUP_DIR" 2>/dev/null

BACKUP_FILE="$BACKUP_DIR/Bitwarden-Backup-$(date '+%Y-%m-%d-%H%M%S').json"
TMP_FILE="${BACKUP_FILE}.part"

if [ -n "$BW_SERVER" ]; then
    CURRENT_SERVER=$(bw config server 2>/dev/null)
    if [ "$CURRENT_SERVER" != "$BW_SERVER" ]; then
        log_message "INFO" "Setting server: $BW_SERVER (was: ${CURRENT_SERVER:-unset})"
        bw config server "$BW_SERVER" >>"$LOG_FILE" 2>&1 || die_gui "Failed to set server URL to $BW_SERVER"
    fi
fi

# starting confirmation
osascript -e 'display alert "Bitwarden Password Backup" message "You are about to backup your Bitwarden passwords.\n\nClick Proceed to enter your Master Password, or Cancel to skip." buttons {"Cancel", "Proceed"} default button "Proceed" cancel button "Cancel"'

if [ $? -ne 0 ]; then
    log_message "INFO" "User clicked Cancel on the dialog. Exiting."
    exit 0
fi

# status authentication
ensure_authentication() {
    local st raw
    raw=$(bw status 2>/dev/null)
    st=$(bw_field "$raw" status)
    log_message "INFO" "bw status: ${raw:-<empty>}"

    case "$st" in
    locked)
        return 0
        ;;
    unlocked)
        bw lock >/dev/null 2>&1
        return 0
        ;;
    unauthenticated)
        log_message "INFO" "Not authenticated. Re-authenticating from Keychain..."
        BW_CLIENTID=$(kc_get "$KC_SERVICE_ID")
        BW_CLIENTSECRET=$(kc_get "$KC_SERVICE_SECRET")

        if [ -z "$BW_CLIENTID" ] || [ -z "$BW_CLIENTSECRET" ]; then
            die_gui "Your Bitwarden CLI login has expired, and the API key was not found in your keychain. Run ./setup.sh to store it."
        fi

        export BW_CLIENTID BW_CLIENTSECRET
        if ! bw login --apikey </dev/null >>"$LOG_FILE" 2>&1; then
            unset BW_CLIENTID BW_CLIENTSECRET
            die_gui "Re-authentication failed. Your API key might have been rotated or revoked. Check Web Vault > Settings > Security > Keys, then run ./setup.sh again."
        fi
        unset BW_CLIENTID BW_CLIENTSECRET
        REAUTH_HAPPENED=1
        return 0
        ;;
    *)
        die_gui "Unexpected Bitwarden status: '${st:-empty}'. See $LOG_FILE for details."
        ;;
    esac
}

ensure_authentication

# main password
if [ -n "$SAFETY_PHRASE" ]; then
    HEADER="Safety Phrase: $SAFETY_PHRASE"
else
    HEADER="Warning: SAFETY_PHRASE not set — see README"
fi

BW_EMAIL=$(bw status 2>/dev/null | sed -n 's/.*"userEmail":"\([^"]*\)".*/\1/p')
LAST_BACKUP=$(ls -t "$BACKUP_DIR"/Bitwarden-Backup-*.json 2>/dev/null | head -1)
if [ -n "$LAST_BACKUP" ]; then
    LAST_DATE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$LAST_BACKUP")
else
    LAST_DATE="(no previous backup)"
fi

BASE_PROMPT="$HEADER

Account: ${BW_EMAIL:-unknown}
Last backup: $LAST_DATE
Backing up to: $BACKUP_DIR"

PROMPT_TEXT="$BASE_PROMPT

Enter your master password:"

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    BW_PASSWORD=$(
        osascript - "$PROMPT_TEXT" <<'OSA' 2>>"$LOG_FILE"
on run argv
    set r to display dialog (item 1 of argv) default answer "" ¬
        with title "Minimalistic Bitwarden Backup Tool" ¬
        with icon caution with hidden answer
    return text returned of r
end run
OSA
    )
    DIALOG_EXIT=$?
    export BW_PASSWORD

    if [ $DIALOG_EXIT -ne 0 ]; then
        log_message "ERROR" "Process cancelled by user."
        exit 1
    fi
    if [ -z "$BW_PASSWORD" ]; then
        PROMPT_TEXT="$BASE_PROMPT

Password cannot be empty. Please try again:"
        continue
    fi

    BW_SESSION=$(bw unlock --passwordenv BW_PASSWORD --raw 2>>"$LOG_FILE")
    EXIT_CODE=$?

    if [ "$EXIT_CODE" -eq 1 ]; then
        if [ $ATTEMPT -ge $MAX_ATTEMPTS ]; then
            log_message "ERROR" "Process terminated due to too many failed attempts."
            die_gui "Too many incorrect attempts. Backup aborted."
        fi
        REMAINING=$((MAX_ATTEMPTS - ATTEMPT))
        PROMPT_TEXT="$BASE_PROMPT

Incorrect password. ($REMAINING attempts remaining)
Please try again:"
        log_message "INFO" "Invalid password. Attempt $ATTEMPT / $MAX_ATTEMPTS."
        ((ATTEMPT++))
        continue

    elif [ "$EXIT_CODE" -ne 0 ]; then
        log_message "ERROR" "Unlock failed with exit code $EXIT_CODE."
        die_gui "Unlock failed with exit code $EXIT_CODE.

See $LOG_FILE for details."
    fi

    if [ -z "$BW_SESSION" ]; then
        ((SESSION_RETRY++))
        log_message "INFO" "Empty session key (retry $SESSION_RETRY / $MAX_SESSION_RETRY)."
        if [ $SESSION_RETRY -ge $MAX_SESSION_RETRY ]; then
            log_message "ERROR" "Bitwarden repeatedly returned an empty session key. Process aborted."
            die_gui "Bitwarden repeatedly returned an empty session key.

See $LOG_FILE for details."
        fi
        bw lock >/dev/null 2>&1
        sleep 1
        continue
    fi

    export BW_SESSION
    break
done

if [ -z "$BW_SESSION" ]; then
    die_gui "Failed to obtain a session key. Process aborted."
fi

# syncing
unset BW_CLIENTID
unset BW_CLIENTSECRET

osascript -e 'display dialog "Authentication succeeded. Backup has started. You will be notified when the process is completed. You can close this dialog." with title "Minimalistic Bitwarden Backup Tool" buttons {"OK"} default button "OK" with icon note' >/dev/null 2>&1 &
BACKUP_PID=$!

log_message "INFO" "Syncing vault..."
SYNC_OUTPUT=$(bw sync -f 2>&1)
SYNC_RC=$?
[ -n "$SYNC_OUTPUT" ] && log_message "INFO" "sync output: $SYNC_OUTPUT"

STATUS_JSON=$(bw status 2>/dev/null)
LAST_SYNC=$(bw_field "$STATUS_JSON" lastSync)
log_message "INFO" "post-sync status: $STATUS_JSON"

# check last sync to prevent an empty vault
if [ -z "$LAST_SYNC" ] || [ "$LAST_SYNC" = "null" ]; then
    die_gui "The vault has never synced (lastSync is null).

Aborting to prevent overwritting existing backups.
Try this in Terminal:
    bw sync -f"
fi

# sync failed: do not silently fall back to the cache. Tell the user why,
# how to fix it, and let them decide whether a stale backup is still wanted.
if [ $SYNC_RC -ne 0 ]; then
    SYNC_HINT=$(sync_hint "$SYNC_OUTPUT")
    LAST_SYNC_LOCAL=$(iso_to_local "$LAST_SYNC")
    CACHE_AGE=$(iso_age_days "$LAST_SYNC")
    SYNC_REASON=$(printf '%s' "$SYNC_OUTPUT" | grep -v '^\s*$' | head -1 | cut -c1-160)

    log_message "ERROR" "sync -f failed (exit $SYNC_RC): ${SYNC_OUTPUT:-<no output>}"
    log_message "WARNING" "Suggested fix: $SYNC_HINT"

    kill_spinner "$BACKUP_PID"
    osascript - "Vault sync failed. The backup would contain CACHED data, not your live vault.

Last successful sync: $LAST_SYNC_LOCAL${CACHE_AGE:+ ($CACHE_AGE days ago)}
Reason: ${SYNC_REASON:-no output from bw sync (exit $SYNC_RC)}

How to fix:
$SYNC_HINT

Back up the cached data anyway, or Cancel and fix the problem first?" <<'OSA' >/dev/null 2>>"$LOG_FILE"
on run argv
    display dialog (item 1 of argv) with title "Minimalistic Bitwarden Backup Tool" ¬
        buttons {"Cancel", "Back Up Cached Data"} default button "Back Up Cached Data" ¬
        cancel button "Cancel" with icon caution
end run
OSA
    if [ $? -ne 0 ]; then
        log_message "INFO" "User cancelled after sync failure. No backup written."
        exit 1
    fi
    log_message "WARNING" "User chose to back up cached data from $LAST_SYNC"
    SYNC_WARNING=" (sync failed, cached data from $LAST_SYNC_LOCAL)"
fi

ITEM_COUNT=$(bw list items 2>>"$LOG_FILE" | grep -o '"object":"item"' | wc -l | tr -d ' ')
log_message "INFO" "Vault contains $ITEM_COUNT items."

if [ -z "$ITEM_COUNT" ] || [ "$ITEM_COUNT" -lt 1 ]; then
    die_gui "The vault reports 0 items. Refusing to create a backup.

This usually means the vault did not sync correctly."
fi

# exporting
# export to encrypted json file protected by the master password
EXPORT_OUTPUT=$(bw export --format encrypted_json --password "$BW_PASSWORD" --output "$TMP_FILE" 2>&1)
EXPORT_EXIT_CODE=$?
unset BW_PASSWORD
log_message "INFO" "$EXPORT_OUTPUT"

if [ $EXPORT_EXIT_CODE -ne 0 ] || [ ! -s "$TMP_FILE" ]; then
    log_message "ERROR" "Backup failed (exit $EXPORT_EXIT_CODE)."
    die_gui "Backup failed. See $LOG_FILE for details."
fi

if ! grep -q '"encrypted"' "$TMP_FILE"; then
    log_message "ERROR" "Export produced an invalid file."
    die_gui "The exported file failed validation and was discarded."
fi

chmod 600 "$TMP_FILE" 2>/dev/null
mv -f "$TMP_FILE" "$BACKUP_FILE" || die_gui "Failed to finalize backup file."
TMP_FILE=""
log_message "INFO" "Backup completed: $BACKUP_FILE ($ITEM_COUNT items)"

cd "$BACKUP_DIR" || die_gui "Cannot enter backup directory. Rotation skipped."
TAIL_START=$(($KEEP_LAST_N + 1))
ls -t Bitwarden-Backup-*.json 2>/dev/null | tail -n +"$TAIL_START" | while IFS= read -r old; do
    rm -- "$old" && log_message "INFO" "Rotated out: $old"
done

kill_spinner "$BACKUP_PID"

# notify user about completion
notify "Minimalistic Bitwarden Backup Tool" \
    "Backup complete — $ITEM_COUNT items${SYNC_WARNING}. Saved to $BACKUP_DIR."

if [ -n "$SYNC_WARNING" ]; then
    notify "Bitwarden Backup" \
        "This backup is from cached data. Fix the sync problem and back up again. See $LOG_FILE."
fi

if [ "$REAUTH_HAPPENED" -eq 1 ]; then
    notify "Bitwarden Backup" \
        "Note: your CLI login had expired and was renewed automatically. If you did not change your master password or deauthorize sessions recently, check your account."
fi

exit 0
