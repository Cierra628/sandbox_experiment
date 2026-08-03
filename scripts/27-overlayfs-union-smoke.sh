#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
BASE_POD_SPEC="$ROOT_DIR/containerd/openclaw-pod-vmm.json"
BASE_CONTAINER_SPEC="$ROOT_DIR/containerd/openclaw-container-vmm.json"
UPPER_LOOP_DEVICE="${HYBRID_OVERLAY_UPPER_LOOP_DEVICE:-}"
READY_TIMEOUT="${OVERLAY_SMOKE_TIMEOUT:-60}"
RESULT_DIR="${OVERLAY_SMOKE_RESULT_DIR:-$ROOT_DIR/.artifacts/overlayfs-union-smoke-$(date -u +%Y%m%dT%H%M%SZ)}"

usage() {
  printf '%s\n' \
    'Usage: scripts/27-overlayfs-union-smoke.sh --upper-loop DEV [options]' \
    '' \
    'Tests VirtioFS lowerdir + virtio-blk upper/work overlayfs semantics.' \
    'The union mount is created by the guest task before the container starts; the container itself is unprivileged.' \
    '' \
    'Options:' \
    '  --upper-loop DEV      writable overlay upper/work loop device' \
    '  --timeout N           smoke timeout in seconds (default: 60)' \
    '  --result-dir DIR      artifact directory' \
    '  -h, --help            show this help'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --upper-loop) UPPER_LOOP_DEVICE="$2"; shift 2 ;;
    --timeout) READY_TIMEOUT="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -n "$UPPER_LOOP_DEVICE" ] || { echo 'error: --upper-loop is required' >&2; exit 2; }
[[ "$READY_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo 'error: --timeout must be positive' >&2; exit 2; }

printf '%s\n' \
  'OverlayFS union smoke plan:' \
  '  lower=/app from VirtioFS rootfs' \
  '  upper/work=/tmp from writable virtio-blk' \
  '  mount_target=/app' \
  '  privileged_smoke_container=false (guest union hook)' \
  "  upper_loop=$UPPER_LOOP_DEVICE" \
  "  result_dir=$RESULT_DIR"

command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
command -v crictl >/dev/null 2>&1 || { echo 'error: crictl is required' >&2; exit 1; }
sudo -v
sudo test -b "$UPPER_LOOP_DEVICE" || { echo "error: not a block device: $UPPER_LOOP_DEVICE" >&2; exit 1; }
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

mkdir -p "$RESULT_DIR/specs"
POD_SPEC="$RESULT_DIR/specs/pod.json"
CONTAINER_SPEC="$RESULT_DIR/specs/container.json"
SMOKE_COMMAND='set -eu; command -v sha256sum >/dev/null 2>&1; test -d /app.lower; test -f /app/openclaw.mjs; test -f /app/dist/entry.js || test -f /app/dist/entry.mjs; app_fstype=$(stat -f -c "%T" /app); lower_fstype=$(stat -f -c "%T" /app.lower); test "$app_fstype" = overlay || test "$app_fstype" = overlayfs; test "$lower_fstype" != overlay; lower_before=$(sha256sum /app.lower/openclaw.mjs | cut -d" " -f1); printf "overlay-smoke-write\n" > /app/.overlay-smoke-new; test -f /tmp/upper/.overlay-smoke-new; test ! -e /app.lower/.overlay-smoke-new; lower_after=$(sha256sum /app.lower/openclaw.mjs | cut -d" " -f1); test "$lower_before" = "$lower_after"; { printf "overlay_mount=PASS\n"; printf "lower_fstype=%s\n" "$lower_fstype"; printf "app_fstype=%s\n" "$app_fstype"; printf "upper_fstype=%s\n" "$(stat -f -c "%T" /tmp)"; printf "upper_write=PASS\n"; printf "lower_unchanged=PASS\n"; } > /tmp/overlay-smoke.evidence; sleep 600' 

jq --arg uid "overlay-smoke-$(date +%s%N)" --argjson attempt 1 \
  '.metadata.uid=$uid | .metadata.attempt=$attempt' \
  "$BASE_POD_SPEC" > "$POD_SPEC"
jq --arg command "$SMOKE_COMMAND" --arg upper "$UPPER_LOOP_DEVICE" \
  --arg union '{"target":"/app","upper_mount":"/tmp","upper_dir":"upper","work_dir":"work","lower_debug_mount":"/app.lower"}' \
  '.metadata.name="openclaw-overlay-smoke" | .annotations["io.openclaw.overlayfs.union"]=$union | .labels["io.openclaw.overlayfs.union"]=$union | .envs += [{"key":"OPENCLAW_KUASAR_OVERLAY_UNION","value":$union}] | .command=["sh"] | .args=["-c",$command] | .working_dir="/" | .mounts=[{"container_path":"/tmp","host_path":$upper,"readonly":false}] | .linux.security_context.run_as_user.value=0 | .linux.security_context.run_as_group.value=0 | .linux.security_context.privileged=false | .linux.security_context.capabilities={add:[],drop:[]}' \
  "$BASE_CONTAINER_SPEC" > "$CONTAINER_SPEC"
python3 -m json.tool "$POD_SPEC" >/dev/null
python3 -m json.tool "$CONTAINER_SPEC" >/dev/null

POD_ID=''
CONTAINER_ID=''
cleanup_ids() {
  local cid="$1" pod="$2"
  set +e
  [ -n "$cid" ] && "${CRI[@]}" stop "$cid" >/dev/null 2>&1
  [ -n "$cid" ] && "${CRI[@]}" rm "$cid" >/dev/null 2>&1
  [ -n "$pod" ] && "${CRI[@]}" stopp "$pod" >/dev/null 2>&1
  [ -n "$pod" ] && "${CRI[@]}" rmp "$pod" >/dev/null 2>&1
  set -e
}
cleanup() {
  local rc=$?
  [ -z "$CONTAINER_ID" ] || "${CRI[@]}" logs "$CONTAINER_ID" > "$RESULT_DIR/container.log" 2>&1 || true
  if [ -n "$POD_ID" ]; then
    sudo cat "/tmp/${POD_ID}-task.log" > "$RESULT_DIR/task.log" 2>&1 || true
  fi
  sudo journalctl -u openclaw-kuasar-vmm.service \
    --since "$VMM_LOG_SINCE" \
    --no-pager > "$RESULT_DIR/vmm-journal.log" 2>&1 || true
  cleanup_ids "$CONTAINER_ID" "$POD_ID"
  exit "$rc"
}
trap cleanup EXIT

VMM_LOG_SINCE="$(date --iso-8601=seconds)"
run_begin="$(date +%s%3N)"
if ! RUNP_OUTPUT="$("${CRI[@]}" runp --runtime kuasar-vmm "$POD_SPEC" 2>&1)"; then
  printf '%s\n' "$RUNP_OUTPUT" > "$RESULT_DIR/runp.out"
  echo 'status=FAIL note=runp-failed' | tee "$RESULT_DIR/result.txt"
  exit 1
fi
POD_ID="$RUNP_OUTPUT"
printf '%s\n' "$RUNP_OUTPUT" > "$RESULT_DIR/runp.out"
if ! CREATE_OUTPUT="$("${CRI[@]}" create "$POD_ID" "$CONTAINER_SPEC" "$POD_SPEC" 2>&1)"; then
  printf '%s\n' "$CREATE_OUTPUT" > "$RESULT_DIR/create.out"
  echo 'status=FAIL note=create-failed' | tee "$RESULT_DIR/result.txt"
  exit 1
fi
CONTAINER_ID="$CREATE_OUTPUT"
printf '%s\n' "$CREATE_OUTPUT" > "$RESULT_DIR/create.out"
if ! "${CRI[@]}" start "$CONTAINER_ID" > "$RESULT_DIR/start.out" 2>&1; then
  echo 'status=FAIL note=start-failed' | tee "$RESULT_DIR/result.txt"
  exit 1
fi

deadline=$((SECONDS + READY_TIMEOUT))
evidence=''
while [ "$SECONDS" -lt "$deadline" ]; do
  if evidence="$(${CRI[@]} exec "$CONTAINER_ID" cat /tmp/overlay-smoke.evidence 2>/dev/null)"; then
    break
  fi
  if "${CRI[@]}" inspect "$CONTAINER_ID" 2>/dev/null | jq -e '.status.state == "CONTAINER_EXITED"' >/dev/null; then
    break
  fi
  sleep 1
done

printf '%s\n' "$evidence" > "$RESULT_DIR/evidence.txt"
run_end="$(date +%s%3N)"
smoke_ms="$((run_end - run_begin))"
status='PASS'
note=''
if ! grep -q '^overlay_mount=PASS$' "$RESULT_DIR/evidence.txt"; then
  status='FAIL'; note='overlay-mount-failed'
elif ! grep -q '^upper_write=PASS$' "$RESULT_DIR/evidence.txt"; then
  status='FAIL'; note='upper-write-failed'
elif ! grep -q '^lower_unchanged=PASS$' "$RESULT_DIR/evidence.txt"; then
  status='FAIL'; note='lower-changed'
fi

jq -n \
  --arg status "$status" \
  --arg note "$note" \
  --arg upper_loop "$UPPER_LOOP_DEVICE" \
  --argjson smoke_ms "$smoke_ms" \
  '{status:$status,note:$note,upper_loop:$upper_loop,smoke_ms:$smoke_ms,evidence_file:"evidence.txt"}' \
  > "$RESULT_DIR/result.json"

printf '%s\n' "status=$status note=$note smoke_ms=$smoke_ms result_dir=$RESULT_DIR" | tee "$RESULT_DIR/result.txt"
[ "$status" = PASS ]
