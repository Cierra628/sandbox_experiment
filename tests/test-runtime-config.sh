#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/config/versions.env"

test "$KUASAR_VERSION" = "v1.1.0"
test "$KUASAR_SHA256" = "05b1aa9048ff2267302b4f16077c0b0bd73c3616d62644003a67ea33df72ca8b"
test "$CLOUD_HYPERVISOR_VERSION" = "v52.0"
test "$CLOUD_HYPERVISOR_SHA256" = "829af01ff075bb96c4f183905134c453a88d68cbabdc6b87df21098842581ee9"
test "$OPENCLAW_IMAGE" = "localhost/openclaw-kuasar:2026.6.11-virtiofs"
test "$CRI_ENDPOINT" = "unix:///run/openclaw-kuasar/containerd.sock"

if [ -f "$ROOT_DIR/containerd/kuasar-containerd.toml" ]; then
  grep -q 'root = "/var/lib/openclaw-kuasar/containerd"' "$ROOT_DIR/containerd/kuasar-containerd.toml"
  grep -q 'address = "/run/openclaw-kuasar/containerd.sock"' "$ROOT_DIR/containerd/kuasar-containerd.toml"
  grep -q 'conf_dir = "/etc/openclaw-kuasar/cni"' "$ROOT_DIR/containerd/kuasar-containerd.toml"
  jq -e '[.plugins[0].ipam.ranges[][] | has("subnet")] == [true]' "$ROOT_DIR/containerd/cni/10-openclaw-bridge.conflist" >/dev/null
  ! grep -q '::' "$ROOT_DIR/containerd/cni/10-openclaw-bridge.conflist"
  jq -e 'any(.plugins[]; .type == "tuning" and .sysctl["net.ipv6.conf.IFNAME.disable_ipv6"] == "1")' "$ROOT_DIR/containerd/cni/10-openclaw-bridge.conflist" >/dev/null
  jq -e 'any(.plugins[]; .type == "firewall" and .ingressPolicy == "same-bridge")' "$ROOT_DIR/containerd/cni/10-openclaw-bridge.conflist" >/dev/null
  ! grep -q '/run/containerd/containerd.sock' "$ROOT_DIR/containerd/kuasar-containerd.toml"
fi

manifest="$($ROOT_DIR/scripts/05-fetch-runtime.sh --print-manifest)"
grep -q 'kuasar=v1.1.0' <<<"$manifest"
grep -q 'cloud-hypervisor=v52.0' <<<"$manifest"
grep -q 'destination=.cache/runtime/stage' <<<"$manifest"
if [ -f "$ROOT_DIR/containerd/kuasar-containerd.toml" ]; then
  grep -q 'runtime_type = "io.containerd.kuasar-vmm.v1"' "$ROOT_DIR/containerd/kuasar-containerd.toml"
  grep -q 'address = "/run/openclaw-kuasar/vmm-sandboxer.sock"' "$ROOT_DIR/containerd/kuasar-containerd.toml"
  grep -q 'enable_environment_restore = false' "$ROOT_DIR/containerd/kuasar-vmm.toml"
  grep -q 'enable_warmfork_restore = false' "$ROOT_DIR/containerd/kuasar-vmm.toml"
  grep -q 'enable_continuation_restore = false' "$ROOT_DIR/containerd/kuasar-vmm.toml"
  grep -q 'container_storage_backend = "virtiofs"' "$ROOT_DIR/containerd/kuasar-vmm.toml"
  grep -q 'path = "/usr/libexec/virtiofsd"' "$ROOT_DIR/containerd/kuasar-vmm.toml"
  grep -q 'Environment=ENABLE_CRI_SANDBOXES=1' "$ROOT_DIR/systemd/openclaw-kuasar-containerd.service"
  ! rg -n '/usr/bin/containerd|/etc/containerd/config.toml' "$ROOT_DIR/systemd" "$ROOT_DIR/containerd/kuasar-containerd.toml"
fi
install_plan="$($ROOT_DIR/scripts/06-install-runtime.sh --print-plan)"
grep -q '/usr/local/libexec/openclaw-kuasar/containerd' <<<"$install_plan"
grep -q '/etc/openclaw-kuasar/containerd.toml' <<<"$install_plan"
! grep -q 'replace /usr/bin/containerd' <<<"$install_plan"
printf "%s\n" "test-runtime-config: PASS"
  grep -q 'Type=simple' "$ROOT_DIR/systemd/openclaw-kuasar-runc.service"
  grep -q 'Environment=HTTPS_PROXY=http://127.0.0.1:17890' "$ROOT_DIR/systemd/openclaw-kuasar-containerd.service"
