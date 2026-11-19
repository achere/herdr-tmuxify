#!/usr/bin/env bash
# End to end, against a real herdr server of its own: install, watch the
# numbering plugin renumber tabs as they come and go, run the display-panes
# action, move focus with prefix+h/j/k/l's actions, uninstall. This is the one test that runs renumber.sh's lock and
# mtime path under the platform's own tools (GNU on Linux, BSD on macOS).
#
# The server runs under `env -i` with a throwaway HOME, so it never meets a
# live herdr: a shell inside a herdr pane carries HERDR_SOCKET_PATH, which
# would point `plugin link` at the live server. The HOME is short because a
# Unix socket path is limited to about 104 bytes on macOS.
#
# Run: test/e2e.sh        (needs herdr, jq, perl on PATH)
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
H=$(mktemp -d /tmp/hxe.XXXXXX)
SERVER_PID=""
cleanup() {
  # Ask the server to stop through its own socket first, then make sure.
  hx herdr server stop >/dev/null 2>&1
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; fi
  rm -rf "$H"
}
trap cleanup EXIT

hx() { env -i PATH="$PATH" HOME="$H" TMPDIR="$H" "$@"; }

failures=0
check() { # check <description> <exit status> [detail]
  if [ "$2" -eq 0 ]; then printf 'ok   %s\n' "$1"
  else failures=$((failures + 1)); printf 'FAIL %s\n' "$1"; [ -n "${3:-}" ] && printf '       %s\n' "$3"; fi
}
wait_for() { # wait_for SECONDS COMMAND...: poll until COMMAND succeeds
  local deadline=$((SECONDS + $1)); shift
  while ! "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}
labels() { hx herdr tab list | jq -r '[.result.tabs[].label] | join(",")'; }
labels_are() { [ "$(labels)" = "$1" ]; }
tab_id_by_label() { hx herdr tab list | jq -r --arg l "$1" '.result.tabs[] | select(.label == $l) | .tab_id'; }

# --- a server of our own ------------------------------------------------------------

# Not through hx: backgrounding a shell function makes $! a subshell's pid, and
# killing that would leave the server running.
env -i PATH="$PATH" HOME="$H" TMPDIR="$H" herdr server >"$H/server.log" 2>&1 &
SERVER_PID=$!
wait_for 20 hx herdr workspace list
check "an isolated herdr server is running" $? "$(tail -3 "$H/server.log" 2>/dev/null)"

# --- install ----------------------------------------------------------------------------

out=$(hx "$ROOT/install.sh" 2>&1); rc=$?
check "install.sh against a running server: exit 0" $rc "$out"
plugins=$(hx herdr plugin list 2>&1)
check "... both plugins are registered" "$(echo "$plugins" | grep -q 'herdr-tmuxify.numbering' && echo "$plugins" | grep -q 'herdr-tmuxify.panes'; echo $?)" "$plugins"
check "... and herdr accepts the merged config" "$(hx herdr config check | grep -q '^config: ok'; echo $?)" "$(hx herdr config check)"

# --- the numbering plugin, on this platform's tools ------------------------------------------

ws=$(hx herdr workspace create 2>&1)
first=$(echo "$ws" | jq -r '.result.tab.tab_id')
hx herdr tab rename "$first" vim >/dev/null
wait_for 15 labels_are "1:vim"
check "a renamed tab gets its number" $? "labels: $(labels)"

hx herdr tab create >/dev/null
second=$(hx herdr tab list | jq -r '.result.tabs[1].tab_id')
hx herdr tab rename "$second" build >/dev/null
wait_for 15 labels_are "1:vim,2:build"
check "a second tab is numbered after it" $? "labels: $(labels)"

hx herdr tab create >/dev/null
third=$(hx herdr tab list | jq -r '.result.tabs[2].tab_id')
hx herdr tab rename "$third" logs >/dev/null
wait_for 15 labels_are "1:vim,2:build,3:logs"
check "... and a third" $? "labels: $(labels)"

# Closing the first tab fires several hook runs at once; the ones that lose the
# lock leave a marker and the holder runs again - the path with the mtime read.
hx herdr tab close "$first" >/dev/null
wait_for 15 labels_are "1:build,2:logs"
check "closing a tab renumbers the rest" $? "labels: $(labels)"

hx herdr tab rename "$(tab_id_by_label "2:logs")" "2:logs" >/dev/null
wait_for 5 labels_are "1:build,2:logs"
check "a rename to the same name settles instead of looping" $? "labels: $(labels)"

# --- the lock directory is not left behind ------------------------------------------------------

no_lock() { [ -z "$(find "$H" -type d -name lock 2>/dev/null | head -1)" ]; }
wait_for 10 no_lock
check "no stuck lock after the dust settles" $? "$(find "$H" -type d -name lock 2>/dev/null)"

# --- display-panes -----------------------------------------------------------------------------------

# Opening the popup itself needs an attached client; what this proves is that
# herdr knows the action and dispatches it.
out=$(hx herdr plugin action invoke herdr-tmuxify.panes.display-panes 2>&1); rc=$?
check "the display-panes action is dispatched: exit 0" $rc "$out"
check "... with a result and no error" "$(echo "$out" | jq -e 'has("result") and (has("error") | not)' >/dev/null 2>&1; echo $?)" "$out"

# --- prefix+h/j/k/l ------------------------------------------------------------------------------------

# The tab "1:build" split into 1 on the left, 2 top right, 3 bottom right.
# From 1, both 2 and 3 are to the right and tie on everything herdr ranks
# by, so herdr always picks 2; the plugin picks the one focused last.
focused() { hx herdr api snapshot | jq -r .result.snapshot.focused_pane_id; }
focused_is() { [ "$(focused)" = "$1" ]; }
focus_pane() { # focus_pane <id>: as a mouse click would, without the actions
  hx perl -I"$ROOT/plugins/panes" -MPanes -e 'api("pane.focus", { pane_id => $ARGV[0] })' "$1"
  wait_for 5 focused_is "$1" && sleep 0.3   # and give the pane.focused hook its turn
}
press() { # press <direction> <pane>: run the action, wait for focus to land on <pane>
  hx herdr plugin action invoke "herdr-tmuxify.panes.focus-$1" >/dev/null
  wait_for 5 focused_is "$2"; local rc=$?
  sleep 0.3
  return $rc
}
p1=$(hx herdr pane list | jq -r --arg t "$(tab_id_by_label "1:build")" '[.result.panes[] | select(.tab_id == $t)][0].pane_id')
p2=$(hx herdr pane split "$p1" --direction right | jq -r '.. | .pane_id? // empty' | grep -vx "$p1" | head -1)
p3=$(hx herdr pane split "$p2" --direction down | jq -r '.. | .pane_id? // empty' | grep -vx -e "$p1" -e "$p2" | head -1)
check "a tab split as 1 | 2 over 3" "$([ -n "$p1" ] && [ -n "$p2" ] && [ -n "$p3" ]; echo $?)" "1=$p1 2=$p2 3=$p3"

focus_pane "$p3"
press left "$p1";  check "[3] h -> 1" $? "at $(focused)"
press right "$p3"; check "[1] l -> 3, where it came from (herdr alone: 2)" $? "at $(focused)"
focus_pane "$p2"
press left "$p1";  check "[2] h -> 1" $? "at $(focused)"
press right "$p2"; check "[1] l -> 2" $? "at $(focused)"
press down "$p3";  check "[2] j -> 3, the only pane below" $? "at $(focused)"

stamps=$(find "$H" -name stamps -path '*herdr-tmuxify.panes*' | head -1)
check "the focus records are in the plugin's state dir" "$([ -f "$stamps" ]; echo $?)" "$(find "$H" -name stamps)"
# Focus is on 3 here, and focusing the focused pane fires no event: go
# through 2 first, so 3 is recorded after 2 by the hook alone.
rm -f "$stamps"
focus_pane "$p2"; focus_pane "$p3"; focus_pane "$p1"
press right "$p3"; check "focus moved without the actions counts too (the pane.focused hook)" $? "at $(focused)"
rm -f "$stamps"
focus_pane "$p1"; rm -f "$stamps"
press right "$p2"; check "no records: herdr's own pick" $? "at $(focused)"

hx herdr pane close "$p2" >/dev/null
focus_pane "$p3"
check "a closed pane leaves the records" "$(! grep -q "^$p2	" "$stamps"; echo $?)" "$(cat "$stamps" 2>/dev/null)"
hx herdr pane close "$p3" >/dev/null

# --- uninstall -------------------------------------------------------------------------------------------

out=$(hx "$ROOT/install.sh" --uninstall 2>&1); rc=$?
check "uninstall: exit 0" $rc "$out"
check "... the numbers are out of the tab names" "$(wait_for 15 labels_are "build,logs"; echo $?)" "labels: $(labels)"
check "... the plugins are gone" "$(! hx herdr plugin list 2>&1 | grep -q 'herdr-tmuxify'; echo $?)"
check "... and the config is clean again" "$(! grep -q 'herdr-tmuxify' "$H/.config/herdr/config.toml" 2>/dev/null; echo $?)"

echo
if [ "$failures" -gt 0 ]; then printf '%d check(s) failed\n' "$failures"; exit 1; fi
echo "end to end: all checks passed"
