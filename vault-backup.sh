#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$REPO_DIR/config"

# --------------------------------------------------------------- output

usage() {
	cat <<USAGE
Usage:
  vault-backup backup <vault-name>   run a backup now
  vault-backup setup [vault-name]    add a vault, or re-answer an existing vault's questions
  vault-backup list                  list configured vaults and their settings
USAGE
}

usage_error() {
	usage >&2
	exit 1
}

log() {
	echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $1"
}

fail() {
	log "Error: $1"
	if [ -n "${2:-}" ]; then
		log "   $2"
	fi
	exit 1
}

# --------------------------------------------------------------- config

config_path() {
	echo "$CONFIG_DIR/$1.conf"
}

# vault names end up in config and bundle file names, and in glob patterns,
# so reject anything that isn't a safe, simple file name:
#   ""              empty
#   -*              leading dash (ls/rm would read it as an option)
#   */*             path separators
#   *[[:space:]]*   whitespace (bundle names would no longer be one word)
#   *[*?[]*         glob metacharacters (*, ?, [). the prune pattern is a
#                   glob, so a name like 'notes*' could match other vaults'
#                   bundles and delete them
vault_name_is_valid() {
	case "$1" in
	"" | -* | */* | *[[:space:]]* | *[*?[]*) return 1 ;;
	esac
	return 0
}

validate_vault_name() {
	vault_name_is_valid "$1" || {
		echo "Error: invalid vault name '$1'." >&2
		exit 1
	}
}

list_vault_names() {
	local config_file name
	# if no .conf exists, the glob stays a literal string; the -f test
	# filters that out (bash has no nullglob here)
	for config_file in "$CONFIG_DIR"/*.conf; do
		[ -f "$config_file" ] || continue
		name="$(basename "$config_file" .conf)"
		echo "$name"
	done
}

find_vault_by_path() {
	local wanted="$1" config_file
	for config_file in "$CONFIG_DIR"/*.conf; do
		[ -f "$config_file" ] || continue
		# shellcheck source=/dev/null
		source "$config_file"
		if [ "${VAULT_DIR:-}" = "$wanted" ]; then
			basename "$config_file" .conf
			return 0
		fi
	done
	return 1
}

load_vault_config() {
	local vault_name="$1" next_step="$2"
	local config_file
	config_file="$(config_path "$vault_name")"
	if [ ! -f "$config_file" ]; then
		local available
		available="$(list_vault_names)"
		if [ -z "$available" ]; then
			echo "Error: no vault named '$vault_name'. No vaults configured yet — $next_step." >&2
		else
			echo "Error: no vault named '$vault_name'. Available vaults:" >&2
			# indent each name by two spaces
			echo "  ${available//$'\n'/$'\n'  }" >&2
		fi
		exit 1
	fi
	# shellcheck source=/dev/null
	source "$config_file"
}

save_vault_config() {
	local vault_name="$1"
	mkdir -p "$CONFIG_DIR" "$BACKUPS_DIR"
	cat >"$(config_path "$vault_name")" <<CONFIG_EOF
VAULT_DIR="$VAULT_DIR"
BACKUPS_DIR="$BACKUPS_DIR"
DEFAULT_BRANCH="$DEFAULT_BRANCH"
MAX_BUNDLES="$MAX_BUNDLES"
CONFIG_EOF
	echo "Vault configured (saved to $(config_path "$vault_name")):"
	print_vault_settings
	echo ""
}

print_vault_settings() {
	echo "  Vault:          $VAULT_DIR"
	echo "  Backups dir:    $BACKUPS_DIR"
	echo "  Default branch: $DEFAULT_BRANCH"
	echo "  Max backups:    $MAX_BUNDLES"
}

# --------------------------------------------------------------- prompts

prompt_vault_dir() {
	local current="${VAULT_DIR:-}" vault_dir
	while true; do
		read -rp "Vault directory path${current:+ [$current]}: " vault_dir
		vault_dir="${vault_dir:-$current}"
		vault_dir="${vault_dir%/}"
		if [ -z "$vault_dir" ]; then
			echo "  Please enter a path."
		elif [ ! -d "$vault_dir" ]; then
			echo "  '$vault_dir' does not exist."
			# rev-parse exits non-zero outside a git repository, the cheapest
			# "is this a repo" test
		elif ! git -C "$vault_dir" rev-parse >/dev/null 2>&1; then
			echo "  '$vault_dir' is not a git repository."
			# a bare repo passes the rev-parse test but has no working files
			# to back up (git status fails in one too)
		elif [ "$(git -C "$vault_dir" rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then
			echo "  '$vault_dir' is a bare repository — vault-backup needs a working copy."
			# unborn branch: rev-parse HEAD fails until the first commit exists
		elif ! git -C "$vault_dir" rev-parse --verify -q HEAD >/dev/null 2>&1; then
			echo "  '$vault_dir' has no commits yet — make an initial commit first."
		else
			break
		fi
	done
	VAULT_DIR="$vault_dir"
}

prompt_backup_settings() {
	local current_backups_dir="${BACKUPS_DIR:-}"
	local current_branch="${DEFAULT_BRANCH:-}"
	local current_max_bundles="${MAX_BUNDLES:-}"

	local default_backups_dir
	default_backups_dir="$current_backups_dir"
	if [ -z "$default_backups_dir" ]; then
		default_backups_dir="$(dirname "$VAULT_DIR")/$(basename "${VAULT_DIR%/}")-backups"
	fi

	while true; do
		read -rp "Vault backups directory [$default_backups_dir]: " BACKUPS_DIR
		BACKUPS_DIR="${BACKUPS_DIR:-$default_backups_dir}"
		BACKUPS_DIR="${BACKUPS_DIR%/}"
		if [ -d "$BACKUPS_DIR" ]; then
			# keeping the current backups dir is fine even though it holds bundles
			if [ "$BACKUPS_DIR" = "$current_backups_dir" ] || [ -z "$(ls -A "$BACKUPS_DIR" 2>/dev/null)" ]; then
				break
			fi
			echo "  '$BACKUPS_DIR' already exists and is not empty."
			# save_vault_config mkdir -p's the dir itself, so only the parent
			# needs to exist and be writable at this point
		elif [ ! -d "$(dirname "$BACKUPS_DIR")" ] || [ ! -w "$(dirname "$BACKUPS_DIR")" ]; then
			echo "  '$(dirname "$BACKUPS_DIR")' does not exist or isn't writable — can't create '$BACKUPS_DIR' there."
		else
			local create
			read -rp "  '$BACKUPS_DIR' doesn't exist. Do you want to create it? [y/N]: " create
			[[ "$create" =~ ^[Yy]$ ]] && break
		fi
	done

	while true; do
		read -rp "Default vault branch [${current_branch:-main}]: " DEFAULT_BRANCH
		DEFAULT_BRANCH="${DEFAULT_BRANCH:-${current_branch:-main}}"
		[[ "$DEFAULT_BRANCH" =~ [[:space:]] ]] && {
			echo "  Branch name can't contain spaces."
			continue
		}
		break
	done

	while true; do
		read -rp "Number of backups to keep [${current_max_bundles:-5}]: " MAX_BUNDLES
		MAX_BUNDLES="${MAX_BUNDLES:-${current_max_bundles:-5}}"
		[[ "$MAX_BUNDLES" =~ ^[1-9][0-9]*$ ]] && break
		echo "  Enter a positive whole number."
	done
}

# --------------------------------------------------------------- backup

run_backup() {
	local vault_name="$1"

	# bundle names key off the vault name, so renaming the vault directory
	# doesn't invalidate existing bundles
	if [ ! -d "$VAULT_DIR" ]; then
		fail "vault directory not found: $VAULT_DIR" \
			"move it back, or run 'vault-backup setup $vault_name' to point the vault at its new location"
	fi
	if [ ! -d "$BACKUPS_DIR" ]; then
		fail "backups directory not found: $BACKUPS_DIR" \
			"move it back, or run 'vault-backup setup $vault_name' to choose a new one"
	fi

	cd "$VAULT_DIR"

	# a repo with no commits yet would crash the branch check below (unborn
	# HEAD). usually unreachable since setup requires a commit, but history
	# can be rewritten back to zero
	if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
		fail "vault has no commits yet — make an initial commit first"
	fi

	# only ever back up the default branch: switching branches (e.g.
	# mid-experiment) pauses backups instead of polluting another branch with
	# an auto-backup commit
	local current_ref
	current_ref="$(git rev-parse --abbrev-ref HEAD)"
	if [ "$current_ref" != "$DEFAULT_BRANCH" ]; then
		fail "not on '$DEFAULT_BRANCH' branch"
	fi

	# commit any pending changes so they're included in the bundle
	if [ -n "$(git status --porcelain)" ]; then
		git add -A
		if ! git commit -m "backup: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >/dev/null; then
			fail "commit failed"
		fi
		log "committed pending changes"
	fi

	# sweep leftovers from earlier interrupted runs, including git's own
	# .lock file, which is what's left if git itself is killed mid-create.
	# before the skip-check, so no-change runs still clean up. .tmp files
	# don't end in .bundle, so they never match the skip-check or the prune
	# pattern; an interrupted create can't be mistaken for a complete backup.
	rm -f -- "$BACKUPS_DIR/$vault_name"-*.bundle.tmp "$BACKUPS_DIR/$vault_name"-*.bundle.tmp.lock

	# skip the backup entirely if a bundle for the current commit already exists
	local current_sha_short
	current_sha_short="$(git rev-parse --short HEAD)"
	# ls is a glob-match test here: exit 0 iff at least one bundle
	# for this commit exists
	if ls "$BACKUPS_DIR/$vault_name"-*-"$current_sha_short".bundle >/dev/null 2>&1; then
		log "no changes since last backup"
		return
	fi

	local bundle_name bundle_path tmp_path
	# UTC ISO timestamp is zero-padded, so lexical order = chronological
	# order; the prune below depends on that
	bundle_name="$vault_name-$(date -u '+%Y%m%dT%H%M%SZ')-$current_sha_short.bundle"
	bundle_path="$BACKUPS_DIR/$bundle_name"
	# publish with a same-dir rename (atomic): a bundle only ever appears
	# complete, and only after it has verified
	tmp_path="$bundle_path.tmp"

	# --all: every ref rides along (side branches included); extra safety,
	# experiment branches get backed up too
	if ! git bundle create "$tmp_path" --all >/dev/null; then
		rm -f -- "$tmp_path"
		fail "bundle creation failed"
	fi

	if ! git bundle verify "$tmp_path" >/dev/null 2>&1; then
		rm -f -- "$tmp_path"
		fail "bundle verification failed"
	fi

	mv -- "$tmp_path" "$bundle_path"
	log "created bundle: $bundle_name"

	# keep only the $MAX_BUNDLES latest bundles, prune the rest.
	# ls (not find) is deliberate: the timestamped names sort lexically, so
	# reverse-lexically = newest first. IFS= guards against whitespace in
	# names; only log "pruned" if rm succeeded.
	# shellcheck disable=SC2012
	(
		cd "$BACKUPS_DIR"
		ls -r "$vault_name"-*.bundle 2>/dev/null | tail -n +"$((MAX_BUNDLES + 1))" | while IFS= read -r old_bundle; do
			rm -f -- "$old_bundle" && log "pruned old bundle: $old_bundle"
		done
	)

	log "backup run completed successfully"
}

# --------------------------------------------------------------- commands

cmd_backup() {
	local vault_name="${1:-}"
	# short-circuit && is safe under set -e: a false test in a && list doesn't
	# exit the shell (but does leave $? = 1, so this can't be the last line)
	[ -z "$vault_name" ] && usage_error
	validate_vault_name "$vault_name"
	load_vault_config "$vault_name" "run 'vault-backup setup $vault_name' first"

	echo "Backing up '$VAULT_DIR' to '$BACKUPS_DIR' ..."
	run_backup "$vault_name"
}

# re-answer an existing vault's questions. the name is fixed: bundles are
# named after it.
setup_vault_by_name() {
	local vault_name="$1"
	validate_vault_name "$vault_name"
	load_vault_config "$vault_name" "run 'vault-backup setup' to add one"

	echo "Press Enter to keep the current value."
	prompt_vault_dir
	prompt_backup_settings
	save_vault_config "$vault_name"
}

# add a vault. its name is its directory's basename: config file and bundle
# names all key off it, so there's nothing to choose.
setup_new_vault() {
	prompt_vault_dir

	local vault_name
	vault_name="$(basename "${VAULT_DIR%/}")"
	# the name was derived, not typed: make sure it's safe the same way a
	# typed one would be
	vault_name_is_valid "$vault_name" || {
		echo "Error: the directory name '$vault_name' can't be used as a vault name (no spaces, '/', or wildcard characters) — rename the folder and run setup again." >&2
		exit 1
	}

	local existing_name
	if existing_name="$(find_vault_by_path "$VAULT_DIR")"; then
		# same vault, re-run: fall into update mode rather than duplicating
		echo "Vault '$VAULT_DIR' is already configured as '$existing_name' — updating its settings."
		echo "Press Enter to keep the current value."
		# shellcheck source=/dev/null
		source "$(config_path "$existing_name")"
		prompt_backup_settings
		vault_name="$existing_name"
	elif [ -f "$(config_path "$vault_name")" ]; then
		echo "Error: vault name '$vault_name' is already used for $(sed -n 's/^VAULT_DIR="\(.*\)"$/\1/p' "$(config_path "$vault_name")")." >&2
		echo "If this is a different vault, rename one of the folders and run setup again." >&2
		exit 1
	else
		prompt_backup_settings
	fi

	save_vault_config "$vault_name"
}

cmd_setup() {
	if [ $# -ge 1 ]; then
		setup_vault_by_name "$1"
	else
		setup_new_vault
	fi
}

cmd_list() {
	local config_file found=""
	for config_file in "$CONFIG_DIR"/*.conf; do
		[ -f "$config_file" ] || continue
		found=1
		# shellcheck source=/dev/null
		source "$config_file"
		echo "$(basename "$config_file" .conf):"
		print_vault_settings
		echo ""
	done
	if [ -z "$found" ]; then
		echo "No vaults configured yet — run 'vault-backup setup' to add one."
	fi
}

# --------------------------------------------------------------- dispatch

main() {
	[ $# -lt 1 ] && usage_error
	case "$1" in
	backup)
		shift
		cmd_backup "$@"
		;;
	setup)
		shift
		cmd_setup "$@"
		;;
	list) cmd_list ;;
	help | -h | --help) usage ;;
	*) usage_error ;;
	esac
}

main "$@"
