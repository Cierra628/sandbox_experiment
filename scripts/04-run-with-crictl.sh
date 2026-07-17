#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT_DIR/config/versions.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/config/versions.env"
fi
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
RUNTIME_HANDLER="${OPENCLAW_RUNTIME_HANDLER:-runc}"
if [ -n "${POD_SPEC:-}" ]; then
  POD_SPEC="$POD_SPEC"
elif [ "$RUNTIME_HANDLER" = "kuasar-vmm" ]; then
  POD_SPEC="$ROOT_DIR/containerd/openclaw-pod-vmm.json"
else
  POD_SPEC="$ROOT_DIR/containerd/openclaw-pod.json"
fi
if [ -n "${CONTAINER_SPEC:-}" ]; then
  CONTAINER_SPEC="$CONTAINER_SPEC"
elif [ "$RUNTIME_HANDLER" = "kuasar-vmm" ]; then
  CONTAINER_SPEC="$ROOT_DIR/containerd/openclaw-container-vmm.json"
else
  CONTAINER_SPEC="$ROOT_DIR/containerd/openclaw-container.json"
fi
STATE_FILE="${STATE_FILE:-$ROOT_DIR/.state/last-run.json}"
AUTO_CLEANUP="${AUTO_CLEANUP:-1}"

command -v crictl >/dev/null 2>&1 || { echo 'error: crictl is required' >&2; exit 1; }
test -f "$POD_SPEC" && test -f "$CONTAINER_SPEC" || {
  echo 'error: missing CRI specs; run scripts/03-generate-cri-specs.sh first' >&2
  exit 1
}

CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")
POD_ID=''
CONTAINER_ID=''
CRI_READY_TIMEOUT="${CRI_READY_TIMEOUT:-60}"

wait_for_cri() {
  local socket_path=''
  local deadline

  if ! [[ "$CRI_READY_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$CRI_READY_TIMEOUT" -lt 1 ]; then
    echo 'error: CRI_READY_TIMEOUT must be a positive integer' >&2
    return 1
  fi
  if [[ "$CRI_ENDPOINT" == unix://* ]]; then
    socket_path="${CRI_ENDPOINT#unix://}"
  fi
  deadline=$((SECONDS + CRI_READY_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if { [ -z "$socket_path" ] || [ -S "$socket_path" ]; } && \
      "${CRI[@]}" info >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'error: CRI endpoint did not become ready within %ss: %s\n' \
    "$CRI_READY_TIMEOUT" "$CRI_ENDPOINT" >&2
  return 1
}


cleanup() {
  local exit_code=$?
  if [ "$AUTO_CLEANUP" != 1 ] && [ "$exit_code" -eq 0 ]; then
    return 0
  fi
  set +e
  [ -n "$CONTAINER_ID" ] && "${CRI[@]}" stop "$CONTAINER_ID" >/dev/null 2>&1
  [ -n "$CONTAINER_ID" ] && "${CRI[@]}" rm "$CONTAINER_ID" >/dev/null 2>&1
  [ -n "$POD_ID" ] && "${CRI[@]}" stopp "$POD_ID" >/dev/null 2>&1
  [ -n "$POD_ID" ] && "${CRI[@]}" rmp "$POD_ID" >/dev/null 2>&1
  return "$exit_code"
}
trap cleanup EXIT

printf 'Planned crictl sequence:\n  endpoint=%s\n  handler=%s\n  runp --runtime %s %s\n  create POD_ID %s %s\n  start CONTAINER_ID\n' "$CRI_ENDPOINT" "$RUNTIME_HANDLER" "$RUNTIME_HANDLER" "$POD_SPEC" "$CONTAINER_SPEC" "$POD_SPEC"
if [ "${RUN_CRICTL:-0}" != 1 ]; then
  echo 'Dry run only. Set RUN_CRICTL=1 to execute.'
  exit 0
fi

wait_for_cri

POD_ID="$("${CRI[@]}" runp --runtime "$RUNTIME_HANDLER" "$POD_SPEC")"
CONTAINER_ID="$("${CRI[@]}" create "$POD_ID" "$CONTAINER_SPEC" "$POD_SPEC")"
"${CRI[@]}" start "$CONTAINER_ID"
printf '%s\n' "Pod sandbox: $POD_ID" "Container: $CONTAINER_ID"
"${CRI[@]}" logs "$CONTAINER_ID" || true

mkdir -p "$(dirname "$STATE_FILE")"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg pod "$POD_ID" --arg container "$CONTAINER_ID" --arg handler "$RUNTIME_HANDLER" \
    '{pod_id:$pod,container_id:$container,runtime_handler:$handler}' > "$STATE_FILE"
fi
printf '%s\n' 'Lifecycle completed; resources are cleaned up on exit.'
