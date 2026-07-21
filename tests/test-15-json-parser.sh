#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/15-benchmark-remote-coldstart.sh"
function_text="$(awk '/^json_from_output\(\)/ { found=1 } found { print } found && /^}/ { exit }' "$SCRIPT")"
[ -n "$function_text" ] || exit 1
eval "$function_text"

sample=$'[diagnostic] before\n{\n  "payloads": [{"text": "KUASAR_SAMPLE_OK"}],\n  "meta": {"durationMs": 12}\n}\n[agent] run ended with stopReason=stop'
parsed="$(json_from_output <<<"$sample")"

jq -e '.payloads[0].text == "KUASAR_SAMPLE_OK" and .meta.durationMs == 12' <<<"$parsed" >/dev/null
printf 'JSON parser test: PASS\n'
