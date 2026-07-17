# OpenClaw Kuasar Cloud Hypervisor Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a repeatable command-line platform that deploys OpenClaw 2026.6.11 through an isolated containerd, Kuasar v1.1.0, and Cloud Hypervisor v52.0 stack and proves the complete runtime chain.

**Architecture:** Install the version-matched Kuasar release artifacts under dedicated paths and run the bundled containerd v2 beside the host's existing containerd 1.7.27. A small shell platform drives CRI through a dedicated socket, records non-secret state, proves the Kuasar/Cloud Hypervisor placement, and cleans up idempotently.

**Tech Stack:** Bash, jq, crictl v1.31.1, Kuasar v1.1.0, Kuasar-bundled containerd v2, Cloud Hypervisor v52.0, KVM, systemd, CRI JSON, official OpenClaw image `ghcr.io/openclaw/openclaw:2026.6.11`.

## Global Constraints

- Final execution path: `platform -> CRI -> isolated containerd -> Kuasar vmm-sandboxer -> Cloud Hypervisor -> OpenClaw`.
- Never overwrite `/usr/bin/containerd`, `/etc/containerd/config.toml`, `/etc/crictl.yaml`, or the existing Kata installation.
- Install experiment runtime binaries under `/usr/local/libexec/openclaw-kuasar` only.
- Store experiment system configuration under `/etc/openclaw-kuasar` and runtime data under `/var/lib/openclaw-kuasar`.
- Use the dedicated CRI socket `unix:///run/openclaw-kuasar/containerd.sock` in every command.
- Kuasar release: `v1.1.0`, release commit `0f804a9599392ff02f8368cd5b823482201149e1`.
- Kuasar archive SHA-256: `05b1aa9048ff2267302b4f16077c0b0bd73c3616d62644003a67ea33df72ca8b`.
- Cloud Hypervisor release: `v52.0`; static binary SHA-256: `829af01ff075bb96c4f183905134c453a88d68cbabdc6b87df21098842581ee9`.
- OpenClaw image tag: `ghcr.io/openclaw/openclaw:2026.6.11`; record the resolved OCI digest after pulling.
- Run the final VMM path with runtime handler `kuasar-vmm`; never fall back to `runc`.
- Use cold boot for the first deliverable. Disable Environment Restore, WarmFork, and Continuation Restore.
- Keep provider credentials outside the repository under `$HOME/.local/share/openclaw-kuasar/openclaw-state` with mode `0700`.
- Never print, archive, or commit OpenClaw configuration, `.env`, OAuth material, or provider keys.
- Ask for explicit approval immediately before package installation, writes under `/usr/local`, `/etc`, or `/var/lib`, or systemd service changes.
- This directory is not a Git repository. Replace commit steps with checksum checkpoints under `.artifacts/checkpoints/`.

---

## File Map

### Create

- `config/versions.env` — immutable release URLs and SHA-256 values.
- `containerd/kuasar-containerd.toml` — isolated containerd v3 configuration.
- `containerd/kuasar-vmm.toml` — cold-boot Cloud Hypervisor configuration.
- `containerd/smoke-pod.json` — minimal host-network sandbox used for runtime gates.
- `containerd/smoke-container.json` — pinned BusyBox workload used for runtime gates.
- `systemd/openclaw-kuasar-runc.service` — time-boxed Kuasar runc sandboxer.
- `systemd/openclaw-kuasar-vmm.service` — Kuasar VMM sandboxer.
- `systemd/openclaw-kuasar-containerd.service` — isolated containerd daemon.
- `scripts/05-fetch-runtime.sh` — download and verify pinned runtime artifacts.
- `scripts/06-install-runtime.sh` — install the isolated runtime stack after approval.
- `scripts/07-prepare-openclaw-state.sh` — copy and rewrite a dedicated OpenClaw state directory without displaying secrets.
- `scripts/openclaw-platform` — `deploy`, `status`, `logs`, `demo`, and `delete` commands.
- `tests/test-runtime-config.sh` — verify isolation, version pins, and VMM cold-boot settings.
- `tests/test-cri-specs.sh` — verify generated CRI specs and secret-safe mounts.
- `tests/test-platform-cli.sh` — test command parsing, dry-run behavior, and missing-handler failure.
- `.gitignore` — exclude `.cache`, `.state`, `.artifacts`, and local secret paths if Git is initialized later.

### Modify

- `scripts/00-check-host.sh` — report isolated-stack prerequisites and exact permissions.
- `scripts/02-build-openclaw-image.sh` — make the official pinned image the default and support CRI pull instead of requiring a Docker build.
- `scripts/03-generate-cri-specs.sh` — generate explicit OpenClaw commands, environment, UID/GID, and state mount; do not put a runtime handler in the JSON.
- `scripts/04-run-with-crictl.sh` — accept endpoint and handler arguments and persist lifecycle IDs safely.
- `images/openclaw/README.md` — document the official-image strategy.
- `README.md` — document the platform workflow and proof commands.
- `HANDOFF.md` — update verified state after each passed gate.

## Task 1: Freeze Versions and Strengthen Host Preflight

**Files:**
- Create: `config/versions.env`
- Modify: `scripts/00-check-host.sh`
- Create: `.gitignore`
- Test: `tests/test-runtime-config.sh`

**Interfaces:**
- Produces: shell variables `KUASAR_VERSION`, `KUASAR_URL`, `KUASAR_SHA256`, `CLOUD_HYPERVISOR_VERSION`, `CLOUD_HYPERVISOR_URL`, `CLOUD_HYPERVISOR_SHA256`, `OPENCLAW_IMAGE`, and `CRI_ENDPOINT`.
- Consumes: no earlier task output.

- [ ] **Step 1: Write the failing configuration test**

Create `tests/test-runtime-config.sh` with assertions for exact pins and isolation:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/config/versions.env"

test "$KUASAR_VERSION" = "v1.1.0"
test "$KUASAR_SHA256" = "05b1aa9048ff2267302b4f16077c0b0bd73c3616d62644003a67ea33df72ca8b"
test "$CLOUD_HYPERVISOR_VERSION" = "v52.0"
test "$CLOUD_HYPERVISOR_SHA256" = "829af01ff075bb96c4f183905134c453a88d68cbabdc6b87df21098842581ee9"
test "$OPENCLAW_IMAGE" = "ghcr.io/openclaw/openclaw:2026.6.11"
test "$CRI_ENDPOINT" = "unix:///run/openclaw-kuasar/containerd.sock"

if [ -f "$ROOT_DIR/containerd/kuasar-containerd.toml" ]; then
  grep -q 'root = "/var/lib/openclaw-kuasar/containerd"' "$ROOT_DIR/containerd/kuasar-containerd.toml"
  grep -q 'address = "/run/openclaw-kuasar/containerd.sock"' "$ROOT_DIR/containerd/kuasar-containerd.toml"
  ! grep -q '/run/containerd/containerd.sock' "$ROOT_DIR/containerd/kuasar-containerd.toml"
fi
```

- [ ] **Step 2: Run the test and verify the missing manifest fails**

Run: `bash tests/test-runtime-config.sh`

Expected: non-zero exit because `config/versions.env` does not exist.

- [ ] **Step 3: Create the version manifest**

Create `config/versions.env`:

```bash
KUASAR_VERSION=v1.1.0
KUASAR_URL=https://github.com/kuasar-io/kuasar/releases/download/v1.1.0/kuasar-v1.1.0-linux-amd64.tar.gz
KUASAR_SHA256=05b1aa9048ff2267302b4f16077c0b0bd73c3616d62644003a67ea33df72ca8b
CLOUD_HYPERVISOR_VERSION=v52.0
CLOUD_HYPERVISOR_URL=https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v52.0/cloud-hypervisor-static
CLOUD_HYPERVISOR_SHA256=829af01ff075bb96c4f183905134c453a88d68cbabdc6b87df21098842581ee9
OPENCLAW_IMAGE=${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:2026.6.11}
CRI_ENDPOINT=unix:///run/openclaw-kuasar/containerd.sock
RUNTIME_HANDLER=kuasar-vmm
```

- [ ] **Step 4: Extend host checks without changing the host**

Add checks to `scripts/00-check-host.sh` for:

```bash
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
```

- [ ] **Step 5: Add local-output exclusions**

Create `.gitignore`:

```gitignore
.cache/
.state/
.artifacts/
.secrets/
images/openclaw/*.tar
```

- [ ] **Step 6: Verify and record the checkpoint**

Run:

```bash
bash -n scripts/00-check-host.sh tests/test-runtime-config.sh
bash tests/test-runtime-config.sh
mkdir -p .artifacts/checkpoints
sha256sum config/versions.env scripts/00-check-host.sh tests/test-runtime-config.sh > .artifacts/checkpoints/task-01.sha256
```

Expected: both checks pass and the checkpoint contains three hashes.

## Task 2: Fetch and Verify the Version-Matched Runtime Bundle

**Files:**
- Create: `scripts/05-fetch-runtime.sh`
- Modify: `tests/test-runtime-config.sh`

**Interfaces:**
- Consumes: `config/versions.env` from Task 1.
- Produces: verified files under `.cache/runtime/stage/`: `containerd`, `vmm-sandboxer`, `runc-sandboxer`, `vmlinux.bin`, `kuasar.img`, and `cloud-hypervisor`.

- [ ] **Step 1: Add a failing manifest-mode test**

Append to `tests/test-runtime-config.sh`:

```bash
manifest="$($ROOT_DIR/scripts/05-fetch-runtime.sh --print-manifest)"
grep -q 'kuasar=v1.1.0' <<<"$manifest"
grep -q 'cloud-hypervisor=v52.0' <<<"$manifest"
grep -q 'destination=.cache/runtime/stage' <<<"$manifest"
```

- [ ] **Step 2: Verify the new test fails**

Run: `bash tests/test-runtime-config.sh`

Expected: failure because `scripts/05-fetch-runtime.sh` is absent.

- [ ] **Step 3: Implement verified fetching**

Create `scripts/05-fetch-runtime.sh` with this behavior:

```bash
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

"$STAGE_DIR/cloud-hypervisor" --version | grep -F 'v52.0'
"$STAGE_DIR/containerd" --version
"$STAGE_DIR/vmm-sandboxer" --version
sha256sum "$STAGE_DIR"/* > "$CACHE_DIR/stage.sha256"
```

- [ ] **Step 4: Run offline syntax and manifest tests**

Run:

```bash
chmod +x scripts/05-fetch-runtime.sh tests/test-runtime-config.sh
bash -n scripts/05-fetch-runtime.sh
bash tests/test-runtime-config.sh
```

Expected: PASS without a network download because the test uses `--print-manifest`.

- [ ] **Step 5: Fetch artifacts after network approval**

Run: `./scripts/05-fetch-runtime.sh`

Expected: checksum verification succeeds; `.cache/runtime/stage/cloud-hypervisor --version` prints `v52.0`.

- [ ] **Step 6: Record the checkpoint**

Run:

```bash
sha256sum scripts/05-fetch-runtime.sh tests/test-runtime-config.sh > .artifacts/checkpoints/task-02.sha256
cp .cache/runtime/stage.sha256 .artifacts/checkpoints/runtime-stage.sha256
```

## Task 3: Define an Isolated containerd and Kuasar Service Stack

**Files:**
- Create: `containerd/kuasar-containerd.toml`
- Create: `containerd/kuasar-vmm.toml`
- Create: `systemd/openclaw-kuasar-runc.service`
- Create: `systemd/openclaw-kuasar-vmm.service`
- Create: `systemd/openclaw-kuasar-containerd.service`
- Modify: `tests/test-runtime-config.sh`

**Interfaces:**
- Consumes: runtime binary paths installed by Task 4.
- Produces: CRI endpoint `/run/openclaw-kuasar/containerd.sock`; runtime handlers `runc`, `kuasar-runc`, and `kuasar-vmm`.

- [ ] **Step 1: Add failing isolation and cold-boot assertions**

Append to `tests/test-runtime-config.sh`:

```bash
grep -q 'runtime_type = "io.containerd.kuasar-vmm.v1"' "$ROOT_DIR/containerd/kuasar-containerd.toml"
grep -q 'address = "/run/openclaw-kuasar/vmm-sandboxer.sock"' "$ROOT_DIR/containerd/kuasar-containerd.toml"
grep -q 'enable_environment_restore = false' "$ROOT_DIR/containerd/kuasar-vmm.toml"
grep -q 'enable_warmfork_restore = false' "$ROOT_DIR/containerd/kuasar-vmm.toml"
grep -q 'enable_continuation_restore = false' "$ROOT_DIR/containerd/kuasar-vmm.toml"
grep -q 'container_storage_backend = "virtio-blk"' "$ROOT_DIR/containerd/kuasar-vmm.toml"
grep -q 'Environment=ENABLE_CRI_SANDBOXES=1' "$ROOT_DIR/systemd/openclaw-kuasar-containerd.service"
! rg -n '/usr/bin/containerd|/etc/containerd/config.toml' "$ROOT_DIR/systemd" "$ROOT_DIR/containerd/kuasar-containerd.toml"
```

- [ ] **Step 2: Run the test and verify missing files fail**

Run: `bash tests/test-runtime-config.sh`

Expected: non-zero exit on the first absent configuration file.

- [ ] **Step 3: Create the isolated containerd configuration**

Create `containerd/kuasar-containerd.toml`:

```toml
version = 3
root = "/var/lib/openclaw-kuasar/containerd"
state = "/run/openclaw-kuasar/containerd-state"

[grpc]
address = "/run/openclaw-kuasar/containerd.sock"

[plugins.'io.containerd.cri.v1.runtime']
disable_apparmor = true

[plugins.'io.containerd.cri.v1.runtime'.containerd]
default_runtime_name = "runc"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
runtime_type = "io.containerd.runc.v2"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kuasar-runc]
runtime_type = "io.containerd.kuasar-runc.v1"
sandboxer = "runc"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kuasar-vmm]
runtime_type = "io.containerd.kuasar-vmm.v1"
sandboxer = "vmm"
io_type = "streaming"

[proxy_plugins.runc]
type = "sandbox"
address = "/run/openclaw-kuasar/runc-sandboxer.sock"

[proxy_plugins.vmm]
type = "sandbox"
address = "/run/openclaw-kuasar/vmm-sandboxer.sock"
```

- [ ] **Step 4: Create the cold-boot VMM configuration**

Create `containerd/kuasar-vmm.toml`:

```toml
[sandbox]
log_level = "info"
enable_tracing = false

[sandbox.snapshot]
enable_environment_restore = false
enable_warmfork_restore = false
enable_continuation_restore = false
max_concurrent_restores = 1
fallback_to_fresh_boot = true
default_memory_restore_mode = "copy"

[hypervisor]
path = "/usr/local/libexec/openclaw-kuasar/cloud-hypervisor"
vcpus = 2
memory_in_mb = 2048
kernel_path = "/var/lib/openclaw-kuasar/kuasar/vmlinux.bin"
image_path = "/var/lib/openclaw-kuasar/kuasar/kuasar.img"
initrd_path = ""
kernel_params = ""
hugepages = false
entropy_source = "/dev/urandom"
debug = false
container_storage_backend = "virtio-blk"

[hypervisor.virtio_blk]
allow_large_bind_mount = true
enable_reflink_cow = false
block_image_size_overhead_percent = 20
small_dir_max_files = 50
small_dir_max_bytes = 10485760
overlay_image_fallback_size_mb = 128
bind_image_fallback_size_mb = 64
direct_io = true

[hypervisor.task]
debug = false
enable_tracing = false

[hypervisor.virtiofsd]
path = "/usr/local/bin/virtiofsd"
log_level = "info"
cache = "never"
thread_pool_size = 4
syslog = true
```

- [ ] **Step 5: Create systemd units**

Create `systemd/openclaw-kuasar-runc.service`:

```ini
[Unit]
Description=OpenClaw experiment Kuasar runc sandboxer
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/libexec/openclaw-kuasar/runc-sandboxer --listen /run/openclaw-kuasar/runc-sandboxer.sock --dir /var/lib/openclaw-kuasar/runc
Restart=on-failure
Delegate=yes

[Install]
WantedBy=multi-user.target
```

Create `systemd/openclaw-kuasar-vmm.service`:

```ini
[Unit]
Description=OpenClaw experiment Kuasar Cloud Hypervisor sandboxer
After=network.target
ConditionPathExists=/dev/kvm

[Service]
Type=notify
ExecStart=/usr/local/libexec/openclaw-kuasar/vmm-sandboxer --config /etc/openclaw-kuasar/vmm.toml --listen /run/openclaw-kuasar/vmm-sandboxer.sock --admin-listen /run/openclaw-kuasar/vmm-admin.sock --dir /var/lib/openclaw-kuasar/vmm
Restart=on-failure
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
```

Create `systemd/openclaw-kuasar-containerd.service`:

```ini
[Unit]
Description=OpenClaw experiment isolated containerd
After=network.target openclaw-kuasar-runc.service openclaw-kuasar-vmm.service
Requires=openclaw-kuasar-runc.service openclaw-kuasar-vmm.service

[Service]
Type=notify
Environment=ENABLE_CRI_SANDBOXES=1
ExecStart=/usr/local/libexec/openclaw-kuasar/containerd --config /etc/openclaw-kuasar/containerd.toml
Restart=on-failure
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 6: Verify static configuration**

Run:

```bash
bash tests/test-runtime-config.sh
systemd-analyze verify systemd/openclaw-kuasar-runc.service systemd/openclaw-kuasar-vmm.service systemd/openclaw-kuasar-containerd.service
sha256sum containerd/kuasar-*.toml systemd/*.service > .artifacts/checkpoints/task-03.sha256
```

Expected: assertions pass; `systemd-analyze verify` reports no unit syntax errors.

## Task 4: Install and Start the Isolated Runtime

**Files:**
- Create: `scripts/06-install-runtime.sh`
- Modify: `tests/test-runtime-config.sh`

**Interfaces:**
- Consumes: `.cache/runtime/stage/*`, configuration files, and systemd units from Tasks 2–3.
- Produces: installed files under dedicated prefixes and three active services.

- [ ] **Step 1: Add a non-destructive install-script test**

Append to `tests/test-runtime-config.sh`:

```bash
install_plan="$($ROOT_DIR/scripts/06-install-runtime.sh --print-plan)"
grep -q '/usr/local/libexec/openclaw-kuasar/containerd' <<<"$install_plan"
grep -q '/etc/openclaw-kuasar/containerd.toml' <<<"$install_plan"
! grep -q 'replace /usr/bin/containerd' <<<"$install_plan"
```

- [ ] **Step 2: Implement the root-gated installer**

Create `scripts/06-install-runtime.sh` so `--print-plan` works unprivileged and installation refuses non-root execution. The install branch must run exactly these operations:

```bash
install -d -m 0755 /usr/local/libexec/openclaw-kuasar
install -m 0755 .cache/runtime/stage/containerd /usr/local/libexec/openclaw-kuasar/containerd
install -m 0755 .cache/runtime/stage/runc-sandboxer /usr/local/libexec/openclaw-kuasar/runc-sandboxer
install -m 0755 .cache/runtime/stage/vmm-sandboxer /usr/local/libexec/openclaw-kuasar/vmm-sandboxer
install -m 0755 .cache/runtime/stage/cloud-hypervisor /usr/local/libexec/openclaw-kuasar/cloud-hypervisor
install -d -m 0755 /etc/openclaw-kuasar /var/lib/openclaw-kuasar/kuasar /var/lib/openclaw-kuasar/containerd /var/lib/openclaw-kuasar/runc /var/lib/openclaw-kuasar/vmm /run/openclaw-kuasar
install -m 0644 .cache/runtime/stage/vmlinux.bin /var/lib/openclaw-kuasar/kuasar/vmlinux.bin
install -m 0644 .cache/runtime/stage/kuasar.img /var/lib/openclaw-kuasar/kuasar/kuasar.img
install -m 0644 containerd/kuasar-containerd.toml /etc/openclaw-kuasar/containerd.toml
install -m 0644 containerd/kuasar-vmm.toml /etc/openclaw-kuasar/vmm.toml
install -m 0644 systemd/openclaw-kuasar-runc.service /etc/systemd/system/openclaw-kuasar-runc.service
install -m 0644 systemd/openclaw-kuasar-vmm.service /etc/systemd/system/openclaw-kuasar-vmm.service
install -m 0644 systemd/openclaw-kuasar-containerd.service /etc/systemd/system/openclaw-kuasar-containerd.service
systemctl daemon-reload
systemctl enable --now openclaw-kuasar-runc.service openclaw-kuasar-vmm.service openclaw-kuasar-containerd.service
```

Before installing, it must verify all staged checksums with `.cache/runtime/stage.sha256` and abort if `/usr/local/libexec/openclaw-kuasar/containerd --version` already reports a different binary.

- [ ] **Step 3: Run non-privileged tests**

Run:

```bash
chmod +x scripts/06-install-runtime.sh
bash -n scripts/06-install-runtime.sh
bash tests/test-runtime-config.sh
```

Expected: PASS; no system files change.

- [ ] **Step 4: Stop at the privileged approval checkpoint**

Present the exact install paths and service names to the user. Do not continue until approval is granted.

- [ ] **Step 5: Install and verify after approval**

Run:

```bash
sudo ./scripts/06-install-runtime.sh
sudo systemctl --no-pager --full status openclaw-kuasar-runc.service openclaw-kuasar-vmm.service openclaw-kuasar-containerd.service
sudo crictl --runtime-endpoint unix:///run/openclaw-kuasar/containerd.sock --image-endpoint unix:///run/openclaw-kuasar/containerd.sock info
```

Expected: all services are active; CRI info returns JSON; existing `containerd.service` remains active and unchanged.

## Task 5: Correct CRI Spec Generation and Pull the OpenClaw Image

**Files:**
- Modify: `scripts/02-build-openclaw-image.sh`
- Modify: `scripts/03-generate-cri-specs.sh`
- Modify: `scripts/04-run-with-crictl.sh`
- Modify: `images/openclaw/README.md`
- Create: `tests/test-cri-specs.sh`

**Interfaces:**
- Consumes: `OPENCLAW_IMAGE`, `CRI_ENDPOINT`, and runtime handler arguments.
- Produces: valid `openclaw-pod.json`, `openclaw-container.json`, and lifecycle IDs.

- [ ] **Step 1: Write failing CRI assertions**

Create `tests/test-cri-specs.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_state="$(mktemp -d)"
trap 'rm -rf "$tmp_state"' EXIT

OPENCLAW_DATA_DIR="$tmp_state" "$ROOT_DIR/scripts/03-generate-cri-specs.sh"
jq -e '.linux.runtime_handler == null' "$ROOT_DIR/containerd/openclaw-pod.json" >/dev/null
jq -e '.image.image == "ghcr.io/openclaw/openclaw:2026.6.11"' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
jq -e '.command == ["node"]' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
jq -e '.args == ["dist/index.js","gateway","--bind","loopback","--port","18789"]' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
jq -e '.mounts[0].container_path == "/home/node/.openclaw"' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
jq -e '.linux.security_context.run_as_user.value == 1002' "$ROOT_DIR/containerd/openclaw-container.json" >/dev/null
! rg -n 'API_KEY|TOKEN|PASSWORD|SECRET' "$ROOT_DIR/containerd/openclaw-container.json"
```

- [ ] **Step 2: Verify the test fails against current specs**

Run: `bash tests/test-cri-specs.sh`

Expected: failure because the current image, command, mount, and UID are wrong.

- [ ] **Step 3: Update image acquisition**

Make `scripts/02-build-openclaw-image.sh` default to CRI pull:

```bash
source "$ROOT_DIR/config/versions.env"
ENDPOINT="${CRI_ENDPOINT#unix://}"
sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT" pull "$OPENCLAW_IMAGE"
sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT" images --digests | grep -F 'ghcr.io/openclaw/openclaw'
```

Retain local Dockerfile building only when `OPENCLAW_IMAGE_DIR` explicitly points to a directory containing a Dockerfile.

- [ ] **Step 4: Generate explicit, secret-free CRI specs**

Update `scripts/03-generate-cri-specs.sh` to:

- default `OPENCLAW_IMAGE` from `config/versions.env`;
- require an existing `OPENCLAW_DATA_DIR` and never create it under `/tmp`;
- remove `runtime_handler` from pod JSON;
- set host-network namespace mode for the first experiment;
- mount the state directory at `/home/node/.openclaw`;
- set `HOME`, `OPENCLAW_STATE_DIR`, and `OPENCLAW_CONFIG_PATH` to container paths;
- run as UID/GID 1002;
- use command `node dist/index.js gateway --bind loopback --port 18789`;
- set container memory limit to 1610612736 bytes and CPU quota to two cores.

The generated environment block is:

```json
"envs": [
  {"key": "HOME", "value": "/home/node"},
  {"key": "OPENCLAW_STATE_DIR", "value": "/home/node/.openclaw"},
  {"key": "OPENCLAW_CONFIG_PATH", "value": "/home/node/.openclaw/openclaw.json"},
  {"key": "OPENCLAW_DISABLE_BONJOUR", "value": "1"}
]
```

- [ ] **Step 5: Correct runtime selection in the lifecycle script**

Update `scripts/04-run-with-crictl.sh` to build a single CRI command array and accept `POD_SPEC` and `CONTAINER_SPEC` environment overrides:

```bash
source "$ROOT_DIR/config/versions.env"
RUNTIME_HANDLER="${OPENCLAW_RUNTIME_HANDLER:-runc}"
POD_SPEC="${POD_SPEC:-$ROOT_DIR/containerd/openclaw-pod.json}"
CONTAINER_SPEC="${CONTAINER_SPEC:-$ROOT_DIR/containerd/openclaw-container.json}"
CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")
POD_ID="$("${CRI[@]}" runp --runtime "$RUNTIME_HANDLER" "$POD_SPEC")"
CONTAINER_ID="$("${CRI[@]}" create "$POD_ID" "$CONTAINER_SPEC" "$POD_SPEC")"
"${CRI[@]}" start "$CONTAINER_ID"
```

Install an `ERR` trap that captures logs, removes any created container, and removes any created pod. Never write credentials to output.

- [ ] **Step 6: Run static tests**

Run:

```bash
chmod +x tests/test-cri-specs.sh
bash -n scripts/02-build-openclaw-image.sh scripts/03-generate-cri-specs.sh scripts/04-run-with-crictl.sh tests/test-cri-specs.sh
bash tests/test-cri-specs.sh
python3 -m json.tool containerd/openclaw-pod.json >/dev/null
python3 -m json.tool containerd/openclaw-container.json >/dev/null
```

Expected: all commands pass.

- [ ] **Step 7: Pull the image and record its resolved digest**

After privileged approval, run:

```bash
./scripts/02-build-openclaw-image.sh
sudo crictl --runtime-endpoint unix:///run/openclaw-kuasar/containerd.sock --image-endpoint unix:///run/openclaw-kuasar/containerd.sock images --digests | grep -F "ghcr.io/openclaw/openclaw" | tee .artifacts/checkpoints/openclaw-image.txt
```

Expected: the image is present and its digest is recorded. The runc application gate runs after Task 6 prepares the dedicated state copy.

## Task 6: Prepare a Dedicated OpenClaw State Copy

**Files:**
- Create: `scripts/07-prepare-openclaw-state.sh`
- Modify: `tests/test-cri-specs.sh`

**Interfaces:**
- Consumes: host state `$HOME/.openclaw` and host OpenClaw CLI.
- Produces: `$HOME/.local/share/openclaw-kuasar/openclaw-state` owned by UID/GID 1002, mode `0700`, with container-safe workspace paths.

- [ ] **Step 1: Test refusal and path rewriting with a fixture**

Extend `tests/test-cri-specs.sh` to create a fixture containing a minimal `openclaw.json`, invoke `scripts/07-prepare-openclaw-state.sh --source fixture --destination target --test-mode`, and assert:

```bash
test "$(stat -c %a "$target")" = "700"
test "$(jq -r '.agents.defaults.workspace' "$target/openclaw.json")" = "/home/node/.openclaw/workspace"
```

- [ ] **Step 2: Implement secret-safe copying**

Create `scripts/07-prepare-openclaw-state.sh` with these rules:

- default source: `$HOME/.openclaw`;
- default destination: `$HOME/.local/share/openclaw-kuasar/openclaw-state`;
- refuse if the source lacks `openclaw.json`;
- refuse if destination exists and is non-empty unless `--replace` is explicitly passed;
- create destination with mode `0700`;
- copy with `cp -a` and never print file contents;
- invoke the host CLI with `OPENCLAW_STATE_DIR` and `OPENCLAW_CONFIG_PATH` pointed at the copy:

```bash
OPENCLAW_STATE_DIR="$destination" \
OPENCLAW_CONFIG_PATH="$destination/openclaw.json" \
openclaw config set agents.defaults.workspace /home/node/.openclaw/workspace
```

- validate with the same environment and `openclaw config validate`;
- print only the destination path, mode, and validation result.

- [ ] **Step 3: Run fixture tests**

Run:

```bash
chmod +x scripts/07-prepare-openclaw-state.sh
bash -n scripts/07-prepare-openclaw-state.sh
bash tests/test-cri-specs.sh
```

Expected: PASS; test output contains no fixture credential value.

- [ ] **Step 4: Create the real state copy after explicit confirmation**

Run: `./scripts/07-prepare-openclaw-state.sh`

Expected: configuration validates; `stat -c '%U %G %a' "$HOME/.local/share/openclaw-kuasar/openclaw-state"` prints `yyxie yyxie 700`.

## Task 7: Time-Box Kuasar runc and Prove Cloud Hypervisor with a Minimal Image

**Files:**
- Modify: `scripts/04-run-with-crictl.sh`
- Create: `containerd/smoke-pod.json`
- Create: `containerd/smoke-container.json`
- Create: `.artifacts/gates/` at runtime only.

**Interfaces:**
- Consumes: isolated services and lifecycle script.
- Produces: Gate 2 and Gate 3 evidence without changing OpenClaw configuration.

- [ ] **Step 1: Prove OpenClaw with plain runc**

Run `OPENCLAW_DATA_DIR="$HOME/.local/share/openclaw-kuasar/openclaw-state" ./scripts/03-generate-cri-specs.sh`, then run `OPENCLAW_RUNTIME_HANDLER=runc RUN_CRICTL=1 ./scripts/04-run-with-crictl.sh`. Verify `openclaw gateway health` and one fixed Agent request through `crictl exec`, then clean up and retain timings.

- [ ] **Step 2: Run the Kuasar runc interface gate**

Create `containerd/smoke-pod.json` with metadata name/UID `kuasar-smoke`, host-network namespace mode `2`, and log directory `/tmp/openclaw-kuasar-smoke`. Create `containerd/smoke-container.json` with image `docker.io/library/busybox:1.36.1`, command `sh -c "uname -a; sleep 30"`, and log path `busybox-smoke.log`. Validate both files with `python3 -m json.tool`.

Use the minimal specs and the official handler:

```bash
sudo crictl --runtime-endpoint unix:///run/openclaw-kuasar/containerd.sock --image-endpoint unix:///run/openclaw-kuasar/containerd.sock pull docker.io/library/busybox:1.36.1
POD_SPEC="$PWD/containerd/smoke-pod.json" CONTAINER_SPEC="$PWD/containerd/smoke-container.json" OPENCLAW_RUNTIME_HANDLER=kuasar-runc RUN_CRICTL=1 ./scripts/04-run-with-crictl.sh
```

Use a dedicated minimal container spec whose command is `sh -c 'uname -a; sleep 30'`; do not reuse the OpenClaw command for this gate.

Expected: Kuasar runc creates, starts, logs, and deletes the sandbox. Stop diagnosis after 10–15% of remaining schedule if this gate fails; preserve logs and continue only after documenting whether the failure is specific to runc sandboxer.

- [ ] **Step 3: Run the Cloud Hypervisor minimal-image gate**

Run `POD_SPEC="$PWD/containerd/smoke-pod.json" CONTAINER_SPEC="$PWD/containerd/smoke-container.json" OPENCLAW_RUNTIME_HANDLER=kuasar-vmm RUN_CRICTL=1 ./scripts/04-run-with-crictl.sh`.

Expected evidence:

```bash
sudo crictl --runtime-endpoint unix:///run/openclaw-kuasar/containerd.sock pods
sudo journalctl -u openclaw-kuasar-vmm.service --since '-10 min' --no-pager
pgrep -a cloud-hypervisor
sudo /usr/local/libexec/openclaw-kuasar/vmm-sandboxer --version
```

The pod must be ready, a `cloud-hypervisor` process must exist, and workload `uname -a` must be captured.

- [ ] **Step 4: Prove outbound DNS and HTTPS inside the MicroVM workload**

Use a minimal image containing `getent` and `curl`, or use the OpenClaw image after it is pulled:

```bash
sudo crictl --runtime-endpoint unix:///run/openclaw-kuasar/containerd.sock exec "$CONTAINER_ID" getent hosts api.deepseek.com
sudo crictl --runtime-endpoint unix:///run/openclaw-kuasar/containerd.sock exec "$CONTAINER_ID" node -e 'fetch("https://api.deepseek.com").then(r=>console.log(r.status)).catch(e=>{console.error(e.message);process.exit(1)})'
```

Expected: DNS resolves and HTTPS returns an HTTP status rather than a network error.

- [ ] **Step 5: Delete the sandbox and prove process reclamation**

Run cleanup, then:

```bash
sudo crictl --runtime-endpoint unix:///run/openclaw-kuasar/containerd.sock ps -a
sudo crictl --runtime-endpoint unix:///run/openclaw-kuasar/containerd.sock pods
pgrep -a cloud-hypervisor || true
```

Expected: no test container/pod and no Cloud Hypervisor process associated with the sandbox.

## Task 8: Build the Platform Lifecycle CLI

**Files:**
- Create: `scripts/openclaw-platform`
- Create: `tests/test-platform-cli.sh`

**Interfaces:**
- Consumes: CRI endpoint, generated specs, state directory, runtime handler, and systemd services.
- Produces: commands `deploy`, `status`, `logs`, `demo`, and `delete`; `.state/runtime.json`; redacted `.artifacts/` diagnostics.

- [ ] **Step 1: Write failing CLI contract tests**

Create `tests/test-platform-cli.sh` to assert:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

help="$($ROOT_DIR/scripts/openclaw-platform help)"
for command in deploy status logs demo delete; do
  grep -q "$command" <<<"$help"
done

if PLATFORM_DRY_RUN=1 OPENCLAW_RUNTIME_HANDLER=runc "$ROOT_DIR/scripts/openclaw-platform" deploy 2>dry-run.err; then
  echo 'deploy unexpectedly accepted runc' >&2
  exit 1
fi
grep -q 'kuasar-vmm is required' dry-run.err
rm -f dry-run.err
```

- [ ] **Step 2: Verify tests fail before implementation**

Run: `bash tests/test-platform-cli.sh`

Expected: failure because the CLI does not exist.

- [ ] **Step 3: Implement shared CLI initialization**

Create `scripts/openclaw-platform` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/config/versions.env"
STATE_DIR="$ROOT_DIR/.state"
STATE_FILE="$STATE_DIR/runtime.json"
ARTIFACT_DIR="$ROOT_DIR/.artifacts/$(date -u +%Y%m%dT%H%M%SZ)"
DATA_DIR="${OPENCLAW_DATA_DIR:-$HOME/.local/share/openclaw-kuasar/openclaw-state}"
HANDLER="${OPENCLAW_RUNTIME_HANDLER:-$RUNTIME_HANDLER}"
CRI=(sudo crictl --runtime-endpoint "$CRI_ENDPOINT" --image-endpoint "$CRI_ENDPOINT")

require_vmm_handler() {
  if [ "$HANDLER" != "kuasar-vmm" ]; then
    echo 'error: kuasar-vmm is required; fallback is disabled' >&2
    exit 2
  fi
}

load_state() {
  test -f "$STATE_FILE" || return 1
  POD_ID="$(jq -er '.pod_id' "$STATE_FILE")"
  CONTAINER_ID="$(jq -er '.container_id' "$STATE_FILE")"
}
```

Implement command dispatch with an explicit `case` statement and reject unknown commands.

- [ ] **Step 4: Implement transactional `deploy`**

`deploy` must:

1. require `kuasar-vmm`;
2. check the data directory, `/dev/kvm`, both services, CRI info, runtime artifacts, and image presence;
3. generate specs with `OPENCLAW_DATA_DIR="$DATA_DIR"`;
4. create pod/container and save IDs only after successful start;
5. poll `openclaw gateway health` inside the container for up to 120 seconds;
6. locate a Cloud Hypervisor PID only after the pod is running;
7. atomically rename a temporary JSON state file into `.state/runtime.json`;
8. capture diagnostics and remove partial resources on `ERR`.

The state schema is:

```json
{
  "pod_id": "CRI pod identifier",
  "container_id": "CRI container identifier",
  "runtime_handler": "kuasar-vmm",
  "image": "ghcr.io/openclaw/openclaw:2026.6.11",
  "image_digest": "resolved OCI digest",
  "cloud_hypervisor_pid": 12345,
  "deployed_at": "RFC3339 timestamp",
  "ready_at": "RFC3339 timestamp"
}
```

- [ ] **Step 5: Implement `status` and `logs`**

`status` reconciles CRI rather than trusting the JSON file and prints exactly five PASS/FAIL lines plus IDs and versions. `logs` prints labeled sections for:

```bash
"${CRI[@]}" logs "$CONTAINER_ID"
sudo journalctl -u openclaw-kuasar-vmm.service --since "$DEPLOYED_AT" --no-pager
sudo journalctl -u openclaw-kuasar-containerd.service --since "$DEPLOYED_AT" --no-pager
```

Before saving diagnostics, redact lines matching `token|password|secret|api[_-]?key|authorization` case-insensitively.

- [ ] **Step 6: Implement `demo`**

Run:

```bash
"${CRI[@]}" exec "$CONTAINER_ID" openclaw agent \
  --agent main \
  --session-key agent:main:kuasar-demo \
  --message 'Read the current runtime environment and produce a short status report.' \
  --timeout 180 \
  --json
```

Measure elapsed milliseconds, print the result, runtime handler, Cloud Hypervisor PID, image digest, and guest `uname -a`. Do not print environment variables or configuration files.

- [ ] **Step 7: Implement idempotent `delete`**

Stop/remove container and pod when present, tolerate CRI NotFound responses, wait up to 30 seconds for the recorded Cloud Hypervisor PID to exit, and remove `.state/runtime.json` only after reconciliation shows no experiment resources.

- [ ] **Step 8: Run CLI tests**

Run:

```bash
chmod +x scripts/openclaw-platform tests/test-platform-cli.sh
bash -n scripts/openclaw-platform tests/test-platform-cli.sh
bash tests/test-platform-cli.sh
```

Expected: help contract passes and runc fallback is rejected.

## Task 9: Run the OpenClaw VMM Gate and Repeatability Test

**Files:**
- Runtime output only: `.state/`, `.artifacts/`, `.artifacts/checkpoints/`.

**Interfaces:**
- Consumes: completed platform CLI and dedicated OpenClaw state.
- Produces: mandatory acceptance evidence and three successful lifecycle records.

- [ ] **Step 1: Verify security and runtime preconditions**

Run:

```bash
test "$(stat -c %a "$HOME/.local/share/openclaw-kuasar/openclaw-state")" = 700
sudo systemctl is-active openclaw-kuasar-containerd.service openclaw-kuasar-vmm.service
sudo test -r /dev/kvm -a -w /dev/kvm
sudo crictl --runtime-endpoint unix:///run/openclaw-kuasar/containerd.sock info >/dev/null
```

Expected: all return zero.

- [ ] **Step 2: Execute one complete VMM lifecycle**

Run:

```bash
./scripts/openclaw-platform deploy
./scripts/openclaw-platform status
./scripts/openclaw-platform demo
./scripts/openclaw-platform logs
./scripts/openclaw-platform delete
./scripts/openclaw-platform status
```

Expected: first status has five PASS lines, demo returns a model response, and final status reports the workload absent with no associated Cloud Hypervisor PID.

- [ ] **Step 3: Execute three consecutive cycles**

Run:

```bash
for run in 1 2 3; do
  ./scripts/openclaw-platform deploy
  ./scripts/openclaw-platform demo > ".artifacts/repeat-$run-demo.json"
  ./scripts/openclaw-platform delete
done
```

Expected: all cycles return zero; CRI lists no experiment pod/container afterward.

- [ ] **Step 4: Capture the six acceptance proofs**

Save:

- CRI pod/container inspection showing handler `kuasar-vmm`;
- Kuasar log lines containing the sandbox ID;
- Cloud Hypervisor process command line and PID;
- guest `uname -a` and boot evidence;
- OpenClaw health plus demo response metadata;
- post-delete CRI and process listings.

Run a redaction scan before retaining evidence:

```bash
if rg -ni 'token|password|secret|api[_-]?key|authorization' .artifacts; then
  echo 'error: diagnostics require manual redaction' >&2
  exit 1
fi
```

- [ ] **Step 5: Produce the runc-versus-MicroVM comparison**

Run the same fixed Agent message through plain `runc` and `kuasar-vmm`. Record numeric cold-deploy milliseconds, first-response milliseconds, and host memory delta. Write `.artifacts/runtime-comparison.md` with columns `Runtime`, `Cold deploy ms`, `First response ms`, `Host memory delta KiB`, and `Isolation`; do not estimate missing values.

## Task 10: Document the Demo and Update Handoff

**Files:**
- Modify: `README.md`
- Modify: `HANDOFF.md`
- Modify: `images/openclaw/README.md`

**Interfaces:**
- Consumes: verified commands, versions, digests, timings, and evidence from Task 9.
- Produces: reproducible operator instructions and an honest progress record.

- [ ] **Step 1: Document the operator workflow**

Add to `README.md`:

```bash
./scripts/00-check-host.sh
./scripts/05-fetch-runtime.sh
sudo ./scripts/06-install-runtime.sh
./scripts/07-prepare-openclaw-state.sh
./scripts/02-build-openclaw-image.sh
./scripts/openclaw-platform deploy
./scripts/openclaw-platform status
./scripts/openclaw-platform demo
./scripts/openclaw-platform logs
./scripts/openclaw-platform delete
```

Explain that the experiment uses an isolated containerd socket and does not modify the host containerd/Kata stack.

- [ ] **Step 2: Document image provenance**

Update `images/openclaw/README.md` to state that the default image is the official pinned GHCR tag, and record the digest obtained from Task 5. Keep the Dockerfile path only as an explicit custom-build alternative.

- [ ] **Step 3: Update the handoff from fresh evidence**

Update `HANDOFF.md` with:

- exact installed versions and checksums;
- isolated socket and service names;
- passed/failed gate status;
- resolved OpenClaw image digest;
- three-cycle result;
- known warnings that remain;
- rollback commands that disable only the three experiment services.

- [ ] **Step 4: Run final verification**

Run:

```bash
bash -n scripts/*.sh scripts/openclaw-platform tests/*.sh
bash tests/test-runtime-config.sh
bash tests/test-cri-specs.sh
bash tests/test-platform-cli.sh
python3 -m json.tool containerd/openclaw-pod.json >/dev/null
python3 -m json.tool containerd/openclaw-container.json >/dev/null
rg -n -e 'TO''DO' -e 'TB''D' -e 'FIX''ME' -e 'PLACE''HOLDER' README.md HANDOFF.md images/openclaw/README.md scripts tests containerd systemd config
```

Expected: syntax and tests pass; JSON validates; the placeholder scan prints nothing.

- [ ] **Step 5: Record the final non-Git checkpoint**

Run:

```bash
find config containerd systemd scripts tests docs/superpowers/specs docs/superpowers/plans -type f -print0 \
  | sort -z \
  | xargs -0 sha256sum > .artifacts/checkpoints/final-source.sha256
```

Expected: the checksum manifest is created without reading the secret state directory.

## Privileged Rollback Boundary

Rollback must affect only the experiment stack:

```bash
sudo systemctl disable --now openclaw-kuasar-containerd.service openclaw-kuasar-vmm.service openclaw-kuasar-runc.service
sudo rm -f /etc/systemd/system/openclaw-kuasar-containerd.service /etc/systemd/system/openclaw-kuasar-vmm.service /etc/systemd/system/openclaw-kuasar-runc.service
sudo systemctl daemon-reload
```

Do not remove `/var/lib/openclaw-kuasar`, `/etc/openclaw-kuasar`, or `/usr/local/libexec/openclaw-kuasar` automatically. Preserve them for diagnosis unless the user explicitly authorizes deletion.

## Official References

- Kuasar v1.1.0 release: <https://github.com/kuasar-io/kuasar/releases/tag/v1.1.0>
- Kuasar containerd integration: <https://github.com/kuasar-io/kuasar/blob/v1.1.0/docs/containerd.md>
- Kuasar VMM guide: <https://github.com/kuasar-io/kuasar/blob/v1.1.0/docs/vmm/README.md>
- Kuasar architecture: <https://kuasar.io/docs/architecture/microvm-sandboxer/>
- Cloud Hypervisor v52.0: <https://github.com/cloud-hypervisor/cloud-hypervisor/releases/tag/v52.0>
- OpenClaw Docker guide: <https://docs.openclaw.ai/install/docker>

