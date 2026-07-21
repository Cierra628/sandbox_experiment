#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${OPENCLAW_DATA_DIR:-$HOME/.local/share/openclaw-kuasar/openclaw-state}"
VMM_STATE_DIR="${VMM_OPENCLAW_DATA_DIR:-/var/lib/openclaw-kuasar/openclaw-state}"
SKIP_VMM=0

usage() {
  printf '%s\n' \
    'Usage: scripts/16-prepare-image-workload.sh [--state DIR] [--vmm-state DIR] [--skip-vmm]'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; STATE_DIR="$2"; shift 2 ;;
    --vmm-state) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; VMM_STATE_DIR="$2"; shift 2 ;;
    --skip-vmm) SKIP_VMM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo 'error: node is required' >&2; exit 1; }
PLUGIN_SRC="$ROOT_DIR/workloads/image-upscale"
test -f "$PLUGIN_SRC/openclaw.plugin.json" || { echo "error: missing plugin source: $PLUGIN_SRC" >&2; exit 1; }
test -f "$PLUGIN_SRC/image-upscale.mjs" || { echo "error: missing image tool: $PLUGIN_SRC/image-upscale.mjs" >&2; exit 1; }

update_config() {
  local state="$1" config="$1/openclaw.json" temp
  test -f "$config" || { echo "error: missing OpenClaw config: $config" >&2; return 1; }
  temp="$(mktemp "${state}/.openclaw.json.XXXXXX")"
  jq '
    (.plugins //= {}) |
    (.plugins.allow //= []) |
    (.plugins.allow += ["image-upscale"] | .plugins.allow |= unique) |
    (.plugins.load //= {}) |
    (.plugins.load.paths //= []) |
    (.plugins.load.paths += ["/home/node/.openclaw/workspace/.openclaw/extensions/image-upscale"] | .plugins.load.paths |= unique) |
    (.plugins.entries //= {}) |
    (.plugins.entries["image-upscale"] //= {}) |
    (.plugins.entries["image-upscale"].enabled = true) |
    (.tools //= {}) |
    (.tools.alsoAllow //= []) |
    (.tools.alsoAllow += ["group:plugins"] | .tools.alsoAllow |= unique)
  ' "$config" > "$temp"
  chmod 600 "$temp"
  mv -f "$temp" "$config"
}

prepare_state() {
  local state="$1" root_owned="${2:-0}" use_sudo=0 extension="$1/workspace/.openclaw/extensions/image-upscale" workload="$1/workspace/complex-workload" staged
  [ -d "$state" ] || use_sudo=1
  [ -w "$state" ] 2>/dev/null || use_sudo=1

  if [ "$use_sudo" = 1 ]; then
    sudo mkdir -p "$extension" "$workload"
    sudo cp -a "$PLUGIN_SRC"/. "$extension"/
    staged="$(mktemp)"
    node "$PLUGIN_SRC/image-upscale.mjs" generate "$staged" --width 32 --height 32 --seed 7 >/dev/null
    sudo install -m 0644 "$staged" "$workload/input.pgm"
    rm -f "$staged"
    if [ "$root_owned" = 1 ]; then
      sudo chown -R 0:0 "$extension"
    fi
    sudo bash -c "$(declare -f update_config); update_config '$state'"
  else
    mkdir -p "$extension" "$workload"
    cp -a "$PLUGIN_SRC"/. "$extension"/
    node "$PLUGIN_SRC/image-upscale.mjs" generate "$workload/input.pgm" --width 32 --height 32 --seed 7 >/dev/null
    update_config "$state"
  fi
  printf '%s\n' "Prepared image workload state: $state"
}

prepare_state "$STATE_DIR" 0
if [ "$SKIP_VMM" != 1 ]; then
  prepare_state "$VMM_STATE_DIR" 1
fi

printf '%s\n' \
  'Input: 32x32 PGM (1024 pixels)' \
  'Output contract: 64x64 PGM (4096 pixels; scale=2 in each dimension)' \
  'Agent tool: image_upscale'
