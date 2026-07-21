#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/17-benchmark-image-workload.sh"
test -f "$SCRIPT"
bash -n "$SCRIPT"

output="$(
  IMAGE_WORKLOAD_HANDLERS='runc kuasar-vmm' \
  IMAGE_WORKLOAD_RUNS=1 \
  IMAGE_WORKLOAD_PASSES=1 \
  "$SCRIPT" --dry-run
)"
grep -Fq 'handlers=runc kuasar-vmm' <<<"$output"
grep -Fq 'scale=2' <<<"$output"
grep -Fq 'input=32x32 PGM (1024 pixels)' <<<"$output"
printf '%s\n' 'image workload benchmark test passed'
