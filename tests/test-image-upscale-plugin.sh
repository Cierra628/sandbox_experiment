#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT_DIR/workloads/image-upscale"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir"
printf '%s\n' '{"plugins":{}}' > "$tmp_dir/openclaw.json"
command -v node >/dev/null 2>&1
command -v openclaw >/dev/null 2>&1
command -v jq >/dev/null 2>&1
test -f "$PLUGIN_DIR/package.json"
test -f "$PLUGIN_DIR/openclaw.plugin.json"
test -f "$PLUGIN_DIR/index.mjs"

jq -e '.id == "image-upscale" and (.contracts.tools | index("image_upscale"))' \
  "$PLUGIN_DIR/openclaw.plugin.json" >/dev/null

OPENCLAW_STATE_DIR="$tmp_dir" \
OPENCLAW_CONFIG_PATH="$tmp_dir/openclaw.json" \
openclaw plugins validate \
  --root "$PLUGIN_DIR" \
  --entry ./index.mjs

printf '%s\n' 'image upscale plugin test passed'
