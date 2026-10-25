#!/usr/bin/env bash
# Every automated test: the merge, the installer, and both plugins.
# Needs herdr, jq, perl and bash on PATH. Run: test/all.sh
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

status=0
step() { printf '\n== %s\n' "$1"; shift; "$@" || status=1; }

# env -i: a herdr pane's HERDR_* and XDG_CONFIG_HOME variables would point
# these at a live setup.
clean() { env -i PATH="$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" "$@"; }

step "merge (test/merge.t)"                    clean perl "$ROOT/test/merge.t"
step "installer (test/run.sh)"                 clean bash "$ROOT/test/run.sh"
step "numbering plugin (renumber_test.sh)"     clean bash "$ROOT/plugins/numbering/renumber_test.sh"
step "display-panes plugin (display-panes.t)"  clean perl "$ROOT/plugins/display-panes/display-panes.t"

echo
if [ "$status" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit "$status"
