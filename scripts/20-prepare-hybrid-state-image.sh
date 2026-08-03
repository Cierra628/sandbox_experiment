#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${HYBRID_STATE_SOURCE:-/var/lib/openclaw-kuasar/openclaw-state}"
IMAGE_DIR="${HYBRID_IMAGE_DIR:-/var/lib/openclaw-kuasar/hybrid-cache}"
IMAGE_PATH="${HYBRID_STATE_IMAGE:-$IMAGE_DIR/openclaw-state.ext4}"
RESULT_DIR="${HYBRID_PREP_RESULT_DIR:-$ROOT_DIR/.artifacts/hybrid-state-prep-$(date -u +%Y%m%dT%H%M%SZ)}"
MIN_SIZE_MB="${HYBRID_MIN_SIZE_MB:-256}"
REBUILD=0

usage() {
  printf '%s\n' \
    'Usage: scripts/20-prepare-hybrid-state-image.sh [options]' \
    '' \
    'Creates or reuses a persistent ext4 image containing the VMM OpenClaw state.' \
    'The image remains attached to a loop device for the following CRI experiment.' \
    '' \
    'Options:' \
    '  --source DIR       source state directory' \
    '  --image FILE       ext4 image path' \
    '  --result-dir DIR   preparation artifact directory' \
    '  --rebuild          rebuild an existing image (explicit and destructive)' \
    '  --dry-run          print the plan without changing anything'
}

DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) SOURCE_DIR="$2"; shift 2 ;;
    --image) IMAGE_PATH="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

IMAGE_DIR="$(dirname "$IMAGE_PATH")"

printf '%s\n' \
  'Hybrid state image preparation plan:' \
  "  source=$SOURCE_DIR" \
  "  image=$IMAGE_PATH" \
  "  result_dir=$RESULT_DIR" \
  "  rebuild=$REBUILD"

[ "$DRY_RUN" -eq 1 ] && exit 0
command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
sudo -v
sudo test -d "$SOURCE_DIR" || { echo "error: missing source directory: $SOURCE_DIR" >&2; exit 1; }
sudo test -f "$SOURCE_DIR/openclaw.json" || {
  echo "error: source state has no openclaw.json: $SOURCE_DIR" >&2
  exit 1
}

CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")
active_containers="$("${CRI[@]}" ps -a -o json | jq '.containers | length')"
active_pods="$("${CRI[@]}" pods -o json | jq '.items | length')"
if [ "$active_containers" -ne 0 ] || [ "$active_pods" -ne 0 ]; then
  echo "error: active CRI resources remain (containers=$active_containers pods=$active_pods)" >&2
  exit 1
fi

mkdir -p "$RESULT_DIR"
LOOP_DEVICE=""
KEEP_LOOP=0
cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$KEEP_LOOP" -ne 1 ] && [ -n "$LOOP_DEVICE" ]; then
    sudo losetup -d "$LOOP_DEVICE" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT

if sudo test -e "$IMAGE_PATH" && [ "$REBUILD" -ne 1 ]; then
  LOOP_DEVICE="$(sudo losetup -j "$IMAGE_PATH" | sed -n '1s/:.*//p')"
  if [ -z "$LOOP_DEVICE" ]; then
    LOOP_DEVICE="$(sudo losetup --find --show "$IMAGE_PATH")"
  fi
  KEEP_LOOP=1
  printf '%s\n' 'Reusing existing state image.'
else
  if sudo test -e "$IMAGE_PATH" && [ "$REBUILD" -eq 1 ]; then
    existing_loop="$(sudo losetup -j "$IMAGE_PATH" | sed -n '1s/:.*//p')"
    [ -z "$existing_loop" ] || {
      echo "error: cannot rebuild while image is attached: $existing_loop" >&2
      exit 1
    }
  fi

  source_bytes="$(sudo du -sb "$SOURCE_DIR" | awk '{print $1}')"
  required_mb=$(( (source_bytes * 125 / 100 + 1048575) / 1048576 ))
  [ "$required_mb" -ge "$MIN_SIZE_MB" ] || required_mb="$MIN_SIZE_MB"
  sudo mkdir -p "$IMAGE_DIR"
  sudo truncate -s "${required_mb}M" "$IMAGE_PATH"
  sudo mkfs.ext4 -F -L openclaw-state "$IMAGE_PATH" > "$RESULT_DIR/mkfs.log"
  LOOP_DEVICE="$(sudo losetup --find --show "$IMAGE_PATH")"
  mount_dir="$(mktemp -d /tmp/openclaw-hybrid-state.XXXXXX)"
  mounted=0
  cleanup_mount() {
    if [ "$mounted" -eq 1 ]; then
      sudo umount "$mount_dir" >/dev/null 2>&1 || true
    fi
    rmdir "$mount_dir" >/dev/null 2>&1 || true
  }
  trap cleanup_mount RETURN
  sudo mount "$LOOP_DEVICE" "$mount_dir"
  mounted=1
  sudo cp -a "$SOURCE_DIR"/. "$mount_dir"/
  sudo sync
  sudo umount "$mount_dir"
  mounted=0
  rmdir "$mount_dir"
  trap - RETURN
  sudo chmod 600 "$IMAGE_PATH"
  KEEP_LOOP=1
fi

sudo test -b "$LOOP_DEVICE" || { echo "error: not a block device: $LOOP_DEVICE" >&2; exit 1; }
sudo blkid "$LOOP_DEVICE" | tee "$RESULT_DIR/blkid.txt"
sudo stat -c 'image=%n size=%s mode=%a' "$IMAGE_PATH" | tee "$RESULT_DIR/image-stat.txt"
sudo losetup "$LOOP_DEVICE" | tee "$RESULT_DIR/loop.txt"

ENV_FILE="$RESULT_DIR/hybrid-state.env"
printf '%s\n' \
  "HYBRID_STATE_SOURCE=$SOURCE_DIR" \
  "HYBRID_STATE_IMAGE=$IMAGE_PATH" \
  "HYBRID_STATE_LOOP_DEVICE=$LOOP_DEVICE" \
  "HYBRID_STATE_RESULT_DIR=$RESULT_DIR" \
  > "$ENV_FILE"

printf '%s\n' \
  "state_image=$IMAGE_PATH" \
  "loop_device=$LOOP_DEVICE" \
  "env_file=$ENV_FILE" \
  "result_dir=$RESULT_DIR"
