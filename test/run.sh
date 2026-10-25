#!/usr/bin/env bash
# Tests install.sh end to end: real `herdr config check` on every merged file,
# a shim `herdr` for everything that would touch a server.
#
# Every case runs under `env -i`: a shell inside a herdr pane carries
# HERDR_SOCKET_PATH and XDG_CONFIG_HOME for the live setup, and `herdr plugin
# link` would reach the live server. The scratch directory is short on purpose:
# herdr's socket lives under the config directory, and a Unix socket path is
# limited to about 104 bytes on macOS.
#
# Run: test/run.sh        (needs herdr, jq, perl on PATH)
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
REAL_HERDR=$(command -v herdr) || { echo "test/run.sh: herdr not found on PATH" >&2; exit 2; }
WORK=$(mktemp -d /tmp/htx.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# The only tools install.sh may use. Anything else it reaches for makes a case
# fail, which is how a missing dependency shows up here and not on a user's box.
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
for t in bash sh env perl cat cp cmp mkdir mktemp rm date diff dirname basename grep sed tr head tail touch ln readlink uname sort printf chmod mv; do
  p=$(command -v "$t") && ln -sf "$p" "$TOOLS/$t"
done
JQ=$(command -v jq) || { echo "test/run.sh: jq not found on PATH" >&2; exit 2; }
JQDIR="$WORK/jqdir"   # jq alone, so a case can leave it out or put it back
mkdir -p "$JQDIR" && ln -sf "$JQ" "$JQDIR/jq"

# A herdr that records plugin link/unlink, plays a running server when
# $HERDR_SHIM_SERVER is a file, and can fail the final check on demand.
# Everything else is the real herdr.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/herdr" <<'SHIM'
#!/bin/sh
case "$1 $2" in
  "plugin link"|"plugin unlink"|"tab rename"|"workspace report-metadata")
    echo "$*" >>"$HERDR_SHIM_LOG"; exit 0 ;;
  "workspace list")
    [ -f "${HERDR_SHIM_SERVER:-/nonexistent}" ] && { echo '{"result":{"workspaces":[{"workspace_id":"w1"}]}}'; exit 0; } ;;
  "tab list")
    [ -f "${HERDR_SHIM_SERVER:-/nonexistent}" ] && { cat "$HERDR_SHIM_SERVER"; exit 0; } ;;
  "config check")
    if [ -n "${HERDR_SHIM_BREAK:-}" ] && [ "$HERDR_CONFIG_PATH" = "$HERDR_SHIM_BREAK" ]; then
      echo "config: issues found"; echo "keys.bogus: unknown config key"; exit 0
    fi ;;
esac
exec "$REAL_HERDR" "$@"
SHIM
chmod +x "$WORK/bin/herdr"

failures=0
cases=0
ok()   { cases=$((cases + 1)); printf 'ok   %s\n' "$1"; }
fail() { cases=$((cases + 1)); failures=$((failures + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { # check <description> <condition-exit-status>
  if [ "$2" -eq 0 ]; then ok "$1"; else fail "$1" "${3:-}"; fi
}
has()   { grep -qF -- "$2" "$1"; }          # has <file> <text>
hasre() { grep -qE -- "$2" "$1"; }          # hasre <file> <regex>

# A fresh case directory; sets CFG, LOG, OUT, and runs go through `inst`.
newcase() {
  CASE="$WORK/c$cases$RANDOM"
  mkdir -p "$CASE/home"
  CFG="$CASE/home/config.toml"
  LOG="$CASE/shim.log"; : >"$LOG"
  OUT="$CASE/out.txt"
  unset HERDR_SHIM_SERVER_FILE
}
inst() { # inst <args...>: runs install.sh in the restricted environment
  env -i PATH="$WORK/bin:$TOOLS:$JQDIR" HOME="$CASE/home" TMPDIR="$WORK" \
    HERDR_CONFIG_PATH="$CFG" HERDR_SHIM_LOG="$LOG" REAL_HERDR="$REAL_HERDR" \
    HERDR_SHIM_SERVER="${SERVER:-}" HERDR_SHIM_BREAK="${BREAK:-}" \
    "$ROOT/install.sh" "$@" >"$OUT" 2>&1
}
herdr_ok() { # herdr_ok <file>: the real `config check` has nothing to say
  env -i PATH="$TOOLS" HOME="$CASE/home" HERDR_CONFIG_PATH="$1" "$REAL_HERDR" config check 2>&1 | grep -q '^config: ok'
}
backups() { ls "$CFG".tmuxify-bak.* 2>/dev/null | wc -l | tr -d ' '; }

# --- fresh install ------------------------------------------------------------

newcase
inst; rc=$?
check "fresh install exits 0" $rc "$(cat "$OUT")"
check "... and creates the config" "$([ -f "$CFG" ]; echo $?)"
check "... which herdr's own check accepts" "$(herdr_ok "$CFG"; echo $?)"
check "... with our tagged lines" "$(has "$CFG" 'split_horizontal = '"'"'prefix+"'"'"' # herdr-tmuxify'; echo $?)"
check "... and the popup block" "$(has "$CFG" '# >>> herdr-tmuxify >>>'; echo $?)"
check "... links both plugins" "$([ "$(grep -c '^plugin link' "$LOG")" = 2 ]; echo $?)" "$(cat "$LOG")"
check "... by their directories in the clone" "$(has "$LOG" "$ROOT/plugins/numbering"; echo $?)"
check "... makes no backup of a file that was not there" "$([ "$(backups)" = 0 ]; echo $?)"
check "... and tells how to reload herdr" "$(has "$OUT" 'herdr server reload-config'; echo $?)"

# --- an existing config ----------------------------------------------------------

newcase
printf 'onboarding = false\n\n[keys]\nprefix = "ctrl+a"\n\n[ui]\npane_borders = "always"\n' >"$CFG"
cp "$CFG" "$CASE/orig.toml"
inst; rc=$?
check "existing config: exit 0" $rc "$(cat "$OUT")"
check "... still valid for herdr" "$(herdr_ok "$CFG"; echo $?)"
check "... the user's lines survive" "$(has "$CFG" 'prefix = "ctrl+a"'; echo $?)"
check "... an untouched prefix: no prefix line of ours" "$(! grep -q 'prefix = .* # herdr-tmuxify' "$CFG"; echo $?)"
check "... one backup, equal to the original" "$([ "$(backups)" = 1 ] && cmp -s "$CASE/orig.toml" "$(ls "$CFG".tmuxify-bak.*)"; echo $?)"
cp "$CFG" "$CASE/after1.toml"
inst; rc=$?
check "second run: exit 0" $rc "$(cat "$OUT")"
check "... changes nothing" "$(cmp -s "$CFG" "$CASE/after1.toml"; echo $?)"
check "... and makes no second backup" "$([ "$(backups)" = 1 ]; echo $?)"
inst --uninstall; rc=$?
check "uninstall: exit 0" $rc "$(cat "$OUT")"
check "... returns the original bytes" "$(cmp -s "$CFG" "$CASE/orig.toml"; echo $?)"
check "... and unlinks both plugins" "$([ "$(grep -c '^plugin unlink' "$LOG")" = 2 ]; echo $?)" "$(cat "$LOG")"
check "... by id" "$(has "$LOG" 'plugin unlink herdr-tmuxify.numbering'; echo $?)"

# --- dry run ---------------------------------------------------------------------------

newcase
printf '[keys]\nprefix = "ctrl+a"\n' >"$CFG"
cp "$CFG" "$CASE/orig.toml"
inst --dry-run; rc=$?
check "--dry-run: exit 0" $rc "$(cat "$OUT")"
check "... changes nothing" "$(cmp -s "$CFG" "$CASE/orig.toml"; echo $?)"
check "... writes no backup" "$([ "$(backups)" = 0 ]; echo $?)"
check "... links nothing" "$([ ! -s "$LOG" ]; echo $?)"
check "... shows what would change" "$(hasre "$OUT" '^\+detach = "prefix\+d"'; echo $?)"

# --- the user's own bindings -------------------------------------------------------------

newcase
printf '[keys]\ndetach = "prefix+q"\n' >"$CFG"
inst; rc=$?
check "own detach: exit 0" $rc "$(cat "$OUT")"
check "... still valid" "$(herdr_ok "$CFG"; echo $?)"
check "... the report says it was skipped" "$(hasre "$OUT" 'skipped +keys\.detach'; echo $?)"
check "... and keeps their line" "$(has "$CFG" 'detach = "prefix+q"'; echo $?)"
check "... without the display-panes binding that needed it" "$(! has "$CFG" 'herdr-tmuxify.display-panes.show'; echo $?)"
check "... but with the other popups" "$(has "$CFG" 'key = "prefix+x"'; echo $?)"

# herdr itself reports this one: two explicit bindings on prefix+s.
newcase
printf '[keys]\nsettings = "prefix+s"\n' >"$CFG"
inst; rc=$?
check "settings on prefix+s: exit 0" $rc "$(cat "$OUT")"
check "... still valid" "$(herdr_ok "$CFG"; echo $?)"
check "... workspace_picker was dropped, with herdr's own words" "$(hasre "$OUT" 'skipped +keys\.workspace_picker.*prefix\+s'; echo $?)" "$(cat "$OUT")"
check "... their settings line stays" "$(has "$CFG" 'settings = "prefix+s"'; echo $?)"

newcase
printf '[[keys.command]]\nkey = "prefix+x"\ntype = "popup"\ncommand = "echo mine"\n' >"$CFG"
inst; rc=$?
check "own popup on prefix+x: exit 0" $rc "$(cat "$OUT")"
check "... still valid" "$(herdr_ok "$CFG"; echo $?)"
check "... ours is skipped" "$(hasre "$OUT" 'skipped +command prefix\+x'; echo $?)"
check "... theirs stays" "$(has "$CFG" 'command = "echo mine"'; echo $?)"

# --- options -------------------------------------------------------------------------------

newcase
inst --prefix ctrl+space; rc=$?
check "--prefix: exit 0" $rc "$(cat "$OUT")"
check "... sets it" "$(has "$CFG" 'prefix = "ctrl+space" # herdr-tmuxify'; echo $?)"
check "... still valid" "$(herdr_ok "$CFG"; echo $?)"
inst --prefix ctrl+a; rc=$?
check "... a later --prefix replaces it" "$(has "$CFG" 'prefix = "ctrl+a" # herdr-tmuxify' && ! has "$CFG" ctrl+space; echo $?)"

newcase
printf '[ui.sidebar.spaces]\nrows = [["workspace"]]\n' >"$CFG"
cp "$CFG" "$CASE/orig.toml"
inst; rc=$?
check "own sidebar rows: kept without --force" "$(has "$CFG" 'rows = [["workspace"]]' && hasre "$OUT" 'skipped +ui\.sidebar\.spaces\.rows'; echo $?)"
inst --force; rc=$?
check "--force: exit 0" $rc "$(cat "$OUT")"
check "... replaces it" "$(has "$CFG" '"$n"' && has "$CFG" '# herdr-tmuxify-replaced: rows = [["workspace"]]'; echo $?)"
check "... still valid" "$(herdr_ok "$CFG"; echo $?)"
inst --uninstall
check "... and uninstall restores theirs" "$(cmp -s "$CFG" "$CASE/orig.toml"; echo $?)"

# --- where the config is -------------------------------------------------------------------------

newcase
mkdir -p "$CASE/dotfiles"
printf '[keys]\nprefix = "ctrl+a"\n' >"$CASE/dotfiles/config.toml"
ln -s "$CASE/dotfiles/config.toml" "$CFG"
inst; rc=$?
check "symlinked config: exit 0" $rc "$(cat "$OUT")"
check "... is still a symlink" "$([ -L "$CFG" ]; echo $?)"
check "... and the target got the lines" "$(has "$CASE/dotfiles/config.toml" '# herdr-tmuxify'; echo $?)"
inst --uninstall
check "... uninstall leaves the link and cleans the target" "$([ -L "$CFG" ] && ! has "$CASE/dotfiles/config.toml" herdr-tmuxify; echo $?)"

newcase
CFG="$CASE/home/new/dir/config.toml"
inst; rc=$?
check "config directory that does not exist: created" "$([ $rc -eq 0 ] && [ -f "$CFG" ]; echo $?)" "$(cat "$OUT")"

# --- safety ----------------------------------------------------------------------------------------

# A final check that disagrees with the trial merges restores the original.
newcase
printf '[keys]\nprefix = "ctrl+a"\n' >"$CFG"
cp "$CFG" "$CASE/orig.toml"
BREAK="$CFG" inst; rc=$?
check "a final check that fails: exit non-zero" "$([ $rc -ne 0 ]; echo $?)"
check "... the original is back" "$(cmp -s "$CFG" "$CASE/orig.toml"; echo $?)"
check "... and plugins were not linked" "$([ ! -s "$LOG" ]; echo $?)"

# Missing dependencies are named.
newcase
NOJQ="$WORK/nojq"; mkdir -p "$NOJQ"
env -i PATH="$WORK/bin:$TOOLS" HOME="$CASE/home" HERDR_CONFIG_PATH="$CFG" REAL_HERDR="$REAL_HERDR" HERDR_SHIM_LOG="$LOG" \
  "$ROOT/install.sh" >"$OUT" 2>&1; rc=$?
check "no jq: exit non-zero" "$([ $rc -ne 0 ]; echo $?)"
check "... and the message names jq" "$(has "$OUT" jq; echo $?)" "$(cat "$OUT")"
check "... nothing was written" "$([ ! -e "$CFG" ]; echo $?)"

newcase
env -i PATH="$TOOLS:$JQDIR" HOME="$CASE/home" HERDR_CONFIG_PATH="$CFG" "$ROOT/install.sh" >"$OUT" 2>&1; rc=$?
check "no herdr: exit non-zero, naming it" "$([ $rc -ne 0 ] && has "$OUT" herdr; echo $?)"

newcase
inst --nonsense; rc=$?
check "an unknown option: exit non-zero" "$([ $rc -ne 0 ] && has "$OUT" '--nonsense'; echo $?)"
inst --help; rc=$?
check "--help: exit 0 and shows usage" "$([ $rc -eq 0 ] && has "$OUT" '--uninstall'; echo $?)"

# --- uninstall and the tab numbers ---------------------------------------------------------------------

# The numbering plugin wrote "1:vim" into a tab's name; with a server running,
# uninstall takes the number back out.
newcase
inst >/dev/null
SERVER="$CASE/server.json"
echo '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"1:vim"}]}}' >"$SERVER"
inst --uninstall; rc=$?
check "uninstall with a server: exit 0" $rc "$(cat "$OUT")"
check "... strips the number from the tab" "$(has "$LOG" 'tab rename w1:t1 vim'; echo $?)" "$(cat "$LOG")"
SERVER=""

newcase
inst >/dev/null
inst --uninstall; rc=$?
check "uninstall without a server: exit 0" $rc "$(cat "$OUT")"
check "... says the tabs keep their numbers" "$(has "$OUT" 'number prefixes'; echo $?)" "$(cat "$OUT")"

echo
if [ "$failures" -gt 0 ]; then
  printf '%d of %d check(s) failed\n' "$failures" "$cases"
  exit 1
fi
printf 'all %d checks passed\n' "$cases"
