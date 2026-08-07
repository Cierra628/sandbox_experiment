#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/32-profile-hybrid-paths.sh"

bash -n "$SCRIPT"
help="$($SCRIPT --help)"
grep -F -- '--expected-cache VALUE' <<<"$help" >/dev/null
grep -F -- '--runtime-loop DEV' <<<"$help" >/dev/null
grep -F -- '--app-mode MODE' <<<"$help" >/dev/null
grep -F -- '--top-paths N' <<<"$help" >/dev/null

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
if "$SCRIPT" --repeats 0 >"$out" 2>&1; then
  echo 'expected --repeats validation failure' >&2
  exit 1
fi
grep -F -- '--repeats must be a positive integer' "$out" >/dev/null

grep -F -- 'cache_mode:$cache_mode' "$SCRIPT" >/dev/null
grep -F -- 'top_paths' "$SCRIPT" >/dev/null
grep -F -- '-top.tsv' "$SCRIPT" >/dev/null

if "$SCRIPT" --top-paths 0 >"$out" 2>&1; then
  echo 'expected --top-paths validation failure' >&2
  exit 1
fi
grep -F -- '--top-paths must be a positive integer' "$out" >/dev/null

if "$SCRIPT" --app-mode unsupported >"$out" 2>&1; then
  echo 'expected --app-mode validation failure' >&2
  exit 1
fi
grep -F -- '--app-mode must be virtiofs or virtio-blk' "$out" >/dev/null
grep -F -- 'vmm-effective.toml' "$SCRIPT" >/dev/null

echo 'test-32-hybrid-path-profile: PASS'
