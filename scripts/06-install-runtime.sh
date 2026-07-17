#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_DIR="$ROOT_DIR/.cache/runtime/stage"
CHECKSUM_FILE="$ROOT_DIR/.cache/runtime/stage.sha256"
INSTALL_DIR="/usr/local/libexec/openclaw-kuasar"
CONFIG_DIR="/etc/openclaw-kuasar"
DATA_DIR="/var/lib/openclaw-kuasar"
RUN_DIR="/run/openclaw-kuasar"

print_plan() {
  printf '%s\n' \
    "install runtime binaries -> $INSTALL_DIR/containerd" \
    "install runtime binaries -> $INSTALL_DIR/runc-sandboxer" \
    "install runtime binaries -> $INSTALL_DIR/vmm-sandboxer" \
    "install runtime binaries -> $INSTALL_DIR/cloud-hypervisor" \
    "install config -> $CONFIG_DIR/containerd.toml" \
    "install config -> $CONFIG_DIR/vmm.toml" \
    "install services -> /etc/systemd/system/openclaw-kuasar-{runc,vmm,containerd}.service" \
    'enable and start only the three openclaw-kuasar services' \
    'existing /usr/bin/containerd and /etc/containerd/config.toml are not modified'
}

if [ "${1:-}" = --print-plan ]; then
  print_plan
  exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo 'error: installation requires root; re-run with sudo' >&2; exit 1; }
[ -f "$CHECKSUM_FILE" ] || { echo "error: missing verified stage checksum: $CHECKSUM_FILE" >&2; exit 1; }
for name in containerd runc-sandboxer vmm-sandboxer cloud-hypervisor vmlinux.bin kuasar.img; do
  [ -e "$STAGE_DIR/$name" ] || { echo "error: missing staged artifact: $STAGE_DIR/$name" >&2; exit 1; }
done
(
  cd "$ROOT_DIR"
  sha256sum --check "$CHECKSUM_FILE"
)

if [ -e "$INSTALL_DIR/containerd" ] && ! cmp -s "$STAGE_DIR/containerd" "$INSTALL_DIR/containerd"; then
  echo 'error: a different experiment containerd binary is already installed; refusing overwrite' >&2
  exit 1
fi

install -d -m 0755 "$INSTALL_DIR"
install -m 0755 "$STAGE_DIR/containerd" "$INSTALL_DIR/containerd"
install -m 0755 "$STAGE_DIR/runc-sandboxer" "$INSTALL_DIR/runc-sandboxer"
install -m 0755 "$STAGE_DIR/vmm-sandboxer" "$INSTALL_DIR/vmm-sandboxer"
install -m 0755 "$STAGE_DIR/cloud-hypervisor" "$INSTALL_DIR/cloud-hypervisor"
install -d -m 0755 "$CONFIG_DIR" "$DATA_DIR/kuasar" "$DATA_DIR/containerd" "$DATA_DIR/runc" "$DATA_DIR/vmm" "$RUN_DIR"
install -m 0644 "$STAGE_DIR/vmlinux.bin" "$DATA_DIR/kuasar/vmlinux.bin"
install -m 0644 "$STAGE_DIR/kuasar.img" "$DATA_DIR/kuasar/kuasar.img"
install -m 0644 "$ROOT_DIR/containerd/kuasar-containerd.toml" "$CONFIG_DIR/containerd.toml"
install -d -m 0755 "$CONFIG_DIR/cni"
install -m 0644 "$ROOT_DIR/containerd/cni/10-openclaw-bridge.conflist" "$CONFIG_DIR/cni/10-openclaw-bridge.conflist"
install -m 0644 "$ROOT_DIR/containerd/kuasar-vmm.toml" "$CONFIG_DIR/vmm.toml"
install -m 0644 "$ROOT_DIR/systemd/openclaw-kuasar-runc.service" /etc/systemd/system/openclaw-kuasar-runc.service
install -m 0644 "$ROOT_DIR/systemd/openclaw-kuasar-vmm.service" /etc/systemd/system/openclaw-kuasar-vmm.service
install -m 0644 "$ROOT_DIR/systemd/openclaw-kuasar-containerd.service" /etc/systemd/system/openclaw-kuasar-containerd.service

systemctl daemon-reload
systemctl enable --now openclaw-kuasar-runc.service openclaw-kuasar-vmm.service openclaw-kuasar-containerd.service
for service in openclaw-kuasar-runc.service openclaw-kuasar-vmm.service openclaw-kuasar-containerd.service; do
  if ! systemctl is-active --quiet "$service"; then
    systemctl --no-pager --full status "$service" >&2 || true
    echo "error: $service did not become active" >&2
    exit 1
  fi
done
printf '%s\n' 'Installed and started the isolated OpenClaw Kuasar runtime stack.'
