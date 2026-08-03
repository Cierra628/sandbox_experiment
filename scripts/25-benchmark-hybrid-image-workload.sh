#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
BASE_POD_SPEC="$ROOT_DIR/containerd/openclaw-pod-vmm.json"
BASE_CONTAINER_SPEC="$ROOT_DIR/containerd/openclaw-container-vmm.json"
STATE_LOOP_DEVICE="${HYBRID_STATE_LOOP_DEVICE:-}"
APP_LOOP_DEVICE="${HYBRID_APP_LOOP_DEVICE:-}"
RUNS="${HYBRID_IMAGE_RUNS:-3}"
PASSES="${HYBRID_IMAGE_PASSES:-512}"
READY_TIMEOUT="${HYBRID_IMAGE_READY_TIMEOUT:-180}"
ARTIFACT_TIMEOUT="${HYBRID_IMAGE_ARTIFACT_TIMEOUT:-15}"
RESULT_DIR="${HYBRID_IMAGE_RESULT_DIR:-$ROOT_DIR/.artifacts/hybrid-image-workload-$(date -u +%Y%m%dT%H%M%SZ)}"

usage() {
  printf '%s\n' \
    'Usage: scripts/25-benchmark-hybrid-image-workload.sh [options]' \
    '' \
    'Runs the image-upscale Agent sample with VirtioFS rootfs and virtio-blk /app/state.' \
    '' \
    'Options:' \
    '  --state-loop DEV       existing state loop block device' \
    '  --app-loop DEV         existing /app loop block device' \
    '  --runs N               independent fresh containers (default: 3)' \
    '  --passes N             image-upscale compute passes (default: 512)' \
    '  --ready-timeout N      Gateway ready timeout in seconds' \
    '  --artifact-timeout N   tool artifact timeout in seconds' \
    '  --result-dir DIR       artifact directory' \
    '  -h, --help             show this help'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state-loop) STATE_LOOP_DEVICE="$2"; shift 2 ;;
    --app-loop) APP_LOOP_DEVICE="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --passes) PASSES="$2"; shift 2 ;;
    --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
    --artifact-timeout) ARTIFACT_TIMEOUT="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for value_name in RUNS PASSES READY_TIMEOUT ARTIFACT_TIMEOUT; do
  value="${!value_name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: $value_name must be positive" >&2
    exit 2
  }
done
[ -n "$STATE_LOOP_DEVICE" ] || { echo 'error: state loop device is required' >&2; exit 2; }
[ -n "$APP_LOOP_DEVICE" ] || { echo 'error: app loop device is required' >&2; exit 2; }

printf '%s\n' \
  'Hybrid image workload benchmark plan:' \
  '  rootfs=VirtioFS' \
  '  /app on virtio-blk (read-only)' \
  '  /home/node/.openclaw on virtio-blk (read-write)' \
  '  handler=kuasar-vmm' \
  "  app_loop=$APP_LOOP_DEVICE" \
  "  state_loop=$STATE_LOOP_DEVICE" \
  "  runs=$RUNS" \
  "  passes=$PASSES" \
  '  input=32x32 PGM (1024 pixels)' \
  '  output=64x64 PGM (4096 pixels)' \
  "  result_dir=$RESULT_DIR"

command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
command -v crictl >/dev/null 2>&1 || { echo 'error: crictl is required' >&2; exit 1; }
sudo -v
sudo test -b "$STATE_LOOP_DEVICE" || { echo "error: not a block device: $STATE_LOOP_DEVICE" >&2; exit 1; }
sudo test -b "$APP_LOOP_DEVICE" || { echo "error: not a block device: $APP_LOOP_DEVICE" >&2; exit 1; }
sudo grep -Eq '^[[:space:]]*container_storage_backend[[:space:]]*=[[:space:]]*"virtiofs"' \
  /etc/openclaw-kuasar/vmm.toml || {
    echo 'error: /etc/openclaw-kuasar/vmm.toml is not configured for virtiofs' >&2
    exit 1
  }

CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")
active_containers="$(${CRI[@]} ps -a -o json | jq '.containers | length')"
active_pods="$(${CRI[@]} pods -o json | jq '.items | length')"
if [ "$active_containers" -ne 0 ] || [ "$active_pods" -ne 0 ]; then
  echo "error: active CRI resources remain (containers=$active_containers pods=$active_pods)" >&2
  exit 1
fi

mkdir -p "$RESULT_DIR/specs" "$RESULT_DIR/rows"
HYBRID_CONTAINER_SPEC="$RESULT_DIR/specs/container-template.json"
jq --arg state "$STATE_LOOP_DEVICE" --arg app "$APP_LOOP_DEVICE" '
  (.mounts[] | select(.container_path == "/home/node/.openclaw")).host_path = $state |
  .mounts += [{"container_path":"/app","host_path":$app,"readonly":true}] |
  .metadata.name = "openclaw-hybrid-image-workload" |
  .linux.security_context.run_as_user.value = 0 |
  .linux.security_context.run_as_group.value = 0
' "$BASE_CONTAINER_SPEC" > "$HYBRID_CONTAINER_SPEC"
python3 -m json.tool "$HYBRID_CONTAINER_SPEC" >/dev/null

now_ms() { date +%s%3N; }

cleanup_ids() {
  local cid="$1" pod="$2"
  set +e
  [ -n "$cid" ] && "${CRI[@]}" stop "$cid" >/dev/null 2>&1
  [ -n "$cid" ] && "${CRI[@]}" rm "$cid" >/dev/null 2>&1
  [ -n "$pod" ] && "${CRI[@]}" stopp "$pod" >/dev/null 2>&1
  [ -n "$pod" ] && "${CRI[@]}" rmp "$pod" >/dev/null 2>&1
  set -e
}

wait_gateway_log() {
  local cid="$1" deadline=$((SECONDS + READY_TIMEOUT)) logs
  while [ "$SECONDS" -lt "$deadline" ]; do
    logs="$("${CRI[@]}" logs "$cid" 2>&1 || true)"
    if grep -q '\[gateway\] ready' <<<"$logs"; then
      return 0
    fi
    if "${CRI[@]}" inspect "$cid" 2>/dev/null |
      jq -e '.status.state == "CONTAINER_EXITED"' >/dev/null; then
      printf '%s\n' "$logs" >&2
      return 1
    fi
    sleep 1
  done
  return 1
}

capture_mounts() {
  local cid="$1" output_file="$2"
  "${CRI[@]}" exec "$cid" sh -c \
    'printf "%s\\n" "--- id ---"; id; printf "%s\\n" "--- fs types ---"; stat -f -c "%T %n" / /app /home/node/.openclaw; printf "%s\\n" "--- mountinfo ---"; grep -E " /app | /home/node/.openclaw " /proc/self/mountinfo || true' \
    > "$output_file" 2>&1 || true
}

verify_workload() {
  local cid="$1"
  "${CRI[@]}" exec "$cid" sh -c \
    'test -s /home/node/.openclaw/workspace/complex-workload/input.pgm && test -f /home/node/.openclaw/workspace/.openclaw/extensions/image-upscale/image-upscale.mjs'
}

capture_tool_trace() {
  local cid="$1" output_file="$2" stderr_file="$3"
  local guest_path=/home/node/.openclaw/workspace/complex-workload/output.pgm.json
  local temp_file="${output_file}.tmp" deadline
  deadline="$(( $(now_ms) + ARTIFACT_TIMEOUT * 1000 ))"
  : > "$stderr_file"
  rm -f "$output_file" "$temp_file"
  while [ "$(now_ms)" -lt "$deadline" ]; do
    if "${CRI[@]}" exec "$cid" sh -c 'test -s "$1" && cat "$1"' _ "$guest_path" \
      > "$temp_file" \
      2>> "$stderr_file" \
      && [ -s "$temp_file" ] \
      && jq -e '.ok == true and .input.pixels == 1024 and .output.pixels == 4096 and .scale == 2' "$temp_file" >/dev/null 2>&1; then
      mv "$temp_file" "$output_file"
      return 0
    fi
    rm -f "$temp_file"
    sleep 0.2
  done
  rm -f "$temp_file"
  return 1
}

run_once() {
  local run="$1"
  local pod='' cid='' output='' status='PASS' note=''
  local pod_spec="$RESULT_DIR/specs/pod-$run.json"
  local container_spec="$RESULT_DIR/specs/container-$run.json"
  local run_begin run_end ready_begin cleanup_begin health_begin sample_begin
  local cri_ready_begin runp_begin create_begin start_begin
  local cri_ready_ms=0 runp_ms=0 create_ms=0 start_ms=0 gateway_ready_ms=0
  local health_exec_ms=0 health_internal_ms=0 sample_exec_ms=0 sample_internal_ms=0
  local tool_read_ms=0 tool_compute_ms=0 tool_write_ms=0 tool_total_ms=0
  local cleanup_ms=0 total_ms=0
  local health_output='' health_json='' sample_output='' sample_json=''
  local sample_text='' fallback_used='false'
  local sample_raw="$RESULT_DIR/hybrid-image-run${run}-sample.raw"
  local sample_stderr="$RESULT_DIR/hybrid-image-run${run}-sample.stderr"
  local artifact="$RESULT_DIR/hybrid-image-run${run}-tool.json"
  local artifact_stderr="$RESULT_DIR/hybrid-image-run${run}-tool.stderr"
  local prompt="Use image_upscale exactly once. Read /home/node/.openclaw/workspace/complex-workload/input.pgm, write /home/node/.openclaw/workspace/complex-workload/output.pgm, use scale=2 and passes=$PASSES. After the tool succeeds, reply with exactly KUASAR_SAMPLE_OK and nothing else. Do not claim success without calling the tool."

  jq --arg uid "hybrid-image-$run-$(date +%s%N)" --argjson attempt "$run" \
    '.metadata.uid=$uid | .metadata.attempt=$attempt' \
    "$BASE_POD_SPEC" > "$pod_spec"
  jq --arg log "hybrid-image-$run-$(date +%s%N).log" --argjson attempt "$run" \
    '.metadata.attempt=$attempt | .log_path=$log' \
    "$HYBRID_CONTAINER_SPEC" > "$container_spec"

  run_begin="$(now_ms)"
  cri_ready_begin="$(now_ms)"
  if ! output="$("${CRI[@]}" info 2>&1)"; then
    status='FAIL'; note='cri-not-ready'
  fi
  cri_ready_ms="$(( $(now_ms) - cri_ready_begin ))"

  if [ "$status" = PASS ]; then
    runp_begin="$(now_ms)"
    if ! pod="$("${CRI[@]}" runp --runtime kuasar-vmm "$pod_spec" 2>&1)"; then
      status='FAIL'; note='runp-failed'
    fi
    runp_ms="$(( $(now_ms) - runp_begin ))"
  fi

  if [ "$status" = PASS ]; then
    create_begin="$(now_ms)"
    if ! cid="$("${CRI[@]}" create "$pod" "$container_spec" "$pod_spec" 2>&1)"; then
      status='FAIL'; note='create-failed'
    fi
    create_ms="$(( $(now_ms) - create_begin ))"
  fi

  if [ "$status" = PASS ]; then
    start_begin="$(now_ms)"
    if ! output="$("${CRI[@]}" start "$cid" 2>&1)"; then
      status='FAIL'; note='start-failed'
    fi
    start_ms="$(( $(now_ms) - start_begin ))"
  fi

  if [ "$status" = PASS ]; then
    ready_begin="$(now_ms)"
    if ! wait_gateway_log "$cid"; then
      status='FAIL'; note='gateway-not-ready'
    fi
    gateway_ready_ms="$(( $(now_ms) - ready_begin ))"
  fi

  if [ -n "$cid" ]; then
    capture_mounts "$cid" "$RESULT_DIR/hybrid-image-run${run}-mounts.txt"
  fi

  if [ "$status" = PASS ] && ! verify_workload "$cid"; then
    status='FAIL'; note='image-workload-not-prepared'
  fi

  if [ "$status" = PASS ]; then
    health_begin="$(now_ms)"
    if health_output="$("${CRI[@]}" exec "$cid" node openclaw.mjs gateway health --json 2>&1)"; then
      printf '%s\n' "$health_output" > "$RESULT_DIR/hybrid-image-run${run}-health.raw"
      health_json="$(awk 'BEGIN{seen=0} /^\{/ {seen=1} seen {print}' <<<"$health_output")"
      if jq -e '.ok == true' <<<"$health_json" >/dev/null 2>&1; then
        health_internal_ms="$(jq -r '.durationMs // 0' <<<"$health_json")"
      else
        status='FAIL'; note='health-not-ok'
      fi
    else
      status='FAIL'; note='health-exec-failed'
    fi
    health_exec_ms="$(( $(now_ms) - health_begin ))"
  fi

  if [ "$status" = PASS ]; then
    "${CRI[@]}" exec "$cid" sh -c \
      'rm -f /home/node/.openclaw/workspace/complex-workload/output.pgm /home/node/.openclaw/workspace/complex-workload/output.pgm.json' \
      >/dev/null 2>&1 || { status='FAIL'; note='sample-output-clean-failed'; }
  fi

  if [ "$status" = PASS ]; then
    sample_begin="$(now_ms)"
    if sample_output="$("${CRI[@]}" exec "$cid" node openclaw.mjs agent --local --agent main \
      --session-key "agent:main:hybrid-image-$run-$(date +%s%N)" \
      --message "$prompt" --timeout 180 --json 2>"$sample_stderr")"; then
      sample_json="$(awk 'BEGIN{seen=0} /^\{/ {seen=1} seen {print}' <<<"$sample_output")"
      printf '%s\n' "$sample_output" > "$sample_raw"
      if jq -e . <<<"$sample_json" >/dev/null 2>&1; then
        sample_text="$(jq -r '.payloads[0].text // ""' <<<"$sample_json")"
        sample_internal_ms="$(jq -r '.meta.durationMs // 0' <<<"$sample_json")"
        fallback_used="$(jq -r '.meta.executionTrace.fallbackUsed // false' <<<"$sample_json")"
        if [ "$sample_text" != KUASAR_SAMPLE_OK ]; then
          status='FAIL'; note='sample-output-mismatch'
        elif [ "$fallback_used" = true ]; then
          status='FAIL'; note='sample-fallback-used'
        fi
      else
        status='FAIL'; note='sample-json-invalid'
      fi
    else
      status='FAIL'; note='sample-exec-failed'
    fi
    sample_exec_ms="$(( $(now_ms) - sample_begin ))"
  fi

  if [ "$status" = PASS ]; then
    if ! capture_tool_trace "$cid" "$artifact" "$artifact_stderr"; then
      status='FAIL'; note='sample-artifact-invalid'
    else
      tool_read_ms="$(jq -r '.timing_ms.read // 0' "$artifact")"
      tool_compute_ms="$(jq -r '.timing_ms.compute // 0' "$artifact")"
      tool_write_ms="$(jq -r '.timing_ms.write // 0' "$artifact")"
      tool_total_ms="$(jq -r '.timing_ms.total // 0' "$artifact")"
    fi
  fi

  [ -z "$cid" ] || "${CRI[@]}" logs "$cid" > "$RESULT_DIR/hybrid-image-run${run}.log" 2>&1 || true
  cleanup_begin="$(now_ms)"
  cleanup_ids "$cid" "$pod"
  cleanup_ms="$(( $(now_ms) - cleanup_begin ))"
  run_end="$(now_ms)"
  total_ms="$((run_end - run_begin))"

  jq -n \
    --arg handler kuasar-vmm \
    --arg config virtiofs-root-virtio-blk-app-state \
    --argjson run "$run" \
    --arg status "$status" \
    --arg note "$note" \
    --arg app_loop "$APP_LOOP_DEVICE" \
    --arg state_loop "$STATE_LOOP_DEVICE" \
    --argjson cri_ready_ms "$cri_ready_ms" \
    --argjson runp_ms "$runp_ms" \
    --argjson create_ms "$create_ms" \
    --argjson start_ms "$start_ms" \
    --argjson gateway_ready_ms "$gateway_ready_ms" \
    --argjson health_exec_ms "$health_exec_ms" \
    --argjson health_internal_ms "$health_internal_ms" \
    --argjson sample_exec_ms "$sample_exec_ms" \
    --argjson sample_internal_ms "$sample_internal_ms" \
    --argjson tool_read_ms "$tool_read_ms" \
    --argjson tool_compute_ms "$tool_compute_ms" \
    --argjson tool_write_ms "$tool_write_ms" \
    --argjson tool_total_ms "$tool_total_ms" \
    --argjson cleanup_ms "$cleanup_ms" \
    --argjson total_ms "$total_ms" \
    '{handler:$handler,config:$config,run:$run,status:$status,note:$note,app_loop:$app_loop,state_loop:$state_loop,cri_ready_ms:$cri_ready_ms,runp_ms:$runp_ms,create_ms:$create_ms,start_ms:$start_ms,gateway_ready_ms:$gateway_ready_ms,health_exec_ms:$health_exec_ms,health_internal_ms:$health_internal_ms,sample_exec_ms:$sample_exec_ms,sample_internal_ms:$sample_internal_ms,tool:{read_ms:$tool_read_ms,compute_ms:$tool_compute_ms,write_ms:$tool_write_ms,total_ms:$tool_total_ms},cleanup_ms:$cleanup_ms,total_ms:$total_ms}' \
    > "$RESULT_DIR/rows/run-$run.json"
  printf 'run=%s status=%s gateway_ready_ms=%s health_exec_ms=%s sample_exec_ms=%s sample_internal_ms=%s total_ms=%s\n' \
    "$run" "$status" "$gateway_ready_ms" "$health_exec_ms" "$sample_exec_ms" "$sample_internal_ms" "$total_ms"
}

for run in $(seq 1 "$RUNS"); do
  run_once "$run"
done

jq -s '.' "$RESULT_DIR/rows"/*.json > "$RESULT_DIR/results.json"
jq '
  def avg($key): map(.[$key] // 0) | if length == 0 then 0 else add / length end;
  def avg_tool($key): map(.tool[$key] // 0) | if length == 0 then 0 else add / length end;
  {
    handler: "kuasar-vmm",
    config: "virtiofs-root+virtio-blk-app+virtio-blk-state",
    runs: length,
    passed: (map(select(.status == "PASS")) | length),
    failed: (map(select(.status != "PASS")) | length),
    averages_ms: {
      cri_ready: avg("cri_ready_ms"),
      runp: avg("runp_ms"),
      create: avg("create_ms"),
      start: avg("start_ms"),
      gateway_ready: avg("gateway_ready_ms"),
      health_exec: avg("health_exec_ms"),
      health_internal: avg("health_internal_ms"),
      sample_exec: avg("sample_exec_ms"),
      sample_internal: avg("sample_internal_ms"),
      tool_read: avg_tool("read_ms"),
      tool_compute: avg_tool("compute_ms"),
      tool_write: avg_tool("write_ms"),
      tool_total: avg_tool("total_ms"),
      cleanup: avg("cleanup_ms"),
      total: avg("total_ms")
    }
  }
' "$RESULT_DIR/results.json" > "$RESULT_DIR/summary.json"

printf '%s\n' "results=$RESULT_DIR"
jq . "$RESULT_DIR/summary.json"
[ "$(jq '[.[] | select(.status != "PASS")] | length' "$RESULT_DIR/results.json")" -eq 0 ]
