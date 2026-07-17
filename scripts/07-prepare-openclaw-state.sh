#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${HOME}/.openclaw"
destination="${HOME}/.local/share/openclaw-kuasar/openclaw-state"
replace=0
test_mode=0

usage() {
  printf '%s\n' 'Usage: scripts/07-prepare-openclaw-state.sh [--source DIR] [--destination DIR] [--replace] [--test-mode]'
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; source_dir="$2"; shift 2 ;;
    --destination) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; destination="$2"; shift 2 ;;
    --replace) replace=1; shift ;;
    --test-mode) test_mode=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -f "$source_dir/openclaw.json" ] || {
  echo "error: source does not contain openclaw.json: $source_dir" >&2
  exit 1
}

if [ -e "$destination" ]; then
  if [ "$replace" != 1 ] && find "$destination" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    echo "error: destination is non-empty; pass --replace to replace it: $destination" >&2
    exit 1
  fi
  if [ "$replace" = 1 ]; then
    rm -rf -- "$destination"
  fi
fi

mkdir -p "$destination"
chmod 700 "$destination"
# Copy state without printing or inspecting credential-bearing files.
cp -a "$source_dir"/. "$destination"/
chmod 700 "$destination"

rewrite_workspace() {
  local config="$destination/openclaw.json"
  local tmp
  tmp="$(mktemp "$destination/.openclaw.json.XXXXXX")"
  jq '(.agents //= {}) | (.agents.defaults //= {}) | .agents.defaults.workspace = "/home/node/.openclaw/workspace"' "$config" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$config"
}

if [ "$test_mode" = 1 ]; then
  command -v jq >/dev/null 2>&1 || { echo 'error: jq is required for test mode' >&2; exit 1; }
  rewrite_workspace
  printf 'Prepared state: %s\nMode: %s\nValidation: fixture rewrite passed\n' "$destination" "$(stat -c %a "$destination")"
  exit 0
fi

command -v openclaw >/dev/null 2>&1 || { echo 'error: openclaw is required' >&2; exit 1; }
OPENCLAW_STATE_DIR="$destination" OPENCLAW_CONFIG_PATH="$destination/openclaw.json" \
  openclaw config set agents.defaults.workspace /home/node/.openclaw/workspace >/dev/null 2>&1
OPENCLAW_STATE_DIR="$destination" OPENCLAW_CONFIG_PATH="$destination/openclaw.json" \
  openclaw config validate >/dev/null 2>&1
printf 'Prepared state: %s\nMode: %s\nValidation: passed\n' "$destination" "$(stat -c %a "$destination")"
