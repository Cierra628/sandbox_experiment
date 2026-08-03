#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
CONTAINER_ID="${HYBRID_APP_EXPORT_CONTAINER_ID:-}"
OUTPUT_DIR="${HYBRID_APP_EXPORT_DIR:-}"

usage() {
  printf '%s\n' \
    'Usage: scripts/24-export-merged-app.sh --container-id CID --output DIR' \
    '' \
    'Exports the merged /app tree from a running container.' \
    'The source container must not have an extra /app bind mount.' \
    '' \
    'Options:' \
    '  --container-id CID  running source container' \
    '  --output DIR        empty host directory to populate' \
    '  -h, --help          show this help'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --container-id) CONTAINER_ID="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -n "$CONTAINER_ID" ] || { echo 'error: --container-id is required' >&2; exit 2; }
[ -n "$OUTPUT_DIR" ] || { echo 'error: --output is required' >&2; exit 2; }

command -v crictl >/dev/null 2>&1 || { echo 'error: crictl is required' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo 'error: tar is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
sudo -v

CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")
state="$(${CRI[@]} inspect "$CONTAINER_ID" | jq -r '.status.state')"
[ "$state" = CONTAINER_RUNNING ] || {
  echo "error: container is not running: $CONTAINER_ID (state=$state)" >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR"
if find "$OUTPUT_DIR" -mindepth 1 -print -quit | grep -q .; then
  echo "error: output directory is not empty: $OUTPUT_DIR" >&2
  exit 1
fi

echo "checking merged /app in container: $CONTAINER_ID"
"${CRI[@]}" exec "$CONTAINER_ID" sh -c \
  'test -f /app/openclaw.mjs && (test -f /app/dist/entry.mjs || test -f /app/dist/entry.js)'

echo "exporting merged /app to: $OUTPUT_DIR"
set -o pipefail
"${CRI[@]}" exec "$CONTAINER_ID" sh -c \
  'tar -C /app -cf - .' \
  | tar -C "$OUTPUT_DIR" -xf -

test -f "$OUTPUT_DIR/openclaw.mjs"
if [ -f "$OUTPUT_DIR/dist/entry.mjs" ]; then
  ENTRY="$OUTPUT_DIR/dist/entry.mjs"
else
  ENTRY="$OUTPUT_DIR/dist/entry.js"
fi

find "$OUTPUT_DIR" -type f | wc -l | awk '{print "files=" $1}'
echo "entry=$ENTRY"
du -sh "$OUTPUT_DIR"
echo "MERGED_APP_EXPORT_OK"
