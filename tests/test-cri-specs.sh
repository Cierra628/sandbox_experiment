#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_state="$(mktemp -d)"
fixture="$(mktemp -d)"
target="$(mktemp -d)/state"
trap 'rm -rf "$tmp_state" "$fixture" "${target%/state}"' EXIT

printf '%s\n' '{"agents":{"defaults":{"workspace":"/host/workspace"}},"test_marker":"fixture-only"}' > "$tmp_state/openclaw.json"
OPENCLAW_DATA_DIR="$tmp_state" "$ROOT_DIR/scripts/03-generate-cri-specs.sh" >/dev/null
jq -e '.linux.runtime_handler == null' "$ROOT_DIR/containerd/openclaw-pod.json" >/dev/null
jq -e '.linux.security_context.namespace_options == {"network":2}' "$ROOT_DIR/containerd/openclaw-pod.json" >/dev/null
jq -e '.linux.security_context.namespace_options.network == 0' "$ROOT_DIR/containerd/openclaw-pod-vmm.json" >/dev/null
jq -e '.dns_config.servers == ["10.2.0.1"]' "$ROOT_DIR/containerd/openclaw-pod-vmm.json" >/dev/null
jq -e '.image.image == "localhost/openclaw-kuasar:2026.6.11-virtiofs"' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
jq -e '.command == ["node"]' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
jq -e '.args == ["openclaw.mjs","gateway","--bind","loopback","--port","18790"]' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
jq -e 'any(.envs[]; .key == "OPENCLAW_GATEWAY_PORT" and .value == "18790")' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
jq -e '.mounts[0].container_path == "/home/node/.openclaw"' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
jq -e '.linux.resources == null' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
jq -e '.linux.security_context.run_as_user.value == 1002' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
jq -e '.mounts[0].host_path == "/var/lib/openclaw-kuasar/openclaw-state"' "$ROOT_DIR/containerd/openclaw-container-vmm.json" >/dev/null
jq -e '.linux.security_context.run_as_user.value == 0' "$ROOT_DIR/containerd/openclaw-container-vmm.json" >/dev/null
jq -e '.linux.security_context.run_as_group.value == 0' "$ROOT_DIR/containerd/openclaw-container-vmm.json" >/dev/null
jq -e '.command == ["sh"]' "$ROOT_DIR/containerd/openclaw-container-vmm.json" >/dev/null
jq -e '.args[1] | contains("VMM-state-mount-not-ready-within-30s")' "$ROOT_DIR/containerd/openclaw-container-vmm.json" >/dev/null
jq -e '.args[1] | contains("deepseek-provider/dist/index.js") and contains("touch /home/node/.openclaw/state/.mount-ready")' "$ROOT_DIR/containerd/openclaw-container-vmm.json" >/dev/null
! rg -ni 'API_KEY|TOKEN|PASSWORD|SECRET' "$ROOT_DIR/containerd/openclaw-container.json"

printf '%s\n' '{"agents":{"defaults":{"workspace":"/host/workspace"}},"credential":"DO_NOT_PRINT"}' > "$fixture/openclaw.json"
output="$($ROOT_DIR/scripts/07-prepare-openclaw-state.sh --source "$fixture" --destination "$target" --test-mode)"
test "$(stat -c %a "$target")" = 700
test "$(jq -r '.agents.defaults.workspace' "$target/openclaw.json")" = "/home/node/.openclaw/workspace"
! grep -q 'DO_NOT_PRINT' <<<"$output"

printf '%s\n' 'test-cri-specs: PASS'
