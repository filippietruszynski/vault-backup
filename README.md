# vault-backup

> **Work in progress.** This README describes the tool's intended shape; details may still change.

A manual backup tool for git-based note vaults. Run `vault-backup backup <vault-name>` when you want a snapshot, and the tool:

- commits any uncommitted changes in the vault,
- stores a self-contained `git bundle` (one file = the whole repo history) in a folder of your choosing,
- verifies the bundle before publishing it, and prunes old bundles past a limit you configure.

Restoring is plain git: cloning from a bundle gives you a fresh working copy. Bundles are plain single files, so any folder syncer (Google Drive, Dropbox, ...).

It runs on any Unix with bash and git. Built for an Obsidian vault kept in a Google Drive-synced folder, but not locked to either; the Motivation section below explains why.

## Motivation

My notes live in an Obsidian vault. That part is my choice. The folder being synced by Google Drive is not: it's a constraint I had to work within, and it shapes everything else. Obsidian's own version history and other sync-based history options weren't available for me, so **git is my change history**. GitHub as a remote wasn't a choice either, so the usual "just push it" answer to backups was off the table too.

Git alone doesn't give me a backup, though. The whole history lives in the same folder that Google Drive is actively syncing, and that's fragile for two reasons. First, syncers and the git internals don't mix well: files like Obsidian's workspace and plugin settings change constantly and are the first to turn into sync conflict copies, and a syncer catching the .git directory mid-write can corrupt the repo itself. Second, the synced folder holds the only copy of the history, so if it gets mangled, you'd be depending on Drive's own version history to get it back.

For the snapshot format I picked `git bundle`, the native, simplest way to snapshot a git repo: one bundle file = the whole repo history, and a plain single file is exactly the kind of thing a folder syncer handles well.

Each backup is a new dated bundle rather than a single file that keeps getting overwritten. A syncer can corrupt a file, and if there's only one bundle, a single corruption can take out the only copy. With more than one, the odds of being left with no working backup get smaller and smaller.

## Requirements

- A Unix system with **bash** and **git**. No other dependencies.
- The vault must be a git repository with at least one commit.
- A folder syncer for the backups folder (the instructions below use Google Drive, but anything goes).

## Installation

1. Clone this repo somewhere permanent.

2. Add an alias to your shell's rc file (`~/.zshrc`, `~/.bashrc`, ...) pointing at the script's real location:

   ```bash
   alias vault-backup="$HOME/permanent/path/vault-backup/vault-backup.sh"
   ```

3. `source` that rc file (or open a new terminal).

The alias must point at the real path: the script looks for its `config/` directory next to itself, so a symlink placed elsewhere won't work.

## Setup

```bash
vault-backup setup
```

You'll be asked for:

| Prompt | Meaning | Default |
| --- | --- | --- |
| Vault directory path | the git repo to back up (must have ≥1 commit) | no default |
| Vault backups directory | where bundle files go | `<vault>-backups` next to the vault |
| Default vault branch | the branch backups run on | `main` |
| Number of backups to keep | how many bundles to keep before pruning | `5` |

Answers are saved to `config/<vault-name>.conf` inside the clone (gitignored). The vault's **name is its directory's basename**: it keys the config file and bundle names, and must be a plain filename (no spaces, `/`, or wildcard characters).

To change a vault's settings later: `vault-backup setup <vault-name>`. Current values are the defaults; press Enter to keep one. The name can't be changed (bundles are named after it).

### Setting up folder sync for backups

The backups folder from above (the **Vault backups directory**) is where the bundles go, and it's the only thing that needs to sync. Nothing in this tool talks to Google Drive: the only requirement is that this folder is set for Drive to sync. That's it.

Sync the folder with **"Folders from your computer"** in the Drive for desktop preferences. The folder stays at its original path on disk, syncs both ways, and its cloud copy shows up under the "Computers" section in the Drive web UI (not inside My Drive). Your vault and its backups can live wherever you like. Follow [Google's official instructions](https://support.google.com/drive/answer/2374987) to set it up.

Another possible way is to put the backups folder inside Drive's own local folder (the one that mirrors My Drive) and point setup at it; its contents sync to My Drive. This chains your backups to wherever Drive keeps its folder, so "Folders from your computer" is the recommended option.

> And to be clear: **it doesn't have to be Google Drive**. Any folder syncer (Dropbox, OneDrive, Syncthing, ...), or no syncer at all, works the same. The tool only cares about the two directory paths you give it.

## Daily use

```bash
vault-backup backup <vault-name>
```

That's it. Safe to run any time, safe to run repeatedly; a run with nothing new just says so.

Other commands:

```bash
vault-backup list    # show configured vaults and their settings
vault-backup help    # usage
```

## Restoring your notes

**Read this once now, not during an emergency.** Every bundle is a complete, standalone git history:

```bash
git bundle verify <path-to-bundle>.bundle      # sanity-check it
git clone <path-to-bundle>.bundle my-restored-notes
```

That gives you a fresh working copy. Nothing about the original vault is touched.

## How a backup run works

1. **Commits** any uncommitted changes in the vault as `backup: <utc-timestamp>`. A snapshot with uncommitted work isn't a snapshot.
2. **Skips** if a bundle for the current commit already exists (nothing changed).
3. **Creates** the bundle as `<name>.bundle.tmp`, **verifies** it with `git bundle verify`, then atomically renames it into place. A bundle file only ever exists complete and verified.
4. **Prunes** oldest bundles beyond the configured count.

## Design decisions and trade-offs

- **The tool commits on your behalf.** Uncommitted vault work gets a `backup:` commit on your current branch. That's deliberate (it's the price of "nothing is missed"), but it means the tool writes to your repo, not just reads it. If you keep half-finished work uncommitted for long, you'll see backup commits accumulate; they're ordinary commits, squash or drop them as you like.
- **Only the default branch is backed up directly.** On any other branch, backup refuses: pausing backups beats polluting an experiment branch with backup commits. (Side branches *are* included in bundle contents via `--all`, so in a restored copy they survive.)
- **Bundles contain `--all` refs.** Restoring brings back every branch, not just the default one.
- **Bundle names are `<vault>-<UTC-timestamp>-<sha>.bundle`.** The zero-padded UTC timestamp sorts lexically = chronologically, which is what the prune step relies on.
- **Vault names are strictly validated.** Names end up inside glob patterns used for pruning, so anything glob-active or path-like (`*`, `?`, `[`, `/`, spaces, leading `-`) is rejected, and a bad name can't make the tool delete another vault's bundles.
- **Config files are sourced, not parsed.** `config/*.conf` must stay plain `KEY="value"` lines; values aren't escaped. Editing them by hand means editing shell code, so keep that shape.
- **Each run adds a new bundle; old ones are pruned, not overwritten.** One corrupted bundle never leaves you with nothing; there are others to restore from (the reasoning is in the Motivation section).
- **Failures are loud and immediate.** A failed run prints the reason and exits non-zero, leaving nothing half-published (the atomic rename above).

## Risks and limitations

- **Nothing runs automatically.** This is a deliberate, manual command. If you don't run it, you don't have a recent backup. Wrap it in cron/launchd yourself if you want schedules.
- **Bundles are unencrypted.** Whoever can read the backups folder can read your notes. Keep the folder somewhere as trusted as the vault itself.
- **Don't rewrite history past backed-up points.** If you `git reset --hard` to before the last bundle, the tool won't "un-backup" you: the working repo just stays where you put it. The bundles still hold the lost commits.
- **Don't touch bundle files by hand.** Creating, renaming, or deleting them corrupts the tool's bookkeeping (dedup and pruning key off exact names).
- **Moved folders are detected, not followed.** If the vault or backups folder moves, `backup` fails with a clear error. Re-run `vault-backup setup <vault-name>` to re-point it. Nothing is lost; bundle names don't depend on directory locations.
- **`git bundle verify` isn't a checksum.** It can't detect corruption introduced *after* the backup ran, e.g. a folder syncer like Google Drive truncating or conflicting the file.

## Development

Layout, linting, and formatting conventions: see [DEVELOPMENT.md](./DEVELOPMENT.md).

## License

MIT. See [LICENSE](./LICENSE).
