#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/33-benchmark-hybrid-worker-sweep.sh"
CONFIG=/etc/openclaw-kuasar/vmm.toml

bash -n "$SCRIPT"
bash -n "$ROOT_DIR/scripts/25-benchmark-hybrid-image-workload.sh"
help="$($SCRIPT --help)"
grep -F -- '--values "2 4 8"' <<<"$help" >/dev/null
grep -F -- '--dry-run' <<<"$help" >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
before="$(sha256sum "$CONFIG")"

dry_output="$($SCRIPT \
  --state-loop /dev/loop8 \
  --app-loop /dev/loop24 \
  --runs 3 \
  --passes 512 \
  --values '2 4 8' \
  --result-dir "$tmp/dry-run" \
  --dry-run)"
grep -F -- 'dry-run: no system config, service, or CRI state was changed.' <<<"$dry_output" >/dev/null
after="$(sha256sum "$CONFIG")"
test "$before" = "$after"

if "$SCRIPT" \
  --state-loop /dev/loop8 \
  --app-loop /dev/loop24 \
  --runs 3 \
  --passes 512 \
  --values '2 bad' \
  --result-dir "$tmp/invalid" \
  --dry-run >"$tmp/invalid.out" 2>&1; then
  echo 'expected invalid worker value failure' >&2
  exit 1
fi
grep -F -- 'worker value is not a positive integer: bad' "$tmp/invalid.out" >/dev/null

grep -F -- 'restore_services' "$SCRIPT" >/dev/null
grep -F -- 'vmm-before.toml' "$SCRIPT" >/dev/null
grep -F -- 'scripts/25-benchmark-hybrid-image-workload.sh' "$SCRIPT" >/dev/null

echo 'test-33-hybrid-worker-sweep: PASS'
