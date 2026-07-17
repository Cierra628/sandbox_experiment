#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/containerd"
if [ -f "$ROOT_DIR/config/versions.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/config/versions.env"
fi

OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:2026.6.11}"
OPENCLAW_DATA_DIR="${OPENCLAW_DATA_DIR:-$HOME/.local/share/openclaw-kuasar/openclaw-state}"
VMM_OPENCLAW_DATA_DIR="${VMM_OPENCLAW_DATA_DIR:-/var/lib/openclaw-kuasar/openclaw-state}"
OPENCLAW_CONTAINER_PORT="${OPENCLAW_CONTAINER_PORT:-18790}"

if [ ! -d "$OPENCLAW_DATA_DIR" ]; then
  echo "error: OpenClaw state directory does not exist: $OPENCLAW_DATA_DIR" >&2
  echo 'Run scripts/07-prepare-openclaw-state.sh first or set OPENCLAW_DATA_DIR to an existing directory.' >&2
  exit 1
fi
if [ ! -f "$OPENCLAW_DATA_DIR/openclaw.json" ]; then
  echo "error: missing openclaw.json in $OPENCLAW_DATA_DIR" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

install -m 0644 /dev/stdin "$OUT_DIR/openclaw-pod.json" <<EOF_POD
{
  "metadata": {
    "name": "openclaw",
    "namespace": "sandbox-experiment",
    "uid": "openclaw-kuasar-experiment"
  },
  "log_directory": "/tmp/openclaw-kuasar-logs",
  "linux": {
    "security_context": {
      "namespace_options": {
        "network": 2
      }
    }
  }
}
EOF_POD

jq '.linux.security_context.namespace_options.network = 0 | .dns_config = {servers:["10.2.0.1"], searches:["epcc"], options:[]}' "$OUT_DIR/openclaw-pod.json" > "$OUT_DIR/openclaw-pod-vmm.json"

install -m 0644 /dev/stdin "$OUT_DIR/openclaw-container.json" <<EOF_CONTAINER
{
  "metadata": {
    "name": "openclaw-gateway"
  },
  "image": {
    "image": "$OPENCLAW_IMAGE"
  },
  "command": ["node"],
  "args": ["openclaw.mjs", "gateway", "--bind", "loopback", "--port", "$OPENCLAW_CONTAINER_PORT"],
  "working_dir": "/app",
  "log_path": "openclaw-gateway.log",
  "envs": [
    {"key": "HOME", "value": "/home/node"},
    {"key": "OPENCLAW_STATE_DIR", "value": "/home/node/.openclaw"},
    {"key": "OPENCLAW_CONFIG_PATH", "value": "/home/node/.openclaw/openclaw.json"},
    {"key": "OPENCLAW_DISABLE_BONJOUR", "value": "1"},
    {"key": "OPENCLAW_GATEWAY_PORT", "value": "$OPENCLAW_CONTAINER_PORT"}
  ],
  "mounts": [
    {
      "container_path": "/home/node/.openclaw",
      "host_path": "$OPENCLAW_DATA_DIR",
      "readonly": false
    }
  ],
  "linux": {
    "security_context": {
      "run_as_user": {"value": 1002},
      "run_as_group": {"value": 1002},
      "readonly_rootfs": false,
      "privileged": false
    }
  }
}
EOF_CONTAINER

jq --arg path "$VMM_OPENCLAW_DATA_DIR" --arg port "$OPENCLAW_CONTAINER_PORT" '
  .mounts[0].host_path = $path |
  .linux.security_context.run_as_user.value = 0 |
  .linux.security_context.run_as_group.value = 0 |
  .command = ["sh"] |
  .args = ["-c", "i=0; while [ $i -lt 150 ]; do if [ -f /home/node/.openclaw/openclaw.json ] && [ -d /home/node/.openclaw/state ] && ls /home/node/.openclaw/npm/projects/*/node_modules/@openclaw/deepseek-provider/dist/index.js >/dev/null 2>&1 && touch /home/node/.openclaw/state/.mount-ready && rm -f /home/node/.openclaw/state/.mount-ready; then exec node openclaw.mjs gateway --bind loopback --port " + $port + "; fi; i=$((i+1)); sleep 0.2; done; echo VMM-state-mount-not-ready-within-30s >&2; exit 1"]
' "$OUT_DIR/openclaw-container.json" > "$OUT_DIR/openclaw-container-vmm.json"

python3 -m json.tool "$OUT_DIR/openclaw-pod.json" >/dev/null
python3 -m json.tool "$OUT_DIR/openclaw-pod-vmm.json" >/dev/null
python3 -m json.tool "$OUT_DIR/openclaw-container.json" >/dev/null
python3 -m json.tool "$OUT_DIR/openclaw-container-vmm.json" >/dev/null
printf '%s\n' "Generated $OUT_DIR/openclaw-pod.json" "Generated $OUT_DIR/openclaw-pod-vmm.json" "Generated $OUT_DIR/openclaw-container.json" "Generated $OUT_DIR/openclaw-container-vmm.json" "Image: $OPENCLAW_IMAGE"
