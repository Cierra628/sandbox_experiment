#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/config/versions.env"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
HANDLERS="${BENCHMARK_HANDLERS:-runc kuasar-runc kuasar-vmm}"
RUNS="${BENCHMARK_RUNS:-3}"
MODEL_SAMPLE_RUNS="${MODEL_SAMPLE_RUNS:-0}"
MODEL_SAMPLE_MESSAGE="${MODEL_SAMPLE_MESSAGE:-Reply with exactly KUASAR_SAMPLE_OK and nothing else.}"
MODEL_SAMPLE_EXPECTED="${MODEL_SAMPLE_EXPECTED:-KUASAR_SAMPLE_OK}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"
OPENCLAW_DATA_DIR="${OPENCLAW_DATA_DIR:-$HOME/.local/share/openclaw-kuasar/openclaw-state}"
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/.artifacts/breakdown-$(date -u +%Y%m%dT%H%M%SZ)}"
CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")
for v in "$RUNS" "$MODEL_SAMPLE_RUNS" "$READY_TIMEOUT"; do [[ "$v" =~ ^[0-9]+$ ]] || { echo "error: counts/timeouts must be integers" >&2; exit 2; }; done
[ "$RUNS" -ge 1 ] && [ "$READY_TIMEOUT" -ge 1 ] || exit 2
command -v jq >/dev/null; command -v crictl >/dev/null; sudo -v
mkdir -p "$RESULT_DIR/specs"
TSV="$RESULT_DIR/results.tsv"
printf '%s\n' $'handler\trun\tstatus\tcri_ready_ms\trunp_ms\tcreate_ms\tstart_ms\tgateway_ready_ms\texec_true_ms\texec_node_ms\thealth_exec_ms\thealth_internal_ms\tsample_exec_ms\tsample_internal_ms\tcleanup_ms\ttotal_ms\tnote' > "$TSV"
now_ms(){ date +%s%3N; }
timed_capture(){ local vv="$1" mv="$2" b e value; shift 2; b="$(now_ms)"; value="$("$@")"; e="$(now_ms)"; printf -v "$vv" %s "$value"; printf -v "$mv" %s "$((e-b))"; }
cleanup_ids(){ local cid="$1" pod="$2"; set +e; [ -n "$cid" ] && "${CRI[@]}" stop "$cid" >/dev/null 2>&1; [ -n "$cid" ] && "${CRI[@]}" rm "$cid" >/dev/null 2>&1; [ -n "$pod" ] && "${CRI[@]}" stopp "$pod" >/dev/null 2>&1; [ -n "$pod" ] && "${CRI[@]}" rmp "$pod" >/dev/null 2>&1; set -e; }
wait_gateway_log(){ local cid="$1" deadline=$((SECONDS+READY_TIMEOUT)) logs; while [ "$SECONDS" -lt "$deadline" ]; do logs="$("${CRI[@]}" logs "$cid" 2>&1 || true)"; grep -q '\[gateway\] ready' <<<"$logs" && return 0; "${CRI[@]}" inspect "$cid" 2>/dev/null | jq -e '.status.state=="CONTAINER_EXITED"' >/dev/null && { printf '%s\n' "$logs" >&2; return 1; }; sleep 1; done; return 1; }
write_row(){ local h="$1" r="$2" s="$3" n="$4"; n="${n//$'\t'/ }"; n="${n//$'\n'/ }"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "$r" "$s" "$cri_ready_ms" "$runp_ms" "$create_ms" "$start_ms" "$gateway_ready_ms" "$exec_true_ms" "$exec_node_ms" "$health_exec_ms" "$health_internal_ms" "$sample_exec_ms" "$sample_internal_ms" "$cleanup_ms" "$total_ms" "$n" >> "$TSV"; }
run_once(){
 local handler="$1" run="$2" bp="$ROOT_DIR/containerd/openclaw-pod.json" bc="$ROOT_DIR/containerd/openclaw-container.json"
 local pod_spec container_spec uid pod='' cid='' output='' status=PASS note='' begin end ready_begin cleanup_begin
 local cri_ready_ms=0 runp_ms=0 create_ms=0 start_ms=0 gateway_ready_ms=0 exec_true_ms=0 exec_node_ms=0 health_exec_ms=0 health_internal_ms=0 sample_exec_ms=0 sample_internal_ms=0 cleanup_ms=0 total_ms=0
 [ "$handler" = kuasar-vmm ] && { bp="$ROOT_DIR/containerd/openclaw-pod-vmm.json"; bc="$ROOT_DIR/containerd/openclaw-container-vmm.json"; }
 uid="breakdown-${handler}-${run}-$(date +%s%N)"; pod_spec="$RESULT_DIR/specs/${handler}-${run}-pod.json"; container_spec="$RESULT_DIR/specs/${handler}-${run}-container.json"
 jq --arg uid "$uid" --argjson attempt "$run" '.metadata.uid=$uid|.metadata.attempt=$attempt' "$bp" > "$pod_spec"
 jq --argjson attempt "$run" --arg log_path "breakdown-${uid}.log" '.metadata.attempt=$attempt | .log_path=$log_path' "$bc" > "$container_spec"
 begin="$(now_ms)"; trap 'cleanup_ids "$cid" "$pod"' RETURN
 if ! timed_capture output cri_ready_ms "${CRI[@]}" info; then status=FAIL; note=cri-not-ready
 elif ! timed_capture pod runp_ms "${CRI[@]}" runp --runtime "$handler" "$pod_spec"; then status=FAIL; note=runp-failed
 elif ! timed_capture cid create_ms "${CRI[@]}" create "$pod" "$container_spec" "$pod_spec"; then status=FAIL; note=create-failed
 elif ! timed_capture output start_ms "${CRI[@]}" start "$cid"; then status=FAIL; note=start-failed
 else
  ready_begin="$(now_ms)"
  if wait_gateway_log "$cid"; then
   end="$(now_ms)"; gateway_ready_ms="$((end-ready_begin))"
   timed_capture output exec_true_ms "${CRI[@]}" exec "$cid" true || { status=FAIL; note=exec-true-failed; }
   [ "$status" != PASS ] || timed_capture output exec_node_ms "${CRI[@]}" exec "$cid" node -e 'process.stdout.write("OK")' || { status=FAIL; note=exec-node-failed; }
   if [ "$status" = PASS ] && timed_capture output health_exec_ms "${CRI[@]}" exec "$cid" node openclaw.mjs gateway health --json; then
    printf '%s\n' "$output" > "$RESULT_DIR/${handler}-run${run}-health.json"; health_internal_ms="$(jq -r '.durationMs//0' <<<"$output")"; [ "$(jq -r '.ok//false' <<<"$output")" = true ] || { status=FAIL; note=health-not-ok; }
   elif [ "$status" = PASS ]; then status=FAIL; note=health-exec-failed; fi
  else end="$(now_ms)"; gateway_ready_ms="$((end-ready_begin))"; status=FAIL; note=gateway-not-ready; fi
 fi
 if [ "$status" = PASS ] && [ "$run" -le "$MODEL_SAMPLE_RUNS" ]; then
  if timed_capture output sample_exec_ms "${CRI[@]}" exec "$cid" node openclaw.mjs agent --local --agent main --session-key "agent:main:breakdown-${handler}-${run}-$(date +%s)" --message "$MODEL_SAMPLE_MESSAGE" --timeout 180 --json; then
   printf '%s\n' "$output" > "$RESULT_DIR/${handler}-run${run}-sample.json"; sample_internal_ms="$(jq -r '.meta.durationMs//0' <<<"$output")"; [ "$(jq -r '.payloads[0].text//""' <<<"$output")" = "$MODEL_SAMPLE_EXPECTED" ] || { status=FAIL; note=sample-output-mismatch; }
  else status=FAIL; note=sample-exec-failed; fi
 fi
 [ -z "$cid" ] || "${CRI[@]}" logs "$cid" > "$RESULT_DIR/${handler}-run${run}.log" 2>&1 || true
 cleanup_begin="$(now_ms)"; cleanup_ids "$cid" "$pod"; end="$(now_ms)"; cleanup_ms="$((end-cleanup_begin))"; cid=''; pod=''
 end="$(now_ms)"; total_ms="$((end-begin))"; write_row "$handler" "$run" "$status" "$note"; trap - RETURN
 printf '%s run=%s status=%s total_ms=%s\n' "$handler" "$run" "$status" "$total_ms"
}
OPENCLAW_DATA_DIR="$OPENCLAW_DATA_DIR" "$ROOT_DIR/scripts/03-generate-cri-specs.sh" >/dev/null
for handler in $HANDLERS; do case "$handler" in runc|kuasar-runc|kuasar-vmm);; *) echo "unsupported handler: $handler" >&2; exit 2;; esac; for run in $(seq 1 "$RUNS"); do run_once "$handler" "$run"; done; done
jq -Rn '[inputs|split("\t")] as $r|($r[0]) as $h|[$r[1:][]|[range(0;$h|length) as $i|{($h[$i]):.[$i]}]|add|with_entries(if (.key|endswith("_ms")) or .key=="run" then .value|=tonumber else . end)]' < "$TSV" > "$RESULT_DIR/results.json"
jq -f "$ROOT_DIR/scripts/benchmark-summary.jq" "$RESULT_DIR/results.json" | tee "$RESULT_DIR/summary.json"
printf 'results=%s\n' "$RESULT_DIR"
