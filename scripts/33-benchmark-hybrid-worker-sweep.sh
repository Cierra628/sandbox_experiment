#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
SYSTEM_CONFIG=/etc/openclaw-kuasar/vmm.toml
BASE_CONFIG="$ROOT_DIR/containerd/kuasar-vmm-virtiofs-metadata.toml"
SYSTEM_SANDBOXER=/usr/local/libexec/openclaw-kuasar/vmm-sandboxer
VMM_SERVICE=openclaw-kuasar-vmm.service
CONTAINERD_SERVICE=openclaw-kuasar-containerd.service
STATE_LOOP_DEVICE="${HYBRID_STATE_LOOP_DEVICE:-}"
APP_LOOP_DEVICE="${HYBRID_APP_LOOP_DEVICE:-}"
IMAGE="${HYBRID_IMAGE:-10.2.30.50:5000/openclaw-kuasar:2026.6.11-virtiofs}"
VALUES="${HYBRID_WORKER_VALUES:-2 4 8}"
RUNS="${HYBRID_WORKER_RUNS:-3}"
PASSES="${HYBRID_WORKER_PASSES:-512}"
READY_TIMEOUT="${HYBRID_WORKER_READY_TIMEOUT:-180}"
ARTIFACT_TIMEOUT="${HYBRID_WORKER_ARTIFACT_TIMEOUT:-15}"
PULL_TIMEOUT="${HYBRID_WORKER_PULL_TIMEOUT:-20m}"
RESULT_DIR="${HYBRID_WORKER_RESULT_DIR:-$ROOT_DIR/.artifacts/hybrid-worker-sweep-$(date -u +%Y%m%dT%H%M%SZ)}"
CONFIRM=0
DRY_RUN=0

usage() {
  printf '%s\n' \
    'Usage: scripts/33-benchmark-hybrid-worker-sweep.sh [options]' \
    '' \
    'Sweeps virtiofsd thread_pool_size while keeping the hybrid workload fixed.' \
    '' \
    'Required options:' \
    '  --state-loop DEV       writable state loop block device' \
    '  --app-loop DEV         read-only /app loop block device' \
    '  --runs N               independent workload rounds per value' \
    '  --passes N             image-upscale passes per workload round' \
    '  --result-dir DIR       result directory' \
    '  --confirm-config-install permit service/config changes' \
    '' \
    'Optional options:' \
    '  --values "2 4 8"       worker values to test' \
    '  --image IMAGE          workload image' \
    '  --ready-timeout N      Gateway ready timeout in seconds' \
    '  --artifact-timeout N   workload artifact timeout in seconds' \
    '  --dry-run              print the plan without changing services/config' \
    '  -h, --help             show this help'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state-loop) STATE_LOOP_DEVICE="$2"; shift 2 ;;
    --app-loop) APP_LOOP_DEVICE="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --passes) PASSES="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    --values) VALUES="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
    --artifact-timeout) ARTIFACT_TIMEOUT="$2"; shift 2 ;;
    --confirm-config-install) CONFIRM=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -n "$STATE_LOOP_DEVICE" ] || { echo 'error: --state-loop is required' >&2; exit 2; }
[ -n "$APP_LOOP_DEVICE" ] || { echo 'error: --app-loop is required' >&2; exit 2; }
[ -f "$BASE_CONFIG" ] || { echo "error: missing config template: $BASE_CONFIG" >&2; exit 2; }
for name in RUNS PASSES READY_TIMEOUT ARTIFACT_TIMEOUT; do
  value="${!name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: $name must be a positive integer" >&2
    exit 2
  }
done
read -r -a WORKER_VALUES <<< "$VALUES"
[ "${#WORKER_VALUES[@]}" -gt 0 ] || { echo 'error: --values must not be empty' >&2; exit 2; }
for value in "${WORKER_VALUES[@]}"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: worker value is not a positive integer: $value" >&2
    exit 2
  }
done

printf '%s\n' \
  'Hybrid VirtioFS worker sweep plan:' \
  '  rootfs=VirtioFS cache=metadata' \
  '  /app on virtio-blk (read-only)' \
  '  /home/node/.openclaw on virtio-blk (read-write)' \
  "  workers=$VALUES" \
  "  image=$IMAGE" \
  "  runs_per_value=$RUNS" \
  "  passes=$PASSES" \
  "  pull_timeout=$PULL_TIMEOUT (outside measured phases)" \
  "  result_dir=$RESULT_DIR"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' 'dry-run: no system config, service, or CRI state was changed.'
  exit 0
fi

[ "$CONFIRM" -eq 1 ] || {
  echo 'error: service/config changes require --confirm-config-install' >&2
  exit 2
}

for command_name in jq crictl sha256sum systemctl sed; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "error: $command_name is required" >&2
    exit 1
  }
done
sudo -v
sudo test -b "$STATE_LOOP_DEVICE" || { echo "error: not a block device: $STATE_LOOP_DEVICE" >&2; exit 1; }
sudo test -b "$APP_LOOP_DEVICE" || { echo "error: not a block device: $APP_LOOP_DEVICE" >&2; exit 1; }
grep -Eq '^[[:space:]]*container_storage_backend[[:space:]]*=[[:space:]]*"virtiofs"' "$BASE_CONFIG" || {
  echo "error: $BASE_CONFIG is not a virtiofs template" >&2
  exit 1
}
grep -Eq '^[[:space:]]*cache[[:space:]]*=[[:space:]]*"metadata"' "$BASE_CONFIG" || {
  echo "error: $BASE_CONFIG is not a metadata-cache template" >&2
  exit 1
}
[ "$(grep -Ec '^[[:space:]]*thread_pool_size[[:space:]]*=' "$BASE_CONFIG")" -eq 1 ] || {
  echo "error: $BASE_CONFIG must contain exactly one thread_pool_size" >&2
  exit 1
}

CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")
active_containers="$("${CRI[@]}" ps -a -o json | jq '.containers | length')"
active_pods="$("${CRI[@]}" pods -o json | jq '.items | length')"
if [ "$active_containers" -ne 0 ] || [ "$active_pods" -ne 0 ]; then
  echo "error: active CRI resources remain (containers=$active_containers pods=$active_pods)" >&2
  exit 1
fi

mkdir -p "$RESULT_DIR/configs" "$RESULT_DIR/evidence" "$RESULT_DIR/runs"
sudo cat "$SYSTEM_CONFIG" > "$RESULT_DIR/evidence/vmm-before.toml"
ORIGINAL_CONFIG="$RESULT_DIR/evidence/vmm-before.toml"
: > "$RESULT_DIR/results.ndjson"
RESTORE_NEEDED=1

cleanup_resources() {
  local ids pods id pod
  set +e
  ids="$("${CRI[@]}" ps -a -o json 2>/dev/null | jq -r '.containers[]?.id // empty' 2>/dev/null || true)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    "${CRI[@]}" stop "$id" >/dev/null 2>&1 || true
    "${CRI[@]}" rm "$id" >/dev/null 2>&1 || true
  done <<< "$ids"
  pods="$("${CRI[@]}" pods -o json 2>/dev/null | jq -r '.items[]?.id // empty' 2>/dev/null || true)"
  while IFS= read -r pod; do
    [ -n "$pod" ] || continue
    "${CRI[@]}" stopp "$pod" >/dev/null 2>&1 || true
    "${CRI[@]}" rmp "$pod" >/dev/null 2>&1 || true
  done <<< "$pods"
  set -e
}

restore_services() {
  local rc="$1" restore_rc=0
  set +e
  cleanup_resources
  sudo systemctl stop "$CONTAINERD_SERVICE" >/dev/null 2>&1 || true
  sudo systemctl stop "$VMM_SERVICE" >/dev/null 2>&1 || true
  sudo install -m 0644 "$ORIGINAL_CONFIG" "$SYSTEM_CONFIG" || restore_rc=1
  sudo systemctl start "$VMM_SERVICE" >/dev/null 2>&1 || restore_rc=1
  sudo systemctl start "$CONTAINERD_SERVICE" >/dev/null 2>&1 || restore_rc=1
  sudo systemctl is-active --quiet "$VMM_SERVICE" || restore_rc=1
  sudo systemctl is-active --quiet "$CONTAINERD_SERVICE" || restore_rc=1
  printf 'restore_rc=%s\n' "$restore_rc" > "$RESULT_DIR/evidence/restore.txt"
  trap - EXIT INT TERM
  [ "$restore_rc" -eq 0 ] || rc=1
  exit "$rc"
}
trap 'restore_services $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pull_begin="$(date +%s%3N)"
"${CRI[@]}" pull --pull-timeout "$PULL_TIMEOUT" "$IMAGE" > "$RESULT_DIR/evidence/pre-pull.log" 2>&1
pull_end="$(date +%s%3N)"
printf 'pre_pull_ms=%s\n' "$((pull_end - pull_begin))" > "$RESULT_DIR/evidence/pre-pull.txt"

install_variant() {
  local value="$1" variant="$2"
  cp "$BASE_CONFIG" "$variant"
  sed -E -i \
    "s/^([[:space:]]*thread_pool_size[[:space:]]*=[[:space:]]*)[0-9]+/\\1${value}/" \
    "$variant"
  [ "$(grep -Ec '^[[:space:]]*thread_pool_size[[:space:]]*=' "$variant")" -eq 1 ]
  grep -Eq "^[[:space:]]*thread_pool_size[[:space:]]*=[[:space:]]*${value}[[:space:]]*$" "$variant"

  sudo systemctl stop "$CONTAINERD_SERVICE"
  sudo systemctl stop "$VMM_SERVICE"
  sudo install -m 0644 "$variant" "$SYSTEM_CONFIG"
  sudo systemctl start "$VMM_SERVICE"
  sudo systemctl start "$CONTAINERD_SERVICE"
  sudo systemctl is-active --quiet "$VMM_SERVICE"
  sudo systemctl is-active --quiet "$CONTAINERD_SERVICE"

  local deadline=$((SECONDS + READY_TIMEOUT)) info=''
  while [ "$SECONDS" -lt "$deadline" ]; do
    if info="$("${CRI[@]}" info 2>&1)"; then
      if jq -e '[.status.conditions[] | select(.type == "RuntimeReady" or .type == "NetworkReady") | .status] | length == 2 and all(. == true)' \
        <<< "$info" >/dev/null; then
        printf '%s\n' "$info"
        return 0
      fi
    fi
    sleep 1
  done
  printf '%s\n' "$info" >&2
  echo "error: CRI did not become ready for worker value $value" >&2
  return 1
}

for value in "${WORKER_VALUES[@]}"; do
  value_dir="$RESULT_DIR/runs/thread-pool-$value"
  mkdir -p "$value_dir/evidence"
  variant="$RESULT_DIR/configs/vmm-thread-pool-$value.toml"
  printf 'worker=%s phase=install\n' "$value"
  install_variant "$value" "$variant"
  cp "$variant" "$value_dir/evidence/vmm-requested.toml"
  sudo cat "$SYSTEM_CONFIG" > "$value_dir/evidence/vmm-effective.toml"
  sudo sha256sum "$SYSTEM_SANDBOXER" > "$value_dir/evidence/sandboxer-sha256.txt"

  set +e
  HYBRID_IMAGE="$IMAGE" \
  HYBRID_IMAGE_RUNS="$RUNS" \
  HYBRID_IMAGE_PASSES="$PASSES" \
  HYBRID_IMAGE_READY_TIMEOUT="$READY_TIMEOUT" \
  HYBRID_IMAGE_ARTIFACT_TIMEOUT="$ARTIFACT_TIMEOUT" \
    bash "$ROOT_DIR/scripts/25-benchmark-hybrid-image-workload.sh" \
      --state-loop "$STATE_LOOP_DEVICE" \
      --app-loop "$APP_LOOP_DEVICE" \
      --image "$IMAGE" \
      --runs "$RUNS" \
      --passes "$PASSES" \
      --ready-timeout "$READY_TIMEOUT" \
      --artifact-timeout "$ARTIFACT_TIMEOUT" \
      --result-dir "$value_dir/workload" \
      > "$value_dir/console.log" 2>&1
  workload_rc=$?
  set -e

  if [ "$workload_rc" -eq 0 ]; then
    status=PASS
  else
    status=FAIL
  fi
  jq -n \
    --arg worker "$value" \
    --arg status "$status" \
    --arg image "$IMAGE" \
    --argjson runs "$RUNS" \
    --argjson passes "$PASSES" \
    --argjson rc "$workload_rc" \
    '{worker:($worker|tonumber),status:$status,image:$image,runs:$runs,passes:$passes,workload_rc:$rc}' \
    | tee -a "$RESULT_DIR/results.ndjson"
  printf 'worker=%s status=%s rc=%s\n' "$value" "$status" "$workload_rc"
done

jq -s '.' "$RESULT_DIR/results.ndjson" > "$RESULT_DIR/results.json"
printf '%s\n' "results=$RESULT_DIR"
jq . "$RESULT_DIR/results.json"
if jq -e 'any(.[]; .status != "PASS")' "$RESULT_DIR/results.json" >/dev/null; then
  exit 1
fi
