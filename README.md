# herdr-tmuxify

Make [herdr](https://herdr.dev) behave like tmux: tmux's key bindings, tmux's
"are you sure?" before a pane or window is killed, tmux's `prefix q` pane
numbers, and numbered windows and sessions.

One command installs it into your existing herdr config without losing
anything of yours, and one command takes it all out again.

## What you get

herdr's prefix stays `ctrl+b`, which is tmux's. A herdr *workspace* is a tmux
session, a herdr *tab* is a tmux window.

| Press | Result |
|---|---|
| `prefix` `"` | split, stacked |
| `prefix` `%` | split, side by side |
| `prefix` `d` | detach |
| `prefix` `,` | rename tab |
| `prefix` `x` | close pane, after a `[y/N]` prompt |
| `prefix` `&` | close tab, after a `[y/N]` prompt that shows its pane count |
| `prefix` `q` | number every pane; press a digit to jump to that pane |
| `prefix` `s` | workspace picker |
| `prefix` `S` | settings |
| `prefix` `;` | last pane |
| `prefix` `[` | copy mode |
| `prefix` `Shift`+`1`..`9` | jump to workspace N (an addition: tmux has no equivalent) |
| `j` / `k` | move through the workspace list in NAVIGATE mode |

Tabs are named `1:name`, `2:name` and so on, renumbered when you open, close or
move one, and the sidebar shows each workspace's number. herdr's own bindings
for `h` `j` `k` `l`, `z`, `c`, `n`, `p` and `1`..`9` already match tmux and are
left alone.

## Requirements

- macOS or Linux. Windows is not supported.
- herdr 0.9.1 or newer.
- `bash`, `perl` and `jq`. The installer names anything that is missing.

## Install

Clone this repository somewhere permanent: the plugins are linked from the
clone, so deleting it breaks them. All commands below run from the repository
root.

See what would change first. Nothing is written.

```sh
./install.sh --dry-run
```

Install:

```sh
./install.sh
```

Then reload a running herdr, or restart it.

```sh
herdr server reload-config
```

The installer reads your config from `$HERDR_CONFIG_PATH`, or
`~/.config/herdr/config.toml` when that is unset. A config that is a symlink
(a stow or dotfiles setup) stays a symlink; the file behind it is edited.

### Options

| Option | Effect |
|---|---|
| `--prefix KEY` | also set herdr's prefix, for example `--prefix ctrl+space` |
| `--force` | replace a single-line setting of yours that differs from ours |
| `--dry-run` | show what would change and change nothing |
| `--uninstall` | remove everything this added |

To use tmux's other common prefix:

```sh
./install.sh --prefix ctrl+a
```

If `ctrl+space` does not register in your terminal, which some Linux terminals
and input methods intercept, pick another chord.

### Update

```sh
git pull
./install.sh
```

Running the installer again never stacks changes.

### Uninstall

```sh
./install.sh --uninstall
```

This removes the lines the installer added, puts back any line of yours that
`--force` replaced, unlinks both plugins, and, if a herdr server is running,
takes the numbers out of your tab names. With no server running the tabs keep
their `1:` prefixes until you run `plugins/numbering/renumber.sh --strip` with
herdr up.

## What the installer does to your config

- Every line it adds ends in `# herdr-tmuxify`. The popup and plugin bindings
  sit in one block between `# >>> herdr-tmuxify >>>` and
  `# <<< herdr-tmuxify <<<`; leave that block's contents alone, since
  uninstall removes it whole.
- It backs your config up first, to `config.toml.tmuxify-bak.<timestamp>`, and
  makes no backup when nothing changes.
- A setting you already made is left alone and listed as `skipped`, with the
  line to add by hand. A binding that would give one chord to two actions is
  skipped too, in herdr's own words from `herdr config check`.
- `prefix q` (display panes) is added only if `detach` is moved off `prefix q`,
  and the `prefix x` and `prefix &` popups only if `close_pane` and `close_tab`
  are unbound. Otherwise they would silently take over a chord of an action you
  still expect to find there.
- It runs `herdr config check` on the result and restores your original if the
  file reads worse than before.
- If you add lines of your own under a table the installer created, uninstall
  keeps the table header and removes only our lines.

The bindings themselves are plain TOML in [`config/`](config/), with the
reasons behind each spelling in its comments.

## Check it by hand

Automated tests cannot press keys, and `herdr config check` only proves a key
name parses, not which physical key it matches. After installing, press each of
these once in a herdr that is not holding work you care about:

1. `prefix` `"` stacks a split, and `prefix` `%` puts one side by side.
2. `prefix` `[` enters copy mode.
3. `prefix` `x` asks `Close pane ... [y/N]`; `n` leaves the pane open.
4. `prefix` `&` asks `Close tab ... [y/N]`; `n` leaves the tab open.
5. `prefix` `q` draws a digit on each pane, and pressing a digit focuses it.
6. `prefix` `;` goes back to the previous pane.
7. Rename a tab with `prefix` `,`: it becomes `1:name`. Open a second tab,
   rename it, and close the first: the second becomes `1:name`.
8. `prefix` `Shift`+`2` jumps to the second workspace, once you have two.

## Limits

- The `prefix q` popup repaints pane borders in your theme's colours. It reads
  the theme named by `[theme] name` in your config and knows herdr 0.9.5's
  built-in themes. For `terminal`, an unknown name, `auto_switch = true`, or
  `[theme.custom]` colours it falls back to the default theme's colours, so the
  borders can flash a different colour for the moment the numbers show.
- A tab name that starts with digits and a colon, such as `12:30 standup`,
  loses that part when numbered: the colon marks a number prefix.
- A tab whose name is only digits is herdr's own automatic name and is left
  alone until you rename it.
- The installer edits lines; it does not parse TOML. If your config writes
  `keys` in a form it cannot extend, such as `keys.prefix = "x"` at the top
  level, herdr's check rejects the result and those lines are skipped with
  herdr's error message.

## Tests

From the repository root, with `herdr`, `jq`, `perl` and `bash` on `PATH`:

```sh
test/all.sh
```

That runs the merge tests, the installer tests and both plugins' tests, each
under `env -i` so a herdr you are sitting in is never touched. The end-to-end
test starts a real herdr server of its own in a scratch directory:

```sh
test/e2e.sh
```

On macOS with [Lima](https://lima-vm.io) installed, this runs both of them on
Debian in a throwaway VM, which has no access to your home directory:

```sh
test/linux.sh
```

`test/linux.sh --delete` removes the VM. The herdr version the tests download
is pinned in [`test/herdr-version`](test/herdr-version).

## Layout

| Path | Contents |
|---|---|
| `install.sh` | the only entry point |
| `lib/merge.pl` | adds and removes the tagged lines |
| `config/` | the bindings, as data |
| `plugins/numbering/` | tab and workspace numbers |
| `plugins/display-panes/` | `prefix q` |
| `test/` | the tests |
| `docs/specs/` | the design |

## License

MIT. See [LICENSE](LICENSE).
