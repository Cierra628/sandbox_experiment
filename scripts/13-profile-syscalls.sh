#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/config/versions.env"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
STRACE_IMAGE="${STRACE_IMAGE:-localhost/openclaw-kuasar:2026.6.11-virtiofs-strace}"
HANDLERS="${PROFILE_HANDLERS:-runc kuasar-runc kuasar-vmm}"
COMMANDS="${PROFILE_COMMANDS:-config_validate}"
PROFILE_REPEATS="${PROFILE_REPEATS:-1}"
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/.artifacts/syscall-profile-$(date -u +%Y%m%dT%H%M%SZ)}"
CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")

command -v jq >/dev/null
command -v node >/dev/null
[[ "$PROFILE_REPEATS" =~ ^[1-9][0-9]*$ ]] || { echo "error: PROFILE_REPEATS must be positive" >&2; exit 2; }
sudo -v
mkdir -p "$RESULT_DIR/specs"
chmod 0777 "$RESULT_DIR"
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
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n");
const calls = new Map(), paths = new Map(), dirs = new Map();
let parsed = 0, totalUs = 0, errors = 0;
function add(map, key, us, error) {
  const x = map.get(key) || {name:key,count:0,total_us:0,max_us:0,errors:0};
  x.count++; x.total_us += us; x.max_us = Math.max(x.max_us,us); if(error)x.errors++;
  map.set(key,x);
}
function group(p) {
  if (p.startsWith("/home/node/.openclaw/npm/")) return "plugin";
  if (p.startsWith("/home/node/.openclaw/")) return "state";
  if (p.startsWith("/app/")) return "app";
  if (p.startsWith("/lib/") || p.startsWith("/usr/lib/")) return "system_lib";
  return "other";
}
for (const line of lines) {
  const m = line.match(/^\d+\s+\d+\.\d+\s+([A-Za-z0-9_]+)\(.*<([0-9.]+)>$/);
  if (!m) continue;
  const us = Number(m[2]) * 1e6;
  const error = /\)\s+=\s+-1\s+/.test(line);
  parsed++; totalUs += us; if(error)errors++;
  add(calls,m[1],us,error);
  const pm = line.match(/"((?:\\.|[^"])*)"/);
  if (pm && pm[1].startsWith("/")) {
    const p = pm[1].replace(/\\([\\"])/g,"$1");
    add(paths,p,us,error); add(dirs,group(p),us,error);
  }
}
const norm = x => [...x.values()].sort((a,b)=>b.total_us-a.total_us)
  .map(v=>({name:v.name,count:v.count,total_ms:+(v.total_us/1000).toFixed(3),
    max_ms:+(v.max_us/1000).toFixed(3),errors:v.errors}));
console.log(JSON.stringify({
  parsed_lines:parsed,errors,summed_syscall_ms:+(totalUs/1000).toFixed(3),
  syscalls:norm(calls),path_groups:norm(dirs),hot_paths:norm(paths).slice(0,30)
}));
NODE
}

profile_handler() {
  local handler="$1" base_pod base_container pod_spec container_spec uid wrapper
  local pod='' cid='' label trace_file host_begin host_end raw guest_ms rc
  local -a args

  base_pod="$ROOT_DIR/containerd/openclaw-pod.json"
  base_container="$ROOT_DIR/containerd/openclaw-container.json"
  if [ "$handler" = kuasar-vmm ]; then
    base_pod="$ROOT_DIR/containerd/openclaw-pod-vmm.json"
    base_container="$ROOT_DIR/containerd/openclaw-container-vmm.json"
    wrapper='i=0; while [ $i -lt 150 ]; do if [ -f /home/node/.openclaw/openclaw.json ] && [ -d /home/node/.openclaw/state ]; then echo BENCH_IDLE_READY; exec sleep 1200; fi; i=$((i+1)); sleep 0.2; done; exit 1'
  else
    wrapper='test -f /home/node/.openclaw/openclaw.json || exit 1; echo BENCH_IDLE_READY; exec sleep 1200'
  fi

  uid="syscall-${handler}-$(date +%s%N)"
  pod_spec="$RESULT_DIR/specs/${handler}-pod.json"
  container_spec="$RESULT_DIR/specs/${handler}-container.json"
  jq --arg uid "$uid" '.metadata.uid=$uid | .metadata.attempt=0' "$base_pod" > "$pod_spec"
  jq --arg image "$STRACE_IMAGE" --arg wrapper "$wrapper"      --arg log_path "syscall-${uid}.log" --arg host_result "$RESULT_DIR" '
    .metadata.attempt=0 | .image.image=$image | .log_path=$log_path |
    .command=["sh"] | .args=["-c",$wrapper] |
    .mounts += [{container_path:"/profile",host_path:$host_result,readonly:false}]
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
  "${CRI[@]}" exec "$cid" strace --version >/dev/null

  for label in $COMMANDS; do
    for run in $(seq 1 "$PROFILE_REPEATS"); do
    case "$label" in
      config_validate) args=(node openclaw.mjs config validate) ;;
      plugins_list) args=(node openclaw.mjs plugins list --json) ;;
      models_status) args=(node openclaw.mjs models status --json) ;;
      *) echo "error: unsupported command $label" >&2; return 2 ;;
    esac
    trace_file="/profile/${handler}-${label}-run${run}.strace"
    host_begin="$(now_ms)"
    set +e
    raw="$("${CRI[@]}" exec "$cid" sh -c '
      trace=$1; label=$2; shift 2
      rm -f "$trace"
      b=$(date +%s%3N)
      strace -f -qq -ttt -T -s 256         -e trace=%file,read,pread64,getdents64,close         -o "$trace" "$@" >"/tmp/syscall-${label}.out" 2>"/tmp/syscall-${label}.err"
      rc=$?; e=$(date +%s%3N)
      printf "BENCH_SYSCALL guest_ms=%s rc=%s\n" "$((e-b))" "$rc"
      exit "$rc"
    ' sh "$trace_file" "$label" "${args[@]}")"
    rc=$?
    set -e
    host_end="$(now_ms)"
    guest_ms="$(sed -nE 's/^BENCH_SYSCALL guest_ms=([0-9]+) rc=[0-9]+$/\1/p' <<<"$raw" | tail -n1)"
    guest_ms="${guest_ms:-0}"
    test -s "$RESULT_DIR/${handler}-${label}-run${run}.strace"
    analyze_trace "$RESULT_DIR/${handler}-${label}-run${run}.strace" > "$RESULT_DIR/${handler}-${label}-run${run}.json"
    jq -n --arg handler "$handler" --arg label "$label" --argjson run "$run" --argjson rc "$rc"       --argjson host_ms "$((host_end-host_begin))" --argjson guest_ms "$guest_ms"       --argjson trace "$(cat "$RESULT_DIR/${handler}-${label}-run${run}.json")"       '{handler:$handler,label:$label,run:$run,rc:$rc,host_wall_ms:$host_ms,
        guest_wall_ms:$guest_ms,transport_residual_ms:($host_ms-$guest_ms),trace:$trace}' |
      tee -a "$NDJSON"
    done
  done

  cleanup_ids "$cid" "$pod"
  cid=''; pod=''
  trap - RETURN
}

for handler in $HANDLERS; do
  case "$handler" in
    runc|kuasar-runc|kuasar-vmm) profile_handler "$handler" ;;
    *) echo "error: unsupported handler $handler" >&2; exit 2 ;;
  esac
done
jq -s '.' "$NDJSON" > "$RESULT_DIR/results.json"
jq '[.[] | {handler,label,run,rc,guest_wall_ms,parsed_lines:.trace.parsed_lines,summed_syscall_ms:.trace.summed_syscall_ms}]' "$RESULT_DIR/results.json"
printf 'results=%s\n' "$RESULT_DIR"
