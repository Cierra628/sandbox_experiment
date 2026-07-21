# Remote Registry cold-pull benchmark Implementation Plan

> **For agentic workers:** This plan is executed inline in the current session. The user explicitly requested no superpowers/subagent mode.

**Goal:** Add a safe, repeatable script that resets the dedicated OpenClaw containerd cache before every run, pulls the remote image, and compares `runc`, `kuasar-runc`, and `kuasar-vmm` for three runs each.

**Architecture:** Keep the existing systemd/containerd/CNI/sandboxer stack and add one independent driver, `scripts/15-benchmark-remote-coldstart.sh`. Each run uses a fresh `/var/lib/openclaw-kuasar/containerd` root, pre-pulls the pause image outside the OpenClaw pull timer, generates unique CRI specs in the artifact directory, records lifecycle/health/sample timings, and cleans up CRI objects. A guarded reset and failure trap protect the host Docker/containerd and OpenClaw state directory.

**Tech Stack:** Bash, `crictl`, `ctr`, `jq`, `systemctl`, existing JSON CRI specs, existing remote HTTP Registry.

## Global Constraints

- Only operate on `/run/openclaw-kuasar/containerd.sock`, `/var/lib/openclaw-kuasar/containerd`, and `/run/openclaw-kuasar/containerd-state`.
- Never delete `/home/yyxie/.local/share/openclaw-kuasar/openclaw-state`, host Docker/containerd roots, or the Registry on server B.
- Default matrix is `runc kuasar-runc kuasar-vmm` × 3 runs.
- Require an explicit `--confirm-cold-reset` before stopping services or moving containerd root.
- Do not store API keys, auth databases, or complete environment dumps in artifacts.
- Use explicit `\` continuations in all documented multi-line shell commands.
- The existing scripts and dirty worktree changes are out of scope; add only the new driver and its tests/docs.

---

### Task 1: Add guarded CLI, path validation, and dry-run output

**Files:**
- Create: `scripts/15-benchmark-remote-coldstart.sh`
- Test: shell syntax and dry-run commands shown below

**Interfaces:**
- Consumes: `REMOTE_IMAGE`, `HANDLERS`, `RUNS`, `CRI_ENDPOINT`, `RESULT_DIR`, and CLI flags `--confirm-cold-reset`, `--handlers`, `--runs`, `--result-dir`, `--skip-sample`, `--keep-backups`, `--dry-run`.
- Produces: validated `CRI_ENDPOINT`, `SOCK`, `CT_ROOT`, `CT_STATE`, `REMOTE_IMAGE`, handler list, run count, artifact directory, and a dry-run summary.

- [ ] **Step 1: Write the script header and option parser**

  Start with:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  CRI_ENDPOINT="${CRI_ENDPOINT:-unix:///run/openclaw-kuasar/containerd.sock}"
  CT_ROOT="${CT_ROOT:-/var/lib/openclaw-kuasar/containerd}"
  CT_STATE="${CT_STATE:-/run/openclaw-kuasar/containerd-state}"
  REMOTE_IMAGE="${REMOTE_IMAGE:-10.2.30.50:5000/openclaw-kuasar:2026.6.11-virtiofs}"
  HANDLERS="${HANDLERS:-runc kuasar-runc kuasar-vmm}"
  RUNS="${RUNS:-3}"
  RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/.artifacts/remote-coldstart-$(date -u +%Y%m%dT%H%M%SZ)}"
  CONFIRMED=0
  DRY_RUN=0
  SKIP_SAMPLE=0
  KEEP_BACKUPS=0
  ```

  Parse flags with a `while [ "$#" -gt 0 ]; do case "$1" in ... esac; done` block. Reject unknown flags, missing values, non-positive `RUNS`, and handlers outside `runc`, `kuasar-runc`, `kuasar-vmm`.

- [ ] **Step 2: Validate exclusive paths and required tools**

  Require `crictl`, `ctr`, `jq`, `date`, `systemctl`, `grep`, `awk`, and `du`. Derive `SOCK="${CRI_ENDPOINT#unix://}"` and refuse to continue unless it equals `/run/openclaw-kuasar/containerd.sock`, `CT_ROOT` equals `/var/lib/openclaw-kuasar/containerd`, and `CT_STATE` equals `/run/openclaw-kuasar/containerd-state`.

  Check the systemd unit command contains `/etc/openclaw-kuasar/containerd.toml` and that the config contains `root = "/var/lib/openclaw-kuasar/containerd"`. This prevents an accidental reset of the host containerd root.

- [ ] **Step 3: Implement dry-run and confirmation gates**

  `--dry-run` must print the exact image, handler matrix, socket, root/state paths, service names, and artifact directory, then exit before `sudo`, `systemctl`, `ctr`, or `crictl` mutation. Without `--dry-run`, require `--confirm-cold-reset`; otherwise print a refusal explaining the flag.

- [ ] **Step 4: Run the first static checks**

  Run:

  ```bash
  bash -n scripts/15-benchmark-remote-coldstart.sh
  RUNS=1 HANDLERS=kuasar-vmm \
    scripts/15-benchmark-remote-coldstart.sh \
    --dry-run
  ```

  Expected: syntax succeeds; dry-run prints one VMM run and never stops a service or changes `/var/lib/openclaw-kuasar`.

### Task 2: Implement safe reset, service lifecycle, and pull measurement

**Files:**
- Modify: `scripts/15-benchmark-remote-coldstart.sh`
- Test: dry-run plus mocked/static command inspection; no destructive reset during local validation

**Interfaces:**
- Consumes: validated configuration from Task 1.
- Produces: `reset_root`, `start_stack`, `stop_stack`, `cleanup_current_root`, `pull_pause`, and `pull_openclaw` functions returning timing and diagnostic data.

- [ ] **Step 1: Implement preflight workload checks**

  Use the CRI array:

  ```bash
  CRI=(sudo crictl \
    --runtime-endpoint "$CRI_ENDPOINT" \
    --image-endpoint "$CRI_ENDPOINT")
  ```

  Before each reset, query `ps -a` and `pods`, and reject reset if either has a data row. Also reject reset when `pgrep -af 'cloud-hypervisor|virtiofsd|vmm-sandboxer|runc-sandboxer'` finds a workload process; the long-lived sandboxer service processes are allowed only after checking that no Cloud Hypervisor/virtiofsd child exists.

- [ ] **Step 2: Implement reversible per-run root reset**

  Stop `openclaw-kuasar-containerd.service`, `openclaw-kuasar-vmm.service`, and `openclaw-kuasar-runc.service`. Move the current `CT_ROOT` and `CT_STATE` to timestamped sibling backups, create empty directories with mode `0755`, and never touch the OpenClaw state directory. Keep the backup path in the current result record. Delete a previous backup only after the new stack passes CRI readiness, unless `--keep-backups` is set.

  Refuse to reset if `CT_ROOT` is empty, `/var/lib/openclaw-kuasar` is not the parent, or the configured service unit does not match the expected root.

- [ ] **Step 3: Implement service start and CRI readiness**

  Start in order: runc sandboxer, VMM sandboxer, containerd. Poll `crictl info` and the Unix socket for up to 60 seconds. Save `systemctl is-active`, `systemctl show --property=ExecMainPID`, and a redacted `crictl info` status into the artifact directory.

- [ ] **Step 4: Implement pause and OpenClaw pull timers**

  Pull `registry.k8s.io/pause:3.10` before the measured target pull and store `pause_pull_ms`. Record `du -sb "$CT_ROOT"`, `ctr images ls`, and target-image absence before pulling. Measure `REMOTE_IMAGE` with millisecond wall time, then verify it appears in `crictl images` and `ctr images ls`; record the target digest and post-pull root size. Do not classify the text `Image is up to date` by itself; the empty-root precondition and before/after state are the cache evidence.

- [ ] **Step 5: Validate pull-only behavior without reset**

  Run the script with `RUNS=1 HANDLERS=kuasar-vmm --dry-run` and inspect the generated command plan. Verify no `rm -rf`, `systemctl stop`, or `ctr images rm` runs during dry-run. Run `bash -n` again.

### Task 3: Implement per-run CRI lifecycle, health, sample, and cleanup

**Files:**
- Modify: `scripts/15-benchmark-remote-coldstart.sh`
- Test: one VMM run after explicit user confirmation; then full matrix

**Interfaces:**
- Consumes: fresh stack and pulled remote image from Task 2.
- Produces: one result object with `handler`, `run`, `pull_ms`, `lifecycle`, `gateway`, `health`, `sample`, `cleanup_ms`, `total_ms`, `status`, and `note`.

- [ ] **Step 1: Generate unique per-run specs**

  Copy the appropriate base pod spec (`containerd/openclaw-pod.json` or `containerd/openclaw-pod-vmm.json`) into `RESULT_DIR/specs`. Set a unique metadata UID containing handler/run/timestamp. Copy the appropriate container spec, set `.image.image` to `REMOTE_IMAGE`, preserve the existing VMM mount and root UID behavior, and save the copy before invoking CRI.

- [ ] **Step 2: Measure `runp`, `create`, and `start`**

  Execute `runp --runtime "$handler"`, `create`, and `start` through the CRI array. Record IDs immediately. Install an exit trap that stops/rm's the container and stopp/rmp's the sandbox on both success and failure.

- [ ] **Step 3: Poll Gateway ready and save logs**

  Poll `crictl logs "$cid"` once per second for `[gateway] ready`, with a 180-second timeout for VMM. Save the complete redacted container log in `logs/<handler>-<run>.log`; record `gateway_ready_ms` and the timeout/error note.

- [ ] **Step 4: Run health and optional local Agent sample**

  Run `node openclaw.mjs gateway health --json` through `crictl exec`, recording host wall time, JSON `ok`, `durationMs`, event-loop fields, and parse errors. Unless `--skip-sample` is set, run the fixed `--local` request with session key `agent:main:remote-coldstart-<handler>-<run>` and message `Reply with exactly KUASAR_SAMPLE_OK and nothing else.`. Record exact text, provider/model, internal duration, host wall time, fallback flag, and error category.

- [ ] **Step 5: Cleanup and write one result row**

  Stop/remove the container and sandbox, record `cleanup_ms`, query `ps -a`/`pods` to verify no rows remain, and append one JSON object to `results.ndjson`. A successful row requires running container, health `ok=true`, and sample exact text unless `--skip-sample` is set.

### Task 4: Implement summary, recovery, and artifact checks

**Files:**
- Modify: `scripts/15-benchmark-remote-coldstart.sh`
- Test: `jq` validation and failure-path static checks

**Interfaces:**
- Consumes: all per-run NDJSON rows and diagnostic files.
- Produces: `results.json`, `summary.json`, exit status, and recovery instructions on failure.

- [ ] **Step 1: Add top-level trap and failure recovery**

  On interruption, attempt CRI cleanup, stop the isolated services if the script owns them, preserve the latest root backup and artifact directory, and print the exact backup path. Never remove OpenClaw state or contact server B.

- [ ] **Step 2: Build summary with jq**

  Convert NDJSON to `results.json` and group by handler. Emit exactly the three expected handlers and their `runs`, `passed`, `failed`, averages for `pull_ms`, `runp_ms`, `create_ms`, `start_ms`, `gateway_ready_ms`, `health_host_wall_ms`, `health_internal_ms`, `sample_host_wall_ms`, `sample_internal_ms`, `cleanup_ms`, and `total_ms`.

- [ ] **Step 3: Add final integrity assertions**

  Before exit, assert that the result count equals `RUNS × number_of_handlers`, every handler has exactly `RUNS` rows, every pull has `cache_before == "empty-root"`, and no required artifact is empty. Return non-zero if any assertion fails.

- [ ] **Step 4: Run static verification**

  Run:

  ```bash
  bash -n scripts/15-benchmark-remote-coldstart.sh
  git diff --check
  RUNS=1 HANDLERS=kuasar-vmm \
    scripts/15-benchmark-remote-coldstart.sh \
    --dry-run
  ```

### Task 5: Execute one confirmed smoke run and then the 9-run matrix

**Files:**
- Test: generated `.artifacts/remote-coldstart-*` directory

- [ ] **Step 1: Execute one confirmed VMM smoke run**

  ```bash
  REMOTE_IMAGE=10.2.30.50:5000/openclaw-kuasar:2026.6.11-virtiofs \
    RUNS=1 \
    HANDLERS=kuasar-vmm \
    scripts/15-benchmark-remote-coldstart.sh \
    --confirm-cold-reset
  ```

  Verify one PASS row, a real post-pull root growth, `KUASAR_SAMPLE_OK`, and empty CRI objects after cleanup before proceeding.

- [ ] **Step 2: Execute the complete matrix**

  ```bash
  REMOTE_IMAGE=10.2.30.50:5000/openclaw-kuasar:2026.6.11-virtiofs \
    RUNS=3 \
    HANDLERS="runc kuasar-runc kuasar-vmm" \
    scripts/15-benchmark-remote-coldstart.sh \
    --confirm-cold-reset
  ```

- [ ] **Step 3: Validate final artifact**

  ```bash
  RESULT_DIR="$(find .artifacts -maxdepth 1 -type d \
    -name 'remote-coldstart-*' | sort | tail -n 1)"

  jq . "$RESULT_DIR/summary.json"
  jq '[.[] | {handler,run,status,pull_ms,gateway_ready_ms,health_ok,sample_ok,note}]' \
    "$RESULT_DIR/results.json"
  ```

  Expected: 9 rows, 3 rows per handler, and no missing pull/lifecycle/health/sample fields.

---

## Self-review checklist

- [x] Each design requirement maps to at least one task.
- [x] The script has a destructive-operation confirmation gate.
- [x] The plan never deletes the host containerd/Docker roots or OpenClaw state.
- [x] Pause-image pull is separated from the measured OpenClaw pull.
- [x] The result schema distinguishes host wall time from guest/internal time.
- [x] Failure and recovery paths preserve a root backup and artifacts.
- [x] Static validation precedes any destructive smoke run.
