#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/config/versions.env"
CACHE_DIR="$ROOT_DIR/.cache/runtime"
STAGE_DIR="$CACHE_DIR/stage"

if [ "${1:-}" = "--print-manifest" ]; then
  printf 'kuasar=%s\ncloud-hypervisor=%s\ndestination=.cache/runtime/stage\n' \
    "$KUASAR_VERSION" "$CLOUD_HYPERVISOR_VERSION"
  exit 0
fi

for command_name in curl sha256sum tar install; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: required command not found: $command_name" >&2
    exit 1
  fi
done

mkdir -p "$CACHE_DIR" "$STAGE_DIR"
kuasar_archive="$CACHE_DIR/kuasar-$KUASAR_VERSION-linux-amd64.tar.gz"
cloud_binary="$CACHE_DIR/cloud-hypervisor-$CLOUD_HYPERVISOR_VERSION"

curl --fail --location --retry 3 --output "$kuasar_archive" "$KUASAR_URL"
printf '%s  %s\n' "$KUASAR_SHA256" "$kuasar_archive" | sha256sum --check --status

curl --fail --location --retry 3 --output "$cloud_binary" "$CLOUD_HYPERVISOR_URL"
printf '%s  %s\n' "$CLOUD_HYPERVISOR_SHA256" "$cloud_binary" | sha256sum --check --status

archive_root="kuasar-${KUASAR_VERSION}-linux-amd64"
for name in containerd vmm-sandboxer runc-sandboxer vmlinux.bin kuasar.img; do
  tar -xOf "$kuasar_archive" "$archive_root/$name" > "$STAGE_DIR/$name"
done
install -m 0755 "$cloud_binary" "$STAGE_DIR/cloud-hypervisor"
chmod 0755 "$STAGE_DIR/containerd" "$STAGE_DIR/vmm-sandboxer" "$STAGE_DIR/runc-sandboxer"
chmod 0644 "$STAGE_DIR/vmlinux.bin" "$STAGE_DIR/kuasar.img"

"$STAGE_DIR/cloud-hypervisor" --version | grep -F "$CLOUD_HYPERVISOR_VERSION"
"$STAGE_DIR/containerd" --version
"$STAGE_DIR/vmm-sandboxer" --version
sha256sum "$STAGE_DIR"/* > "$CACHE_DIR/stage.sha256"
