#!/usr/bin/env bash
# Runs every test inside a Lima Debian VM, as a stranger's Linux box would see
# them. A developer tool: CI covers the same ground on ubuntu-latest, and the
# VM adds a real Linux login and the arm64 build. Run it from macOS:
#
#   test/linux.sh            create the VM on first use, then run the tests
#   test/linux.sh --delete   remove the VM
#
# The VM has no host mounts: it cannot see your home directory. The repo is
# copied in (without .git) on every run, and herdr is the release named in
# test/herdr-version, downloaded as a binary.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
VM=${HERDR_TMUXIFY_VM:-herdr-tmuxify-test}
VERSION=$(tr -d '[:space:]' <"$ROOT/test/herdr-version")

die() { printf 'test/linux.sh: %s\n' "$*" >&2; exit 1; }
command -v limactl >/dev/null 2>&1 || die "Lima is not installed (macOS: brew install lima)"

if [ "${1:-}" = "--delete" ]; then
  limactl delete --force "$VM"
  exit 0
fi

vm() { limactl shell "$VM" -- "$@"; }

state=$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$VM" '$1 == n { print $2 }')
case $state in
  Running) ;;
  Stopped) limactl start "$VM" ;;
  "")      limactl start --name="$VM" --cpus 2 --memory 4 --disk 20 --containerd none \
             --mount-none --tty=false template:debian ;;
  *)       die "VM $VM is in state $state" ;;
esac

echo "== provisioning (jq, perl, curl, herdr $VERSION)"
vm sh -s "$VERSION" <<'PROVISION'
set -eu
version=$1
for t in jq curl perl; do
  command -v "$t" >/dev/null 2>&1 || need="${need:-} $t"
done
if [ -n "${need:-}" ]; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq jq curl ca-certificates perl >/dev/null
fi
case $(uname -m) in
  aarch64|arm64) asset=herdr-linux-aarch64 ;;
  x86_64)        asset=herdr-linux-x86_64 ;;
  *) echo "no herdr build for $(uname -m)" >&2; exit 1 ;;
esac
mkdir -p "$HOME/.local/bin"
want=${version#v}
have=$("$HOME/.local/bin/herdr" --version 2>/dev/null || true)
case $have in
  *" $want") ;;
  *) curl -fsSL -o "$HOME/.local/bin/herdr" "https://github.com/herdrdev/herdr/releases/download/$version/$asset"
     chmod +x "$HOME/.local/bin/herdr" ;;
esac
"$HOME/.local/bin/herdr" --version
PROVISION

echo "== copying the repo into the VM"
tar -C "$ROOT" --exclude=.git -cf - . | vm sh -c 'rm -rf "$HOME/herdr-tmuxify" && mkdir "$HOME/herdr-tmuxify" && tar -C "$HOME/herdr-tmuxify" -xf -'

echo "== running the tests in the VM"
vm bash -c 'cd "$HOME/herdr-tmuxify" && export PATH="$HOME/.local/bin:$PATH" && test/all.sh && echo && test/e2e.sh'
