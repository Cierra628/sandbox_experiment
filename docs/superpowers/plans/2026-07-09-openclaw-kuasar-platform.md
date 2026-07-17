# OpenClaw Kuasar Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a minimal, inspectable experiment platform for running OpenClaw Gateway through containerd and Kuasar.

**Architecture:** Use containerd CRI as the stable upper interface. Keep scripts small and non-destructive so each runtime layer can be validated independently before platform automation is added.

**Tech Stack:** Bash, containerd, crictl, Kuasar, OCI image tooling (`nerdctl`, `docker`, or `podman`).

## Global Constraints

- Do not automate privileged system changes in this iteration.
- Do not commit model API keys or OpenClaw secrets.
- Use `localhost/openclaw-gateway:experiment` as the local image tag.
- Default OpenClaw persistent data path is `/tmp/openclaw-kuasar-data`.
- Prefer plain containerd/runc first, Kuasar runc second, Kuasar VMM third.

---

### Task 1: Project Documentation

**Files:**
- Create: `README.md`
- Create: `docs/superpowers/specs/2026-07-09-openclaw-kuasar-design.md`

**Interfaces:**
- Consumes: User goal to run OpenClaw on Kuasar/containerd.
- Produces: Documented experiment scope, runtime strategy, and verification gates.

- [ ] **Step 1: Create the README**

Write `README.md` with the project goal, stages, directory layout, and first
commands.

- [ ] **Step 2: Create the design spec**

Write `docs/superpowers/specs/2026-07-09-openclaw-kuasar-design.md` with
architecture, components, runtime strategy, data handling, and verification.

- [ ] **Step 3: Verify documentation files exist**

Run:

```bash
test -f README.md
test -f docs/superpowers/specs/2026-07-09-openclaw-kuasar-design.md
```

Expected: both commands exit with status 0.

### Task 2: Host and Image Preparation Scripts

**Files:**
- Create: `scripts/00-check-host.sh`
- Create: `scripts/01-prepare-openclaw-image.sh`
- Create: `scripts/02-build-openclaw-image.sh`
- Create: `images/openclaw/.gitkeep`

**Interfaces:**
- Consumes: Local machine environment and optional OpenClaw source directory.
- Produces: Host prerequisite report and an image build command path.

- [ ] **Step 1: Create host check script**

Write `scripts/00-check-host.sh` to check kernel, CPU virtualization, `/dev/kvm`,
containerd, crictl, Kuasar binaries, and image builders.

- [ ] **Step 2: Create image context preparation script**

Write `scripts/01-prepare-openclaw-image.sh` to create `images/openclaw/` and
print where to place or clone the OpenClaw source.

- [ ] **Step 3: Create image build script**

Write `scripts/02-build-openclaw-image.sh` to build
`localhost/openclaw-gateway:experiment` with the first available builder from
`nerdctl`, `docker`, or `podman`.

- [ ] **Step 4: Verify script syntax**

Run:

```bash
bash -n scripts/00-check-host.sh
bash -n scripts/01-prepare-openclaw-image.sh
bash -n scripts/02-build-openclaw-image.sh
```

Expected: all commands exit with status 0.

### Task 3: CRI Spec Generation and Runtime Commands

**Files:**
- Create: `scripts/03-generate-cri-specs.sh`
- Create: `scripts/04-run-with-crictl.sh`
- Generate: `containerd/openclaw-pod.json`
- Generate: `containerd/openclaw-container.json`

**Interfaces:**
- Consumes: Local image tag, OpenClaw data path, and runtime handler name.
- Produces: CRI specs and repeatable `crictl` command sequence.

- [ ] **Step 1: Create CRI spec generator**

Write `scripts/03-generate-cri-specs.sh` to generate pod and container JSON
files using environment variables:

```text
OPENCLAW_IMAGE=localhost/openclaw-gateway:experiment
OPENCLAW_DATA_DIR=/tmp/openclaw-kuasar-data
OPENCLAW_RUNTIME_HANDLER=
```

- [ ] **Step 2: Create crictl runner**

Write `scripts/04-run-with-crictl.sh` to print the `crictl runp`, `create`,
`start`, `logs`, and cleanup commands. Execute only when `RUN_CRITCL=1`.

- [ ] **Step 3: Verify generated specs**

Run:

```bash
./scripts/03-generate-cri-specs.sh
test -f containerd/openclaw-pod.json
test -f containerd/openclaw-container.json
```

Expected: all commands exit with status 0.

### Task 4: Final Verification

**Files:**
- Verify: all created files.

**Interfaces:**
- Consumes: Tasks 1 through 3.
- Produces: Evidence that the project skeleton is ready for runtime-specific work.

- [ ] **Step 1: Verify file inventory**

Run:

```bash
find . -maxdepth 4 -type f | sort
```

Expected: the output includes the README, design spec, implementation plan,
four scripts, and generated CRI specs after Task 3.

- [ ] **Step 2: Verify shell scripts**

Run:

```bash
for script in scripts/*.sh; do bash -n "$script"; done
```

Expected: command exits with status 0.

