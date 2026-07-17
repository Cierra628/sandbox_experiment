#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
help="$($ROOT_DIR/scripts/openclaw-platform help)"
for command in deploy status logs demo delete; do
  grep -q "$command" <<<"$help"
done

if PLATFORM_DRY_RUN=1 OPENCLAW_RUNTIME_HANDLER=runc "$ROOT_DIR/scripts/openclaw-platform" deploy 2>"$ROOT_DIR/.state/dry-run.err"; then
  echo 'deploy unexpectedly accepted runc' >&2
  exit 1
fi
grep -q 'kuasar-vmm is required' "$ROOT_DIR/.state/dry-run.err"
rm -f "$ROOT_DIR/.state/dry-run.err"

if OPENCLAW_RUNTIME_HANDLER=invalid "$ROOT_DIR/scripts/openclaw-platform" unknown >/dev/null 2>&1; then
  echo 'unknown command unexpectedly accepted' >&2
  exit 1
fi

grep -q 'CRI_READY_TIMEOUT' "$ROOT_DIR/scripts/04-run-with-crictl.sh"
grep -q 'wait_for_cri' "$ROOT_DIR/scripts/04-run-with-crictl.sh"
grep -q 'openclaw-container-vmm.json' "$ROOT_DIR/scripts/04-run-with-crictl.sh"
grep -q 'openclaw-pod-vmm.json' "$ROOT_DIR/scripts/04-run-with-crictl.sh"

printf '%s\n' 'test-platform-cli: PASS'
