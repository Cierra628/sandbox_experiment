#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT_DIR/workloads/image-upscale/image-upscale.mjs"
command -v node >/dev/null 2>&1
command -v jq >/dev/null 2>&1
test -f "$TOOL"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

node "$TOOL" generate "$tmp_dir/input.pgm" \
  --width 32 \
  --height 32 \
  --seed 7 > "$tmp_dir/generate.json"

node "$TOOL" upscale "$tmp_dir/input.pgm" "$tmp_dir/output.pgm" \
  --scale 2 \
  --passes 16 > "$tmp_dir/upscale.json"

jq -e '
  .ok == true and
  .scale == 2 and
  .passes == 16 and
  .input.width == 32 and
  .input.height == 32 and
  .input.pixels == 1024 and
  .output.width == 64 and
  .output.height == 64 and
  .output.pixels == 4096 and
  (.input.sha256 | length == 64) and
  (.output.sha256 | length == 64) and
  (.output.bytes > 4000)
' "$tmp_dir/upscale.json" >/dev/null

node "$TOOL" upscale "$tmp_dir/input.pgm" "$tmp_dir/output-2.pgm" \
  --scale 2 \
  --passes 16 > "$tmp_dir/upscale-2.json"

test "$(jq -r .output.sha256 "$tmp_dir/upscale.json")" = \
  "$(jq -r .output.sha256 "$tmp_dir/upscale-2.json")"
printf '%s\n' 'image upscale test passed'
