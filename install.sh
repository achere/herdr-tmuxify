#!/usr/bin/env bash
# herdr-tmuxify: make herdr behave like tmux.
#
#   ./install.sh [--prefix KEY] [--force] [--dry-run]
#   ./install.sh --uninstall [--dry-run]
#
# Merges tmux-style key bindings into your herdr config.toml, as lines tagged
# `# herdr-tmuxify`, and links two plugins from this clone. Lines you already
# set are left alone and reported. Nothing is lost: your config is backed up
# first, and --uninstall takes out exactly what was added.
#
# Keep this clone where it is: the plugins are linked from it. To update,
# `git pull && ./install.sh`.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
MIN_HERDR=0.9.1
PLUGINS="numbering display-panes"   # herdr plugin ids are herdr-tmuxify.<name>

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: ./install.sh [--prefix KEY] [--force] [--dry-run]
       ./install.sh --uninstall [--dry-run]

  --prefix KEY  also set herdr's prefix, for example ctrl+space (default: leave
                herdr's own ctrl+b, which is tmux's)
  --force       replace a single-line setting of yours that differs from ours
                (the original stays as a comment, and --uninstall restores it)
  --dry-run     show what would change and change nothing
  --uninstall   remove everything this added, unlink the plugins, and take the
                numbers back out of tab names

Your config is $HERDR_CONFIG_PATH, or ~/.config/herdr/config.toml.
EOF
}

PREFIX_KEY=""
FORCE=0
DRY_RUN=0
UNINSTALL=0
while [ $# -gt 0 ]; do
  case $1 in
    --prefix)   [ $# -ge 2 ] || die "--prefix needs a key, for example ctrl+space"; PREFIX_KEY=$2; shift 2 ;;
    --prefix=*) PREFIX_KEY=${1#--prefix=}; shift ;;
    --force)    FORCE=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage >&2; die "unknown option: $1" ;;
  esac
done
if [ "$UNINSTALL" = 1 ] && { [ -n "$PREFIX_KEY" ] || [ "$FORCE" = 1 ]; }; then
  die "--uninstall takes no --prefix or --force"
fi

# --- preflight ------------------------------------------------------------------

version_ge() { # version_ge HAVE WANT: is HAVE at least WANT?
  local IFS=. i a b
  local -a h w
  h=($1); w=($2)
  for i in 0 1 2; do
    a=${h[$i]:-0}; b=${w[$i]:-0}
    if ((a > b)); then return 0; fi
    if ((a < b)); then return 1; fi
  done
  return 0
}

missing=""
need() { command -v "$1" >/dev/null 2>&1 || missing="$missing
  $1 - $2"; }
need herdr "install it from https://herdr.dev"
need perl  "macOS ships it; Debian/Ubuntu: apt install perl; Fedora: dnf install perl"
need jq    "macOS: brew install jq; Debian/Ubuntu: apt install jq; Fedora: dnf install jq"
[ -z "$missing" ] || die "missing:$missing"

have=$(herdr --version 2>/dev/null || true)
have=${have##* }
if [[ $have =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  version_ge "$have" "$MIN_HERDR" || die "herdr $have is too old: herdr-tmuxify needs $MIN_HERDR or newer"
else
  say "note: could not read herdr's version; assuming it is at least $MIN_HERDR"
fi

[ -n "${HOME:-}" ] || [ -n "${HERDR_CONFIG_PATH:-}" ] || die "HOME is not set"
CONFIG=${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/herdr-tmuxify.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
CAND="$TMP/config.toml"      # the config as it would be
ORIG="$TMP/orig.toml"        # the config as it is
if [ -e "$CONFIG" ]; then cp "$CONFIG" "$ORIG"; else : >"$ORIG"; fi
cp "$ORIG" "$CAND"

# --- helpers ------------------------------------------------------------------------

print_report() { # print_report FILE: merge.pl's report, one aligned line per unit
  local status what detail
  while IFS=$'\t' read -r status what detail; do
    [ -n "$status" ] || continue
    if [ -n "$detail" ]; then printf '  %-9s %s - %s\n' "$status" "$what" "$detail"
    else printf '  %-9s %s\n' "$status" "$what"; fi
  done <"$1"
}

new_diagnostics() { # new_diagnostics BEFORE AFTER: lines of AFTER that BEFORE lacks
  if [ -z "$1" ]; then printf '%s' "$2"; return; fi
  printf '%s\n' "$2" | grep -vxF -f <(printf '%s\n' "$1") || true
}

BACKUP=""
write_config() { # write_config: CAND becomes the config, after a backup
  mkdir -p "$(dirname "$CONFIG")"
  if [ -e "$CONFIG" ]; then
    BACKUP="$CONFIG.tmuxify-bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$CONFIG" "$BACKUP"
  fi
  cat "$CAND" >"$CONFIG"          # through a symlink, never over it
}

restore_config() {
  if [ -n "$BACKUP" ]; then cat "$BACKUP" >"$CONFIG"; rm -f "$BACKUP"; BACKUP=""
  else rm -f "$CONFIG"; fi
}

server_running() {
  local out
  out=$(herdr workspace list 2>/dev/null || true)
  case $out in *'"result"'*) return 0 ;; *) return 1 ;; esac
}

show_diff() {
  diff -u -L "$CONFIG" -L "$CONFIG (after)" "$ORIG" "$CAND" || true
}

# --- uninstall ---------------------------------------------------------------------------

if [ "$UNINSTALL" = 1 ]; then
  perl "$ROOT/lib/merge.pl" uninstall "$CAND"
  if [ "$DRY_RUN" = 1 ]; then
    if cmp -s "$ORIG" "$CAND"; then say "Nothing of ours in $CONFIG."; else show_diff; fi
    say "Would unlink the plugins and take the numbers out of tab names."
    exit 0
  fi
  if ! cmp -s "$ORIG" "$CAND"; then
    write_config
    say "Removed our lines from $CONFIG."
    [ -z "$BACKUP" ] || say "Backup of the file as it was: $BACKUP"
  else
    say "Nothing of ours in $CONFIG."
  fi
  # Unlink first: stripping renames tabs, and a still-linked numbering plugin
  # would answer each rename by putting the numbers back.
  for p in $PLUGINS; do
    herdr plugin unlink "herdr-tmuxify.$p" >/dev/null 2>&1 || say "  (plugin herdr-tmuxify.$p was not linked)"
  done
  say "Unlinked the plugins."
  if server_running; then
    if "$ROOT/plugins/numbering/renumber.sh" --strip; then say "Took the numbers out of tab names."
    else say "warning: could not take the numbers out of tab names; run plugins/numbering/renumber.sh --strip"; fi
  else
    say "No herdr server is running, so tab names keep their number prefixes (1:name)."
    say "Run plugins/numbering/renumber.sh --strip while herdr is running to remove them."
  fi
  say "Reload a running herdr with: herdr server reload-config"
  exit 0
fi

# --- install -----------------------------------------------------------------------------------

args=(install "$CAND" "$ROOT/config" --check "$ROOT/lib/check.sh")
[ -z "$PREFIX_KEY" ] || args+=(--prefix "$PREFIX_KEY")
[ "$FORCE" = 0 ] || args+=(--force)
perl "$ROOT/lib/merge.pl" "${args[@]}" >"$TMP/report" || die "merging the config failed"

if [ "$DRY_RUN" = 1 ]; then
  say "Dry run: nothing will be changed."
  print_report "$TMP/report"
  if cmp -s "$ORIG" "$CAND"; then say "No change to $CONFIG."; else show_diff; fi
  for p in $PLUGINS; do say "Would link plugin: $ROOT/plugins/$p"; done
  exit 0
fi

if ! cmp -s "$ORIG" "$CAND"; then
  write_config
  # The trial merge already kept only units that left herdr's check no worse.
  # This is the safety net: if the file as written still reads worse than the
  # one we started from, put the original back.
  before=$("$ROOT/lib/check.sh" "$ORIG" || true)
  after=$("$ROOT/lib/check.sh" "$CONFIG" || true)
  worse=$(new_diagnostics "$before" "$after")
  if [ -n "$worse" ]; then
    restore_config
    die "herdr's config check disliked the merged file, so your config was restored:
$worse"
  fi
fi

for p in $PLUGINS; do
  herdr plugin link "$ROOT/plugins/$p" >/dev/null \
    || die "herdr plugin link failed for $p. The config is already merged; fix the problem and run ./install.sh again."
done

say "herdr-tmuxify installed. Config: $CONFIG"
print_report "$TMP/report"
say "Linked plugins: $(for p in $PLUGINS; do printf 'herdr-tmuxify.%s ' "$p"; done)"
[ -z "$BACKUP" ] || say "Backup of your config as it was: $BACKUP"
if grep -q '^skipped' "$TMP/report"; then
  say "Skipped lines are settings of yours (or conflicts) left as they were; see above for the line to add by hand, or run again with --force."
fi
say "Reload a running herdr with: herdr server reload-config"
say "Remove it all with: ./install.sh --uninstall"
