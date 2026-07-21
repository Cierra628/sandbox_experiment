#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
CURSOR_IMAGE="${CURSOR_IMAGE:-}"
CURSOR_COMMAND="${CURSOR_COMMAND:-echo CURSOR_CONTAINER_READY; exec sleep 300}"
CURSOR_HANDLERS="${CURSOR_HANDLERS:-runc kuasar-runc kuasar-vmm}"
CURSOR_RUNS="${CURSOR_RUNS:-3}"
CURSOR_PULL="${CURSOR_PULL:-0}"
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/.artifacts/cursor-coldstart-$(date -u +%Y%m%dT%H%M%SZ)}"
CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")

[ -n "$CURSOR_IMAGE" ] || {
  echo "error: set CURSOR_IMAGE to the image Cursor actually starts" >&2
  exit 2
}
[[ "$CURSOR_RUNS" =~ ^[1-9][0-9]*$ ]] || {
  echo "error: CURSOR_RUNS must be a positive integer" >&2
  exit 2
}
command -v jq >/dev/null
command -v crictl >/dev/null
sudo -v
mkdir -p "$RESULT_DIR/specs"
NDJSON="$RESULT_DIR/results.ndjson"
: > "$NDJSON"
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

pull_image() {
  local b e
  b="$(now_ms)"
  "${CRI[@]}" pull "$CURSOR_IMAGE" >/dev/null
  e="$(now_ms)"
  printf '%s\n' "$((e-b))"
}

run_once() {
  local handler="$1" run="$2" base_pod container_pod pod_spec container_spec
  local uid pod='' cid='' b e status=PASS note='' output=''
  local runp_ms=0 create_ms=0 start_api_ms=0 ready_ms=0 cleanup_ms=0 total_ms=0
  base_pod="$ROOT_DIR/containerd/openclaw-pod.json"
  [ "$handler" = kuasar-vmm ] && base_pod="$ROOT_DIR/containerd/openclaw-pod-vmm.json"
  uid="cursor-coldstart-${handler}-${run}-$(date +%s%N)"
  pod_spec="$RESULT_DIR/specs/${handler}-${run}-pod.json"
  container_spec="$RESULT_DIR/specs/${handler}-${run}-container.json"
  jq --arg uid "$uid" '.metadata.uid=$uid | .metadata.attempt=0' "$base_pod" > "$pod_spec"
  jq -n --arg image "$CURSOR_IMAGE" --arg command "$CURSOR_COMMAND"     --arg log_path "cursor-${uid}.log" --arg name "cursor-container"     --argjson attempt "$run" --argjson vmm "$([ "$handler" = kuasar-vmm ] && echo true || echo false)" '
    {
      metadata:{name:$name,attempt:$attempt},
      image:{image:$image},
      command:["sh","-c"],
      args:[$command],
      working_dir:"/",
      log_path:$log_path,
      envs:[],
      mounts:[],
      linux:{security_context:{
        run_as_user:{value:(if $vmm then 0 else 1002 end)},
        run_as_group:{value:(if $vmm then 0 else 1002 end)},
        readonly_rootfs:false,
        privileged:false
      }}
    }
  ' > "$container_spec"

  trap 'cleanup_ids "$cid" "$pod"' RETURN
  b="$(now_ms)"
  pod="$("${CRI[@]}" runp --runtime "$handler" "$pod_spec")"
  e="$(now_ms)"; runp_ms="$((e-b))"
  b="$(now_ms)"
  cid="$("${CRI[@]}" create "$pod" "$container_spec" "$pod_spec")"
  e="$(now_ms)"; create_ms="$((e-b))"
  b="$(now_ms)"
  "${CRI[@]}" start "$cid" >/dev/null
  e="$(now_ms)"; start_api_ms="$((e-b))"
  b="$(now_ms)"
  for _ in $(seq 1 120); do
    output="$("${CRI[@]}" logs "$cid" 2>&1 || true)"
    if grep -q CURSOR_CONTAINER_READY <<<"$output"; then
      e="$(now_ms)"; ready_ms="$((e-b))"; break
    fi
    if "${CRI[@]}" inspect "$cid" 2>/dev/null | jq -e '.status.state=="CONTAINER_EXITED"' >/dev/null; then
      status=FAIL; note=container-exited-before-ready; break
    fi
    sleep 0.25
  done
  [ "$ready_ms" -gt 0 ] || { status=FAIL; note="${note:-ready-timeout}"; }
  cleanup_begin="$(now_ms)"
  cleanup_ids "$cid" "$pod"
  e="$(now_ms)"; cleanup_ms="$((e-cleanup_begin))"
  cid=''; pod=''
  total_ms="$((runp_ms+create_ms+start_api_ms+ready_ms+cleanup_ms))"
  jq -n --arg handler "$handler" --argjson run "$run" --arg status "$status"     --arg note "$note" --argjson runp_ms "$runp_ms" --argjson create_ms "$create_ms"     --argjson start_api_ms "$start_api_ms" --argjson ready_ms "$ready_ms"     --argjson cleanup_ms "$cleanup_ms" --argjson total_ms "$total_ms"     '{handler:$handler,run:$run,status:$status,note:$note,
      runp_ms:$runp_ms,create_ms:$create_ms,start_api_ms:$start_api_ms,
      ready_ms:$ready_ms,cleanup_ms:$cleanup_ms,total_ms:$total_ms}' |
    tee -a "$NDJSON"
  trap - RETURN
}

pull_ms=0
if [ "$CURSOR_PULL" = 1 ]; then
  pull_ms="$(pull_image)"
fi
for handler in $CURSOR_HANDLERS; do
  case "$handler" in runc|kuasar-runc|kuasar-vmm) ;; *) exit 2 ;; esac
  for run in $(seq 1 "$CURSOR_RUNS"); do
    run_once "$handler" "$run"
  done
done
jq -s --arg image "$CURSOR_IMAGE" --arg command "$CURSOR_COMMAND"   --argjson pull_ms "$pull_ms" '{image:$image,command:$command,pull_ms:$pull_ms,results:.}'   "$NDJSON" > "$RESULT_DIR/results.json"
jq '{image,command,pull_ms,results:[.results[] | {handler,run,status,runp_ms,create_ms,start_api_ms,ready_ms,cleanup_ms,total_ms,note}]}'   "$RESULT_DIR/results.json"
printf 'results=%s\n' "$RESULT_DIR"
