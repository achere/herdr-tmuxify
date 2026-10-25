# herdr-tmuxify — design

**Date:** 2026-10-25
**Status:** implemented and tested on macOS (herdr 0.9.3) and Debian 13 arm64
(herdr 0.9.5). The CI workflow has not run yet: the repo is not on GitHub.

Where the build departs from the design first approved in conversation:

- **Install is "unmerge, then merge".** Re-runs and option changes never stack,
  and uninstall is the same code run backwards.
- **Conflicts are found by trial, not by a table.** Each unit is added alone and
  kept only if `herdr config check` shows nothing new. See "Verified during
  implementation", item 4.
- **Uninstall unlinks the plugins before stripping tab numbers.** The other order
  is wrong: stripping renames tabs, and a still-linked numbering plugin answers
  each rename by putting the numbers back.
- **A skipped unit does not make the installer fail.** Skips are the expected
  outcome of a user having their own settings; the installer exits 0 and lists
  them with the line to add by hand.
- **`display-panes` follows the user's theme** (the design had not noticed it
  hardcoded one-dark's colours).
- The GNU `stat` bug in `renumber.sh` was worse than expected: it aborts the
  script, not just the staleness check.

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
  path, `~/.config/herdr/config.toml`; `XDG_CONFIG_HOME` moves it and
  `HERDR_CONFIG_PATH` overrides both.
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
  lib/check.sh            herdr's config diagnostics for a file, one per line
  config/
    keys.toml             lines for [keys]
    ui.toml               the sidebar rows line for [ui.sidebar.spaces]
    commands.toml         [[keys.command]] blocks: two popups + display-panes
  plugins/
    numbering/            herdr-plugin.toml, renumber.sh, renumber_test.sh
    display-panes/        herdr-plugin.toml, display-panes.pl, display-panes.t
  test/
    all.sh                merge, installer and both plugins' tests
    merge.t               lib/merge.pl, with a fake validator
    run.sh                install.sh end to end, with the real `config check`
    e2e.sh                install into a real herdr server of its own
    linux.sh              runs all of it in a Lima Debian VM
    herdr-version         the herdr release the tests download
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
- `numbering/renumber.sh`: the lock-staleness check used BSD `stat -f %m`. On
  GNU `stat`, `-f` means filesystem status: it prints a multi-line report and
  exits 1, the `|| printf "$now"` fallback glued a timestamp onto that report,
  and the arithmetic aborted the whole script whenever the lock was contended.
  `mtime_of` now tries `stat -c %Y` first and `stat -f %m` second and returns
  plain epoch seconds or nothing; `lock_is_stale` treats an unreadable age as
  "not stale". Both have unit tests that run on both platforms.
- `display-panes/display-panes.pl` repaints each pane's border and scrollbar in
  a popup, using a `%PALETTE` hardcoded to one-dark's colours. The theme stays
  out of this repo, so a stranger's popup would not match their panes. It now
  carries a table of the four colours it uses for each of herdr v0.9.5's
  seventeen RGB themes (extracted from `src/app/state.rs`), reads `[theme] name`
  from the config (`HERDR_CONFIG_PATH` or `~/.config/herdr/config.toml`), and
  falls back to the default theme, catppuccin, for an unset or unknown name,
  for `terminal` (ANSI names, no RGB) and for `auto_switch = true` (the active
  theme then depends on the host's appearance). `[theme.custom]` overrides are
  not applied: the named theme's own colours are used. A new herdr theme needs
  a new row.
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
   `$XDG_CONFIG_HOME/herdr/config.toml` if that is set, else
   `~/.config/herdr/config.toml`. If the file does not exist, start from an
   empty one.
3. **Backup.** Only if the file changes, copy it first to
   `config.toml.tmuxify-bak.<YYYYmmddHHMMSS>`.
4. **Merge** through `lib/merge.pl`: remove everything of ours (the inverse
   below), then add each unit. Every line the installer adds ends in
   `# herdr-tmuxify`.
   - *Scalar keys* (the `[keys]` bindings, `prefix`, sidebar `rows`) go under
     their table, after its last setting so the user's lines stay on top; the
     table is created at the end of the file if missing. A key the user already
     set is skipped and reported. A key the user set to the same value counts as
     already applied. A commented-out key counts as unset.
   - *`--force`* replaces the user's scalar line and keeps the original as
     `# herdr-tmuxify-replaced: <original line>`, so uninstall can restore it.
     It applies only to single-line values; a multi-line user value is skipped
     and reported even with `--force`.
   - *Command bindings* (`[[keys.command]]`) go in one block at the end of the
     file between `# >>> herdr-tmuxify >>>` and `# <<< herdr-tmuxify <<<`.
     A block whose `key` is already used by another `[[keys.command]]` is
     skipped and reported; `--force` does not override it.
   - *Trial merge.* Each unit (one scalar line, or one command block) is added
     on its own and kept only if `herdr config check` shows no diagnostic that
     was not already there. A dropped unit is reported with herdr's own words.
     This is how "no chord is bound twice" is enforced: herdr reports a chord
     given to two explicit bindings, for example our `workspace_picker =
     "prefix+s"` against a user's `settings = "prefix+s"`.
   - *Requires.* herdr does not report a command binding that sits on the
     default chord of an action the user left unset. So each command block
     carries `# requires: table.key` in its fragment, naming the scalar that
     frees its chord (`prefix+q`: `keys.detach`; `prefix+x`: `keys.close_pane`;
     `prefix+&`: `keys.close_tab`), and is added only while that scalar is in
     effect, whether we set it or the user already had the same value.
   - *Unsupported shapes.* The editor works on lines, not TOML. If `keys` is
     written as a dotted key or an inline table, adding `[keys]` is a TOML
     error, herdr's check says so, and each affected unit is skipped with that
     message and the line to add by hand. Nothing is half-applied.
   - *Symlinked config.* If `config.toml` is a symlink (stow users), write
     through it. Never rename a temp file over it.
5. **Validate.** After writing, run `herdr config check` on the file once more.
   The trial merge makes this a safety net: if it prints any diagnostic that
   the original file did not, restore the original and abort.
6. **Plugins.** `herdr plugin link <repo>/plugins/numbering` and
   `.../display-panes`. Linking is idempotent. The repo clone must stay in place;
   update with `git pull && ./install.sh`.
7. **Summary.** Print what was applied, what was skipped and why, and how to
   reload herdr.

`--dry-run` merges into a temporary copy and prints a diff and the planned
plugin links. It changes nothing.

`--uninstall` does four things, in this order:

1. Removes the tagged lines and the marked block, and restores
   `--force`-replaced lines. A `[keys]`-style table header that the installer
   created (tagged) is removed only if no other line remains under it; if the
   user added keys under it since, the header stays. That is still valid TOML.
2. Runs `herdr plugin unlink` on both plugins. This comes before the strip:
   stripping renames tabs, and a still-linked numbering plugin answers each
   rename (`tab.renamed`) by putting the numbers back.
3. Runs `renumber.sh --strip` if a herdr server is running (detected by `herdr
   workspace list` returning a result), so tab names lose the numbers the plugin
   wrote into them. Those names are custom names and would persist after the
   plugin is gone. If no server is running, uninstall says that the tabs keep
   their number prefixes until stripped by hand.
4. Leaves the backup files in place.

The sidebar's `$n` token is runtime-only and disappears on its own.

**Invariants** (each has a test):

- a second run changes nothing (byte-identical file);
- install followed by uninstall, with no edits to the file in between, returns it
  to its original bytes;
- uninstall leaves no numbered tab names behind when a server is running;
- `--dry-run` writes nothing;
- the user's own lines are never edited, except under `--force`, and then
  reversibly;
- a merge that makes `herdr config check` worse is rolled back.

## Testing

**Installer tests: `test/run.sh`.** Run under `env -i`, with `HERDR_CONFIG_PATH`
pointing into a short `mktemp -d`. Validation uses the real `herdr config check`.
A shim `herdr` on `PATH` records `plugin link` / `unlink` calls and passes every
other subcommand (including `config check` and `--version`) through to the real
binary, so these tests never touch a live server. The shim also plays a running
server (for the tab-number strip) and can fail the final check on demand. Cases:
fresh install; an existing config with a backup; a second run; `--dry-run`;
install then uninstall; the user's own `detach`, `settings` on `prefix+s` and a
popup on `prefix+x`; `--prefix`; `--force` then uninstall; a symlinked config; a
config directory that does not exist; a final check that fails (rolled back); a
missing `jq` or `herdr`; an unknown option; uninstall with and without a server.
The cases run with only the tools `install.sh` is allowed to use on `PATH`, so a
new dependency shows up as a failure. `test/merge.t` covers `lib/merge.pl` on its
own with a fake validator, including the dotted-key and duplicate-block shapes,
and the real fragments. Both were checked by mutation: five deliberate breakages
of the installer were each caught.

**Isolation lesson (learned while designing this).** Setting only `HOME` does
not isolate herdr when the shell runs inside a herdr pane: the inherited
`XDG_CONFIG_HOME`, `HERDR_SOCKET_PATH` and `HERDR_*` variables point at the
live setup, and `herdr plugin link` then talks to the live server. Use
`env -i`. The scratch directory must also be short: a macOS socket path is
limited to about 104 bytes, and herdr's socket lives under the config directory.

**Plugin tests.** `renumber_test.sh` and `display-panes.t` come across with the
plugins and must pass on macOS and Linux.

**End to end: `test/e2e.sh`.** Starts a real `herdr server` of its own under
`env -i` and a throwaway `HOME`, then runs the real `install.sh` against it:
both plugins are registered and the merged config passes `config check`; a tab
renamed to `vim` becomes `1:vim`, a second becomes `2:build`, a third `3:logs`;
closing the first renumbers the rest (several hook runs at once, so the lock and
mtime path runs under the platform's own tools); a rename to the same name
settles; no lock directory is left behind; `herdr plugin action invoke
herdr-tmuxify.display-panes.show` is dispatched without an error (opening the
popup itself needs an attached client); and `--uninstall` removes the numbers,
the plugins and the config lines. A tab whose name is only digits is herdr's
automatic name and is skipped by the plugin, so the script renames tabs first.

**Linux: `test/linux.sh`.** Creates (once) and uses a Lima Debian VM named
`herdr-tmuxify-test` (2 CPUs, 4 GB, 20 GB, arm64, no host mounts; `--delete`
removes it). It installs `jq`, downloads the herdr release named in
`test/herdr-version` as a binary (not by piping an install script into a shell),
copies the repo in, and runs `test/all.sh` and `test/e2e.sh`. A developer tool;
the README mentions it as optional.

**CI: `.github/workflows/test.yml`.** Runs `test/all.sh` and `test/e2e.sh` on
`ubuntu-latest` (x86_64) and `macos-latest`. It covers the x86_64 Linux build
that the local arm64 VM cannot. It downloads the herdr release pinned in
`test/herdr-version`, because the tests use the real `herdr config check`; the
pin is bumped on purpose, not by accident. Written but not yet run.

**Not automated: pressing the keys.** The README carries a short key-by-key
checklist (splits, copy mode, both popups, `prefix+q` digits, last pane, tab
and workspace numbers). It is for a person to run in a herdr that holds no work
they care about, on each platform they use. Nobody has pressed those keys on
Linux yet: Linux is verified at the config and server level only. If
`ctrl+space` does not register in a user's terminal, the README tells them to
pass a different `--prefix`.

## Verified during implementation (herdr 0.9.3 locally, docs for 0.9.5)

1. `herdr plugin link` works with no server running. It writes the registry
   directly and starts no server, so the installer needs no running herdr.
2. The Linux run exposed no GNU/BSD difference in `renumber.sh` beyond the
   `stat` call fixed above: the unit tests, the installer tests and the end-to-end
   run all pass on Debian 13.
3. `herdr config check` honours `HERDR_CONFIG_PATH`. Otherwise herdr reads
   `$XDG_CONFIG_HOME/herdr/config.toml` when `XDG_CONFIG_HOME` is set (checked:
   with it pointing elsewhere, herdr ignored `~/.config` and kept its plugin
   registry under the XDG directory), and `~/.config/herdr/config.toml` when not.
   The installer and the display-panes plugin resolve the path the same way. The
   design had missed the XDG case; it stayed hidden because on the author's
   machine `XDG_CONFIG_HOME` equals `~/.config`.
4. `herdr config check` reports a chord used by two explicit bindings, either two
   `[keys]` actions or two `[[keys.command]]` blocks, as `<chord>: kept A,
   disabled B`. It does not report a command binding that sits on the default
   chord of an action the user left unset. So the installer **trial-merges**:
   it adds one unit at a time (a scalar line or a command block), runs `herdr
   config check`, and drops the unit, with a report, if the check shows a
   diagnostic that was not there before. No table of herdr default chords is
   needed. A command block also declares the scalar it depends on (for
   `prefix+q`, `detach`; for `prefix+x`, `close_pane`) and is skipped when that
   scalar was not applied or already equal, because otherwise the command would
   silently take over the chord of an action the user still expects.
5. A running herdr re-reads `config.toml` on `herdr server reload-config` (or
   the global menu's "reload config"). The installer prints that command; it does
   not run it against a live server.
6. herdr exposes no theme colours through its documented API. The built-in
   palettes are in herdr's `src/app/state.rs`. Decision: `display-panes` ships a
   table of the four colours it uses (accent, overlay0, overlay1, surface_dim)
   per built-in theme, extracted from herdr v0.9.5, and picks the entry named by
   `[theme] name` in the user's config. It falls back to the default theme's
   (catppuccin) for an unset or unknown name, for `terminal` (ANSI named colours
   have no RGB), and when `auto_switch` is on; `[theme.custom]` overrides are not
   applied. The README states these limits.

## Decisions for the author before publishing

- **License.** `LICENSE` is MIT, in the author's name. A proposal, not a
  decision; change it freely.
- **GitHub owner and visibility.** The repo exists locally only. Pushing it is a
  separate step, to be confirmed first. The README has no clone URL until then.
- **Key checklist.** Not yet run by a person, on either platform.
