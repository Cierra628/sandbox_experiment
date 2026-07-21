#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/config/versions.env"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
HANDLERS="${PROFILE_HANDLERS:-runc kuasar-runc kuasar-vmm}"
OPENCLAW_DATA_DIR="${OPENCLAW_DATA_DIR:-$HOME/.local/share/openclaw-kuasar/openclaw-state}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/.artifacts/stage-profile-$(date -u +%Y%m%dT%H%M%SZ)}"
CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")

command -v jq >/dev/null
command -v crictl >/dev/null
[[ "$READY_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$READY_TIMEOUT" -ge 1 ] || {
  echo "error: READY_TIMEOUT must be a positive integer" >&2
  exit 2
}
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

epoch_marker() {
  local marker="$1" file="$2"
  grep -E "^${marker} epoch_ms=[0-9]+$" "$file" |
    tail -n 1 |
    sed -E 's/.*epoch_ms=([0-9]+).*/\1/' || true
}

event_epoch_ms() {
  local pattern="$1" file="$2" line ts
  line="$(grep -E "$pattern" "$file" | tail -n 1 || true)"
  [ -n "$line" ] || { printf '0\n'; return; }
  ts="$(sed -E 's/^([^ ]+) .*/\1/' <<<"$line")"
  date -u -d "$ts" +%s%3N 2>/dev/null || printf '0\n'
}

delta() {
  local end="$1" begin="$2"
  if [ "$end" -gt 0 ] && [ "$begin" -gt 0 ] && [ "$end" -ge "$begin" ]; then
    printf '%s\n' "$((end-begin))"
  else
    printf '0\n'
  fi
}

profile_handler() {
  local handler="$1" base_pod base_container pod_spec container_spec uid wrapper
  local pod='' cid='' start_call_begin=0 start_call_end=0 observed_ready=0
  local poll=0 logs_call_begin logs_call_end matched logs_file polls_file
  local entry state_ready app_exec loading auth starting http_start http_listen channels ready
  local health_host_begin health_host_end health_raw health_json health_guest_begin health_guest_end health_ws_ms
  local runp_begin runp_end create_begin create_end cleanup_begin cleanup_end

  base_pod="$ROOT_DIR/containerd/openclaw-pod.json"
  base_container="$ROOT_DIR/containerd/openclaw-container.json"
  if [ "$handler" = kuasar-vmm ]; then
    base_pod="$ROOT_DIR/containerd/openclaw-pod-vmm.json"
    base_container="$ROOT_DIR/containerd/openclaw-container-vmm.json"
    wrapper='printf "BENCH_ENTRY epoch_ms=%s\n" "$(date +%s%3N)"; i=0; while [ $i -lt 150 ]; do if [ -f /home/node/.openclaw/openclaw.json ] && [ -d /home/node/.openclaw/state ] && ls /home/node/.openclaw/npm/projects/*/node_modules/@openclaw/deepseek-provider/dist/index.js >/dev/null 2>&1 && touch /home/node/.openclaw/state/.profile-ready && rm -f /home/node/.openclaw/state/.profile-ready; then break; fi; i=$((i+1)); sleep 0.2; done; [ $i -lt 150 ] || { echo BENCH_STATE_TIMEOUT >&2; exit 1; }; printf "BENCH_STATE_READY epoch_ms=%s\n" "$(date +%s%3N)"; printf "BENCH_OPENCLAW_EXEC epoch_ms=%s\n" "$(date +%s%3N)"; exec node openclaw.mjs gateway --bind loopback --port 18790'
  else
    wrapper='printf "BENCH_ENTRY epoch_ms=%s\n" "$(date +%s%3N)"; test -f /home/node/.openclaw/openclaw.json || exit 1; touch /home/node/.openclaw/.profile-ready && rm -f /home/node/.openclaw/.profile-ready; printf "BENCH_STATE_READY epoch_ms=%s\n" "$(date +%s%3N)"; printf "BENCH_OPENCLAW_EXEC epoch_ms=%s\n" "$(date +%s%3N)"; exec node openclaw.mjs gateway --bind loopback --port 18790'
  fi

  uid="profile-${handler}-$(date +%s%N)"
  pod_spec="$RESULT_DIR/specs/${handler}-pod.json"
  container_spec="$RESULT_DIR/specs/${handler}-container.json"
  logs_file="$RESULT_DIR/${handler}-gateway.log"
  polls_file="$RESULT_DIR/${handler}-log-polls.tsv"
  printf '%s\n' $'poll\tcall_begin_ms\tcall_end_ms\tcall_wall_ms\tready_seen' > "$polls_file"

  jq --arg uid "$uid" '.metadata.uid=$uid | .metadata.attempt=0' "$base_pod" > "$pod_spec"
  jq --arg wrapper "$wrapper" --arg log_path "profile-${uid}.log" '
    .metadata.attempt=0 |
    .log_path=$log_path |
    .command=["sh"] |
    .args=["-c",$wrapper]
  ' "$base_container" > "$container_spec"

  trap 'cleanup_ids "$cid" "$pod"' RETURN

  runp_begin="$(now_ms)"
  pod="$("${CRI[@]}" runp --runtime "$handler" "$pod_spec")"
  runp_end="$(now_ms)"
  create_begin="$(now_ms)"
  cid="$("${CRI[@]}" create "$pod" "$container_spec" "$pod_spec")"
  create_end="$(now_ms)"
  start_call_begin="$(now_ms)"
  "${CRI[@]}" start "$cid" >/dev/null
  start_call_end="$(now_ms)"

  local deadline=$((SECONDS+READY_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    poll=$((poll+1))
    logs_call_begin="$(now_ms)"
    "${CRI[@]}" logs "$cid" > "$logs_file" 2>&1 || true
    logs_call_end="$(now_ms)"
    matched=false
    if grep -q '\[gateway\] ready' "$logs_file"; then
      matched=true
      observed_ready="$logs_call_end"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$poll" "$logs_call_begin" "$logs_call_end"       "$((logs_call_end-logs_call_begin))" "$matched" >> "$polls_file"
    [ "$matched" = true ] && break
    sleep 1
  done
  [ "$observed_ready" -gt 0 ] || {
    echo "error: gateway not ready for $handler" >&2
    return 1
  }

  entry="$(epoch_marker BENCH_ENTRY "$logs_file")"
  state_ready="$(epoch_marker BENCH_STATE_READY "$logs_file")"
  app_exec="$(epoch_marker BENCH_OPENCLAW_EXEC "$logs_file")"
  loading="$(event_epoch_ms '\[gateway\] loading configuration' "$logs_file")"
  auth="$(event_epoch_ms '\[gateway\] resolving authentication' "$logs_file")"
  starting="$(event_epoch_ms '\[gateway\] starting\.\.\.$' "$logs_file")"
  http_start="$(event_epoch_ms '\[gateway\] starting HTTP server' "$logs_file")"
  http_listen="$(event_epoch_ms '\[gateway\] http server listening' "$logs_file")"
  channels="$(event_epoch_ms '\[gateway\] starting channels and sidecars' "$logs_file")"
  ready="$(event_epoch_ms '\[gateway\] ready$' "$logs_file")"

  health_host_begin="$(now_ms)"
  health_raw="$("${CRI[@]}" exec "$cid" sh -c '
    b=$(date +%s%3N)
    printf "BENCH_HEALTH_GUEST_BEGIN epoch_ms=%s\n" "$b"
    node openclaw.mjs gateway health --json
    rc=$?
    e=$(date +%s%3N)
    printf "BENCH_HEALTH_GUEST_END epoch_ms=%s\n" "$e"
    exit "$rc"
  ')"
  health_host_end="$(now_ms)"
  printf '%s\n' "$health_raw" > "$RESULT_DIR/${handler}-health-raw.txt"
  health_guest_begin="$(sed -nE 's/^BENCH_HEALTH_GUEST_BEGIN epoch_ms=([0-9]+)$/\1/p' <<<"$health_raw" | tail -n1)"
  health_guest_end="$(sed -nE 's/^BENCH_HEALTH_GUEST_END epoch_ms=([0-9]+)$/\1/p' <<<"$health_raw" | tail -n1)"
  health_json="$(sed '/^BENCH_HEALTH_GUEST_/d' <<<"$health_raw")"
  printf '%s\n' "$health_json" > "$RESULT_DIR/${handler}-health.json"
  jq -e '.ok == true' <<<"$health_json" >/dev/null
  "${CRI[@]}" logs "$cid" > "$logs_file" 2>/dev/null || true
  health_ws_ms="$(grep -E '\[ws\].* health [0-9]+ms' "$logs_file" | tail -n1 | sed -nE 's/.* health ([0-9]+)ms.*/\1/p' || true)"
  health_ws_ms="${health_ws_ms:-null}"

  cleanup_begin="$(now_ms)"
  cleanup_ids "$cid" "$pod"
  cleanup_end="$(now_ms)"
  cid=''; pod=''

  local actual_ready_ms observed_ready_ms observation_residual_ms guest_health_ms health_json_ms
  actual_ready_ms="$(delta "$ready" "$entry")"
  observed_ready_ms="$(delta "$observed_ready" "$start_call_end")"
  observation_residual_ms="$((observed_ready_ms-actual_ready_ms))"
  guest_health_ms="$(delta "$health_guest_end" "$health_guest_begin")"
  health_json_ms="$(jq -r '.durationMs // 0' <<<"$health_json")"

  jq -n \
    --arg handler "$handler" \
    --argjson runp_ms "$((runp_end-runp_begin))" \
    --argjson create_ms "$((create_end-create_begin))" \
    --argjson start_api_ms "$((start_call_end-start_call_begin))" \
    --argjson state_ready_ms "$(delta "$state_ready" "$entry")" \
    --argjson openclaw_exec_after_state_ms "$(delta "$app_exec" "$state_ready")" \
    --argjson cli_to_loading_ms "$(delta "$loading" "$app_exec")" \
    --argjson config_load_ms "$(delta "$auth" "$loading")" \
    --argjson auth_resolve_ms "$(delta "$starting" "$auth")" \
    --argjson gateway_core_ms "$(delta "$http_start" "$starting")" \
    --argjson http_listen_ms "$(delta "$http_listen" "$http_start")" \
    --argjson pre_channels_ms "$(delta "$channels" "$http_listen")" \
    --argjson channels_ready_ms "$(delta "$ready" "$channels")" \
    --argjson actual_gateway_ready_ms "$actual_ready_ms" \
    --argjson observed_gateway_ready_ms "$observed_ready_ms" \
    --argjson observation_residual_ms "$observation_residual_ms" \
    --argjson log_poll_count "$poll" \
    --argjson log_poll_avg_ms "$(awk 'NR>1{s+=$4;n++}END{if(n)printf "%.0f",s/n;else print 0}' "$polls_file")" \
    --argjson log_poll_max_ms "$(awk 'NR>1&&$4>m{m=$4}END{print m+0}' "$polls_file")" \
    --argjson health_host_wall_ms "$((health_host_end-health_host_begin))" \
    --argjson health_guest_wall_ms "$guest_health_ms" \
    --argjson health_transport_residual_ms "$(((health_host_end-health_host_begin)-guest_health_ms))" \
    --argjson health_json_duration_ms "$health_json_ms" \
    --argjson health_ws_duration_ms "$health_ws_ms" \
    --argjson health_cli_outer_ms "$((guest_health_ms-health_json_ms))" \
    --argjson cleanup_ms "$((cleanup_end-cleanup_begin))" \
    '{
      handler:$handler,
      lifecycle:{runp_ms:$runp_ms,create_ms:$create_ms,start_api_ms:$start_api_ms},
      gateway:{
        clock_domain:"durations only; guest and host absolute epochs are not subtracted",
        state_ready_ms:$state_ready_ms,
        openclaw_exec_after_state_ms:$openclaw_exec_after_state_ms,
        cli_to_loading_ms:$cli_to_loading_ms,
        config_load_ms:$config_load_ms,
        auth_resolve_ms:$auth_resolve_ms,
        gateway_core_ms:$gateway_core_ms,
        http_listen_ms:$http_listen_ms,
        pre_channels_ms:$pre_channels_ms,
        channels_ready_ms:$channels_ready_ms,
        actual_ready_ms:$actual_gateway_ready_ms,
        observed_ready_ms:$observed_gateway_ready_ms,
        observation_residual_ms:$observation_residual_ms
      },
      log_poll:{count:$log_poll_count,average_call_ms:$log_poll_avg_ms,max_call_ms:$log_poll_max_ms},
      health:{
        host_wall_ms:$health_host_wall_ms,
        guest_wall_ms:$health_guest_wall_ms,
        transport_residual_ms:$health_transport_residual_ms,
        json_duration_ms:$health_json_duration_ms,
        ws_duration_ms:$health_ws_duration_ms,
        cli_outer_ms:$health_cli_outer_ms
      },
      cleanup_ms:$cleanup_ms
    }' | tee -a "$NDJSON"

  trap - RETURN
}

OPENCLAW_DATA_DIR="$OPENCLAW_DATA_DIR" "$ROOT_DIR/scripts/03-generate-cri-specs.sh" >/dev/null
for handler in $HANDLERS; do
  case "$handler" in
    runc|kuasar-runc|kuasar-vmm) profile_handler "$handler" ;;
    *) echo "error: unsupported handler: $handler" >&2; exit 2 ;;
  esac
done
jq -s '.' "$NDJSON" > "$RESULT_DIR/results.json"
jq '.' "$RESULT_DIR/results.json"
printf 'results=%s\n' "$RESULT_DIR"
