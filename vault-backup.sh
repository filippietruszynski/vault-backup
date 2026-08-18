#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_SCRIPT_SRC="$REPO_DIR/lib/core.sh"
PLIST_TEMPLATE_SRC="$REPO_DIR/templates/launchd.plist.template"
APPLESCRIPT_TEMPLATE_SRC="$REPO_DIR/templates/vault-backup.applescript.template"
SHARED_SCRIPT_PATH="$HOME/.local/bin/vault-backup-core.sh"
CONFIG_DIR="$HOME/.config/vault-backup"

usage() {
    cat >&2 << USAGE
Usage:
  $0 setup                        interactive setup for a vault
  $0 backup <vault-name>          run a backup now
  $0 schedule on|off <vault-name> enable/disable the daily automatic backup
  $0 notify on|off <vault-name>   enable/disable success notifications for scheduled runs
  $0 info <vault-name>            print the configuration and file locations for a vault
USAGE
    exit 1
}

vault_name() {
    basename "${1%/}"
}

config_path() {
    echo "$CONFIG_DIR/$1.conf"
}

list_vault_names() {
    local config_file name
    for config_file in "$CONFIG_DIR"/*.conf; do
        [ -f "$config_file" ] || continue
        name="$(basename "$config_file" .conf)"
        echo "$name"
    done
}

load_config() {
    local vault_name="$1"
    local config_file
    config_file="$(config_path "$vault_name")"
    if [ ! -f "$config_file" ]; then
        local available
        available="$(list_vault_names)"
        if [ -z "$available" ]; then
            echo "Error: no vault named '$vault_name'. No vaults configured yet — run '$0 setup' first." >&2
        else
            echo "Error: no vault named '$vault_name'. Available vaults:" >&2
            echo "$available" | sed 's/^/  /' >&2
        fi
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$config_file"
}

write_config() {
    local config_file vault_name
    vault_name="$(vault_name "$VAULT_DIR")"
    config_file="$(config_path "$vault_name")"
    mkdir -p "$CONFIG_DIR"
    cat > "$config_file" << CONFIG_EOF
VAULT_DIR="$VAULT_DIR"
BACKUPS_DIR="$BACKUPS_DIR"
DEFAULT_BRANCH="$DEFAULT_BRANCH"
MAX_BUNDLES="$MAX_BUNDLES"
NOTIFY_SUCCESS="$NOTIFY_SUCCESS"
SCHEDULE_ENABLED="$SCHEDULE_ENABLED"
BACKUP_HOUR="$BACKUP_HOUR"
BACKUP_MINUTE="$BACKUP_MINUTE"
CONFIG_EOF
}

log_path() {
    echo "$HOME/Library/Logs/VaultBackup/$1.log"
}

app_path() {
    echo "$HOME/Applications/VaultBackup/$1.app"
}

plist_label() {
    echo "com.$(whoami).vault-backup-$1"
}

plist_path() {
    echo "$HOME/Library/LaunchAgents/$(plist_label "$1").plist"
}

cmd_setup() {
    local vault_dir=""

    if [ ! -f "$SHARED_SCRIPT_SRC" ]; then
        echo "Error: shared script not found at '$SHARED_SCRIPT_SRC'." >&2
        exit 1
    fi

    read -rp "Vault directory path: " vault_dir

    while true; do
        vault_dir="${vault_dir%/}"
        if [ -z "$vault_dir" ]; then
            echo "  Please enter a path."
            elif [ ! -d "$vault_dir" ]; then
            echo "  '$vault_dir' does not exist."
            elif ! git -C "$vault_dir" rev-parse > /dev/null 2>&1; then
            echo "  '$vault_dir' is not a git repository."
        else
            break
        fi
        read -rp "Vault directory path: " vault_dir
    done
    VAULT_DIR="$vault_dir"
    
    local vault_name vault_parent_dir default_backups_dir
    vault_name="$(vault_name "$VAULT_DIR")"
    vault_parent_dir="$(dirname "$VAULT_DIR")"
    default_backups_dir="$vault_parent_dir/$vault_name-backups"
    
    while true; do
        read -rp "Vault backups directory [$default_backups_dir]: " BACKUPS_DIR
        BACKUPS_DIR="${BACKUPS_DIR:-$default_backups_dir}"
        BACKUPS_DIR="${BACKUPS_DIR%/}"
        
        if [ -d "$BACKUPS_DIR" ]; then
            if [ -n "$(ls -A "$BACKUPS_DIR" 2>/dev/null)" ]; then
                echo "  '$BACKUPS_DIR' already exists and is not empty."
                continue
            fi
            break
        fi
        
        local backups_parent_dir
        backups_parent_dir="$(dirname "$BACKUPS_DIR")"
        if [ ! -d "$backups_parent_dir" ] || [ ! -w "$backups_parent_dir" ]; then
            echo "  '$backups_parent_dir' does not exist or isn't writable — can't create '$BACKUPS_DIR' there."
            continue
        fi
        
        read -rp "  '$BACKUPS_DIR' doesn't exist. Do you want to create it? [y/N]: " create_backups_dir
        if [[ ! "$create_backups_dir" =~ ^[Yy]$ ]]; then
            continue
        fi
        break
    done
    
    while true; do
        read -rp "Default vault branch [main]: " DEFAULT_BRANCH
        DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
        if [[ "$DEFAULT_BRANCH" =~ [[:space:]] ]]; then
            echo "  Branch name can't contain spaces."
            continue
        fi
        break
    done
    
    while true; do
        read -rp "Number of backups to keep [5]: " MAX_BUNDLES
        MAX_BUNDLES="${MAX_BUNDLES:-5}"
        if [[ ! "$MAX_BUNDLES" =~ ^[1-9][0-9]*$ ]]; then
            echo "  Enter a positive whole number."
            continue
        fi
        break
    done
    
    local existing_config
    existing_config="$(config_path "$vault_name")"
    NOTIFY_SUCCESS="false"
    SCHEDULE_ENABLED="false"
    BACKUP_HOUR="17"
    BACKUP_MINUTE="00"
    if [ -f "$existing_config" ]; then
        # shellcheck source=/dev/null
        source "$existing_config"
    fi
    
    mkdir -p "$HOME/.local/bin"
    echo "Installing shared backup script to $SHARED_SCRIPT_PATH ..."
    cp "$SHARED_SCRIPT_SRC" "$SHARED_SCRIPT_PATH"
    chmod +x "$SHARED_SCRIPT_PATH"
    mkdir -p "$BACKUPS_DIR"
    
    write_config
    
    echo ""
    echo "Vault set up:"
    echo "  Vault:          $VAULT_DIR"
    echo "  Backups dir:    $BACKUPS_DIR"
    echo "  Default branch: $DEFAULT_BRANCH"
    echo "  Max backups:    $MAX_BUNDLES"
    echo ""
    echo "Run a backup now:      $0 backup $vault_name"
    echo "Enable daily schedule: $0 schedule on $vault_name"
}

cmd_backup() {
    local vault_name="${1:-}"
    [ -z "$vault_name" ] && usage
    load_config "$vault_name"
    
    local log_file
    log_file="$(log_path "$vault_name")"
    mkdir -p "$(dirname "$log_file")"
    
    echo "Backing up '$VAULT_DIR' to '$BACKUPS_DIR' ..."
    local status=0
    "$SHARED_SCRIPT_PATH" "$VAULT_DIR" "$BACKUPS_DIR" "$DEFAULT_BRANCH" "$MAX_BUNDLES" "$log_file" "$NOTIFY_SUCCESS" "false" "manual" || status=$?
    tail -n 1 "$log_file"
    exit "$status"
}

cmd_schedule() {
    local action="${1:-}"
    local vault_name="${2:-}"
    [ -z "$action" ] || [ -z "$vault_name" ] && usage

    case "$action" in
        on) cmd_schedule_on "$vault_name" ;;
        off) cmd_schedule_off "$vault_name" ;;
        *) usage ;;
    esac
}

cmd_schedule_on() {
    local vault_name="$1"
    load_config "$vault_name"
    
    if [ ! -f "$PLIST_TEMPLATE_SRC" ]; then
        echo "Error: plist template not found at '$PLIST_TEMPLATE_SRC'." >&2
        exit 1
    fi
    if [ ! -f "$APPLESCRIPT_TEMPLATE_SRC" ]; then
        echo "Error: applescript template not found at '$APPLESCRIPT_TEMPLATE_SRC'." >&2
        exit 1
    fi
    
    read -rp "Daily backup time, HH:MM [${BACKUP_HOUR:-17}:${BACKUP_MINUTE:-00}]: " backup_time
    if [ -n "$backup_time" ]; then
        while [[ ! "$backup_time" =~ ^([0-1][0-9]|2[0-3]):([0-5][0-9])$ ]]; do
            echo "  Enter a time as HH:MM, 24-hour clock (e.g. 09:30, 17:00)."
            read -rp "Daily backup time, HH:MM: " backup_time
        done
        BACKUP_HOUR="${backup_time%:*}"
        BACKUP_MINUTE="${backup_time#*:}"
    fi
    BACKUP_HOUR="${BACKUP_HOUR:-17}"
    BACKUP_MINUTE="${BACKUP_MINUTE:-00}"
    
    local app_path plist_label plist_path log_file
    app_path="$(app_path "$vault_name")"
    plist_label="$(plist_label "$vault_name")"
    plist_path="$(plist_path "$vault_name")"
    log_file="$(log_path "$vault_name")"
    
    local app_created=0
    local plist_created=0
    rollback() {
        echo "" >&2
        echo "Enabling schedule failed — rolling back ..." >&2
        launchctl bootout "gui/$(id -u)/$plist_label" > /dev/null 2>&1 || true
        [ "$plist_created" -eq 1 ] && rm -f "$plist_path"
        [ "$app_created" -eq 1 ] && rm -rf "$app_path"
    }
    trap rollback ERR
    
    mkdir -p "$(dirname "$app_path")" "$(dirname "$log_file")"
    
    echo "Creating $app_path ..."
    rm -rf "$app_path"
    local tmp_applescript
    tmp_applescript="$(mktemp /tmp/vault-backup-XXXXXX.applescript)"
    sed -e "s#__SHARED_SCRIPT_PATH__#$SHARED_SCRIPT_PATH#g" \
    -e "s#__VAULT_DIR__#$VAULT_DIR#g" \
    -e "s#__BACKUPS_DIR__#$BACKUPS_DIR#g" \
    -e "s#__DEFAULT_BRANCH__#$DEFAULT_BRANCH#g" \
    -e "s#__MAX_BUNDLES__#$MAX_BUNDLES#g" \
    -e "s#__LOG_PATH__#$log_file#g" \
    -e "s#__NOTIFY_SUCCESS__#$NOTIFY_SUCCESS#g" \
    "$APPLESCRIPT_TEMPLATE_SRC" > "$tmp_applescript"
    osacompile -o "$app_path" "$tmp_applescript"
    rm -f "$tmp_applescript"
    app_created=1
    
    echo "Creating $plist_path ..."
    sed -e "s#__LABEL__#$plist_label#g" \
    -e "s#__PROGRAM_ARG__#$app_path/Contents/MacOS/applet#g" \
    -e "s#__HOUR__#$BACKUP_HOUR#g" \
    -e "s#__MINUTE__#$BACKUP_MINUTE#g" \
    -e "s#__LOG_PATH__#$log_file#g" \
    "$PLIST_TEMPLATE_SRC" > "$plist_path"
    plist_created=1
    
    echo "Registering launchd job ..."
    launchctl bootout "gui/$(id -u)/$plist_label" > /dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$plist_path"
    
    trap - ERR
    
    SCHEDULE_ENABLED="true"
    write_config
    
    echo ""
    echo "Scheduled daily at $BACKUP_HOUR:$BACKUP_MINUTE."
    echo ""
    echo "Test it immediately without waiting for the schedule:"
    echo "  launchctl kickstart -k gui/\$(id -u)/$plist_label"
    echo "  tail -f $log_file"
}

cmd_schedule_off() {
    local vault_name="$1"
    load_config "$vault_name"
    
    local plist_label plist_path app_path
    plist_label="$(plist_label "$vault_name")"
    plist_path="$(plist_path "$vault_name")"
    app_path="$(app_path "$vault_name")"
    
    echo "Disabling schedule for '$VAULT_DIR' ..."
    launchctl bootout "gui/$(id -u)/$plist_label" > /dev/null 2>&1 || true
    rm -f "$plist_path"
    rm -rf "$app_path"
    
    SCHEDULE_ENABLED="false"
    write_config
    
    echo "Schedule disabled. On-demand backups (\"$0 backup\") still work."
}

cmd_notify() {
    local action="${1:-}"
    local vault_name="${2:-}"
    [ -z "$action" ] || [ -z "$vault_name" ] && usage

    load_config "$vault_name"
    
    case "$action" in
        on) NOTIFY_SUCCESS="true" ;;
        off) NOTIFY_SUCCESS="false" ;;
        *) usage ;;
    esac
    
    write_config
    echo "Success notifications for scheduled runs: $NOTIFY_SUCCESS"
}

cmd_info() {
    local vault_name="${1:-}"
    [ -z "$vault_name" ] && usage
    load_config "$vault_name"

    echo "Vault:             $VAULT_DIR"
    echo "Backups dir:       $BACKUPS_DIR"
    echo "Default branch:    $DEFAULT_BRANCH"
    echo "Max backups:       $MAX_BUNDLES"
    echo "Notify success:    $NOTIFY_SUCCESS"
    echo "Schedule enabled:  $SCHEDULE_ENABLED"
    echo "Backup time:       $BACKUP_HOUR:$BACKUP_MINUTE"
    echo ""
    echo "Config file:       $(config_path "$vault_name")"
    echo "Log file:          $(log_path "$vault_name")"
    echo "App bundle:        $(app_path "$vault_name")"
    echo "LaunchAgent label: $(plist_label "$vault_name")"
    echo "LaunchAgent plist: $(plist_path "$vault_name")"
}

[ $# -lt 1 ] && usage

case "$1" in
    setup) cmd_setup ;;
    backup) shift; cmd_backup "$@" ;;
    schedule) shift; cmd_schedule "$@" ;;
    notify) shift; cmd_notify "$@" ;;
    info) shift; cmd_info "$@" ;;
    *) usage ;;
esac
