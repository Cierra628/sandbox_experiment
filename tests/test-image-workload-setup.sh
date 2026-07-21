#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

state_dir="$tmp_dir/state"
vmm_state_dir="$tmp_dir/vmm-state"
mkdir -p "$state_dir/workspace" "$vmm_state_dir/workspace"
cat > "$state_dir/openclaw.json" <<'JSON'
{
  "agents": {"defaults": {"workspace": "/home/node/.openclaw/workspace"}},
  "plugins": {"allow": ["deepseek"], "entries": {"deepseek": {"enabled": true}}}
}
JSON
cp "$state_dir/openclaw.json" "$vmm_state_dir/openclaw.json"

set +e
output="$(
  "$ROOT_DIR/scripts/16-prepare-image-workload.sh" \
    --state "$state_dir" \
    --vmm-state "$vmm_state_dir" 2>&1
)"
rc=$?
set -e
[ "$rc" -eq 0 ] || { printf '%s\n' "$output" >&2; exit "$rc"; }

for state in "$state_dir" "$vmm_state_dir"; do
  test -f "$state/openclaw.json"
  test -f "$state/workspace/complex-workload/input.pgm"
  test -f "$state/workspace/.openclaw/extensions/image-upscale/openclaw.plugin.json"
  jq -e '.plugins.allow | index("image-upscale")' "$state/openclaw.json" >/dev/null
  jq -e '.plugins.entries["image-upscale"].enabled == true' "$state/openclaw.json" >/dev/null
  jq -e '.tools.alsoAllow | index("group:plugins")' "$state/openclaw.json" >/dev/null
done

test "$(sha256sum "$state_dir/workspace/complex-workload/input.pgm" | awk '{print $1}')" = \
  "$(sha256sum "$vmm_state_dir/workspace/complex-workload/input.pgm" | awk '{print $1}')"
printf '%s\n' 'image workload setup test passed'
