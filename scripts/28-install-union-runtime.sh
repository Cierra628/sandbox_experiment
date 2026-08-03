#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${KUASAR_UNION_SRC:-$ROOT_DIR/.cache/src/kuasar-v1.1.0-image-type}"
SANDBOXER_BIN="${KUASAR_UNION_SANDBOXER_BIN:-$SRC_DIR/target/release/cloud_hypervisor}"
TASK_BIN="${KUASAR_UNION_TASK_BIN:-$SRC_DIR/target/x86_64-unknown-linux-musl/release/vmm-task}"
LIVE_SANDBOXER="${KUASAR_UNION_LIVE_SANDBOXER:-/usr/local/libexec/openclaw-kuasar/vmm-sandboxer}"
LIVE_IMAGE="${KUASAR_UNION_LIVE_IMAGE:-/var/lib/openclaw-kuasar/kuasar/kuasar.img}"
VMM_UNIT="${KUASAR_UNION_VMM_UNIT:-openclaw-kuasar-vmm.service}"
CONTAINERD_UNIT="${KUASAR_UNION_CONTAINERD_UNIT:-openclaw-kuasar-containerd.service}"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
BACKUP_DIR="${KUASAR_UNION_BACKUP_DIR:-$ROOT_DIR/.artifacts/pre-union-install-$(date -u +%Y%m%dT%H%M%SZ)}"
CONFIRM=0

usage() {
  printf '%s\n' \
    'Usage: scripts/28-install-union-runtime.sh --confirm-install' \
    '' \
    'Installs the rebuilt host sandboxer and a patched kuasar.img containing the rebuilt guest vmm-task.' \
    'The script refuses active CRI resources/workloads and keeps a rollback backup.' \
    '' \
    'Environment overrides:' \
    '  KUASAR_UNION_SRC, KUASAR_UNION_SANDBOXER_BIN, KUASAR_UNION_TASK_BIN' \
    '  KUASAR_UNION_LIVE_SANDBOXER, KUASAR_UNION_LIVE_IMAGE, KUASAR_UNION_VMM_UNIT' \
    '  KUASAR_UNION_CONTAINERD_UNIT' \
    '  KUASAR_UNION_BACKUP_DIR, CRI_ENDPOINT' \
    '' \
    '  --confirm-install       perform the privileged install' \
    '  -h, --help              show this help'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --confirm-install) CONFIRM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

printf '%s\n' \
  'Kuasar union runtime install plan:' \
  "  source=$SRC_DIR" \
  "  host_sandboxer=$SANDBOXER_BIN" \
  "  guest_task=$TASK_BIN" \
  "  live_sandboxer=$LIVE_SANDBOXER" \
  "  live_image=$LIVE_IMAGE" \
  "  vmm_unit=$VMM_UNIT" \
  "  containerd_unit=$CONTAINERD_UNIT" \
  "  backup=$BACKUP_DIR" \
  "  cri_endpoint=$CRI_ENDPOINT"

if [ "$CONFIRM" -ne 1 ]; then
  echo 'error: pass --confirm-install only after reviewing the plan' >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
command -v losetup >/dev/null 2>&1 || { echo 'error: losetup is required' >&2; exit 1; }
command -v sgdisk >/dev/null 2>&1 || { echo 'error: sgdisk is required' >&2; exit 1; }
command -v mount >/dev/null 2>&1 || { echo 'error: mount is required' >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo 'error: systemctl is required' >&2; exit 1; }
[ -x "$SANDBOXER_BIN" ] || { echo "error: host sandboxer binary is not executable: $SANDBOXER_BIN" >&2; exit 1; }
[ -x "$TASK_BIN" ] || { echo "error: guest task binary is not executable: $TASK_BIN" >&2; exit 1; }
sudo -v
sudo test -x "$LIVE_SANDBOXER" || { echo "error: live sandboxer missing: $LIVE_SANDBOXER" >&2; exit 1; }
sudo test -f "$LIVE_IMAGE" || { echo "error: live guest image missing: $LIVE_IMAGE" >&2; exit 1; }

CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")
if "${CRI[@]}" ps -a 2>/dev/null | awk 'NR > 1 && NF { found=1 } END { exit found ? 0 : 1 }'; then
  echo 'error: active CRI container remains' >&2
  exit 1
fi
if "${CRI[@]}" pods 2>/dev/null | awk 'NR > 1 && NF { found=1 } END { exit found ? 0 : 1 }'; then
  echo 'error: active CRI pod remains' >&2
  exit 1
fi
VMM_WORKLOADS="$(ps -eo pid=,args= 2>/dev/null | awk \
  '/\/var\/lib\/openclaw-kuasar\/vmm\// && /(cloud-hypervisor|virtiofsd)/ { print }' \
  || true)"
if [ -n "$VMM_WORKLOADS" ]; then
  printf '%s\n' "$VMM_WORKLOADS" >&2
  echo 'error: Cloud Hypervisor or virtiofsd workload remains' >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
SERVICE_STOPPED=0
INSTALLED=0
CONTAINERD_WAS_ACTIVE=0
LOOP_DEVICE=''
PART_DEVICE=''
MOUNT_DIR=''
MOUNTED=0
restore_on_failure() {
  local rc=$?
  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    sudo umount "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  if [ -n "$MOUNT_DIR" ]; then
    rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  if [ -n "$LOOP_DEVICE" ]; then
    sudo losetup -d "$LOOP_DEVICE" >/dev/null 2>&1 || true
  fi
  if [ "$rc" -ne 0 ] && [ "$SERVICE_STOPPED" -eq 1 ]; then
    if [ "$INSTALLED" -eq 1 ]; then
      sudo install -m 0755 "$BACKUP_DIR/live-vmm-sandboxer" "$LIVE_SANDBOXER" || true
      sudo install -m 0644 "$BACKUP_DIR/live-kuasar.img" "$LIVE_IMAGE" || true
    fi
    sudo systemctl start "$VMM_UNIT" >/dev/null 2>&1 || true
    if [ "$CONTAINERD_WAS_ACTIVE" -eq 1 ]; then
      sudo systemctl start "$CONTAINERD_UNIT" >/dev/null 2>&1 || true
    fi
    echo "install failed; rollback backup retained at $BACKUP_DIR" >&2
  fi
  exit "$rc"
}
trap restore_on_failure EXIT

if sudo systemctl is-active --quiet "$CONTAINERD_UNIT"; then
  CONTAINERD_WAS_ACTIVE=1
fi

sudo systemctl stop "$VMM_UNIT"
SERVICE_STOPPED=1
sudo cp --reflink=auto "$LIVE_SANDBOXER" "$BACKUP_DIR/live-vmm-sandboxer"
sudo cp --reflink=auto "$LIVE_IMAGE" "$BACKUP_DIR/live-kuasar.img"
sudo cp -a /etc/openclaw-kuasar/vmm.toml "$BACKUP_DIR/vmm.toml"
sudo chmod 600 "$BACKUP_DIR/live-vmm-sandboxer" "$BACKUP_DIR/live-kuasar.img"

PATCH_IMAGE="$BACKUP_DIR/kuasar-union.img"
sudo cp --reflink=auto "$LIVE_IMAGE" "$PATCH_IMAGE"
LOOP_DEVICE="$(sudo losetup --find --show --partscan "$PATCH_IMAGE")"
for _ in $(seq 1 20); do
  PART_DEVICE="$(lsblk -nrpo NAME,TYPE "$LOOP_DEVICE" 2>/dev/null | awk '$2 == "part" { print $1; exit }')"
  [ -n "$PART_DEVICE" ] && break
  sleep 0.2
done
if [ -z "$PART_DEVICE" ]; then
  # Some distributed kuasar.img copies have a stale/corrupt backup GPT header
  # after the image was resized. The primary entry remains usable, but the
  # kernel refuses to create loopNp1. Mount that primary entry by offset on
  # the disposable patch image instead of rewriting the live image's GPT.
  PART_START="$(sgdisk -i 1 "$PATCH_IMAGE" 2>/dev/null | awk -F': *' '/First sector:/ { print $2 }' | awk '{ print $1 }')"
  PART_END="$(sgdisk -i 1 "$PATCH_IMAGE" 2>/dev/null | awk -F': *' '/Last sector:/ { print $2 }' | awk '{ print $1 }')"
  if [[ "$PART_START" =~ ^[0-9]+$ ]] && [[ "$PART_END" =~ ^[0-9]+$ ]] && [ "$PART_END" -ge "$PART_START" ]; then
    PART_OFFSET_BYTES=$((PART_START * 512))
    PART_SIZE_BYTES=$(((PART_END - PART_START + 1) * 512))
    sudo losetup -d "$LOOP_DEVICE"
    LOOP_DEVICE=''
    LOOP_DEVICE="$(sudo losetup --find --show --offset "$PART_OFFSET_BYTES" --sizelimit "$PART_SIZE_BYTES" "$PATCH_IMAGE")"
    PART_DEVICE="$LOOP_DEVICE"
    printf '%s\n' \
      "partition scan unavailable; using primary GPT entry by offset" \
      "  start_sector=$PART_START" \
      "  end_sector=$PART_END" \
      "  loop_device=$PART_DEVICE"
  else
    echo "error: no partition discovered for $LOOP_DEVICE and primary GPT entry is unavailable" >&2
    exit 1
  fi
fi
MOUNT_DIR="$(mktemp -d /tmp/openclaw-union-image.XXXXXX)"
sudo mount -o rw "$PART_DEVICE" "$MOUNT_DIR"
MOUNTED=1
sudo test -x "$MOUNT_DIR/sbin/init" || { echo "error: guest image has no executable /sbin/init" >&2; exit 1; }
sudo install -m 0755 "$TASK_BIN" "$MOUNT_DIR/sbin/init"
sudo sync
sudo umount "$MOUNT_DIR"
MOUNTED=0
rmdir "$MOUNT_DIR"
MOUNT_DIR=''
sudo losetup -d "$LOOP_DEVICE"
LOOP_DEVICE=''

sudo install -m 0755 "$SANDBOXER_BIN" "$LIVE_SANDBOXER"
sudo install -m 0644 "$PATCH_IMAGE" "$LIVE_IMAGE"
INSTALLED=1
sudo systemctl daemon-reload
sudo systemctl start "$VMM_UNIT"
sudo systemctl is-active --quiet "$VMM_UNIT"
sudo systemctl start "$CONTAINERD_UNIT"
sudo systemctl is-active --quiet "$CONTAINERD_UNIT"

HOST_SHA="$(sha256sum "$SANDBOXER_BIN" | awk '{print $1}')"
TASK_SHA="$(sha256sum "$TASK_BIN" | awk '{print $1}')"
IMAGE_SHA="$(sudo sha256sum "$LIVE_IMAGE" | awk '{print $1}')"
sudo tee "$BACKUP_DIR/manifest.txt" >/dev/null <<EOF
host_sandboxer_sha256=$HOST_SHA
guest_task_sha256=$TASK_SHA
installed_image_sha256=$IMAGE_SHA
live_sandboxer=$LIVE_SANDBOXER
live_image=$LIVE_IMAGE
unit=$VMM_UNIT
EOF
sudo chown -R "$(id -u):$(id -g)" "$BACKUP_DIR"
trap - EXIT
printf '%s\n' \
  "status=PASS" \
  "backup=$BACKUP_DIR" \
  "host_sandboxer_sha256=$HOST_SHA" \
  "guest_task_sha256=$TASK_SHA" \
  "installed_image_sha256=$IMAGE_SHA"
