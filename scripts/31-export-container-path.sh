#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
CONTAINER_ID="${CONTAINER_PATH_EXPORT_CONTAINER_ID:-}"
CONTAINER_PATH="${CONTAINER_PATH_EXPORT_PATH:-/usr/local}"
OUTPUT_DIR="${CONTAINER_PATH_EXPORT_DIR:-}"

usage() {
  printf '%s\n' \
    'Usage: scripts/31-export-container-path.sh --container-id CID --path PATH --output DIR' \
    '' \
    'Exports one complete directory from a running source container.' \
    'Top-level entries are transferred as separate compressed streams to avoid CRI stream truncation.' \
    'The output directory must be empty and is populated with the container path contents.' \
    '' \
    'Options:' \
    '  --container-id CID  running source container' \
    '  --path PATH         absolute container path (default: /usr/local)' \
    '  --output DIR        empty host directory to populate' \
    '  -h, --help          show this help'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --container-id) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; CONTAINER_ID="$2"; shift 2 ;;
    --path) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; CONTAINER_PATH="$2"; shift 2 ;;
    --output) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -n "$CONTAINER_ID" ] || { echo 'error: --container-id is required' >&2; exit 2; }
[ -n "$OUTPUT_DIR" ] || { echo 'error: --output is required' >&2; exit 2; }
[[ "$CONTAINER_PATH" = /* && "$CONTAINER_PATH" != "/" ]] || {
  echo 'error: --path must be a non-root absolute directory' >&2
  exit 2
}

command -v crictl >/dev/null 2>&1 || { echo 'error: crictl is required' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo 'error: tar is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
sudo -v

CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")
state="$("${CRI[@]}" inspect "$CONTAINER_ID" | jq -r '.status.state')"
[ "$state" = CONTAINER_RUNNING ] || {
  echo "error: container is not running: $CONTAINER_ID (state=$state)" >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR"
if find "$OUTPUT_DIR" -mindepth 1 -print -quit | grep -q .; then
  echo "error: output directory is not empty: $OUTPUT_DIR" >&2
  exit 1
fi

printf '%s\n' \
  "container=$CONTAINER_ID" \
  "path=$CONTAINER_PATH" \
  "output=$OUTPUT_DIR"

CHUNK_SIZE="${CONTAINER_PATH_EXPORT_CHUNK_SIZE:-4M}"
FLUSH_DELAY="${CONTAINER_PATH_EXPORT_FLUSH_DELAY_SECONDS:-2}"
REMOTE_PREFIX="/tmp/openclaw-path-export-${CONTAINER_ID:0:12}-$$"
LOCAL_ARCHIVE="$(mktemp /tmp/openclaw-path-export.XXXXXX.tar)"
LOCAL_PART="${LOCAL_ARCHIVE}.part"
chunk_list=""

cleanup() {
  rm -f "$LOCAL_ARCHIVE" "$LOCAL_PART"
  if [ -n "$chunk_list" ]; then
    "${CRI[@]}" exec "$CONTAINER_ID" sh -c \
      'rm -f "$@"' _ $chunk_list >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Build the archive inside the container, then split it before sending it
# through CRI exec. The raw /usr/local archive is about 162 MB and large single
# streams are truncated by the current Kuasar CRI SPDY implementation.
"${CRI[@]}" exec "$CONTAINER_ID" sh -c \
  'set -eu
   rm -f "$1".* "$1.full"
   tar -C "$2" -cf "$1.full" .
   split -b "$3" "$1.full" "$1."
   rm -f "$1.full"
   test -n "$(for f in "$1".*; do [ -f "$f" ] && printf "%s\n" "$f" && break; done)"' \
  _ "$REMOTE_PREFIX" "$CONTAINER_PATH" "$CHUNK_SIZE"

chunk_list="$("${CRI[@]}" exec "$CONTAINER_ID" sh -c \
  'for f in "$1".*; do [ -f "$f" ] && printf "%s\t%s\n" "$f" "$(stat -c %s "$f")"; done' \
  _ "$REMOTE_PREFIX")"
[ -n "$chunk_list" ] || {
  echo "error: container produced no archive chunks" >&2
  exit 1
}

chunk_count=0
while IFS=$'\t' read -r chunk remote_size; do
  [ -n "$chunk" ] || continue
  [ -n "$remote_size" ] || {
    echo "error: missing remote size for chunk $chunk" >&2
    exit 1
  }
  chunk_count=$((chunk_count + 1))
  printf '%s\n' "fetching_chunk=$chunk_count remote_bytes=$remote_size" >&2
  # Keep the exec process alive briefly after cat exits. Kuasar's CRI
  # streaming path can otherwise close before the final stdout buffer flushes.
  "${CRI[@]}" exec "$CONTAINER_ID" sh -c \
    'cat "$1"; sleep "$2"' \
    _ "$chunk" "$FLUSH_DELAY" \
    > "$LOCAL_PART"
  local_size="$(stat -c '%s' "$LOCAL_PART")"
  if [ "$local_size" -ne "$remote_size" ]; then
    echo "error: truncated chunk $chunk (remote=$remote_size local=$local_size)" >&2
    exit 1
  fi
  cat "$LOCAL_PART" >> "$LOCAL_ARCHIVE"
  rm -f "$LOCAL_PART"
done <<< "$chunk_list"

tar -tf "$LOCAL_ARCHIVE" >/dev/null
tar -C "$OUTPUT_DIR" -xf "$LOCAL_ARCHIVE"

sudo test -d "$OUTPUT_DIR"
file_count="$(find "$OUTPUT_DIR" -type f | wc -l | awk '{print $1}')"
printf '%s\n' \
  "chunks=$chunk_count" \
  "files=$file_count" \
  "path=$CONTAINER_PATH" \
  "output=$OUTPUT_DIR"
du -sh "$OUTPUT_DIR"
printf '%s\n' 'CONTAINER_PATH_EXPORT_OK'
