#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="$ROOT_DIR/images/openclaw"

mkdir -p "$IMAGE_DIR"

cat > "$IMAGE_DIR/README.md" <<'EOF'
# OpenClaw Image Context

Place the OpenClaw source tree here, or replace this directory with a checked
out OpenClaw repository.

The build script expects a Dockerfile in this directory. If the upstream
OpenClaw repository already contains one, keep it. Otherwise create one that
runs the OpenClaw Gateway as the container entrypoint.

Target image tag:

```text
localhost/openclaw-gateway:experiment
```
EOF

echo "Prepared image context at: $IMAGE_DIR"
echo "Next: add the OpenClaw source and Dockerfile, then run ./scripts/02-build-openclaw-image.sh"

