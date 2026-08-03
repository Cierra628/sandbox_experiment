#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR=""
IMAGE_PATH=""
LABEL="app"
RESULT_DIR="${HYBRID_PATH_PREP_RESULT_DIR:-$ROOT_DIR/.artifacts/hybrid-path-prep-$(date -u +%Y%m%dT%H%M%SZ)}"
MIN_SIZE_MB="${HYBRID_PATH_MIN_SIZE_MB:-256}"
SAFETY_PERCENT="${HYBRID_PATH_SAFETY_PERCENT:-150}"
REBUILD=0
READONLY=0

usage() {
  printf '%s\n' \
    'Usage: scripts/22-prepare-hybrid-path-image.sh [options]' \
    '' \
    'Creates or reuses an ext4 image from a directory and leaves it attached.' \
    '' \
    'Options:' \
    '  --source DIR       directory to pack into the image (required)' \
    '  --image FILE       output ext4 image (required)' \
    '  --label LABEL      image label used in evidence (default: app)' \
    '  --result-dir DIR   preparation artifact directory' \
    '  --readonly         mark the loop device read-only after creation' \
    '  --rebuild          rebuild an existing image (explicit and destructive)' \
    '  --dry-run          print the plan without changing anything'
}

DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) SOURCE_DIR="$2"; shift 2 ;;
    --image) IMAGE_PATH="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    --readonly) READONLY=1; shift ;;
    --rebuild) REBUILD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -n "$SOURCE_DIR" ] || { echo 'error: --source is required' >&2; exit 2; }
[ -n "$IMAGE_PATH" ] || { echo 'error: --image is required' >&2; exit 2; }
[[ "$SAFETY_PERCENT" =~ ^[1-9][0-9]*$ ]] || {
  echo 'error: HYBRID_PATH_SAFETY_PERCENT must be positive' >&2
  exit 2
}
IMAGE_DIR="$(dirname "$IMAGE_PATH")"

if [[ "$LABEL" == app* ]] && \
  ! sudo test -f "$SOURCE_DIR/dist/entry.mjs" && \
  ! sudo test -f "$SOURCE_DIR/dist/entry.js"; then
  echo "error: app source is not a complete merged /app tree: missing dist/entry.(m)js" >&2
  echo '       export /app from a running container rather than copying an overlayfs layer' >&2
  exit 1
fi

printf '%s\n' \
  'Hybrid path image preparation plan:' \
  "  label=$LABEL" \
  "  source=$SOURCE_DIR" \
  "  image=$IMAGE_PATH" \
  "  readonly=$READONLY" \
  "  result_dir=$RESULT_DIR" \
  "  rebuild=$REBUILD"

[ "$DRY_RUN" -eq 1 ] && exit 0
sudo -v
sudo test -d "$SOURCE_DIR" || { echo "error: missing source directory: $SOURCE_DIR" >&2; exit 1; }

mkdir -p "$RESULT_DIR"
LOOP_DEVICE=""
KEEP_LOOP=0
MOUNT_DIR=""
MOUNTED=0
cleanup() {
  local rc=$?
  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    sudo umount "$MOUNT_DIR" >/dev/null 2>&1 || true
    MOUNTED=0
  fi
  if [ -n "$MOUNT_DIR" ]; then
    rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
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
else
  if sudo test -e "$IMAGE_PATH" && [ "$REBUILD" -eq 1 ]; then
    existing_loop="$(sudo losetup -j "$IMAGE_PATH" | sed -n '1s/:.*//p')"
    [ -z "$existing_loop" ] || {
      echo "error: cannot rebuild while image is attached: $existing_loop" >&2
      exit 1
    }
  fi
  source_bytes="$(sudo du -sB1 "$SOURCE_DIR" | awk '{print $1}')"
  required_mb=$(( (source_bytes * SAFETY_PERCENT / 100 + 1048575) / 1048576 ))
  [ "$required_mb" -ge "$MIN_SIZE_MB" ] || required_mb="$MIN_SIZE_MB"
  sudo mkdir -p "$IMAGE_DIR"
  sudo truncate -s "${required_mb}M" "$IMAGE_PATH"
  sudo mkfs.ext4 -F -L "hybrid-$LABEL" "$IMAGE_PATH" > "$RESULT_DIR/mkfs.log"
  LOOP_DEVICE="$(sudo losetup --find --show "$IMAGE_PATH")"
  sudo blockdev --setrw "$LOOP_DEVICE"
  MOUNT_DIR="$(mktemp -d /tmp/openclaw-hybrid-path.XXXXXX)"
  sudo mount -o rw "$LOOP_DEVICE" "$MOUNT_DIR"
  MOUNTED=1
  sudo cp -a "$SOURCE_DIR"/. "$MOUNT_DIR"/
  sudo sync
  sudo umount "$MOUNT_DIR"
  MOUNTED=0
  rmdir "$MOUNT_DIR"
  MOUNT_DIR=""
  if [ "$READONLY" -eq 1 ]; then
    sudo blockdev --setro "$LOOP_DEVICE"
  fi
  sudo chmod 600 "$IMAGE_PATH"
  KEEP_LOOP=1
fi

sudo test -b "$LOOP_DEVICE" || { echo "error: not a block device: $LOOP_DEVICE" >&2; exit 1; }
sudo blkid "$LOOP_DEVICE" | tee "$RESULT_DIR/blkid.txt"
sudo stat -c 'image=%n size=%s mode=%a' "$IMAGE_PATH" | tee "$RESULT_DIR/image-stat.txt"
sudo losetup "$LOOP_DEVICE" | tee "$RESULT_DIR/loop.txt"

ENV_FILE="$RESULT_DIR/hybrid-$LABEL.env"
printf '%s\n' \
  "HYBRID_PATH_LABEL=$LABEL" \
  "HYBRID_PATH_SOURCE=$SOURCE_DIR" \
  "HYBRID_PATH_IMAGE=$IMAGE_PATH" \
  "HYBRID_PATH_LOOP_DEVICE=$LOOP_DEVICE" \
  "HYBRID_PATH_RESULT_DIR=$RESULT_DIR" \
  > "$ENV_FILE"

printf '%s\n' \
  "path_image=$IMAGE_PATH" \
  "loop_device=$LOOP_DEVICE" \
  "env_file=$ENV_FILE" \
  "result_dir=$RESULT_DIR"
