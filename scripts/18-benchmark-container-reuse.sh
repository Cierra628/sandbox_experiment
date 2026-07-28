#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-10.2.30.50:5000/openclaw-kuasar:2026.6.11-virtiofs}"
RUNS="${REUSE_RUNS:-3}"
REQUESTS="${REUSE_REQUESTS_PER_CONTAINER:-5}"
PASSES="${IMAGE_WORKLOAD_PASSES:-512}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"
ARTIFACT_TIMEOUT="${MODEL_SAMPLE_ARTIFACT_TIMEOUT:-15}"
LABEL="${REUSE_ROOTFS_LABEL:-virtiofs-metadata}"
STATE_DIR="${OPENCLAW_DATA_DIR:-$HOME/.local/share/openclaw-kuasar/openclaw-state}"
VMM_STATE_DIR="${VMM_OPENCLAW_DATA_DIR:-/var/lib/openclaw-kuasar/openclaw-state}"
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/.artifacts/container-reuse-$(date -u +%Y%m%dT%H%M%SZ)}"
VMM_CONFIG="${VMM_CONFIG:-/etc/openclaw-kuasar/vmm.toml}"

usage() {
  printf '%s\n' \
    'Usage: scripts/18-benchmark-container-reuse.sh [--label LABEL] [--runs N] [--requests N] [--passes N] [--result-dir DIR] [--dry-run]'
}

DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --requests) REQUESTS="$2"; shift 2 ;;
    --passes) PASSES="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$LABEL" in
  virtio-blk) EXPECTED_BACKEND=virtio-blk; EXPECTED_CACHE='' ;;
  virtiofs-never) EXPECTED_BACKEND=virtiofs; EXPECTED_CACHE=never ;;
  virtiofs-metadata) EXPECTED_BACKEND=virtiofs; EXPECTED_CACHE=metadata ;;
  *) echo 'error: label must be virtio-blk, virtiofs-never, or virtiofs-metadata' >&2; exit 2 ;;
esac

for value in "$RUNS" "$REQUESTS" "$PASSES" "$READY_TIMEOUT" "$ARTIFACT_TIMEOUT"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo 'error: runs, requests, passes and timeout must be positive integers' >&2
    exit 2
  }
done

printf '%s\n' \
  'Container reuse benchmark plan:' \
  '  handler=kuasar-vmm' \
  "  rootfs_config=$LABEL" \
  "  image=$OPENCLAW_IMAGE" \
  "  containers=$RUNS" \
  "  requests_per_container=$REQUESTS" \
  "  passes=$PASSES" \
  '  input=32x32 PGM (1024 pixels)' \
  '  output=64x64 PGM (4096 pixels)' \
  '  comparison=first request vs requests 2..N in the same container' \
  "  result_dir=$RESULT_DIR"

[ "$DRY_RUN" -eq 1 ] && exit 0

command -v jq >/dev/null
command -v crictl >/dev/null
sudo -v

if ! sudo grep -Eq "^[[:space:]]*container_storage_backend[[:space:]]*=[[:space:]]*\"${EXPECTED_BACKEND}\"" "$VMM_CONFIG"; then
  echo "error: $VMM_CONFIG does not use container_storage_backend=\"$EXPECTED_BACKEND\"" >&2
  exit 1
fi
if [ -n "$EXPECTED_CACHE" ] && ! sudo grep -Eq "^[[:space:]]*cache[[:space:]]*=[[:space:]]*\"${EXPECTED_CACHE}\"" "$VMM_CONFIG"; then
  echo "error: $VMM_CONFIG does not use cache=\"$EXPECTED_CACHE\"" >&2
  exit 1
fi

cri() {
  sudo crictl \
    --runtime-endpoint "$CRI_ENDPOINT" \
    --image-endpoint "$CRI_ENDPOINT" \
    "$@"
}

active_containers="$(cri ps -a -o json | jq '.containers | length')"
active_pods="$(cri pods -o json | jq '.items | length')"
if [ "$active_containers" -ne 0 ] || [ "$active_pods" -ne 0 ]; then
  echo "error: active CRI resources remain (containers=$active_containers pods=$active_pods)" >&2
  echo 'Clean them before running this benchmark.' >&2
  exit 1
fi

mkdir -p "$RESULT_DIR/runs" "$RESULT_DIR/rows" "$RESULT_DIR/sequences" "$RESULT_DIR/specs"

"$ROOT_DIR/scripts/16-prepare-image-workload.sh" \
  --state "$STATE_DIR" \
  --vmm-state "$VMM_STATE_DIR"

OPENCLAW_IMAGE="$OPENCLAW_IMAGE" \
OPENCLAW_DATA_DIR="$STATE_DIR" \
VMM_OPENCLAW_DATA_DIR="$VMM_STATE_DIR" \
"$ROOT_DIR/scripts/03-generate-cri-specs.sh" >/dev/null

BASE_POD="$ROOT_DIR/containerd/openclaw-pod-vmm.json"
BASE_CONTAINER="$ROOT_DIR/containerd/openclaw-container-vmm.json"
PROMPT="Use image_upscale exactly once. Read /home/node/.openclaw/workspace/complex-workload/input.pgm, write /home/node/.openclaw/workspace/complex-workload/output.pgm, use scale=2 and passes=$PASSES. After the tool succeeds, reply with exactly KUASAR_SAMPLE_OK and nothing else. Do not claim success without calling the tool."

now_ms() {
  date +%s%3N
}

timed_capture() {
  local value_var="$1"
  local elapsed_var="$2"
  local begin end value rc
  shift 2
  begin="$(now_ms)"
  set +e
  value="$("$@")"
  rc=$?
  set -e
  end="$(now_ms)"
  printf -v "$value_var" '%s' "$value"
  printf -v "$elapsed_var" '%s' "$((end - begin))"
  return "$rc"
}

POD_ID=''
CONTAINER_ID=''
cleanup_current() {
  set +e
  [ -n "$CONTAINER_ID" ] && cri stop "$CONTAINER_ID" >/dev/null 2>&1
  [ -n "$CONTAINER_ID" ] && cri rm "$CONTAINER_ID" >/dev/null 2>&1
  [ -n "$POD_ID" ] && cri stopp "$POD_ID" >/dev/null 2>&1
  [ -n "$POD_ID" ] && cri rmp "$POD_ID" >/dev/null 2>&1
  CONTAINER_ID=''
  POD_ID=''
  set -e
}
trap cleanup_current EXIT INT TERM

wait_gateway() {
  local cid="$1"
  local logfile="$2"
  local deadline=$((SECONDS + READY_TIMEOUT))
  local logs
  while [ "$SECONDS" -lt "$deadline" ]; do
    logs="$(cri logs "$cid" 2>&1 || true)"
    printf '%s\n' "$logs" > "$logfile"
    if grep -q '\[gateway\] ready' <<<"$logs"; then
      return 0
    fi
    if cri inspect "$cid" 2>/dev/null | jq -e '.status.state == "CONTAINER_EXITED"' >/dev/null; then
      return 1
    fi
    sleep 1
  done
  return 1
}

run_agent() {
  local cid="$1"
  local session="$2"
  local stderr_file="$3"
  cri exec "$cid" \
    node openclaw.mjs agent \
    --local \
    --agent main \
    --session-key "$session" \
    --message "$PROMPT" \
    --timeout 180 \
    --json \
    2>"$stderr_file"
}

capture_tool_trace() {
  local cid="$1" output_file="$2" stderr_file="$3"
  local path=/home/node/.openclaw/workspace/complex-workload/output.pgm.json
  local temp_file="${output_file}.tmp" deadline
  deadline="$(( $(now_ms) + ARTIFACT_TIMEOUT * 1000 ))"
  : > "$stderr_file"
  rm -f "$output_file" "$temp_file"
  while [ "$(now_ms)" -lt "$deadline" ]; do
    if cri exec "$cid" sh -c 'test -s "$1" && cat "$1"' _ "$path" \
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

for run in $(seq 1 "$RUNS"); do
  run_dir="$RESULT_DIR/runs/run-$run"
  mkdir -p "$run_dir"
  uid="reuse-kuasar-vmm-$run-$(date +%s%N)"
  pod_spec="$RESULT_DIR/specs/run-$run-pod.json"
  container_spec="$RESULT_DIR/specs/run-$run-container.json"

  jq \
    --arg uid "$uid" \
    --argjson attempt "$run" \
    '.metadata.uid = $uid | .metadata.attempt = $attempt' \
    "$BASE_POD" > "$pod_spec"

  jq \
    --arg name "openclaw-reuse-$run" \
    --arg log_path "reuse-$uid.log" \
    --argjson attempt "$run" \
    '.metadata.name = $name | .metadata.attempt = $attempt | .log_path = $log_path' \
    "$BASE_CONTAINER" > "$container_spec"

  sequence_begin="$(now_ms)"
  output=''
  runp_ms=0
  create_ms=0
  start_ms=0
  gateway_ready_ms=0

  timed_capture POD_ID runp_ms \
    cri runp --runtime kuasar-vmm "$pod_spec"

  timed_capture CONTAINER_ID create_ms \
    cri create "$POD_ID" "$container_spec" "$pod_spec"

  timed_capture output start_ms \
    cri start "$CONTAINER_ID"

  ready_begin="$(now_ms)"
  if ! wait_gateway "$CONTAINER_ID" "$run_dir/gateway.log"; then
    echo "error: gateway did not become ready in run $run" >&2
    exit 1
  fi
  gateway_ready_ms="$(( $(now_ms) - ready_begin ))"
  startup_ms="$((runp_ms + create_ms + start_ms + gateway_ready_ms))"

  cri exec "$CONTAINER_ID" \
    stat -f -c '%T %n' \
    / \
    /app \
    /home/node/.openclaw \
    > "$run_dir/mounts.txt"

  health_json=''
  health_exec_ms=0
  if ! timed_capture health_json health_exec_ms \
    cri exec "$CONTAINER_ID" node openclaw.mjs gateway health --json; then
    printf '%s\n' "$health_json" > "$run_dir/health.json"
    echo "error: health command failed in run $run" >&2
    exit 1
  fi
  printf '%s\n' "$health_json" > "$run_dir/health.json"
  jq -e '.ok == true' >/dev/null <<<"$health_json"
  health_internal_ms="$(jq -r '.durationMs // 0' <<<"$health_json")"

  request_sum_ms=0
  sequence_status=PASS
  for request in $(seq 1 "$REQUESTS"); do
    request_dir="$run_dir/request-$request"
    mkdir -p "$request_dir"
    cri exec "$CONTAINER_ID" \
      rm -f \
      /home/node/.openclaw/workspace/complex-workload/output.pgm \
      /home/node/.openclaw/workspace/complex-workload/output.pgm.json \
      >/dev/null

    session="agent:main:reuse-$run-$request-$(date +%s%N)"
    sample_json=''
    sample_exec_ms=0
    status=PASS
    note=''

    if ! timed_capture sample_json sample_exec_ms \
      run_agent "$CONTAINER_ID" "$session" "$request_dir/stderr.log"; then
      status=FAIL
      note=sample-exec-failed
    fi
    printf '%s\n' "$sample_json" > "$request_dir/sample.json"
    sample_internal_ms=0
    response_text=''
    if [ -n "$sample_json" ] && jq -e . >/dev/null 2>&1 <<<"$sample_json"; then
      sample_internal_ms="$(jq -r '.meta.durationMs // 0' <<<"$sample_json")"
      response_text="$(jq -r '.payloads[0].text // ""' <<<"$sample_json")"
    fi
    [[ "$sample_internal_ms" =~ ^[0-9]+([.][0-9]+)?$ ]] || sample_internal_ms=0

    tool_trace='{}'
    if [ "$status" = PASS ]; then
      if capture_tool_trace "$CONTAINER_ID" "$request_dir/tool.json" "$request_dir/tool.stderr"; then
        tool_trace="$(cat "$request_dir/tool.json")"
      else
        status=FAIL
        note=tool-artifact-capture-timeout
      fi
    else
      printf '{}\n' > "$request_dir/tool.json"
      : > "$request_dir/tool.stderr"
    fi

    if [ "$status" = PASS ] && [ "$response_text" != KUASAR_SAMPLE_OK ]; then
      status=FAIL
      note=sample-output-mismatch
    fi
    if [ "$status" = PASS ] && ! jq -e \
      '.ok == true and .input.pixels == 1024 and .output.pixels == 4096 and .scale == 2' \
      >/dev/null 2>&1 <<<"$tool_trace"; then
      status=FAIL
      note=tool-validation-failed
    fi
    [ "$status" = PASS ] || sequence_status=FAIL
    request_sum_ms="$((request_sum_ms + sample_exec_ms))"

    jq -n \
      --arg handler kuasar-vmm \
      --arg config "$LABEL" \
      --argjson sequence "$run" \
      --argjson request "$request" \
      --arg kind "$([ "$request" -eq 1 ] && printf first || printf warm)" \
      --arg status "$status" \
      --arg note "$note" \
      --argjson sample_exec_ms "$sample_exec_ms" \
      --argjson sample_internal_ms "$sample_internal_ms" \
      --argjson trace "$tool_trace" \
      '{
        handler:$handler,
        config:$config,
        sequence:$sequence,
        request:$request,
        kind:$kind,
        status:$status,
        note:$note,
        sample_exec_ms:$sample_exec_ms,
        sample_internal_ms:$sample_internal_ms,
        tool:{
          read_ms:($trace.timing_ms.read // 0),
          compute_ms:($trace.timing_ms.compute // 0),
          write_ms:($trace.timing_ms.write // 0),
          total_ms:($trace.timing_ms.total // 0)
        }
      }' > "$RESULT_DIR/rows/run-$run-request-$request.json"

    printf 'sequence=%s request=%s kind=%s status=%s sample_exec_ms=%s sample_internal_ms=%s\n' \
      "$run" \
      "$request" \
      "$([ "$request" -eq 1 ] && printf first || printf warm)" \
      "$status" \
      "$sample_exec_ms" \
      "$sample_internal_ms"
  done

  cleanup_begin="$(now_ms)"
  cleanup_current
  cleanup_ms="$(( $(now_ms) - cleanup_begin ))"
  sequence_total_ms="$(( $(now_ms) - sequence_begin ))"
  amortized_ms="$(( (startup_ms + request_sum_ms) / REQUESTS ))"

  jq -n \
    --arg handler kuasar-vmm \
      --arg config "$LABEL" \
    --argjson sequence "$run" \
    --arg status "$sequence_status" \
    --argjson runp_ms "$runp_ms" \
    --argjson create_ms "$create_ms" \
    --argjson start_ms "$start_ms" \
    --argjson gateway_ready_ms "$gateway_ready_ms" \
    --argjson startup_ms "$startup_ms" \
    --argjson health_exec_ms "$health_exec_ms" \
    --argjson health_internal_ms "$health_internal_ms" \
    --argjson requests "$REQUESTS" \
    --argjson request_sum_ms "$request_sum_ms" \
    --argjson cleanup_ms "$cleanup_ms" \
    --argjson total_ms "$sequence_total_ms" \
    --argjson amortized_ms "$amortized_ms" \
    '{
      handler:$handler,
        config:$config,
      sequence:$sequence,
      status:$status,
      lifecycle:{
        runp_ms:$runp_ms,
        create_ms:$create_ms,
        start_ms:$start_ms,
        gateway_ready_ms:$gateway_ready_ms,
        startup_ms:$startup_ms
      },
      health:{
        exec_ms:$health_exec_ms,
        internal_ms:$health_internal_ms
      },
      requests:$requests,
      request_sum_ms:$request_sum_ms,
      cleanup_ms:$cleanup_ms,
      total_ms:$total_ms,
      amortized_startup_plus_requests_ms:$amortized_ms
    }' > "$RESULT_DIR/sequences/run-$run.json"
done

jq -s 'sort_by(.sequence, .request)' \
  "$RESULT_DIR"/rows/*.json > "$RESULT_DIR/results.json"

jq -s 'sort_by(.sequence)' \
  "$RESULT_DIR"/sequences/*.json > "$RESULT_DIR/sequences.json"

jq -n \
  --arg config "$LABEL" \
  --slurpfile requests "$RESULT_DIR/results.json" \
  --slurpfile sequences "$RESULT_DIR/sequences.json" '
  def avg:
    if length == 0 then 0 else add / length end;
  def percentile($p):
    sort as $s |
    if ($s | length) == 0 then 0
    else $s[((($s | length) - 1) * $p | floor)]
    end;
  ($requests[0]) as $r |
  ($sequences[0]) as $s |
  {
    handler:"kuasar-vmm",
    config:$config,
    containers:($s | length),
    requests_per_container:($s[0].requests // 0),
    passed_requests:([$r[] | select(.status == "PASS")] | length),
    failed_requests:([$r[] | select(.status != "PASS")] | length),
    averages_ms:{
      startup:([$s[].lifecycle.startup_ms] | avg),
      gateway_ready:([$s[].lifecycle.gateway_ready_ms] | avg),
      health_exec:([$s[].health.exec_ms] | avg),
      first_exec:([$r[] | select(.status == "PASS" and .kind == "first") | .sample_exec_ms] | avg),
      first_internal:([$r[] | select(.status == "PASS" and .kind == "first") | .sample_internal_ms] | avg),
      warm_exec:([$r[] | select(.status == "PASS" and .kind == "warm") | .sample_exec_ms] | avg),
      warm_internal:([$r[] | select(.status == "PASS" and .kind == "warm") | .sample_internal_ms] | avg),
      tool_total:([$r[] | select(.status == "PASS") | .tool.total_ms] | avg),
      amortized_startup_plus_requests_per_request:
        ([$s[].amortized_startup_plus_requests_ms] | avg)
    },
    warm_distribution_ms:{
      exec_p50:([$r[] | select(.status == "PASS" and .kind == "warm") | .sample_exec_ms] | percentile(0.50)),
      exec_p95:([$r[] | select(.status == "PASS" and .kind == "warm") | .sample_exec_ms] | percentile(0.95)),
      internal_p50:([$r[] | select(.status == "PASS" and .kind == "warm") | .sample_internal_ms] | percentile(0.50)),
      internal_p95:([$r[] | select(.status == "PASS" and .kind == "warm") | .sample_internal_ms] | percentile(0.95))
    }
  }' > "$RESULT_DIR/summary.json"

failed="$(jq '[.[] | select(.status != "PASS")] | length' "$RESULT_DIR/results.json")"
printf '%s\n' \
  "results=$RESULT_DIR" \
  "containers=$RUNS" \
  "requests=$((RUNS * REQUESTS))" \
  "failed=$failed"
jq . "$RESULT_DIR/summary.json"
[ "$failed" -eq 0 ]
