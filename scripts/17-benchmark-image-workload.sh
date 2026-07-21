#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT_DIR/config/versions.env" ] && source "$ROOT_DIR/config/versions.env"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-localhost/openclaw-kuasar:2026.6.11-virtiofs}"
HANDLERS="${IMAGE_WORKLOAD_HANDLERS:-runc kuasar-runc kuasar-vmm}"
RUNS="${IMAGE_WORKLOAD_RUNS:-3}"
PASSES="${IMAGE_WORKLOAD_PASSES:-512}"
STATE_DIR="${OPENCLAW_DATA_DIR:-$HOME/.local/share/openclaw-kuasar/openclaw-state}"
VMM_STATE_DIR="${VMM_OPENCLAW_DATA_DIR:-/var/lib/openclaw-kuasar/openclaw-state}"
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/.artifacts/image-workload-$(date -u +%Y%m%dT%H%M%SZ)}"
DRY_RUN=0
usage(){ printf '%s\n' 'Usage: scripts/17-benchmark-image-workload.sh [--handlers LIST] [--runs N] [--passes N] [--result-dir DIR] [--dry-run]'; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --handlers) HANDLERS="$2"; shift 2;;
    --runs) RUNS="$2"; shift 2;;
    --passes) PASSES="$2"; shift 2;;
    --result-dir) RESULT_DIR="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) usage >&2; exit 2;;
  esac
done
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo 'error: runs must be positive' >&2; exit 2; }
[[ "$PASSES" =~ ^[1-9][0-9]*$ ]] || { echo 'error: passes must be positive' >&2; exit 2; }
for h in $HANDLERS; do case "$h" in runc|kuasar-runc|kuasar-vmm);; *) echo "error: unsupported handler $h" >&2; exit 2;; esac; done
printf '%s\n' 'Image workload benchmark plan:' "  image=$OPENCLAW_IMAGE" "  handlers=$HANDLERS" "  runs_per_handler=$RUNS" "  passes=$PASSES" '  input=32x32 PGM (1024 pixels)' '  output=64x64 PGM (4096 pixels)' '  scale=2 (4x pixels)' "  result_dir=$RESULT_DIR"
[ "$DRY_RUN" -eq 1 ] && exit 0
command -v jq >/dev/null || exit 1
sudo -v
mkdir -p "$RESULT_DIR/runs" "$RESULT_DIR/rows"
"$ROOT_DIR/scripts/16-prepare-image-workload.sh" --state "$STATE_DIR" --vmm-state "$VMM_STATE_DIR"
OPENCLAW_IMAGE="$OPENCLAW_IMAGE" OPENCLAW_DATA_DIR="$STATE_DIR" VMM_OPENCLAW_DATA_DIR="$VMM_STATE_DIR" "$ROOT_DIR/scripts/03-generate-cri-specs.sh" >/dev/null
PROMPT="Use image_upscale exactly once. Read /home/node/.openclaw/workspace/complex-workload/input.pgm, write /home/node/.openclaw/workspace/complex-workload/output.pgm, use scale=2 and passes=$PASSES. After the tool succeeds, reply with exactly KUASAR_SAMPLE_OK and nothing else. Do not claim success without calling the tool."
for h in $HANDLERS; do
  for r in $(seq 1 "$RUNS"); do
    dir="$RESULT_DIR/runs/$h-$r"; mkdir -p "$dir"
    state="$STATE_DIR"; [ "$h" = kuasar-vmm ] && state="$VMM_STATE_DIR"
    if [ "$h" = kuasar-vmm ]; then sudo rm -f "$state/workspace/complex-workload/output.pgm" "$state/workspace/complex-workload/output.pgm.json"; else rm -f "$state/workspace/complex-workload/output.pgm" "$state/workspace/complex-workload/output.pgm.json"; fi
    set +e
    BENCHMARK_HANDLERS="$h" BENCHMARK_RUNS=1 MODEL_SAMPLE_RUNS=1 MODEL_SAMPLE_MESSAGE="$PROMPT" MODEL_SAMPLE_EXPECTED=KUASAR_SAMPLE_OK OPENCLAW_IMAGE="$OPENCLAW_IMAGE" OPENCLAW_DATA_DIR="$STATE_DIR" VMM_OPENCLAW_DATA_DIR="$VMM_STATE_DIR" RESULT_DIR="$dir" "$ROOT_DIR/scripts/08-benchmark-runtimes.sh" > "$dir/runner.log" 2>&1
    rc=$?
    set -e
    base="$(jq '.[0] // {}' "$dir/results.json" 2>/dev/null || printf '{}')"
    if [ "$h" = kuasar-vmm ]; then trace="$(sudo cat "$state/workspace/complex-workload/output.pgm.json" 2>/dev/null || true)"; else trace="$(cat "$state/workspace/complex-workload/output.pgm.json" 2>/dev/null || true)"; fi
    [ -n "$trace" ] || trace='{}'
    status="$(jq -r '.status // "FAIL"' <<<"$base")"; [ "$rc" -eq 0 ] || status=FAIL
    jq -e '.ok == true and .input.pixels == 1024 and .output.pixels == 4096 and .scale == 2' >/dev/null 2>&1 <<<"$trace" || status=FAIL
    jq -n --arg handler "$h" --argjson run "$r" --arg status "$status" --argjson base "$base" --argjson trace "$trace" '$base + {handler:$handler,run:$run,status:$status,validation:{tool_trace:($trace.ok == true and $trace.input.pixels == 1024 and $trace.output.pixels == 4096 and $trace.scale == 2)},tool:{read_ms:($trace.timing_ms.read//0),compute_ms:($trace.timing_ms.compute//0),write_ms:($trace.timing_ms.write//0),total_ms:($trace.timing_ms.total//0)},image:{input_bytes:($trace.input.bytes//0),output_bytes:($trace.output.bytes//0),input_pixels:($trace.input.pixels//0),output_pixels:($trace.output.pixels//0)}}' > "$RESULT_DIR/rows/$h-$r.json"
    printf 'handler=%s run=%s status=%s\n' "$h" "$r" "$status"
  done
done
jq -s '.' "$RESULT_DIR/rows"/*.json > "$RESULT_DIR/results.json"
jq 'def avg(f):(map(f)|if length==0 then 0 else add/length end); group_by(.handler)|map({handler:.[0].handler,runs:length,passed:(map(select(.status=="PASS"))|length),failed:(map(select(.status!="PASS"))|length),averages_ms:{runp:avg(.runp_ms),create:avg(.create_ms),start:avg(.start_ms),gateway_ready:avg(.gateway_ready_ms),health_exec:avg(.health_exec_ms),health_internal:avg(.health_internal_ms),sample_exec:avg(.sample_exec_ms),sample_internal:avg(.sample_internal_ms),tool_read:avg(.tool.read_ms),tool_compute:avg(.tool.compute_ms),tool_write:avg(.tool.write_ms),tool_total:avg(.tool.total_ms),cleanup:avg(.cleanup_ms),total:avg(.total_ms)}})' "$RESULT_DIR/results.json" > "$RESULT_DIR/summary.json"
failed="$(jq '[.[]|select(.status!="PASS")]|length' "$RESULT_DIR/results.json")"
printf '%s\n' "results=$RESULT_DIR" "rows=$(jq length "$RESULT_DIR/results.json")" "failed=$failed"
jq . "$RESULT_DIR/summary.json"
[ "$failed" -eq 0 ]
