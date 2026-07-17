#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

check_cmd() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    printf 'ok: %s -> %s\n' "$name" "$(command -v "$name")"
  else
    printf 'missing: %s\n' "$name"
  fi
}

section "Host"
uname -a

section "CPU virtualization"
if grep -Eq 'vmx|svm' /proc/cpuinfo; then
  echo "ok: CPU virtualization flag is present"
else
  echo "missing: CPU virtualization flag was not found"
fi

if [ -e /dev/kvm ]; then
  ls -l /dev/kvm
else
  echo "missing: /dev/kvm; Kuasar VMM experiments may not work"
fi

section "Container runtime tools"
check_cmd containerd
check_cmd ctr
check_cmd crictl
check_cmd nerdctl
check_cmd docker
check_cmd podman

section "Kuasar binaries"
check_cmd containerd-shim-runc-v2
check_cmd kuasar-runc
check_cmd vmm-sandboxer
check_cmd quark-sandboxer
check_cmd wasm-sandboxer

section "Experiment runtime access"
for path in /run/containerd/containerd.sock /var/run/docker.sock /dev/kvm; do
  if [ -e "$path" ]; then
    namei -l "$path"
  else
    printf 'missing: %s\n' "$path"
  fi
done

section "Build and VMM dependencies"
for name in jq curl sha256sum systemctl cloud-hypervisor vmm-sandboxer virtiofsd; do
  check_cmd "$name"
done

section "Pinned experiment"
printf '%s\n' \
  'Kuasar: v1.1.0' \
  'Cloud Hypervisor: v52.0' \
  'OpenClaw: 2026.6.11' \
  'CRI endpoint: unix:///run/openclaw-kuasar/containerd.sock'

section "Notes"
echo "This script only reports host state. It does not install packages or edit system configuration."

