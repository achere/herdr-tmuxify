# herdr-tmuxify — design

**Date:** 2026-10-25
**Status:** design approved in conversation; written spec awaiting review. Nothing
is implemented yet.

## Goal

A public repository that anyone running [herdr](https://herdr.dev) can clone to
make it behave like tmux: tmux's key bindings, tmux's confirm-before-kill
prompts, tmux's `display-panes` (`prefix q`), and tmux-style numbering of
windows (tabs) and sessions (spaces). One command installs it. The same command
undoes it.

Success means a stranger with a working herdr and their own `config.toml` can run
`./install.sh`, press `prefix` + the usual tmux keys, and get the tmux behaviour,
without losing any of their own settings, and can remove all of it with
`./install.sh --uninstall`.

## Context and constraints

- **Origin.** The content is a snapshot of the author's personal setup in
  `~/dotfiles/herdr/.config/herdr` (taken at dotfiles commit `a94f29d`). That
  setup mixes tmux emulation with personal taste. This repo carries only the
  tmux emulation.
- **The dotfiles repo is not touched.** It keeps its own copy. No sync, no
  dependency in either direction. The two copies drift after the snapshot, by
  design.
- **herdr has no config include mechanism.** `config.toml` is one file. Installing
  into a user's existing file therefore means editing it.
- **herdr plugin registry** is machine-local (`plugins.json`). Plugins must be
  registered with `herdr plugin link`; copying files is not enough.
- **Platforms:** macOS and Linux. Windows is out of scope: the installer and
  plugins rely on bash, perl and `stty`. Linux and macOS use the same config
  path, `~/.config/herdr/config.toml`; `HERDR_CONFIG_PATH` overrides it.
- **herdr version:** `min_herdr_version = "0.9.1"` (as the plugins declare today).
  Tests run against the current stable release.
- **Dependencies:** `herdr`, `bash` (3.2 compatible: macOS ships 3.2), `perl`
  (core modules only), `jq` (used by the close-confirm popups). The installer
  checks for them and names what is missing; it does not install packages.

## Scope

### In: everything that exists to make herdr behave like tmux

| Piece | Behaviour |
|---|---|
| `[keys]` bindings | `split_horizontal = 'prefix+"'` (stacked), `split_vertical = "prefix+percent"` (side by side), `detach = "prefix+d"`, `rename_tab = "prefix+comma"`, `workspace_picker = "prefix+s"`, `settings = "prefix+shift+s"`, `last_pane = "prefix+semicolon"`, `copy_mode = "prefix+["`, `navigate_workspace_up = "k"`, `navigate_workspace_down = "j"`. `close_pane = ""` and `close_tab = ""` (the popups below replace them). |
| Confirm popups | `prefix+x` asks before closing a pane; `prefix+ampersand` asks before closing a tab. Single keypress, `y`/`Y` confirms, anything else declines. Need `jq` and `bash`. |
| `display-panes` plugin | `prefix+q` paints a number on each pane; a digit focuses that pane; any other key or 3 s closes it. |
| `numbering` plugin | Keeps tab numbers in tab names and space numbers in the sidebar. Ships with `switch_workspace = "prefix+shift+1..9"` and the sidebar row `rows = [["state_icon", "$n", "workspace"], ["branch", "git_status"]]`. |
| Prefix | Not set by default: herdr's own `ctrl+b` is stock tmux's prefix. `./install.sh --prefix KEY` sets another (for example `ctrl+space`). |

The exact values are copied from the author's `config.toml`; the key-name
spellings (`'prefix+"'`, `prefix+percent`, `prefix+[`) were confirmed by pressing
the keys and must not be "normalised". `herdr config check` only proves a key
name parses, not which physical key it matches.

### Out: stays in the author's dotfiles

The one-dark theme, `pane_borders` / `pane_outer_borders`, the `sysload`
tab-bar readout, `agent_panel_sort`, OS toasts, `pane_history`, `focus_agent`
(`alt+1..9`), the space-usage plugin's `$usage` row, and the pi/claude agent
integrations.

### Non-goals

Windows. Installing herdr or `jq` for the user. A Homebrew tap or packaged CLI.
Installing the plugins with `herdr plugin install owner/repo/subdir` (possible
later by swapping one command in the installer). Syncing with the author's
dotfiles.

## Repository layout

```
herdr-tmuxify/
  install.sh              the only entry point
  lib/merge.pl            tagged-line merge / unmerge of config.toml
  config/
    keys.toml             lines for [keys]
    ui.toml               the sidebar rows line for [ui.sidebar.spaces]
    commands.toml         [[keys.command]] blocks: two popups + display-panes
  plugins/
    numbering/            herdr-plugin.toml, renumber.sh, renumber_test.sh
    display-panes/        herdr-plugin.toml, display-panes.pl, display-panes.t
  test/
    run.sh                installer tests (runs on macOS and Linux)
    linux.sh              runs everything in a Lima Debian VM
  .github/workflows/test.yml
  README.md  LICENSE  AGENTS.md  CLAUDE.md -> AGENTS.md
  docs/specs/             this document
```

The bindings live in `config/*.toml` as plain data. `merge.pl` contains no
keybindings.

### Changes to the snapshotted plugins

- Plugin ids `dotfiles.numbering` / `dotfiles.display-panes` become
  `herdr-tmuxify.numbering` / `herdr-tmuxify.display-panes`. The `prefix+q`
  binding in `commands.toml` points at `herdr-tmuxify.display-panes.show`.
- `platforms = ["macos", "linux"]` in both manifests.
- `numbering/renumber.sh`: the lock-staleness check uses BSD `stat -f %m`. On
  GNU `stat`, `-f` means filesystem status, so the check fails silently and a
  stuck lock never expires. Replace it with a portable mtime read through perl.
  Any further GNU/BSD differences the Linux run exposes get the same treatment.
- Comments are rewritten for a reader who has never seen the author's setup:
  no "the user confirmed", no references to `tmux.conf`, `.zshrc`, stow or
  other dotfiles paths. Technical lessons (why a key is spelled a certain way,
  why a plugin is needed instead of a plain popup) stay.

## Installer

`./install.sh [--prefix KEY] [--force] [--dry-run] [--uninstall]`

1. **Preflight.** Check `herdr` ≥ 0.9.1, `bash`, `perl`, `jq`. Name anything
   missing, with a package-manager-neutral message (plus a `brew install` hint
   on macOS), and exit non-zero.
2. **Locate config.** `$HERDR_CONFIG_PATH` if set, else
   `~/.config/herdr/config.toml`. If the file does not exist, start from an
   empty one.
3. **Backup.** Before the first change, copy the file to
   `config.toml.tmuxify-bak.<YYYYmmddHHMMSS>`.
4. **Merge** through `lib/merge.pl`. Every line the installer adds ends in
   `# herdr-tmuxify`.
   - *Scalar keys* (the `[keys]` bindings, `prefix`, sidebar `rows`) go under
     their table, which is created if missing. A key the user already set is
     skipped and reported. A key the user set to the same value counts as
     already applied. A commented-out key counts as unset.
   - *`--force`* replaces the user's scalar line and keeps the original as
     `# herdr-tmuxify-replaced: <original line>`, so uninstall can restore it.
     It applies only to single-line values; a multi-line user value is skipped
     and reported even with `--force`.
   - *Command bindings* (`[[keys.command]]`) go in one block at the end of the
     file between `# >>> herdr-tmuxify >>>` and `# <<< herdr-tmuxify <<<`.
     A block whose `key` is already used by another `[[keys.command]]` is
     skipped and reported; `--force` does not override it.
   - *Companion rule.* The `prefix+q` block must not coexist with a `detach`
     bound to `prefix+q`, and the `prefix+x` block not with a `close_pane`
     bound to `prefix+x`. If the user's own `detach` / `close_pane` value keeps
     herdr's chord, the block is skipped and reported. Whether `herdr config
     check` already reports duplicate chords is an open item below.
   - *Unsupported shapes.* If `keys` is written as a dotted key or an inline
     table, the installer makes no edit, prints the lines to add by hand, and
     exits non-zero.
   - *Symlinked config.* If `config.toml` is a symlink (stow users), write
     through it. Never rename a temp file over it.
5. **Validate.** Run `herdr config check` on the merged file. If it prints any
   diagnostic that the original file did not, restore the backup and abort.
6. **Plugins.** `herdr plugin link <repo>/plugins/numbering` and
   `.../display-panes`. Linking is idempotent. The repo clone must stay in place;
   update with `git pull && ./install.sh`.
7. **Summary.** Print what was applied, what was skipped and why, and how to
   reload herdr.

`--dry-run` merges into a temporary copy and prints a diff and the planned
plugin links. It changes nothing. `--uninstall` removes tagged lines and the
marked block, restores `--force`-replaced lines, and runs `herdr plugin unlink`
on both plugins.

**Invariants** (each has a test):

- a second run changes nothing (byte-identical file);
- install followed by uninstall returns the file to its original bytes;
- `--dry-run` writes nothing;
- the user's own lines are never edited, except under `--force`, and then
  reversibly;
- a merge that makes `herdr config check` worse is rolled back.

## Testing

**Installer tests: `test/run.sh`.** Run under `env -i`, with `HERDR_CONFIG_PATH`
pointing into a short `mktemp -d`. Validation uses the real `herdr config check`.
A shim `herdr` on `PATH` records `plugin link` / `unlink` calls and passes every
other subcommand (including `config check` and `--version`) through to the real
binary, so these tests never touch a live server. Cases: fresh install with no config; existing `[keys]`
with a conflict; existing sidebar `rows`; symlinked config; second run;
`--dry-run`; install then uninstall; `--force` then uninstall; a deliberately
broken result (rolled back); a companion-rule conflict; a dotted/inline `keys`.

**Isolation lesson (learned while designing this).** Setting only `HOME` does
not isolate herdr when the shell runs inside a herdr pane: the inherited
`XDG_CONFIG_HOME`, `HERDR_SOCKET_PATH` and `HERDR_*` variables point at the
live setup, and `herdr plugin link` then talks to the live server. Use
`env -i`. The scratch directory must also be short: a macOS socket path is
limited to about 104 bytes, and herdr's socket lives under the config directory.

**Plugin tests.** `renumber_test.sh` and `display-panes.t` come across with the
plugins and must pass on macOS and Linux.

**Linux: `test/linux.sh`.** Creates (once) and uses a Lima Debian VM named
`herdr-tmuxify-test` (arm64; delete with `limactl delete`). Inside it: install
herdr with herdr's own installer, install `jq`, run `./install.sh`, `test/run.sh`
and the plugin tests, then exercise the real `plugin link` / `unlink` against an
isolated herdr server. This is a developer tool; the README mentions it as
optional.

**CI: `.github/workflows/test.yml`.** Runs `test/run.sh` and the plugin tests
on `ubuntu-latest` (x86_64) and `macos-latest`. It covers the x86_64 Linux build
that the local arm64 VM cannot.

**Not automated: pressing the keys.** The README carries a short key-by-key
checklist (the bindings above, `prefix+q` digits, both popups, tab and space
numbers). It is run by hand, on macOS and in the Linux VM
(`limactl shell herdr-tmuxify-test`), inside an isolated second herdr, never a
live one. Keypress behaviour on Linux terminals is otherwise verified at the
config level only. If `ctrl+space` does not register in a user's terminal, the
README tells them to pass `--prefix`.

## Open items (settle during implementation)

1. Does `herdr plugin link` work with no server running? If not, the installer
   says "start herdr, then re-run" and exits non-zero after the config merge.
2. Which other GNU/BSD differences does the Linux run expose in `renumber.sh`?
3. Does `herdr config check` honour `HERDR_CONFIG_PATH`? (The tests assume it, or
   fall back to `HOME`.)
4. Does `herdr config check` report two actions on one chord? If it does, the
   companion rule can lean on validation and rollback instead of a table of
   herdr's default chords.
5. Does a running herdr pick up an edited `config.toml`, or does it need a
   restart? The summary text depends on the answer.

## Decisions for the author before publishing

- **License.** Proposed: MIT. Not yet confirmed.
- **GitHub owner and visibility.** The repo is created locally only. Pushing it
  is a separate step, to be confirmed first.
