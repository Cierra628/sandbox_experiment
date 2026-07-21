#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/15-benchmark-remote-coldstart.sh"

function_text="$(awk '
  /^vmm_workload_lines\(\)/ { found=1 }
  found { print }
  found && /^}/ { exit }
' "$SCRIPT")"

[ -n "$function_text" ] || {
  printf 'vmm_workload_lines function is missing\n' >&2
  exit 1
}
eval "$function_text"

sample=$'1997391 /opt/kata/libexec/virtiofsd --shared-dir=/run/kata-containers/shared/sandboxes/old/shared\n2049451 /usr/libexec/virtiofsd --socket-path /var/lib/openclaw-kuasar/vmm/sandbox/virtiofs.sock\n2049450 /usr/local/libexec/openclaw-kuasar/cloud-hypervisor --api-socket /var/lib/openclaw-kuasar/vmm/sandbox/api.sock'
matches="$(vmm_workload_lines "$sample")"

grep -q '^2049451 ' <<<"$matches"
grep -q '^2049450 ' <<<"$matches"
if grep -q '^1997391 ' <<<"$matches"; then
  printf 'unrelated Kata virtiofsd was incorrectly classified\n' >&2
  exit 1
fi

printf 'vmm process filter test: PASS\n'
