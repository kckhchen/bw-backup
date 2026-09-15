#!/bin/zsh

umask 077
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR=${0:a:h}
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
BACKUP_SCRIPT="$SCRIPT_DIR/bw-backup.sh"
ALERTER_SCRIPT="$SCRIPT_DIR/backup-alerter.sh"

KC_SERVICE_ID="bw-backup-clientid"
KC_SERVICE_SECRET="bw-backup-clientsecret"

LAUNCH_AGENT_LABEL="com.user.bw-backup-alerter"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

BW_DATA_DIR="${BITWARDENCLI_APPDATA_DIR:-$HOME/Library/Application Support/Bitwarden CLI}"

# ---------------------------------------------------------------- Output

C_OK=$'\033[32m'
C_WARN=$'\033[33m'
C_ERR=$'\033[31m'
C_HEAD=$'\033[1;36m'
C_DIM=$'\033[2m'
C_OFF=$'\033[0m'

step() { echo "\n${C_HEAD}==> $1${C_OFF}"; }
ok() { echo "  ${C_OK}✓${C_OFF} $1"; }
warn() { echo "  ${C_WARN}!${C_OFF} $1"; }
die() {
    echo "\n  ${C_ERR}✗ $1${C_OFF}\n"
    exit 1
}
dim() { echo "  ${C_DIM}$1${C_OFF}"; }

confirm() {
    local REPLY
    read -q "REPLY?  $1 [y/N] "
    echo
    [[ "$REPLY" == "y" ]]
}

bw_field() { printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null; }
kc_has() { security find-generic-password -a "$USER" -s "$1" >/dev/null 2>&1; }
kc_get() { security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null; }

echo "${C_HEAD}"
echo "  Minimalistic Bitwarden Backup Tool — Setup"
echo "${C_OFF}"

# ---------------------------------------------------------------- 1. Dependencies

step "1/7  Checking dependencies"

[[ "$(uname)" == "Darwin" ]] || die "This tool is macOS only."

if command -v bw >/dev/null 2>&1; then
    ok "bitwarden-cli  $(bw --version 2>/dev/null)"
else
    die "bitwarden-cli not found. Install it with:

      brew install bitwarden-cli"
fi

if command -v terminal-notifier >/dev/null 2>&1; then
    ok "terminal-notifier"
else
    warn "terminal-notifier not found — clickable notifications will be disabled."
    dim "Install with:  brew install terminal-notifier"
fi

for f in "$BACKUP_SCRIPT" "$ALERTER_SCRIPT"; do
    [ -f "$f" ] || die "Missing file: $f"
done
chmod +x "$BACKUP_SCRIPT" "$ALERTER_SCRIPT" 2>/dev/null
ok "Scripts are executable"

# ---------------------------------------------------------------- 2. .env

step "2/7  Configuration file"

if [ -f "$ENV_FILE" ]; then
    ok ".env already exists"
else
    [ -f "$ENV_EXAMPLE" ] || die "Neither .env nor .env.example found."
    cp "$ENV_EXAMPLE" "$ENV_FILE" || die "Failed to create .env"
    ok "Created .env from .env.example"
fi
chmod 600 "$ENV_FILE" || die "Failed to chmod .env"
ok "Permissions on .env set to 600"

LEGACY_SECRET=0
grep -qE '^\s*BW_CLIENTSECRET\s*=\s*["'\'']?[^"'\'' ]+' "$ENV_FILE" 2>/dev/null && LEGACY_SECRET=1

set -a
source "$ENV_FILE"
set +a

: ${BACKUP_DIR:="$HOME/Backups/Bitwarden"}
: ${BW_SERVER:=""}

mkdir -p "$BACKUP_DIR" || die "Failed to create backup directory: $BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
ok "Backup directory ready (700): $BACKUP_DIR"

if [ -z "$SAFETY_PHRASE" ]; then
    echo
    dim "A safety phrase is shown in the master-password dialog."
    dim "It lets you tell the real prompt apart from a fake one. Leave blank to skip."
    local_phrase=""
    read "local_phrase?  Safety phrase: "
    if [ -n "$local_phrase" ]; then
        if grep -q '^SAFETY_PHRASE=' "$ENV_FILE"; then
            /usr/bin/sed -i '' "s|^SAFETY_PHRASE=.*|SAFETY_PHRASE=\"$local_phrase\"|" "$ENV_FILE"
        else
            echo "SAFETY_PHRASE=\"$local_phrase\"" >>"$ENV_FILE"
        fi
        SAFETY_PHRASE="$local_phrase"
        ok "Safety phrase saved"
    else
        warn "No safety phrase set (you can add SAFETY_PHRASE to .env later)"
    fi
else
    ok "Safety phrase already set"
fi

# ---------------------------------------------------------------- 3. server

step "3/7  Bitwarden server"

CURRENT_SERVER=$(bw config server 2>/dev/null)
dim "Currently configured: ${CURRENT_SERVER:-<unset>}"

if [ -n "$BW_SERVER" ]; then
    if [ "$CURRENT_SERVER" != "$BW_SERVER" ]; then
        bw config server "$BW_SERVER" >/dev/null 2>&1 ||
            die "Failed to set server to $BW_SERVER"
        ok "Server set to $BW_SERVER"
    else
        ok "Server already matches BW_SERVER"
    fi
else
    ok "Using Bitwarden cloud (set BW_SERVER in .env for self-hosted Vaultwarden)"
fi

# ---------------------------------------------------------------- 4. keychain

step "4/7  API key in Keychain"

NEED_STORE=1
if kc_has "$KC_SERVICE_ID" && kc_has "$KC_SERVICE_SECRET"; then
    ok "API key already stored in Keychain"
    if confirm "Replace it?"; then NEED_STORE=1; else NEED_STORE=0; fi
fi

if [ "$NEED_STORE" -eq 1 ]; then
    echo
    dim "Get your personal API key from the Web Vault:"
    dim "  Settings → Security → Keys → View API key"
    dim "You will be prompted twice for each value (enter + confirm)."
    echo

    security delete-generic-password -a "$USER" -s "$KC_SERVICE_ID" >/dev/null 2>&1
    security delete-generic-password -a "$USER" -s "$KC_SERVICE_SECRET" >/dev/null 2>&1

    echo "  client_id  (looks like user.xxxxxxxx-xxxx-...):"
    security add-generic-password -a "$USER" -s "$KC_SERVICE_ID" \
        -l "Bitwarden Backup client_id" -U -w ||
        die "Failed to store client_id in Keychain"

    echo "  client_secret:"
    security add-generic-password -a "$USER" -s "$KC_SERVICE_SECRET" \
        -l "Bitwarden Backup client_secret" -U -w ||
        die "Failed to store client_secret in Keychain"

    kc_has "$KC_SERVICE_ID" && kc_has "$KC_SERVICE_SECRET" ||
        die "Keychain readback failed — the values were not stored."
    ok "API key stored in Keychain"
fi

# ---------------------------------------------------------------- 5. login

step "5/7  Bitwarden login"

STATUS_JSON=$(bw status 2>/dev/null)
BW_STATE=$(bw_field "$STATUS_JSON" status)
dim "Current state: ${BW_STATE:-unknown}"

if [ "$BW_STATE" = "unauthenticated" ] || [ -z "$BW_STATE" ]; then
    BW_CLIENTID=$(kc_get "$KC_SERVICE_ID")
    BW_CLIENTSECRET=$(kc_get "$KC_SERVICE_SECRET")

    [ -n "$BW_CLIENTID" ] && [ -n "$BW_CLIENTSECRET" ] ||
        die "API key missing from Keychain. Re-run setup and store it."

    export BW_CLIENTID BW_CLIENTSECRET
    if bw login --apikey </dev/null >/dev/null 2>&1; then
        ok "Logged in with API key"
    else
        unset BW_CLIENTID BW_CLIENTSECRET
        die "Login failed. Check that the API key is correct and not rotated."
    fi
    unset BW_CLIENTID BW_CLIENTSECRET
else
    ok "Already authenticated (state: $BW_STATE)"
fi

if [ -f "$BW_DATA_DIR/data.json" ]; then
    BEFORE=$(stat -f "%OLp" "$BW_DATA_DIR/data.json" 2>/dev/null)
    chmod 600 "$BW_DATA_DIR/data.json" 2>/dev/null
    chmod 700 "$BW_DATA_DIR" 2>/dev/null
    ok "Locked down data.json (was $BEFORE, now 600)"
    dim "This file holds your CLI credentials — worth checking after CLI upgrades."
fi

# ---------------------------------------------------------------- 6. Validation

step "6/7  End-to-end verification"

dim "This unlocks the vault and syncs it, but does NOT write a backup file."
echo

if confirm "Run verification now? (recommended)"; then
    VPASS=""
    read -s "VPASS?  Master password: "
    echo

    if [ -z "$VPASS" ]; then
        warn "Skipped (no password entered)"
    else
        export BW_PASSWORD="$VPASS"
        VPASS=""

        bw lock >/dev/null 2>&1

        VSESSION=$(bw unlock --passwordenv BW_PASSWORD --raw 2>/dev/null)
        VRC=$?
        unset BW_PASSWORD

        if [ $VRC -ne 0 ]; then
            die "Unlock failed (exit $VRC). Wrong master password?"
        fi
        if [ -z "$VSESSION" ]; then
            die "Unlock returned an empty session key.

This is the bug the rewritten script is meant to avoid. Try:
  bw sync -f
then re-run setup."
        fi
        export BW_SESSION="$VSESSION"
        ok "Unlock succeeded (session key length: ${#VSESSION})"

        VSYNC_OUT=$(bw sync -f 2>&1)
        if [ $? -eq 0 ]; then
            ok "Sync succeeded"
        else
            warn "Sync failed: ${VSYNC_OUT:-no output}"
            dim "Check your network. If the error mentions a token or authorization, run: bw logout && ./setup.sh"
        fi

        VLAST=$(bw_field "$(bw status 2>/dev/null)" lastSync)
        if [ -z "$VLAST" ] || [ "$VLAST" = "null" ]; then
            die "lastSync is still null. The vault has not downloaded.

Do NOT run a backup yet — it would produce an empty file."
        fi
        ok "lastSync: $VLAST"

        VCOUNT=$(bw list items 2>/dev/null | grep -o '"object":"item"' | wc -l | tr -d ' ')
        if [ -z "$VCOUNT" ] || [ "$VCOUNT" -lt 1 ]; then
            die "Vault reports 0 items. Something is wrong — do not back up yet."
        fi
        ok "Vault contains $VCOUNT items"

        bw lock >/dev/null 2>&1
        unset BW_SESSION
        ok "Vault re-locked"
        echo
        echo "  ${C_OK}Verification passed.${C_OFF} $VCOUNT items are ready to back up."
    fi
else
    warn "Verification skipped — run ./bw-backup.sh manually to test"
fi

# ---------------------------------------------------------------- 7. Convenience

step "7/7  Convenience"

# --- alias ---
RC_FILE="$HOME/.zshrc"
ALIAS_LINE="alias bw-backup='$BACKUP_SCRIPT'"
if [ -f "$RC_FILE" ] && grep -Fxq "$ALIAS_LINE" "$RC_FILE"; then
    ok "Alias 'bw-backup' already in .zshrc"
else
    if confirm "Add 'bw-backup' alias to ~/.zshrc?"; then
        printf '\n# Minimalistic Bitwarden Backup Tool\n%s\n' "$ALIAS_LINE" >>"$RC_FILE"
        ok "Alias added — run 'source ~/.zshrc' to use it now"
    else
        dim "Skipped"
    fi
fi

# --- LaunchAgent ---
echo
if [ -f "$LAUNCH_AGENT_PLIST" ]; then
    ok "LaunchAgent already installed"
    dim "$LAUNCH_AGENT_PLIST"
    if confirm "Reinstall it?"; then INSTALL_AGENT=1; else INSTALL_AGENT=0; fi
else
    dim "A LaunchAgent can remind you to back up on a schedule."
    if confirm "Install a reminder twice a month (1st and 15th, 12:00)?"; then
        INSTALL_AGENT=1
    else
        INSTALL_AGENT=0
        dim "Skipped — you can always run 'bw-backup' manually"
    fi
fi

if [ "${INSTALL_AGENT:-0}" -eq 1 ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1

    cat >"$LAUNCH_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCH_AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$ALERTER_SCRIPT</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict>
            <key>Day</key><integer>1</integer>
            <key>Hour</key><integer>12</integer>
            <key>Minute</key><integer>0</integer>
        </dict>
        <dict>
            <key>Day</key><integer>15</integer>
            <key>Hour</key><integer>12</integer>
            <key>Minute</key><integer>0</integer>
        </dict>
    </array>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/bw-backup-alerter.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/bw-backup-alerter.log</string>
</dict>
</plist>
PLIST

    chmod 644 "$LAUNCH_AGENT_PLIST"
    if launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST" >/dev/null 2>&1; then
        ok "LaunchAgent installed and loaded"
        dim "Test it now:  launchctl kickstart gui/$(id -u)/$LAUNCH_AGENT_LABEL"
        dim "Remove it:    launchctl bootout gui/$(id -u)/$LAUNCH_AGENT_LABEL && rm '$LAUNCH_AGENT_PLIST'"
    else
        warn "plist written but launchctl bootstrap failed"
        dim "Try manually: launchctl bootstrap gui/$(id -u) '$LAUNCH_AGENT_PLIST'"
    fi
fi

# ---------------------------------------------------------------- cleanup

echo
echo "${C_HEAD}  Setup complete.${C_OFF}"
echo

if [ "$LEGACY_SECRET" -eq 1 ]; then
    echo "  ${C_WARN}!  Your .env still contains BW_CLIENTSECRET.${C_OFF}"
    echo "     It is no longer used — the API key now lives in your Keychain."
    echo "     Remove those two lines from .env:"
    echo "       ${C_DIM}$ENV_FILE${C_OFF}"
    echo
fi

echo "  Run a backup:   ${C_DIM}$BACKUP_SCRIPT${C_OFF}"
echo "  Backups go to:  ${C_DIM}$BACKUP_DIR${C_OFF}"
echo "  Log file:       ${C_DIM}${LOG_FILE:-$HOME/Library/Logs/bw-backup.log}${C_OFF}"
echo
echo "  ${C_WARN}Note:${C_OFF} bw export does not include file attachments or"
echo "        organization vaults. Back those up separately if you use them."
echo
