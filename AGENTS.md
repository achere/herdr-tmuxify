# herdr-tmuxify

A public repo that makes [herdr](https://herdr.dev) behave like tmux. `install.sh`
merges tmux-style key bindings into a user's `config.toml` as tagged, reversible
lines, and links two plugins (`numbering`, `display-panes`) from the clone.
macOS and Linux. Start with `README.md`; the design is in
`docs/specs/2026-10-25-herdr-tmuxify-design.md`.

## Build and test

There is no build. From the repo root, with `herdr`, `jq`, `perl`, `bash` on PATH:

- `test/all.sh` - merge, installer and both plugins' tests.
- `test/e2e.sh` - installs into a real herdr server of its own and watches the
  numbering plugin.
- `test/linux.sh` - the same inside a Lima Debian VM (`--delete` removes it).
  CI (`.github/workflows/test.yml`) runs `all.sh` and `e2e.sh` on ubuntu and
  macOS, with herdr pinned in `test/herdr-version`. The first run passed on both.

## Caveats

- **Never test against a live herdr.** A shell inside a herdr pane carries
  `HERDR_SOCKET_PATH` and `XDG_CONFIG_HOME`, so `HOME=scratch` alone does not
  isolate herdr: `herdr plugin link` reaches the live server. Use `env -i`, and
  a short scratch dir (`/tmp/hx.XXXXXX`): socket paths are limited to ~104 bytes
  on macOS.
- **Config path.** `HERDR_CONFIG_PATH`, else `$XDG_CONFIG_HOME/herdr/config.toml`,
  else `~/.config/herdr/config.toml`. herdr honours XDG; resolve it the same way
  in `install.sh` and `display-panes.pl` (`config_path`). A machine where
  `XDG_CONFIG_HOME` is `~/.config` hides a mistake here.
- **Key spellings are load-bearing.** `'prefix+"'`, `prefix+percent` and
  `prefix+[` were confirmed by pressing the keys. `herdr config check` only
  proves a name parses, never which physical key it matches. Do not "tidy" them.
- **Install is "unmerge, then merge"** (`lib/merge.pl`), so it is idempotent and
  `--uninstall` is its exact inverse for a file that ends in a newline. Each unit
  is added alone and kept only if `herdr config check` shows no new diagnostic.
  herdr reports a chord given to two explicit bindings but not a command on a
  default chord, which is why command blocks carry `# requires: table.key`.
- **Fragment format** (`config/*.toml`): comments are documentation and are not
  copied. A command block ends at the first blank or comment line.
- **Uninstall unlinks the plugins before stripping tab numbers.** Stripping
  renames tabs, and a still-linked numbering plugin would re-number them.
- **GNU vs BSD.** `stat -f %m` on GNU prints a filesystem report and exits 1;
  `renumber.sh` aborted on Linux because of it (`mtime_of` is the fix). Check
  any new `stat`, `sed -i`, `date`, `readlink` use on both. Scripts must stay
  bash 3.2 compatible (macOS).
- **Theme colours.** `display-panes.pl` carries a palette table copied from
  herdr v0.9.5's `src/app/state.rs`; a new herdr theme needs a new row.
- `plugins/` was copied from the author's dotfiles (commit `a94f29d`) and has
  drifted since; there is no sync.
