#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-10.2.30.50:5000/openclaw-kuasar:2026.6.11-virtiofs}"
RUNS="${ROOTFS_RUNS:-3}"
PASSES="${IMAGE_WORKLOAD_PASSES:-512}"
EXPECTED_SANDBOXER_SHA256="${EXPECTED_SANDBOXER_SHA256:-85303a286ff3f676d56a6c784564688ca42bf181b630299c02bd435dff7bf33d}"
SYSTEM_CONFIG=/etc/openclaw-kuasar/vmm.toml
SYSTEM_SANDBOXER=/usr/local/libexec/openclaw-kuasar/vmm-sandboxer
VMM_SERVICE=openclaw-kuasar-vmm.service
CONTAINERD_SERVICE=openclaw-kuasar-containerd.service

LABEL=''
CONFIG_SOURCE=''
RESULT_DIR=''
CONFIRM=0

usage() {
  printf '%s\n' \
    'Usage:' \
    '  scripts/19-benchmark-rootfs-config.sh --label LABEL --config FILE --confirm-config-install [options]' \
    '' \
    'Options:' \
    '  --label LABEL        virtio-blk, virtiofs-never, or virtiofs-metadata' \
    '  --config FILE        VMM TOML file matching LABEL' \
    '  --runs N             independent fresh containers per phase (default: 3)' \
    '  --passes N           image-upscale compute passes (default: 512)' \
    '  --image IMAGE        cached target image; pull happens once before timing' \
    '  --result-dir DIR     artifact directory' \
    '  --confirm-config-install  permit installing FILE to /etc/openclaw-kuasar/vmm.toml' \
    '  --dry-run            print the plan without changing services or running workloads'
}

DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --config) CONFIG_SOURCE="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --passes) PASSES="$2"; shift 2 ;;
    --image) OPENCLAW_IMAGE="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    --confirm-config-install) CONFIRM=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$LABEL" in
  virtio-blk)
    EXPECTED_BACKEND=virtio-blk
    EXPECTED_CACHE=''
    ;;
  virtiofs-never)
    EXPECTED_BACKEND=virtiofs
    EXPECTED_CACHE=never
    ;;
  virtiofs-metadata)
    EXPECTED_BACKEND=virtiofs
    EXPECTED_CACHE=metadata
    ;;
  *)
    echo 'error: --label must be virtio-blk, virtiofs-never, or virtiofs-metadata' >&2
    exit 2
    ;;
esac

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo 'error: --runs must be positive' >&2; exit 2; }
[[ "$PASSES" =~ ^[1-9][0-9]*$ ]] || { echo 'error: --passes must be positive' >&2; exit 2; }
[ -n "$CONFIG_SOURCE" ] || { echo 'error: --config is required' >&2; exit 2; }
CONFIG_SOURCE="$(realpath "$CONFIG_SOURCE")"
[ -f "$CONFIG_SOURCE" ] || { echo "error: missing config: $CONFIG_SOURCE" >&2; exit 2; }

grep -Eq "^[[:space:]]*container_storage_backend[[:space:]]*=[[:space:]]*\"${EXPECTED_BACKEND}\"" "$CONFIG_SOURCE" || {
  echo "error: $CONFIG_SOURCE does not select backend $EXPECTED_BACKEND" >&2
  exit 2
}
if [ -n "$EXPECTED_CACHE" ]; then
  grep -Eq "^[[:space:]]*cache[[:space:]]*=[[:space:]]*\"${EXPECTED_CACHE}\"" "$CONFIG_SOURCE" || {
    echo "error: $CONFIG_SOURCE does not select virtiofs cache $EXPECTED_CACHE" >&2
    exit 2
  }
fi

RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/.artifacts/rootfs-${LABEL}-$(date -u +%Y%m%dT%H%M%SZ)}"

printf '%s\n' \
  'Rootfs configuration benchmark plan:' \
  "  label=$LABEL" \
  "  config=$CONFIG_SOURCE" \
  "  image=$OPENCLAW_IMAGE" \
  "  independent_runs=$RUNS" \
  "  image_workload_passes=$PASSES" \
  '  pull_policy=one pre-pull outside measured phases' \
  '  micro_policy=one fresh Pod/VM/container per run' \
  '  workload_policy=one fresh Pod/VM/container per run' \
  "  expected_sandboxer_sha256=$EXPECTED_SANDBOXER_SHA256" \
  "  result_dir=$RESULT_DIR"

[ "$DRY_RUN" -eq 1 ] && exit 0
[ "$CONFIRM" -eq 1 ] || {
  echo 'error: configuration installation requires --confirm-config-install' >&2
  exit 2
}

command -v jq >/dev/null
command -v crictl >/dev/null
command -v sha256sum >/dev/null
sudo -v

cri() {
  sudo crictl \
    --runtime-endpoint "$CRI_ENDPOINT" \
    --image-endpoint "$CRI_ENDPOINT" \
    "$@"
}

active_containers="$(cri ps -a -o json | jq '.containers | length')"
active_pods="$(cri pods -o json | jq '.items | length')"
if [ "$active_containers" -ne 0 ] || [ "$active_pods" -ne 0 ]; then
  echo "error: active CRI resources remain (containers=$active_containers pods=$active_pods)" >&2
  exit 1
fi

installed_hash="$(sudo sha256sum "$SYSTEM_SANDBOXER" | awk '{print $1}')"
if [ "$installed_hash" != "$EXPECTED_SANDBOXER_SHA256" ]; then
  echo "error: unexpected vmm-sandboxer hash: $installed_hash" >&2
  exit 1
fi

mkdir -p "$RESULT_DIR/micro" "$RESULT_DIR/workload" "$RESULT_DIR/evidence"
sudo cat "$SYSTEM_CONFIG" > "$RESULT_DIR/evidence/vmm-before.toml"
cp "$CONFIG_SOURCE" "$RESULT_DIR/evidence/vmm-requested.toml"

sudo systemctl stop "$CONTAINERD_SERVICE"
sudo systemctl stop "$VMM_SERVICE"
sudo install -m 0644 "$CONFIG_SOURCE" "$SYSTEM_CONFIG"
sudo systemctl start "$VMM_SERVICE"
sudo systemctl start "$CONTAINERD_SERVICE"

sudo systemctl is-active --quiet "$VMM_SERVICE"
sudo systemctl is-active --quiet "$CONTAINERD_SERVICE"
cri info | jq -e '
  [.status.conditions[] | select(.type == "RuntimeReady" or .type == "NetworkReady") | .status]
  | all(. == true)
' >/dev/null

sudo cat "$SYSTEM_CONFIG" > "$RESULT_DIR/evidence/vmm-effective.toml"
sudo sha256sum "$SYSTEM_SANDBOXER" > "$RESULT_DIR/evidence/sandboxer-sha256.txt"
sudo systemctl status "$VMM_SERVICE" --no-pager --lines=30 > "$RESULT_DIR/evidence/vmm-service.txt"

pull_begin="$(date +%s%3N)"
cri pull --pull-timeout 20m "$OPENCLAW_IMAGE" > "$RESULT_DIR/evidence/pre-pull.txt" 2>&1
pull_end="$(date +%s%3N)"
pre_pull_ms="$((pull_end - pull_begin))"

MICRO_NDJSON="$RESULT_DIR/micro/results.ndjson"
: > "$MICRO_NDJSON"
for run in $(seq 1 "$RUNS"); do
  run_dir="$RESULT_DIR/micro/run-$run"
  mkdir -p "$run_dir"
  printf 'micro label=%s run=%s\n' "$LABEL" "$run"
  OPENCLAW_IMAGE="$OPENCLAW_IMAGE" \
  PROFILE_HANDLERS=kuasar-vmm \
  PROFILE_REPEATS=1 \
  RESULT_DIR="$run_dir" \
    "$ROOT_DIR/scripts/10-profile-guest-bootstrap.sh" \
      > "$run_dir/console.log" \
      2>&1
  jq \
    --arg config "$LABEL" \
    --argjson independent_run "$run" \
    '.[0] + {config:$config, independent_run:$independent_run}' \
    "$run_dir/results.json" >> "$MICRO_NDJSON"
done
jq -s '.' "$MICRO_NDJSON" > "$RESULT_DIR/micro/results.json"

OPENCLAW_IMAGE="$OPENCLAW_IMAGE" \
IMAGE_WORKLOAD_HANDLERS=kuasar-vmm \
IMAGE_WORKLOAD_RUNS="$RUNS" \
IMAGE_WORKLOAD_PASSES="$PASSES" \
RESULT_DIR="$RESULT_DIR/workload" \
  "$ROOT_DIR/scripts/17-benchmark-image-workload.sh" \
    > "$RESULT_DIR/workload/console.log" \
    2>&1

jq -e --argjson runs "$RUNS" '
  length == $runs and all(.status == "PASS")
' "$RESULT_DIR/workload/results.json" >/dev/null

jq -n \
  --arg label "$LABEL" \
  --arg config "$CONFIG_SOURCE" \
  --arg image "$OPENCLAW_IMAGE" \
  --arg sandboxer_sha256 "$installed_hash" \
  --argjson runs "$RUNS" \
  --argjson passes "$PASSES" \
  --argjson pre_pull_ms "$pre_pull_ms" \
  --slurpfile micro "$RESULT_DIR/micro/results.json" \
  --slurpfile workload "$RESULT_DIR/workload/summary.json" \
  '{
    label:$label,
    config_source:$config,
    image:$image,
    sandboxer_sha256:$sandboxer_sha256,
    independent_runs:$runs,
    workload_passes:$passes,
    pre_pull_ms:$pre_pull_ms,
    pre_pull_included_in_measurements:false,
    micro:$micro[0],
    workload:$workload[0]
  }' > "$RESULT_DIR/summary.json"

cat > "$RESULT_DIR/experiment-metadata.txt" <<EOF
configuration=$LABEL
sandboxer_sha256=$installed_hash
independent_runs=$RUNS
image=$OPENCLAW_IMAGE
pre_pull_ms=$pre_pull_ms
pre_pull_included_in_measurements=false
micro_semantics=fresh Pod/VM/container per run; cached image
workload_semantics=fresh Pod/VM/container per run; cached image
EOF

printf '%s\n' \
  "benchmark completed: $LABEL" \
  "results=$RESULT_DIR"
jq '{
  label,
  independent_runs,
  pre_pull_ms,
  workload
}' "$RESULT_DIR/summary.json"
