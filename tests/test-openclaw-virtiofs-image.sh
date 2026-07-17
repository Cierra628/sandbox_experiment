#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="$ROOT_DIR/images/openclaw-virtiofs"

grep -Fqx 'FROM ghcr.io/openclaw/openclaw:2026.6.11' "$IMAGE_DIR/Dockerfile"
grep -Fq '"virtiofs"' "$IMAGE_DIR/patch-sqlite-virtiofs.mjs"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/sqlite-wal-fixture.js" <<'FIXTURE'
const NETWORK_FILESYSTEM_TYPES = new Set([
	"cifs"
]);
FIXTURE

node "$IMAGE_DIR/patch-sqlite-virtiofs.mjs" "$fixture" >/dev/null
grep -Fq $'\t"virtiofs",' "$fixture/sqlite-wal-fixture.js"

echo 'PASS: OpenClaw virtiofs image patch'
