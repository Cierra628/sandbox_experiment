#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/config/versions.env"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
HANDLERS="${PROFILE_HANDLERS:-runc kuasar-runc kuasar-vmm}"
COMMANDS="${PROFILE_COMMANDS:-config_validate plugins_list models_status}"
OPENCLAW_DATA_DIR="${OPENCLAW_DATA_DIR:-$HOME/.local/share/openclaw-kuasar/openclaw-state}"
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/.artifacts/node-io-profile-$(date -u +%Y%m%dT%H%M%SZ)}"
CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")

command -v jq >/dev/null
command -v node >/dev/null
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

analyze_trace() {
  node - "$1" <<'NODE'
const fs = require("fs");
const input = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const syncStacks = new Map(), asyncStarts = new Map(), stats = new Map();
function add(name, us) {
  const s = stats.get(name) || {name, count: 0, total_us: 0, max_us: 0};
  s.count++; s.total_us += us; s.max_us = Math.max(s.max_us, us); stats.set(name, s);
}
for (const e of input.traceEvents || []) {
  if (!String(e.cat || "").includes("node.fs")) continue;
  if (e.ph === "B") {
    const k = [e.pid,e.tid,e.name].join(":");
    const stack = syncStacks.get(k) || []; stack.push(e.ts); syncStacks.set(k, stack);
  } else if (e.ph === "E") {
    const k = [e.pid,e.tid,e.name].join(":");
    const stack = syncStacks.get(k) || [], start = stack.pop();
    if (start !== undefined) add(e.name, e.ts - start);
  } else if (e.ph === "b") {
    asyncStarts.set([e.pid,e.tid,e.name,e.id].join(":"), e.ts);
  } else if (e.ph === "e") {
    const k = [e.pid,e.tid,e.name,e.id].join(":"), start = asyncStarts.get(k);
    if (start !== undefined) add("fs.async." + e.name, e.ts - start);
  }
}
const operations = [...stats.values()].sort((a,b) => b.total_us-a.total_us)
  .map(x => ({...x,total_ms:+(x.total_us/1000).toFixed(3),max_ms:+(x.max_us/1000).toFixed(3)}));
console.log(JSON.stringify({
  event_count: operations.reduce((n,x)=>n+x.count,0),
  summed_event_ms:+(operations.reduce((n,x)=>n+x.total_us,0)/1000).toFixed(3),
  operations
}));
NODE
}

analyze_modules() {
  node - "$1" <<'NODE'
const fs = require("fs");
const text = fs.readFileSync(process.argv[2], "utf8");
const paths = new Set();
for (const line of text.split("\n")) {
  const m = line.match(/load "([^"]+)" for module/);
  if (m && m[1].startsWith("/")) paths.add(m[1]);
}
const groups = {app:0,plugin:0,state:0,other:0};
for (const p of paths) {
  if (p.includes("/home/node/.openclaw/npm/")) groups.plugin++;
  else if (p.startsWith("/home/node/.openclaw/")) groups.state++;
  else if (p.startsWith("/app/")) groups.app++;
  else groups.other++;
}
console.log(JSON.stringify({unique_loaded_paths:paths.size,groups}));
NODE
}

profile_handler() {
  local handler="$1" base_pod base_container pod_spec container_spec uid wrapper
  local pod='' cid='' label host_begin host_end raw guest_ms rc trace_guest
  local -a args

  base_pod="$ROOT_DIR/containerd/openclaw-pod.json"
  base_container="$ROOT_DIR/containerd/openclaw-container.json"
  if [ "$handler" = kuasar-vmm ]; then
    base_pod="$ROOT_DIR/containerd/openclaw-pod-vmm.json"
    base_container="$ROOT_DIR/containerd/openclaw-container-vmm.json"
    wrapper='i=0; while [ $i -lt 150 ]; do if [ -f /home/node/.openclaw/openclaw.json ] && [ -d /home/node/.openclaw/state ] && touch /home/node/.openclaw/state/.node-io-ready && rm -f /home/node/.openclaw/state/.node-io-ready; then echo BENCH_IDLE_READY; exec sleep 900; fi; i=$((i+1)); sleep 0.2; done; exit 1'
  else
    wrapper='test -f /home/node/.openclaw/openclaw.json || exit 1; echo BENCH_IDLE_READY; exec sleep 900'
  fi

  uid="node-io-${handler}-$(date +%s%N)"
  pod_spec="$RESULT_DIR/specs/${handler}-pod.json"
  container_spec="$RESULT_DIR/specs/${handler}-container.json"
  jq --arg uid "$uid" '.metadata.uid=$uid | .metadata.attempt=0' "$base_pod" > "$pod_spec"
  jq --arg wrapper "$wrapper" --arg log_path "node-io-${uid}.log" '
    .metadata.attempt=0 | .log_path=$log_path |
    .command=["sh"] | .args=["-c",$wrapper]
  ' "$base_container" > "$container_spec"

  trap 'cleanup_ids "$cid" "$pod"' RETURN
  pod="$("${CRI[@]}" runp --runtime "$handler" "$pod_spec")"
  cid="$("${CRI[@]}" create "$pod" "$container_spec" "$pod_spec")"
  "${CRI[@]}" start "$cid" >/dev/null
  for _ in $(seq 1 60); do
    "${CRI[@]}" logs "$cid" 2>/dev/null | grep -q BENCH_IDLE_READY && break
    sleep 1
  done
  "${CRI[@]}" logs "$cid" 2>/dev/null | grep -q BENCH_IDLE_READY

  for label in $COMMANDS; do
    case "$label" in
      config_validate) args=(node openclaw.mjs config validate) ;;
      plugins_list) args=(node openclaw.mjs plugins list --json) ;;
      models_status) args=(node openclaw.mjs models status --json) ;;
      *) echo "error: unsupported command $label" >&2; return 2 ;;
    esac
    trace_guest="/tmp/node-io-${label}.json"
    host_begin="$(now_ms)"
    set +e
    raw="$("${CRI[@]}" exec "$cid" sh -c '
      label=$1; trace_file=$2; shift 2
      rm -f "$trace_file" "/tmp/node-io-${label}.stdout" "/tmp/node-io-${label}.modules"
      b=$(date +%s%3N)
      NODE_DEBUG=module NODE_OPTIONS="--trace-event-categories=node.fs.sync,node.fs.async --trace-event-file-pattern=$trace_file"         "$@" >"/tmp/node-io-${label}.stdout" 2>"/tmp/node-io-${label}.modules"
      rc=$?; e=$(date +%s%3N)
      printf "BENCH_NODE_IO guest_ms=%s rc=%s\n" "$((e-b))" "$rc"
      exit "$rc"
    ' sh "$label" "$trace_guest" "${args[@]}")"
    rc=$?
    set -e
    host_end="$(now_ms)"
    guest_ms="$(sed -nE 's/^BENCH_NODE_IO guest_ms=([0-9]+) rc=[0-9]+$/\1/p' <<<"$raw" | tail -n1)"
    guest_ms="${guest_ms:-0}"

    "${CRI[@]}" exec "$cid" cat "$trace_guest" > "$RESULT_DIR/${handler}-${label}-trace.json"
    "${CRI[@]}" exec "$cid" cat "/tmp/node-io-${label}.modules" > "$RESULT_DIR/${handler}-${label}-modules.log"
    analyze_trace "$RESULT_DIR/${handler}-${label}-trace.json" > "$RESULT_DIR/${handler}-${label}-io.json"
    analyze_modules "$RESULT_DIR/${handler}-${label}-modules.log" > "$RESULT_DIR/${handler}-${label}-modules.json"

    jq -n --arg handler "$handler" --arg label "$label" --argjson rc "$rc"       --argjson host_ms "$((host_end-host_begin))" --argjson guest_ms "$guest_ms"       --argjson io "$(cat "$RESULT_DIR/${handler}-${label}-io.json")"       --argjson modules "$(cat "$RESULT_DIR/${handler}-${label}-modules.json")"       '{handler:$handler,label:$label,rc:$rc,host_wall_ms:$host_ms,guest_wall_ms:$guest_ms,
        transport_residual_ms:($host_ms-$guest_ms),io:$io,modules:$modules}' |
      tee -a "$NDJSON"
  done

  cleanup_ids "$cid" "$pod"
  cid=''; pod=''
  trap - RETURN
}

OPENCLAW_DATA_DIR="$OPENCLAW_DATA_DIR" "$ROOT_DIR/scripts/03-generate-cri-specs.sh" >/dev/null
for handler in $HANDLERS; do
  case "$handler" in
    runc|kuasar-runc|kuasar-vmm) profile_handler "$handler" ;;
    *) echo "error: unsupported handler $handler" >&2; exit 2 ;;
  esac
done
jq -s '.' "$NDJSON" > "$RESULT_DIR/results.json"
jq '.' "$RESULT_DIR/results.json"
printf 'results=%s\n' "$RESULT_DIR"
