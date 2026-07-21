#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/15-benchmark-remote-coldstart.sh"
function_text="$(awk '/^root_bytes\(\)/ { found=1 } found { print } found && /^}/ { exit }' "$SCRIPT")"
[ -n "$function_text" ] || {
  printf 'root_bytes function is missing\n' >&2
  exit 1
}
eval "$function_text"

CT_ROOT=/var/lib/openclaw-kuasar/containerd
du() { return 1; }
sudo() {
  [ "$1" = du ] || return 1
  printf '123456\n'
}

bytes="$(root_bytes)"
[ "$bytes" = 123456 ]
printf 'root_bytes privilege test: PASS\n'
