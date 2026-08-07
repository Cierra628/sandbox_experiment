#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
PROFILE_IMAGE="${HYBRID_PROFILE_IMAGE:-localhost/openclaw-kuasar:2026.6.11-virtiofs-strace}"
STATE_LOOP_DEVICE="${HYBRID_STATE_LOOP_DEVICE:-}"
APP_LOOP_DEVICE="${HYBRID_APP_LOOP_DEVICE:-}"
APP_MODE="${HYBRID_APP_MODE:-virtio-blk}"
RUNTIME_LOOP_DEVICE="${HYBRID_RUNTIME_LOOP_DEVICE:-}"
REPEATS="${HYBRID_PATH_REPEATS:-3}"
RESULT_DIR="${HYBRID_PATH_RESULT_DIR:-$ROOT_DIR/.artifacts/hybrid-path-profile-$(date -u +%Y%m%dT%H%M%SZ)}"
EXPECTED_CACHE="${HYBRID_EXPECTED_CACHE:-}"
TOP_PATHS="${HYBRID_TOP_PATHS:-25}"

usage() {
  printf '%s\n' \
    'Usage: scripts/32-profile-hybrid-paths.sh [options]' \
    '' \
    'Profiles file-path access in the current hybrid VMM mount layout.' \
    '' \
    'Options:' \
    '  --state-loop DEV       writable state loop device' \
    '  --app-loop DEV         read-only /app loop device (virtio-blk mode)' \
    '  --app-mode MODE        /app backing: virtio-blk or virtiofs (default: virtio-blk)' \
    '  --runtime-loop DEV     read-only /usr/local loop device' \
    '  --profile-image IMAGE  profiling image containing strace' \
    '  --repeats N            fresh VMM containers (default: 3)' \
    '  --expected-cache VALUE require this VirtioFS cache value in vmm.toml' \
    '  --top-paths N          retain top N file paths per traced command (default: 25)' \
    '  --result-dir DIR       artifact directory' \
    '  -h, --help             show this help'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state-loop) STATE_LOOP_DEVICE="$2"; shift 2 ;;
    --app-loop) APP_LOOP_DEVICE="$2"; shift 2 ;;
    --app-mode) APP_MODE="$2"; shift 2 ;;
    --runtime-loop) RUNTIME_LOOP_DEVICE="$2"; shift 2 ;;
    --profile-image) PROFILE_IMAGE="$2"; shift 2 ;;
    --repeats) REPEATS="$2"; shift 2 ;;
    --expected-cache) EXPECTED_CACHE="$2"; shift 2 ;;
    --top-paths) TOP_PATHS="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ "$REPEATS" =~ ^[1-9][0-9]*$ ]] || {
  echo 'error: --repeats must be a positive integer' >&2
  exit 2
}
[[ "$TOP_PATHS" =~ ^[1-9][0-9]*$ ]] || {
  echo 'error: --top-paths must be a positive integer' >&2
  exit 2
}
case "$APP_MODE" in
  virtiofs|virtio-blk) ;;
  *) echo 'error: --app-mode must be virtiofs or virtio-blk' >&2; exit 2 ;;
esac
[ -n "$STATE_LOOP_DEVICE" ] || { echo 'error: --state-loop is required' >&2; exit 2; }
if [ "$APP_MODE" = virtio-blk ]; then
  [ -n "$APP_LOOP_DEVICE" ] || { echo 'error: --app-loop is required for virtio-blk app mode' >&2; exit 2; }
fi
[ -n "$RUNTIME_LOOP_DEVICE" ] || { echo 'error: --runtime-loop is required' >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
command -v crictl >/dev/null 2>&1 || { echo 'error: crictl is required' >&2; exit 1; }
command -v awk >/dev/null 2>&1 || { echo 'error: awk is required' >&2; exit 1; }
sudo -v
sudo test -b "$STATE_LOOP_DEVICE" || { echo "error: not a block device: $STATE_LOOP_DEVICE" >&2; exit 1; }
if [ "$APP_MODE" = virtio-blk ]; then
  sudo test -b "$APP_LOOP_DEVICE" || { echo "error: not a block device: $APP_LOOP_DEVICE" >&2; exit 1; }
fi
sudo test -b "$RUNTIME_LOOP_DEVICE" || { echo "error: not a block device: $RUNTIME_LOOP_DEVICE" >&2; exit 1; }

SYSTEM_CONFIG=/etc/openclaw-kuasar/vmm.toml
SYSTEM_SANDBOXER=/usr/local/libexec/openclaw-kuasar/vmm-sandboxer
mkdir -p "$RESULT_DIR/specs" "$RESULT_DIR/evidence"

if [ -n "$EXPECTED_CACHE" ]; then
  [[ "$EXPECTED_CACHE" =~ ^[A-Za-z0-9_-]+$ ]] || {
    echo 'error: --expected-cache contains unsupported characters' >&2
    exit 2
  }
  sudo grep -Eq \
    "^[[:space:]]*cache[[:space:]]*=[[:space:]]*\"${EXPECTED_CACHE}\"" \
    "$SYSTEM_CONFIG" || {
      echo "error: $SYSTEM_CONFIG does not select cache=$EXPECTED_CACHE" >&2
      exit 1
    }
fi
sudo cat "$SYSTEM_CONFIG" > "$RESULT_DIR/evidence/vmm-effective.toml"
sudo sha256sum "$SYSTEM_SANDBOXER" > "$RESULT_DIR/evidence/sandboxer-sha256.txt"

BASE_POD_SPEC="$ROOT_DIR/containerd/openclaw-pod-vmm.json"
BASE_CONTAINER_SPEC="$ROOT_DIR/containerd/openclaw-container-vmm.json"
CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")
NDJSON="$RESULT_DIR/results.ndjson"
: > "$NDJSON"

printf '%s\n' \
  'Hybrid path attribution plan:' \
  "  image=$PROFILE_IMAGE" \
  '  rootfs=VirtioFS' \
  "  app_mode=$APP_MODE" \
  "  app_loop=${APP_LOOP_DEVICE:-none}" \
  "  state_loop=$STATE_LOOP_DEVICE" \
  "  runtime_loop=$RUNTIME_LOOP_DEVICE" \
  "  repeats=$REPEATS" \
  "  result_dir=$RESULT_DIR"

now_ms() { date +%s%3N; }

normalize_uint() {
  case "$1" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

cleanup_ids() {
  local cid="$1" pod="$2"
  set +e
  [ -n "$cid" ] && "${CRI[@]}" stop "$cid" >/dev/null 2>&1
  [ -n "$cid" ] && "${CRI[@]}" rm "$cid" >/dev/null 2>&1
  [ -n "$pod" ] && "${CRI[@]}" stopp "$pod" >/dev/null 2>&1
  [ -n "$pod" ] && "${CRI[@]}" rmp "$pod" >/dev/null 2>&1
  set -e
}

wait_idle() {
  local cid="$1" logs
  for _ in $(seq 1 90); do
    logs="$("${CRI[@]}" logs "$cid" 2>&1 || true)"
    grep -q 'BENCH_PATH_IDLE_READY' <<<"$logs" && return 0
    "${CRI[@]}" inspect "$cid" 2>/dev/null |
      jq -e '.status.state == "CONTAINER_EXITED"' >/dev/null 2>&1 && {
        printf '%s\n' "$logs" >&2
        return 1
      }
    sleep 1
  done
  return 1
}

make_specs() {
  local uid="$1" pod_spec="$2" container_spec="$3" log_path="$4"
  local wrapper='i=0; while [ "$i" -lt 150 ]; do if [ -f /home/node/.openclaw/openclaw.json ] && [ -d /home/node/.openclaw/state ] && touch /home/node/.openclaw/state/.hybrid-path-ready && rm -f /home/node/.openclaw/state/.hybrid-path-ready; then echo BENCH_PATH_IDLE_READY; exec sleep 900; fi; i=$((i+1)); sleep 0.2; done; exit 1'
  jq --arg uid "$uid" \
    '.metadata.uid=$uid | .metadata.attempt=0' \
    "$BASE_POD_SPEC" > "$pod_spec"
  jq --arg uid "$uid" \
    --arg image "$PROFILE_IMAGE" \
    --arg state "$STATE_LOOP_DEVICE" \
    --arg app "$APP_LOOP_DEVICE" \
    --arg app_mode "$APP_MODE" \
    --arg runtime "$RUNTIME_LOOP_DEVICE" \
    --arg wrapper "$wrapper" \
    --arg log_path "$log_path" \
    '.metadata.uid=$uid |
     .metadata.attempt=0 |
     .image.image=$image |
     .log_path=$log_path |
     .command=["sh"] |
     .args=["-c",$wrapper] |
     (.mounts |= map(select(.container_path != "/app" and
                            .container_path != "/usr/local" and
                            .container_path != "/home/node/.openclaw"))) |
     .mounts += (
       (if $app_mode == "virtio-blk" then
          [{container_path:"/app",host_path:$app,readonly:true}]
        else [] end)
       + [
         {container_path:"/usr/local",host_path:$runtime,readonly:true},
         {container_path:"/home/node/.openclaw",host_path:$state,readonly:false}
       ]
     )' \
    "$BASE_CONTAINER_SPEC" > "$container_spec"
}

AWK_PROGRAM=''
AWK_PROGRAM+='function bucket(p) {'
AWK_PROGRAM+=' if (p ~ "^/app(/|$)") return "app";'
AWK_PROGRAM+=' if (p ~ "^/home/node/.openclaw(/|$)") return "state";'
AWK_PROGRAM+=' if (p ~ "^/usr/local(/|$)") return "usr_local";'
AWK_PROGRAM+=' if (p ~ "^/usr(/|$)" || p ~ "^/lib(/|$)" || p ~ "^/bin(/|$)") return "usr_system";'
AWK_PROGRAM+=' if (p ~ "^/etc(/|$)") return "etc";'
AWK_PROGRAM+=' return "other_absolute";'
AWK_PROGRAM+='}'
AWK_PROGRAM+='BEGIN { names[1]="app"; names[2]="state"; names[3]="usr_local"; names[4]="usr_system"; names[5]="etc"; names[6]="other_absolute"; }'
AWK_PROGRAM+='{ q=index($0,"\""); if (q == 0) next; rest=substr($0,q+1); q2=index(rest,"\""); if (q2 == 0) next; p=substr(rest,1,q2-1); d=0; if (match($0, /<[0-9.]+>$/)) d=substr($0,RSTART+1,RLENGTH-2)*1000; b=bucket(p); count[b]++; time[b]+=d; }'
AWK_PROGRAM+='END { printf "{\"buckets\":{"; for (i=1;i<=6;i++) { b=names[i]; if (i>1) printf ","; printf "\"%s\":{\"events\":%d,\"syscall_ms\":%.3f}",b,count[b]+0,time[b]+0; } print "}}"; }'

TOP_AWK_PROGRAM=''
TOP_AWK_PROGRAM+='function path_from_line(    q,rest,q2) { q=index($0,"\""); if (q == 0) return ""; rest=substr($0,q+1); q2=index(rest,"\""); if (q2 == 0) return ""; return substr(rest,1,q2-1); }'
TOP_AWK_PROGRAM+='{ p=path_from_line(); if (p == "") next; d=0; if (match($0, /<[0-9.]+>$/)) d=substr($0,RSTART+1,RLENGTH-2)*1000; count[p]++; time[p]+=d; }'
TOP_AWK_PROGRAM+='END { for (i=1;i<=limit;i++) { best=""; best_time=-1; for (p in time) if (!(p in used) && time[p] > best_time) { best=p; best_time=time[p]; } if (best == "") break; used[best]=1; printf "%.3f\t%d\t%s\n",time[best]+0,count[best]+0,best; } }'

aggregate_trace() {
  local cid="$1" prefix="$2"
  "${CRI[@]}" exec "$cid" sh -c \
    'prefix=$1; program=$2; awk "$program" "$prefix".*' \
    sh "$prefix" "$AWK_PROGRAM"
}

aggregate_top_trace() {
  local cid="$1" prefix="$2"
  "${CRI[@]}" exec "$cid" sh -c \
    'prefix=$1; program=$2; limit=$3; awk -v limit="$limit" "$program" "$prefix".*' \
    sh "$prefix" "$TOP_AWK_PROGRAM" "$TOP_PATHS"
}

top_tsv_to_json() {
  local tsv="$1"
  if [ -z "$tsv" ]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' "$tsv" | jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(split("\t") | select(length >= 3) |
        {syscall_ms:(.[0] | tonumber), events:(.[1] | tonumber), path:(.[2:] | join("\t"))})
  '
}

extract_path_json() {
  local raw="$1" json
  json="$(awk '/^\{"buckets":/ {line=$0} END {if (line != "") print line}' <<<"$raw")"
  if [ -z "$json" ] || ! jq -e . >/dev/null 2>&1 <<<"$json"; then
    printf '%s\n' "$raw" >&2
    return 1
  fi
  printf '%s' "$json"
}

remove_trace() {
  local cid="$1" prefix="$2"
  "${CRI[@]}" exec "$cid" sh -c \
    'rm -f "$1".*' \
    sh "$prefix" >/dev/null 2>&1 || true
}

trace_cli() {
  local cid="$1" uid="$2" run="$3" label="$4" trace_prefix="$5"
  local host_begin host_end raw rc guest_ms guest_rc path_json top_tsv top_json
  local -a args
  case "$label" in
    config_validate) args=(node openclaw.mjs config validate) ;;
    plugins_list) args=(node openclaw.mjs plugins list --json) ;;
    models_status) args=(node openclaw.mjs models status --json) ;;
    *) echo "error: unsupported CLI label: $label" >&2; return 2 ;;
  esac
  host_begin="$(now_ms)"
  set +e
  raw="$("${CRI[@]}" exec "$cid" sh -c \
    'label=$1; prefix=$2; shift 2; rm -f "$prefix".*; b=$(date +%s%3N); timeout -k 5s 120s strace -ff -qq -ttt -T -e trace=%file -o "$prefix." "$@" >/tmp/hybrid-path-stdout 2>/tmp/hybrid-path-stderr; rc=$?; e=$(date +%s%3N); printf "BENCH_PATH label=%s guest_ms=%s rc=%s\\n" "$label" "$((e-b))" "$rc"; exit "$rc"' \
    sh "$label" "$trace_prefix" "${args[@]}" 2>"$RESULT_DIR/${uid}-${label}-exec.stderr")"
  rc=$?
  set -e
  printf '%s\n' "$raw" > "$RESULT_DIR/${uid}-${label}-raw.txt"
  host_end="$(now_ms)"
  guest_ms="$(sed -nE 's/.*BENCH_PATH label=[^ ]+ guest_ms=([0-9]+) rc=[0-9]+.*/\1/p' <<<"$raw" | tail -n1)"
  guest_rc="$(sed -nE 's/.*BENCH_PATH label=[^ ]+ guest_ms=[0-9]+ rc=([0-9]+).*/\1/p' <<<"$raw" | tail -n1)"
  guest_ms="$(normalize_uint "${guest_ms:-0}")"
  guest_rc="$(normalize_uint "${guest_rc:-$rc}")"
  path_json="$(extract_path_json "$(aggregate_trace "$cid" "$trace_prefix")")"
  top_tsv="$(aggregate_top_trace "$cid" "$trace_prefix")"
  printf '%s\n' "$top_tsv" > "$RESULT_DIR/${uid}-${label}-top.tsv"
  top_json="$(top_tsv_to_json "$top_tsv")"
  jq -n \
    --arg handler kuasar-vmm \
    --arg command "$label" \
    --argjson run "$run" \
    --argjson rc "$guest_rc" \
    --argjson host_ms "$((host_end-host_begin))" \
    --argjson guest_ms "$guest_ms" \
    --argjson path "$path_json" \
    --argjson top_paths "$top_json" \
    --arg cache_mode "$EXPECTED_CACHE" \
    --arg app_mode "$APP_MODE" \
    --arg vmm_config "$SYSTEM_CONFIG" \
    '{handler:$handler,run:$run,command:$command,rc:$rc,app_mode:$app_mode,cache_mode:$cache_mode,vmm_config:$vmm_config,host_wall_ms:$host_ms,guest_wall_ms:$guest_ms,transport_residual_ms:($host_ms-$guest_ms),path:$path,top_paths:$top_paths}' \
    | tee -a "$NDJSON"
  remove_trace "$cid" "$trace_prefix"
}

trace_gateway_health() {
  local cid="$1" uid="$2" run="$3" gateway_prefix="$4" health_prefix="$5"
  local host_begin host_end raw rc gateway_ms health_ms health_rc path_gateway path_health top_gateway_tsv top_health_tsv top_gateway_json top_health_json
  host_begin="$(now_ms)"
  set +e
  raw="$("${CRI[@]}" exec "$cid" sh -c \
    'gp=$1; hp=$2; rm -f "$gp".* "$hp".* /tmp/hybrid-path-gateway.log /tmp/hybrid-path-health.json; gbegin=$(date +%s%3N); timeout -k 5s 90s strace -ff -qq -ttt -T -e trace=%file -o "$gp." env OPENCLAW_GATEWAY_PORT=18791 node openclaw.mjs gateway --bind loopback --port 18791 >/tmp/hybrid-path-gateway.log 2>&1 & gpid=$!; ready=0; i=0; while [ "$i" -lt 120 ]; do grep -q "\\[gateway\\] ready" /tmp/hybrid-path-gateway.log && { ready=1; break; }; kill -0 "$gpid" 2>/dev/null || break; i=$((i+1)); sleep 0.25; done; gateway_end=$(date +%s%3N); if [ "$ready" -ne 1 ]; then kill "$gpid" 2>/dev/null || true; wait "$gpid" 2>/dev/null || true; printf "BENCH_GATEWAY ready=0 gateway_ms=%s health_ms=0 health_rc=1\\n" "$((gateway_end-gbegin))"; exit 1; fi; gateway_ms=$((gateway_end-gbegin)); hbegin=$(date +%s%3N); timeout -k 5s 45s strace -ff -qq -ttt -T -e trace=%file -o "$hp." env OPENCLAW_GATEWAY_PORT=18791 node openclaw.mjs gateway health --json >/tmp/hybrid-path-health.json 2>/tmp/hybrid-path-health.err; hrc=$?; hend=$(date +%s%3N); kill "$gpid" 2>/dev/null || true; wait "$gpid" 2>/dev/null || true; printf "BENCH_GATEWAY ready=1 gateway_ms=%s health_ms=%s health_rc=%s\\n" "$gateway_ms" "$((hend-hbegin))" "$hrc"; exit "$hrc"' \
    sh "$gateway_prefix" "$health_prefix" 2>"$RESULT_DIR/${uid}-gateway-health-exec.stderr")"
  rc=$?
  set -e
  printf '%s\n' "$raw" > "$RESULT_DIR/${uid}-gateway-health-raw.txt"
  host_end="$(now_ms)"
  gateway_ms="$(sed -nE 's/.*BENCH_GATEWAY ready=1 gateway_ms=([0-9]+) health_ms=.*/\1/p' <<<"$raw" | tail -n1)"
  health_ms="$(sed -nE 's/.*BENCH_GATEWAY ready=1 gateway_ms=[0-9]+ health_ms=([0-9]+).*/\1/p' <<<"$raw" | tail -n1)"
  health_rc="$(sed -nE 's/.*BENCH_GATEWAY ready=1 gateway_ms=[0-9]+ health_ms=[0-9]+ health_rc=([0-9]+).*/\1/p' <<<"$raw" | tail -n1)"
  gateway_ms="$(normalize_uint "${gateway_ms:-0}")"
  health_ms="$(normalize_uint "${health_ms:-0}")"
  health_rc="$(normalize_uint "${health_rc:-$rc}")"
  path_gateway="$(extract_path_json "$(aggregate_trace "$cid" "$gateway_prefix")")"
  path_health="$(extract_path_json "$(aggregate_trace "$cid" "$health_prefix")")"
  top_gateway_tsv="$(aggregate_top_trace "$cid" "$gateway_prefix")"
  top_health_tsv="$(aggregate_top_trace "$cid" "$health_prefix")"
  printf '%s\n' "$top_gateway_tsv" > "$RESULT_DIR/${uid}-gateway-top.tsv"
  printf '%s\n' "$top_health_tsv" > "$RESULT_DIR/${uid}-health-top.tsv"
  top_gateway_json="$(top_tsv_to_json "$top_gateway_tsv")"
  top_health_json="$(top_tsv_to_json "$top_health_tsv")"
  "${CRI[@]}" exec "$cid" cat /tmp/hybrid-path-health.json > "$RESULT_DIR/${uid}-gateway-health.json" 2>/dev/null || true
  jq -n \
    --arg handler kuasar-vmm \
    --arg command gateway_health \
    --argjson run "$run" \
    --argjson rc "$health_rc" \
    --argjson host_ms "$((host_end-host_begin))" \
    --argjson gateway_ms "$gateway_ms" \
    --argjson health_ms "$health_ms" \
    --argjson gateway_path "$path_gateway" \
    --argjson health_path "$path_health" \
    --argjson top_gateway "$top_gateway_json" \
    --argjson top_health "$top_health_json" \
    --arg cache_mode "$EXPECTED_CACHE" \
    --arg app_mode "$APP_MODE" \
    --arg vmm_config "$SYSTEM_CONFIG" \
    '{handler:$handler,run:$run,command:$command,rc:$rc,app_mode:$app_mode,cache_mode:$cache_mode,vmm_config:$vmm_config,host_wall_ms:$host_ms,gateway_guest_ms:$gateway_ms,health_guest_ms:$health_ms,transport_residual_ms:($host_ms-$gateway_ms-$health_ms),path:{gateway:$gateway_path,health:$health_path},top_paths:{gateway:$top_gateway,health:$top_health}}' \
    | tee -a "$NDJSON"
  remove_trace "$cid" "$gateway_prefix"
  remove_trace "$cid" "$health_prefix"
}

run_one() {
  local run="$1" uid="hybrid-path-vmm-${1}-$(date +%s%N)" pod='' cid='' pod_spec container_spec
  local wrapper_log="hybrid-path-${uid}.log"
  pod_spec="$RESULT_DIR/specs/${uid}-pod.json"
  container_spec="$RESULT_DIR/specs/${uid}-container.json"
  trap 'cleanup_ids "$cid" "$pod"' RETURN
  make_specs "$uid" "$pod_spec" "$container_spec" "$wrapper_log"
  printf 'run=%s phase=runp\n' "$run"
  pod="$("${CRI[@]}" runp --runtime kuasar-vmm "$pod_spec")"
  printf 'run=%s phase=create\n' "$run"
  cid="$("${CRI[@]}" create "$pod" "$container_spec" "$pod_spec")"
  printf 'run=%s phase=start\n' "$run"
  "${CRI[@]}" start "$cid" >/dev/null
  printf 'run=%s phase=idle-ready\n' "$run"
  wait_idle "$cid"
  "${CRI[@]}" exec "$cid" sh -c 'id; stat -f -c "%T %n" / /app /usr/local /home/node/.openclaw; cat /proc/self/mountinfo' \
    > "$RESULT_DIR/${uid}-mounts.txt"
  printf 'run=%s phase=gateway-health\n' "$run"
  trace_gateway_health "$cid" "$uid" "$run" "/tmp/${uid}-gateway" "/tmp/${uid}-health"
  for label in config_validate plugins_list models_status; do
    printf 'run=%s phase=%s\n' "$run" "$label"
    trace_cli "$cid" "$uid" "$run" "$label" "/tmp/${uid}-${label}"
  done
  "${CRI[@]}" logs "$cid" > "$RESULT_DIR/${uid}.log" 2>&1 || true
  cleanup_ids "$cid" "$pod"
  cid=''; pod=''
  trap - RETURN
}

for run in $(seq 1 "$REPEATS"); do
  run_one "$run"
done

jq -s '.' "$NDJSON" > "$RESULT_DIR/results.json"
jq '.' "$RESULT_DIR/results.json"
printf '%s\n' "results=$RESULT_DIR"
