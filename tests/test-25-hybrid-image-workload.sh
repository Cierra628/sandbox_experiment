#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/25-benchmark-hybrid-image-workload.sh"

bash -n "$SCRIPT"
help="$($SCRIPT --help)"
grep -F -- '--app-mode MODE' <<<"$help" >/dev/null
grep -F -- '--app-loop DEV' <<<"$help" >/dev/null

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
if "$SCRIPT" --state-loop dummy --app-mode unsupported >"$out" 2>&1; then
  echo 'expected --app-mode validation failure' >&2
  exit 1
fi
grep -F -- '--app-mode must be virtiofs or virtio-blk' "$out" >/dev/null

grep -F -- 'app_mode' "$SCRIPT" >/dev/null
grep -F -- 'virtiofs-root+virtiofs-app+virtio-blk-state' "$SCRIPT" >/dev/null

echo 'test-25-hybrid-image-workload: PASS'
