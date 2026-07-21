#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${STRACE_IMAGE:-localhost/openclaw-kuasar:2026.6.11-virtiofs-strace}"
PROXY="${BUILD_PROXY:-http://127.0.0.1:17890}"
ENDPOINT="${CRI_ENDPOINT:-/run/openclaw-kuasar/containerd.sock}"

sudo docker build --network host \
  --build-arg "HTTP_PROXY=$PROXY" \
  --build-arg "HTTPS_PROXY=$PROXY" \
  --build-arg "http_proxy=$PROXY" \
  --build-arg "https_proxy=$PROXY" \
  -t "$IMAGE" "$ROOT_DIR/images/openclaw-strace"

sudo docker save "$IMAGE" |
  sudo ctr --address "$ENDPOINT" --namespace k8s.io images import -

sudo crictl \
  --runtime-endpoint "unix://$ENDPOINT" \
  --image-endpoint "unix://$ENDPOINT" \
  images |
  grep 'openclaw-kuasar' |
  grep 'virtiofs-strace'
