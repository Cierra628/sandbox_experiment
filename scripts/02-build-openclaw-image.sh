#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="${OPENCLAW_IMAGE_DIR:-$ROOT_DIR/images/openclaw}"
if [ -f "$ROOT_DIR/config/versions.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/config/versions.env"
fi
IMAGE_TAG="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:2026.6.11}"
CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"

# The default path is the official, version-pinned image. A local build is
# opt-in only, so a missing Dockerfile never blocks the supported workflow.
if [ -z "${OPENCLAW_IMAGE_DIR:-}" ] && [ ! -f "$IMAGE_DIR/Dockerfile" ]; then
  if ! command -v crictl >/dev/null 2>&1; then
    echo "error: crictl is required to pull the official image" >&2
    exit 1
  fi
  if [ "${RUN_CRICTL:-0}" != "1" ]; then
    printf 'Planned CRI pull: %s\nEndpoint: %s\n' "$IMAGE_TAG" "$CRI_ENDPOINT"
    echo 'Set RUN_CRICTL=1 to execute the pull.'
    exit 0
  fi
  pull_timeout="${CRICTL_PULL_TIMEOUT:-20m}"
  pull_retries="${CRICTL_PULL_RETRIES:-3}"
  pulled=0
  for attempt in $(seq 1 "$pull_retries"); do
    printf 'Pulling %s (attempt %s/%s, timeout %s)\n' "$IMAGE_TAG" "$attempt" "$pull_retries" "$pull_timeout" >&2
    if sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT" pull --pull-timeout "$pull_timeout" "$IMAGE_TAG"; then
      pulled=1
      break
    fi
    [ "$attempt" -lt "$pull_retries" ] && sleep 5
done
  if [ "$pulled" != 1 ]; then
    echo 'error: CRI pull failed after retries; check GHCR/proxy connectivity' >&2
    exit 1
  fi
  sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT" images --digests | grep -F 'ghcr.io/openclaw/openclaw'
  exit 0
fi

if [ ! -f "$IMAGE_DIR/Dockerfile" ]; then
  echo "error: missing Dockerfile at $IMAGE_DIR/Dockerfile" >&2
  echo 'Set OPENCLAW_IMAGE_DIR to a directory containing an explicit custom Dockerfile.' >&2
  exit 1
fi

if command -v nerdctl >/dev/null 2>&1; then
  BUILDER=(nerdctl build)
elif command -v docker >/dev/null 2>&1; then
  BUILDER=(docker build)
elif command -v podman >/dev/null 2>&1; then
  BUILDER=(podman build)
else
  echo 'error: no supported image builder found; install nerdctl, docker, or podman' >&2
  exit 1
fi

printf 'Building custom image %s from %s\n' "$IMAGE_TAG" "$IMAGE_DIR"
"${BUILDER[@]}" -t "$IMAGE_TAG" "$IMAGE_DIR"
printf '%s\n' 'Image build completed. Import it into the dedicated containerd namespace before CRI use.'
