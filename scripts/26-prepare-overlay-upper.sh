#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_PATH="${HYBRID_OVERLAY_UPPER_IMAGE:-/var/lib/openclaw-kuasar/hybrid-cache/openclaw-overlay-upper.ext4}"
SIZE_MB="${HYBRID_OVERLAY_UPPER_SIZE_MB:-256}"
RESULT_DIR="${HYBRID_OVERLAY_UPPER_RESULT_DIR:-$ROOT_DIR/.artifacts/overlay-upper-prep-$(date -u +%Y%m%dT%H%M%SZ)}"
REBUILD=0

usage() {
  printf '%s\n' \
    'Usage: scripts/26-prepare-overlay-upper.sh [options]' \
    '' \
    'Creates a writable ext4 image containing overlayfs upper/work directories.' \
    '' \
    'Options:' \
    '  --image FILE       output image path' \
    '  --size-mb N        image size in MiB (default: 256)' \
    '  --result-dir DIR   preparation artifact directory' \
    '  --rebuild          rebuild an existing image' \
    '  -h, --help         show this help'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) IMAGE_PATH="$2"; shift 2 ;;
    --size-mb) SIZE_MB="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ "$SIZE_MB" =~ ^[1-9][0-9]*$ ]] || { echo 'error: --size-mb must be positive' >&2; exit 2; }

printf '%s\n' \
  'Overlay upper image preparation plan:' \
  "  image=$IMAGE_PATH" \
  "  size_mb=$SIZE_MB" \
  '  directories=upper,work' \
  '  runtime_mount=read-write' \
  "  result_dir=$RESULT_DIR" \
  "  rebuild=$REBUILD"

sudo -v
mkdir -p "$RESULT_DIR"
IMAGE_DIR="$(dirname "$IMAGE_PATH")"
LOOP_DEVICE=""
MOUNT_DIR=""
MOUNTED=0
KEEP_LOOP=0

cleanup() {
  local rc=$?
  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    sudo umount "$MOUNT_DIR" >/dev/null 2>&1 || true
    MOUNTED=0
  fi
  [ -z "$MOUNT_DIR" ] || rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
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
  sudo blockdev --setrw "$LOOP_DEVICE"
else
  if sudo test -e "$IMAGE_PATH" && [ "$REBUILD" -eq 1 ]; then
    existing_loop="$(sudo losetup -j "$IMAGE_PATH" | sed -n '1s/:.*//p')"
    [ -z "$existing_loop" ] || {
      echo "error: cannot rebuild while image is attached: $existing_loop" >&2
      exit 1
    }
  fi
  sudo mkdir -p "$IMAGE_DIR"
  sudo truncate -s "${SIZE_MB}M" "$IMAGE_PATH"
  sudo mkfs.ext4 -F -L overlay-upper "$IMAGE_PATH" > "$RESULT_DIR/mkfs.log"
  LOOP_DEVICE="$(sudo losetup --find --show "$IMAGE_PATH")"
  sudo blockdev --setrw "$LOOP_DEVICE"
  MOUNT_DIR="$(mktemp -d /tmp/openclaw-overlay-upper.XXXXXX)"
  sudo mount -o rw "$LOOP_DEVICE" "$MOUNT_DIR"
  MOUNTED=1
  sudo mkdir -p "$MOUNT_DIR/upper" "$MOUNT_DIR/work"
  sudo chmod 700 "$MOUNT_DIR/upper" "$MOUNT_DIR/work"
  sudo sync
  sudo umount "$MOUNT_DIR"
  MOUNTED=0
  rmdir "$MOUNT_DIR"
  MOUNT_DIR=""
fi

sudo test -b "$LOOP_DEVICE"
sudo blkid "$LOOP_DEVICE" | tee "$RESULT_DIR/blkid.txt"
sudo stat -c 'image=%n size=%s mode=%a' "$IMAGE_PATH" | tee "$RESULT_DIR/image-stat.txt"
sudo losetup "$LOOP_DEVICE" | tee "$RESULT_DIR/loop.txt"

ENV_FILE="$RESULT_DIR/overlay-upper.env"
printf '%s\n' \
  "HYBRID_OVERLAY_UPPER_IMAGE=$IMAGE_PATH" \
  "HYBRID_OVERLAY_UPPER_LOOP_DEVICE=$LOOP_DEVICE" \
  "HYBRID_OVERLAY_UPPER_RESULT_DIR=$RESULT_DIR" \
  > "$ENV_FILE"

KEEP_LOOP=1
printf '%s\n' \
  "image=$IMAGE_PATH" \
  "loop_device=$LOOP_DEVICE" \
  "env_file=$ENV_FILE" \
  "result_dir=$RESULT_DIR"
