#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/config/versions.env"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
HANDLERS="${PROFILE_HANDLERS:-runc kuasar-runc kuasar-vmm}"
PROFILE_REPEATS="${PROFILE_REPEATS:-1}"
OPENCLAW_DATA_DIR="${OPENCLAW_DATA_DIR:-$HOME/.local/share/openclaw-kuasar/openclaw-state}"
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/.artifacts/guest-profile-$(date -u +%Y%m%dT%H%M%SZ)}"
CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")

[[ "$PROFILE_REPEATS" =~ ^[1-9][0-9]*$ ]] || { echo "error: PROFILE_REPEATS must be a positive integer" >&2; exit 2; }
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

MICRO_JS="$(sed -n '/^__MICRO_JS__$/,/^__MICRO_JS_END__$/p' "$0" | sed '1d;$d')"

profile_cli() {
  local cid="$1" handler="$2" label="$3"
  shift 3
  local host_begin host_end raw guest_ms rc
  host_begin="$(now_ms)"
  set +e
  raw="$("${CRI[@]}" exec "$cid" sh -c '
    label=$1
    shift
    b=$(date +%s%3N)
    "$@" >"/tmp/profile-${label}.out" 2>"/tmp/profile-${label}.err"
    rc=$?
    e=$(date +%s%3N)
    printf "BENCH_CLI label=%s guest_ms=%s rc=%s\n" "$label" "$((e-b))" "$rc"
    exit "$rc"
  ' sh "$label" "$@" 2>"$RESULT_DIR/${handler}-${label}-exec.stderr")"
  rc=$?
  set -e
  host_end="$(now_ms)"
  guest_ms="$(sed -nE 's/^BENCH_CLI label=[^ ]+ guest_ms=([0-9]+) rc=[0-9]+$/\1/p' <<<"$raw" | tail -n1)"
  guest_ms="${guest_ms:-0}"
  jq -n --arg label "$label" --argjson rc "$rc"     --argjson host_ms "$((host_end-host_begin))" --argjson guest_ms "$guest_ms"     '{label:$label,rc:$rc,host_wall_ms:$host_ms,guest_wall_ms:$guest_ms,
      transport_residual_ms:($host_ms-$guest_ms)}'
}

profile_handler() {
  local handler="$1" base_pod base_container pod_spec container_spec uid wrapper
  local pod='' cid='' micro_host_begin micro_host_end micro_json micro_total run label
  local -a args
  local cli_file="$RESULT_DIR/${handler}-cli.ndjson"
  local micro_file="$RESULT_DIR/${handler}-micro.ndjson"

  base_pod="$ROOT_DIR/containerd/openclaw-pod.json"
  base_container="$ROOT_DIR/containerd/openclaw-container.json"
  if [ "$handler" = kuasar-vmm ]; then
    base_pod="$ROOT_DIR/containerd/openclaw-pod-vmm.json"
    base_container="$ROOT_DIR/containerd/openclaw-container-vmm.json"
    wrapper='i=0; while [ $i -lt 150 ]; do if [ -f /home/node/.openclaw/openclaw.json ] && [ -d /home/node/.openclaw/state ] && touch /home/node/.openclaw/state/.guest-profile-ready && rm -f /home/node/.openclaw/state/.guest-profile-ready; then echo BENCH_IDLE_READY; exec sleep 600; fi; i=$((i+1)); sleep 0.2; done; echo BENCH_IDLE_TIMEOUT >&2; exit 1'
  else
    wrapper='test -f /home/node/.openclaw/openclaw.json || exit 1; echo BENCH_IDLE_READY; exec sleep 600'
  fi

  uid="guest-profile-${handler}-$(date +%s%N)"
  pod_spec="$RESULT_DIR/specs/${handler}-pod.json"
  container_spec="$RESULT_DIR/specs/${handler}-container.json"
  : > "$cli_file"
  : > "$micro_file"
  jq --arg uid "$uid" '.metadata.uid=$uid | .metadata.attempt=0' "$base_pod" > "$pod_spec"
  jq --arg wrapper "$wrapper" --arg log_path "guest-profile-${uid}.log" '
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
  "${CRI[@]}" logs "$cid" 2>/dev/null | grep -q BENCH_IDLE_READY || {
    echo "error: idle container not ready for $handler" >&2
    return 1
  }

  for run in $(seq 1 "$PROFILE_REPEATS"); do
    micro_host_begin="$(now_ms)"
    micro_json="$("${CRI[@]}" exec "$cid" node -e "$MICRO_JS")"
    micro_host_end="$(now_ms)"
    printf '%s\n' "$micro_json" > "$RESULT_DIR/${handler}-micro-run${run}.json"
    jq -e '.ok == true' <<<"$micro_json" >/dev/null
    micro_total="$(jq -r '.total_ms | round' <<<"$micro_json")"
    jq --argjson run "$run" --argjson host_ms "$((micro_host_end-micro_host_begin))" --argjson transport_ms "$((micro_host_end-micro_host_begin-micro_total))" '. + {run:$run,host_wall_ms:$host_ms,transport_and_node_ms:$transport_ms}' <<<"$micro_json" >> "$micro_file"
  done

  for label in version config_validate plugins_list models_status; do
    for run in $(seq 1 "$PROFILE_REPEATS"); do
      case "$label" in
        version) args=(node openclaw.mjs --version) ;;
        config_validate) args=(node openclaw.mjs config validate) ;;
        plugins_list) args=(node openclaw.mjs plugins list --json) ;;
        models_status) args=(node openclaw.mjs models status --json) ;;
      esac
      profile_cli "$cid" "$handler" "$label" "${args[@]}" | jq --argjson run "$run" '. + {run:$run}' >> "$cli_file"
    done
  done
  cleanup_ids "$cid" "$pod"
  cid=''; pod=''

  jq -n --arg handler "$handler"     --argjson repeats "$PROFILE_REPEATS"     --argjson micro "$(jq -s '.' "$micro_file")"     --argjson cli "$(jq -s '.' "$cli_file")"     '{
      handler:$handler,
      repeats:$repeats,
      micro:$micro,
      cli:$cli
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
exit 0

: <<'__MICRO_JS_END__'
__MICRO_JS__
const fs = require("fs");
const path = require("path");
const { performance } = require("perf_hooks");
const processStart = performance.now();


function mountInfo(target) {
  let best = null;
  for (const line of fs.readFileSync("/proc/self/mountinfo", "utf8").trim().split("\n")) {
    const parts = line.split(" ");
    const sep = parts.indexOf("-");
    if (sep < 0) continue;
    const mountPoint = parts[4].replace(/\\040/g, " ");
    if (target === mountPoint || target.startsWith(mountPoint.replace(/\/$/, "") + "/")) {
      if (!best || mountPoint.length > best.mountPoint.length) {
        best = { mountPoint, fsType: parts[sep + 1] };
      }
    }
  }
  return best;
}
function timed(fn) {
  const b = performance.now();
  const value = fn();
  return { ms: +(performance.now() - b).toFixed(3), value };
}

function scanTree(root, limit = 5000) {
  const files = [];
  let dirs = 0;
  let errors = 0;
  const stack = [root];
  while (stack.length && files.length < limit) {
    const dir = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
      dirs++;
    } catch {
      errors++;
      continue;
    }
    for (const entry of entries) {
      const p = path.join(dir, entry.name);
      try {
        fs.lstatSync(p);
        if (entry.isDirectory()) stack.push(p);
        else files.push(p);
      } catch {
        errors++;
      }
      if (files.length >= limit) break;
    }
  }
  return { root, files, dirs, errors, truncated: stack.length > 0 };
}

function readFiles(files, byteLimit = 16 * 1024 * 1024) {
  let bytes = 0;
  let count = 0;
  let errors = 0;
  for (const file of files) {
    if (bytes >= byteLimit) break;
    try {
      const data = fs.readFileSync(file);
      bytes += data.length;
      count++;
    } catch {
      errors++;
    }
  }
  return { count, bytes, errors };
}

function sqliteRead(file) {
  if (!fs.existsSync(file)) return { file, exists: false };
  const b = performance.now();
  try {
    const { DatabaseSync } = require("node:sqlite");
    const db = new DatabaseSync(file, { readOnly: true });
    const journal = db.prepare("PRAGMA journal_mode").get();
    const tables = db.prepare("SELECT count(*) AS n FROM sqlite_master").get();
    db.close();
    return {
      file, exists: true, ok: true,
      ms: +(performance.now() - b).toFixed(3),
      journalMode: journal.journal_mode,
      schemaObjects: Number(tables.n)
    };
  } catch (error) {
    return {
      file, exists: true, ok: false,
      ms: +(performance.now() - b).toFixed(3),
      code: error.code || null,
      message: String(error.message)
    };
  }
}

const appScan = timed(() => scanTree("/app"));
const appRead = timed(() => readFiles(appScan.value.files));
const stateScan = timed(() => scanTree("/home/node/.openclaw"));
const stateRead = timed(() => readFiles(stateScan.value.files));

const pluginScan = timed(() => scanTree("/home/node/.openclaw/npm/projects"));
const pluginRead = timed(() => readFiles(pluginScan.value.files));
const configParse = timed(() => {
  const file = "/home/node/.openclaw/openclaw.json";
  let keys = 0;
  for (let i = 0; i < 50; i++) keys = Object.keys(JSON.parse(fs.readFileSync(file, "utf8"))).length;
  return { iterations: 50, keys };
});

const sqlite = [
  "/home/node/.openclaw/state/openclaw.sqlite",
  "/home/node/.openclaw/agents/main/agent/openclaw-agent.sqlite"
].map(sqliteRead);

const result = {
  ok: true,
  app: {
    metadata_ms: appScan.ms,
    files: appScan.value.files.length,
    dirs: appScan.value.dirs,
    errors: appScan.value.errors,
    truncated: appScan.value.truncated,
    read_ms: appRead.ms,
    read_count: appRead.value.count,
    read_bytes: appRead.value.bytes
  },
  state: {
    metadata_ms: stateScan.ms,
    files: stateScan.value.files.length,
    dirs: stateScan.value.dirs,
    errors: stateScan.value.errors,
    truncated: stateScan.value.truncated,
    read_ms: stateRead.ms,
    read_count: stateRead.value.count,
    read_bytes: stateRead.value.bytes
  },
  mounts: {
    app: mountInfo("/app"),
    state: mountInfo("/home/node/.openclaw"),
    plugin: mountInfo("/home/node/.openclaw/npm/projects")
  },
  plugin: {
    metadata_ms: pluginScan.ms,
    files: pluginScan.value.files.length,
    dirs: pluginScan.value.dirs,
    errors: pluginScan.value.errors,
    truncated: pluginScan.value.truncated,
    read_ms: pluginRead.ms,
    read_count: pluginRead.value.count,
    read_bytes: pluginRead.value.bytes
  },
  config_parse_50: { ms: configParse.ms, ...configParse.value },
  sqlite,
  total_ms: +(performance.now() - processStart).toFixed(3)
};
console.log(JSON.stringify(result));
__MICRO_JS_END__
