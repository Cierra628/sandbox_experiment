#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT_DIR/config/versions.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/config/versions.env"
fi

CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
REMOTE_IMAGE="${REMOTE_IMAGE:-10.2.30.50:5000/openclaw-kuasar:2026.6.11-virtiofs}"
HANDLERS="${HANDLERS:-runc kuasar-runc kuasar-vmm}"
RUNS="${RUNS:-3}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"
CRI_READY_TIMEOUT="${CRI_READY_TIMEOUT:-60}"
PULL_TIMEOUT="${PULL_TIMEOUT:-20m}"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"
CT_ROOT=/var/lib/openclaw-kuasar/containerd
CT_STATE=/run/openclaw-kuasar/containerd-state
SOCK=/run/openclaw-kuasar/containerd.sock
CONTAINERD_CONFIG=/etc/openclaw-kuasar/containerd.toml
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/.artifacts/remote-coldstart-$(date -u +%Y%m%dT%H%M%SZ)}"

CONFIRMED=0
DRY_RUN=0
SKIP_SAMPLE=0
KEEP_BACKUPS=0
CURRENT_POD=''
CURRENT_CID=''
ACTIVE_BACKUP_ROOT=''
ACTIVE_BACKUP_STATE=''
CURRENT_HANDLER=''
CURRENT_RUN=''
CONTAINERD_SERVICE=openclaw-kuasar-containerd.service
RUNC_SERVICE=openclaw-kuasar-runc.service
VMM_SERVICE=openclaw-kuasar-vmm.service

usage() {
  cat <<'EOF'
Usage: scripts/15-benchmark-remote-coldstart.sh [options]
  --confirm-cold-reset  Permit reset of the dedicated containerd root.
  --handlers LIST       Space-separated handlers.
  --runs N              Runs per handler.
  --result-dir DIR      Artifact directory.
  --skip-sample         Skip the model sample.
  --keep-backups        Keep reset backups.
  --dry-run             Validate and print without mutation.
  -h, --help            Show this help.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
now_ms() { date +%s%3N; }

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --confirm-cold-reset) CONFIRMED=1 ;;
      --handlers) [ "$#" -ge 2 ] || die '--handlers needs a value'; HANDLERS="$2"; shift ;;
      --runs) [ "$#" -ge 2 ] || die '--runs needs a value'; RUNS="$2"; shift ;;
      --result-dir) [ "$#" -ge 2 ] || die '--result-dir needs a value'; RESULT_DIR="$2"; shift ;;
      --skip-sample) SKIP_SAMPLE=1 ;;
      --keep-backups) KEEP_BACKUPS=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
}

validate_config() {
  local h spec
  [[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || die 'RUNS must be a positive integer'
  [[ "$READY_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 'READY_TIMEOUT must be positive'
  [[ "$CRI_READY_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 'CRI_READY_TIMEOUT must be positive'
  [ "${CRI_ENDPOINT#unix://}" = "$SOCK" ] || die "unexpected CRI endpoint: $CRI_ENDPOINT"
  [ -n "$REMOTE_IMAGE" ] || die 'REMOTE_IMAGE is empty'
  for h in $HANDLERS; do
    case "$h" in runc|kuasar-runc|kuasar-vmm) ;; *) die "unsupported handler: $h" ;; esac
  done
  test -r "$CONTAINERD_CONFIG" || die "missing $CONTAINERD_CONFIG"
  grep -Fq 'root = "/var/lib/openclaw-kuasar/containerd"' "$CONTAINERD_CONFIG" ||
    die 'containerd config does not use the dedicated root'
  for spec in \
    containerd/openclaw-pod.json \
    containerd/openclaw-pod-vmm.json \
    containerd/openclaw-container.json \
    containerd/openclaw-container-vmm.json
  do
    test -f "$ROOT_DIR/$spec" || die "missing $spec"
  done
  [ "$DRY_RUN" -eq 1 ] && return 0
  for cmd in crictl ctr jq date systemctl grep awk du pgrep sudo; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd"
  done
  [ "$CONFIRMED" -eq 1 ] || die 'pass --confirm-cold-reset for destructive reset'
  sudo -v
}

print_plan() {
  printf '%s\n' \
    'Remote cold-pull benchmark plan:' \
    "  image=$REMOTE_IMAGE" \
    "  handlers=$HANDLERS" \
    "  runs_per_handler=$RUNS" \
    "  cri_endpoint=$CRI_ENDPOINT" \
    "  containerd_root=$CT_ROOT" \
    "  result_dir=$RESULT_DIR" \
    "  sample=$([ "$SKIP_SAMPLE" -eq 1 ] && echo skipped || echo enabled)" \
    "  keep_backups=$KEEP_BACKUPS"
}

parse_args "$@"
validate_config
print_plan
[ "$DRY_RUN" -eq 1 ] && exit 0

CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")
CTR=(sudo ctr --address "$SOCK" --namespace k8s.io)
mkdir -p "$RESULT_DIR/specs" "$RESULT_DIR/logs" "$RESULT_DIR/diagnostics" "$RESULT_DIR/rows"
NDJSON="$RESULT_DIR/results.ndjson"
: > "$NDJSON"

timed() {
  local out_var="$1" ms_var="$2"; shift 2
  local b e captured rc
  b="$(now_ms)"
  set +e
  captured="$("$@" 2>&1)"
  rc=$?
  set -e
  e="$(now_ms)"
  printf -v "$out_var" '%s' "$captured"
  printf -v "$ms_var" '%s' "$((e-b))"
  return "$rc"
}

json_from_output() {
  awk 'BEGIN{found=0} !found && $0 ~ /^[[:space:]]*\{/ {found=1} found{print}'
}

workloads_present() {
  local ps pods
  ps="$(${CRI[@]} ps -a 2>/dev/null || true)"
  pods="$(${CRI[@]} pods 2>/dev/null || true)"
  printf '%s\n' "$ps" | tail -n +2 | grep -Eq '^[[:space:]]*[[:xdigit:]]{12,}' && return 0
  printf '%s\n' "$pods" | tail -n +2 | grep -Eq '^[[:space:]]*[[:xdigit:]]{12,}' && return 0
  return 1
}

assert_empty() {
  workloads_present && die 'active CRI container or pod remains'
  pgrep -af 'cloud-hypervisor|virtiofsd' >/dev/null 2>&1 &&
    die 'Cloud Hypervisor or virtiofsd workload remains'
}

image_present() {
  local image="$1"
  "${CTR[@]}" images ls 2>/dev/null |
    awk -v ref="$image" '$1==ref{found=1} END{exit found?0:1}'
}

root_bytes() { du -sb "$CT_ROOT" 2>/dev/null | awk '{print $1}'; }

stop_stack() {
  sudo systemctl stop "$CONTAINERD_SERVICE" || true
  sudo systemctl stop "$VMM_SERVICE" || true
  sudo systemctl stop "$RUNC_SERVICE" || true
}

start_stack() {
  local deadline=$((SECONDS+CRI_READY_TIMEOUT)) info
  sudo systemctl start "$RUNC_SERVICE"
  sudo systemctl start "$VMM_SERVICE"
  sudo systemctl start "$CONTAINERD_SERVICE"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -S "$SOCK" ] && info="$(${CRI[@]} info 2>&1)"; then
      printf '%s\n' "$info" |
        jq '{runtimeReady:(.status.conditions[]? | select(.type=="RuntimeReady") | .status),networkReady:(.status.conditions[]? | select(.type=="NetworkReady") | .status)}' \
        > "$RESULT_DIR/diagnostics/${CURRENT_HANDLER}-run${CURRENT_RUN}-cri.json" || true
      return 0
    fi
    sleep 1
  done
  return 1
}

reset_root() {
  local stamp
  assert_empty
  [ -d "$CT_ROOT" ] || die "missing containerd root: $CT_ROOT"
  stop_stack
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-${CURRENT_HANDLER}-${CURRENT_RUN}"
  ACTIVE_BACKUP_ROOT="${CT_ROOT}.coldstart-backup-${stamp}"
  ACTIVE_BACKUP_STATE="${CT_STATE}.coldstart-backup-${stamp}"
  sudo mv "$CT_ROOT" "$ACTIVE_BACKUP_ROOT"
  if [ -e "$CT_STATE" ]; then sudo mv "$CT_STATE" "$ACTIVE_BACKUP_STATE"; else ACTIVE_BACKUP_STATE=''; fi
  sudo install -d -m 0755 "$CT_ROOT"
  sudo install -d -m 0755 "$CT_STATE"
}

discard_backup() {
  [ "$KEEP_BACKUPS" -eq 1 ] && return 0
  [ -z "$ACTIVE_BACKUP_ROOT" ] || {
    case "$ACTIVE_BACKUP_ROOT" in "$CT_ROOT".coldstart-backup-*) ;; *) die 'unsafe root backup path' ;; esac
    sudo rm -rf -- "$ACTIVE_BACKUP_ROOT"
  }
  [ -z "$ACTIVE_BACKUP_STATE" ] || {
    case "$ACTIVE_BACKUP_STATE" in "$CT_STATE".coldstart-backup-*) ;; *) die 'unsafe state backup path' ;; esac
    sudo rm -rf -- "$ACTIVE_BACKUP_STATE"
  }
  ACTIVE_BACKUP_ROOT=''
  ACTIVE_BACKUP_STATE=''
}

pull_one() {
  local image="$1" out_var="$2" ms_var="$3" out rc
  if timed out "$ms_var" "${CRI[@]}" pull --pull-timeout "$PULL_TIMEOUT" "$image"; then rc=0; else rc=$?; fi
  printf -v "$out_var" '%s' "$captured"
  return "$rc"
}

pull_images() {
  local out rc
  pull_one "$PAUSE_IMAGE" out PAUSE_PULL_MS || die "pause pull failed"
  printf '%s\n' "$out" > "$RESULT_DIR/logs/${CURRENT_HANDLER}-run${CURRENT_RUN}-pause-pull.log"
  image_present "$REMOTE_IMAGE" && die 'target image already present before pull'
  CACHE_BEFORE=empty-root
  ROOT_BYTES_BEFORE="$(root_bytes)"
  rc=0
  pull_one "$REMOTE_IMAGE" out PULL_MS || rc=$?
  rc="${rc:-0}"
  printf '%s\n' "$out" > "$RESULT_DIR/logs/${CURRENT_HANDLER}-run${CURRENT_RUN}-openclaw-pull.log"
  [ "$rc" -eq 0 ] || die 'OpenClaw pull failed'
  image_present "$REMOTE_IMAGE" || die 'target image absent after pull'
  CACHE_AFTER=present
  ROOT_BYTES_AFTER="$(root_bytes)"
  IMAGE_DIGEST="$(${CTR[@]} images ls 2>/dev/null | awk -v ref="$REMOTE_IMAGE" '$1==ref{print $3;exit}')"
  [ -n "$IMAGE_DIGEST" ] || IMAGE_DIGEST=unknown
}

cleanup_ids() {
  set +e
  [ -z "$CURRENT_CID" ] || { "${CRI[@]}" stop "$CURRENT_CID" >/dev/null 2>&1 || true; "${CRI[@]}" rm "$CURRENT_CID" >/dev/null 2>&1 || true; }
  [ -z "$CURRENT_POD" ] || { "${CRI[@]}" stopp "$CURRENT_POD" >/dev/null 2>&1 || true; "${CRI[@]}" rmp "$CURRENT_POD" >/dev/null 2>&1 || true; }
  set -e
}

wait_gateway() {
  local deadline=$((SECONDS+READY_TIMEOUT)) logs
  while [ "$SECONDS" -lt "$deadline" ]; do
    logs="$(${CRI[@]} logs "$CURRENT_CID" 2>&1 || true)"
    printf '%s\n' "$logs" > "$RESULT_DIR/logs/${CURRENT_HANDLER}-run${CURRENT_RUN}-gateway.log"
    printf '%s\n' "$logs" | grep -q '\[gateway\] ready' && return 0
    "${CRI[@]}" inspect "$CURRENT_CID" 2>/dev/null |
      jq -e '.status.state=="CONTAINER_EXITED"' >/dev/null 2>&1 && return 1
    sleep 1
  done
  return 1
}

make_specs() {
  local pod_base="$ROOT_DIR/containerd/openclaw-pod.json"
  local container_base="$ROOT_DIR/containerd/openclaw-container.json"
  local uid="remote-coldstart-${CURRENT_HANDLER}-${CURRENT_RUN}-$(date +%s%N)"
  POD_SPEC="$RESULT_DIR/specs/${CURRENT_HANDLER}-run${CURRENT_RUN}-pod.json"
  CONTAINER_SPEC="$RESULT_DIR/specs/${CURRENT_HANDLER}-run${CURRENT_RUN}-container.json"
  if [ "$CURRENT_HANDLER" = kuasar-vmm ]; then
    pod_base="$ROOT_DIR/containerd/openclaw-pod-vmm.json"
    container_base="$ROOT_DIR/containerd/openclaw-container-vmm.json"
  fi
  jq --arg uid "$uid" --argjson attempt "$CURRENT_RUN" \
    '.metadata.uid=$uid | .metadata.attempt=$attempt' "$pod_base" > "$POD_SPEC"
  jq --arg image "$REMOTE_IMAGE" --arg log_path "${uid}.log" --argjson attempt "$CURRENT_RUN" \
    '.image.image=$image | .metadata.attempt=$attempt | .log_path=$log_path' "$container_base" > "$CONTAINER_SPEC"
}

add_note() { [ -z "$NOTE" ] && NOTE="$1" || NOTE="$NOTE,$1"; }

write_row() {
  local file="$RESULT_DIR/rows/${CURRENT_HANDLER}-run${CURRENT_RUN}.json"
  jq -n \
    --arg handler "$CURRENT_HANDLER" --argjson run "$CURRENT_RUN" --arg status "$STATUS" --arg note "$NOTE" \
    --arg image "$REMOTE_IMAGE" --arg cache_before "$CACHE_BEFORE" --arg cache_after "$CACHE_AFTER" --arg digest "$IMAGE_DIGEST" \
    --argjson reset_ms "$RESET_MS" --argjson cri_ready_ms "$CRI_READY_MS" --argjson pause_pull_ms "$PAUSE_PULL_MS" --argjson pull_ms "$PULL_MS" \
    --argjson root_before "$ROOT_BYTES_BEFORE" --argjson root_after "$ROOT_BYTES_AFTER" \
    --argjson runp_ms "$RUNP_MS" --argjson create_ms "$CREATE_MS" --argjson start_ms "$START_MS" --argjson gateway_ready_ms "$GATEWAY_READY_MS" \
    --argjson health_ok "$HEALTH_OK" --argjson health_wall "$HEALTH_HOST_WALL_MS" --argjson health_internal "$HEALTH_INTERNAL_MS" \
    --argjson sample_ok "$SAMPLE_OK" --argjson sample_wall "$SAMPLE_HOST_WALL_MS" --argjson sample_internal "$SAMPLE_INTERNAL_MS" \
    --arg text "$SAMPLE_TEXT" --arg provider "$SAMPLE_PROVIDER" --arg model "$SAMPLE_MODEL" --argjson fallback "$FALLBACK_USED" \
    --argjson cleanup_ms "$CLEANUP_MS" --argjson total_ms "$TOTAL_MS" \
    '{handler:$handler,run:$run,status:$status,image:$image,cache_before:$cache_before,cache_after:$cache_after,image_digest:$digest,root_bytes_before:$root_before,root_bytes_after:$root_after,reset_ms:$reset_ms,cri_ready_ms:$cri_ready_ms,pause_pull_ms:$pause_pull_ms,pull_ms:$pull_ms,lifecycle:{runp_ms:$runp_ms,create_ms:$create_ms,start_ms:$start_ms,gateway_ready_ms:$gateway_ready_ms},health:{ok:$health_ok,host_wall_ms:$health_wall,internal_ms:$health_internal},sample:{ok:$sample_ok,host_wall_ms:$sample_wall,internal_ms:$sample_internal,text:$text,provider:$provider,model:$model,fallback_used:$fallback},cleanup_ms:$cleanup_ms,total_ms:$total_ms,note:$note}' > "$file"
  cat "$file" >> "$NDJSON"
}

run_once() {
  local run_begin b e ready_begin output json
  CURRENT_HANDLER="$1"
  CURRENT_RUN="$2"
  CURRENT_POD=''
  CURRENT_CID=''
  STATUS=PASS
  NOTE=''
  CACHE_BEFORE=unknown
  CACHE_AFTER=unknown
  IMAGE_DIGEST=unknown
  ROOT_BYTES_BEFORE=0
  ROOT_BYTES_AFTER=0
  RESET_MS=0
  CRI_READY_MS=0
  PAUSE_PULL_MS=0
  PULL_MS=0
  RUNP_MS=0
  CREATE_MS=0
  START_MS=0
  GATEWAY_READY_MS=0
  HEALTH_OK=false
  HEALTH_HOST_WALL_MS=0
  HEALTH_INTERNAL_MS=0
  SAMPLE_OK=null
  SAMPLE_HOST_WALL_MS=0
  SAMPLE_INTERNAL_MS=0
  SAMPLE_TEXT=''
  SAMPLE_PROVIDER=''
  SAMPLE_MODEL=''
  FALLBACK_USED=false
  CLEANUP_MS=0
  run_begin="$(now_ms)"
  b="$(now_ms)"; reset_root; e="$(now_ms)"; RESET_MS="$((e-b))"
  b="$(now_ms)"; start_stack || die "CRI not ready for $CURRENT_HANDLER run $CURRENT_RUN"; e="$(now_ms)"; CRI_READY_MS="$((e-b))"
  pull_images
  make_specs
  if ! timed CURRENT_POD RUNP_MS "${CRI[@]}" runp --runtime "$CURRENT_HANDLER" "$POD_SPEC"; then STATUS=FAIL; add_note runp-failed; fi
  if [ "$STATUS" = PASS ] && ! timed CURRENT_CID CREATE_MS "${CRI[@]}" create "$CURRENT_POD" "$CONTAINER_SPEC" "$POD_SPEC"; then STATUS=FAIL; add_note create-failed; fi
  if [ "$STATUS" = PASS ] && ! timed output START_MS "${CRI[@]}" start "$CURRENT_CID"; then STATUS=FAIL; add_note start-failed; fi
  if [ "$STATUS" = PASS ]; then
    ready_begin="$(now_ms)"
    if wait_gateway; then e="$(now_ms)"; GATEWAY_READY_MS="$((e-ready_begin))"; else e="$(now_ms)"; GATEWAY_READY_MS="$((e-ready_begin))"; STATUS=FAIL; add_note gateway-not-ready; fi
  fi
  if [ "$STATUS" = PASS ]; then
    if timed output HEALTH_HOST_WALL_MS "${CRI[@]}" exec "$CURRENT_CID" node openclaw.mjs gateway health --json; then
      printf '%s\n' "$output" > "$RESULT_DIR/logs/${CURRENT_HANDLER}-run${CURRENT_RUN}-health.raw"
      json="$(printf '%s\n' "$output" | json_from_output)"
      if printf '%s\n' "$json" | jq -e . >/dev/null 2>&1; then
        HEALTH_OK="$(printf '%s\n' "$json" | jq -r '.ok // false')"
        HEALTH_INTERNAL_MS="$(printf '%s\n' "$json" | jq -r '.durationMs // 0')"
        [ "$HEALTH_OK" = true ] || { STATUS=FAIL; add_note health-not-ok; }
      else STATUS=FAIL; add_note health-json-invalid; fi
    else STATUS=FAIL; add_note health-exec-failed; fi
  fi
  if [ "$SKIP_SAMPLE" -eq 0 ] && [ "$STATUS" = PASS ]; then
    if timed output SAMPLE_HOST_WALL_MS "${CRI[@]}" exec "$CURRENT_CID" node openclaw.mjs agent --local --agent main \
      --session-key "agent:main:remote-coldstart-${CURRENT_HANDLER}-${CURRENT_RUN}" \
      --message 'Reply with exactly KUASAR_SAMPLE_OK and nothing else.' --timeout 180 --json; then
      printf '%s\n' "$output" > "$RESULT_DIR/logs/${CURRENT_HANDLER}-run${CURRENT_RUN}-sample.raw"
      json="$(printf '%s\n' "$output" | json_from_output)"
      if printf '%s\n' "$json" | jq -e . >/dev/null 2>&1; then
        SAMPLE_TEXT="$(printf '%s\n' "$json" | jq -r '.payloads[0].text // ""')"
        SAMPLE_PROVIDER="$(printf '%s\n' "$json" | jq -r '.meta.agentMeta.provider // ""')"
        SAMPLE_MODEL="$(printf '%s\n' "$json" | jq -r '.meta.agentMeta.model // ""')"
        SAMPLE_INTERNAL_MS="$(printf '%s\n' "$json" | jq -r '.meta.durationMs // 0')"
        FALLBACK_USED="$(printf '%s\n' "$json" | jq -r '.meta.executionTrace.fallbackUsed // false')"
        SAMPLE_OK=true
        [ "$SAMPLE_TEXT" = KUASAR_SAMPLE_OK ] || { SAMPLE_OK=false; STATUS=FAIL; add_note sample-output-mismatch; }
        [ "$FALLBACK_USED" = false ] || { STATUS=FAIL; add_note sample-fallback-used; }
      else SAMPLE_OK=false; STATUS=FAIL; add_note sample-json-invalid; fi
    else SAMPLE_OK=false; STATUS=FAIL; add_note sample-exec-failed; fi
  fi
  [ -z "$CURRENT_CID" ] || "${CRI[@]}" logs "$CURRENT_CID" > "$RESULT_DIR/logs/${CURRENT_HANDLER}-run${CURRENT_RUN}.log" 2>&1 || true
  b="$(now_ms)"; cleanup_ids; e="$(now_ms)"; CLEANUP_MS="$((e-b))"
  CURRENT_CID=''; CURRENT_POD=''
  workloads_present && { STATUS=FAIL; add_note cleanup-leftover; } || true
  e="$(now_ms)"; TOTAL_MS="$((e-run_begin))"
  write_row
  [ "$STATUS" = PASS ] && discard_backup
  printf 'handler=%s run=%s status=%s pull_ms=%s gateway_ready_ms=%s total_ms=%s\n' "$CURRENT_HANDLER" "$CURRENT_RUN" "$STATUS" "$PULL_MS" "$GATEWAY_READY_MS" "$TOTAL_MS"
}

build_summary() {
  local expected=0 actual failed h count
  jq -s '.' "$RESULT_DIR/rows"/*.json > "$RESULT_DIR/results.json"
  jq 'def avg(f):(map(f)|if length==0 then 0 else add/length end);group_by(.handler)|map({handler:.[0].handler,runs:length,passed:(map(select(.status=="PASS"))|length),failed:(map(select(.status!="PASS"))|length),averages_ms:{reset:avg(.reset_ms),cri_ready:avg(.cri_ready_ms),pause_pull:avg(.pause_pull_ms),pull:avg(.pull_ms),runp:avg(.lifecycle.runp_ms),create:avg(.lifecycle.create_ms),start:avg(.lifecycle.start_ms),gateway_ready:avg(.lifecycle.gateway_ready_ms),health_exec:avg(.health.host_wall_ms),health_internal:avg(.health.internal_ms),sample_exec:avg(.sample.host_wall_ms),sample_internal:avg(.sample.internal_ms),cleanup:avg(.cleanup_ms),total:avg(.total_ms)}})' "$RESULT_DIR/results.json" > "$RESULT_DIR/summary.json"
  for h in $HANDLERS; do
    expected=$((expected+RUNS))
    count="$(jq --arg h "$h" '[.[]|select(.handler==$h)]|length' "$RESULT_DIR/results.json")"
    [ "$count" -eq "$RUNS" ] || die "expected $RUNS rows for $h, got $count"
  done
  actual="$(jq 'length' "$RESULT_DIR/results.json")"
  [ "$actual" -eq "$expected" ] || die "expected $expected rows, got $actual"
  failed="$(jq '[.[]|select(.status!="PASS")]|length' "$RESULT_DIR/results.json")"
  printf '%s\n' "results=$RESULT_DIR" "rows=$actual" "failed=$failed"
  jq . "$RESULT_DIR/summary.json"
  [ "$failed" -eq 0 ]
}

on_exit() {
  local rc=$?
  trap - EXIT
  set +e
  cleanup_ids
  if [ "$rc" -ne 0 ]; then
    printf 'benchmark failed; artifacts=%s\n' "$RESULT_DIR" >&2
    [ -z "$ACTIVE_BACKUP_ROOT" ] || printf 'root backup retained at %s\n' "$ACTIVE_BACKUP_ROOT" >&2
    [ -z "$ACTIVE_BACKUP_STATE" ] || printf 'state backup retained at %s\n' "$ACTIVE_BACKUP_STATE" >&2
  fi
  exit "$rc"
}

trap on_exit EXIT
for h in $HANDLERS; do
  for r in $(seq 1 "$RUNS"); do
    run_once "$h" "$r"
  done
done
build_summary
