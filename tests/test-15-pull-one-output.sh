#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/15-benchmark-remote-coldstart.sh"

timed_text="$(awk '/^timed\(\)/ { found=1 } found { print } found && /^}/ { exit }' "$SCRIPT")"
pull_text="$(awk '/^pull_one\(\)/ { found=1 } found { print } found && /^}/ { exit }' "$SCRIPT")"

[ -n "$timed_text" ] && [ -n "$pull_text" ] || {
  printf 'timed/pull_one functions are missing\n' >&2
  exit 1
}
eval "$timed_text"
eval "$pull_text"

now_ms() { printf '1\n'; }
PULL_TIMEOUT=1s
CRI=(printf 'PULL_OK ')

out=''
elapsed=''
pull_one test-image out elapsed

[ -n "$out" ]
[ "$elapsed" = 0 ]
printf 'pull_one output test: PASS\n'
