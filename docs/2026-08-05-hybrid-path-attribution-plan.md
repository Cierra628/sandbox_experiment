# Hybrid Path Attribution Implementation Plan

**Goal:** 在保持当前混合挂载不变的前提下，收集 VMM guest 内 CLI 文件访问的路径分桶，定位 Gateway/health 优化候选。

**Architecture:** 新增一个独立的 profiling runner，基于现有 `openclaw-pod-vmm.json` 和 `openclaw-container-vmm.json` 生成临时 spec。它把现有 app/state/usr-local loop 作为只读/可写挂载，使用 profiling 镜像在 guest 内运行 `strace`，只将每个命令的路径分桶摘要传回 host。

**Tech Stack:** Bash, crictl/CRI v1, jq, guest strace, awk, existing Kuasar VMM handler.

## Global Constraints

- 不修改 `/etc/openclaw-kuasar`、systemd unit 或现有 loop 镜像。
- 所有临时 pod/container 使用唯一 UID，并在每轮结束时清理。
- `strace` 结果只用于路径归因；不把带 trace 的绝对 wall time 作为最终性能数字。
- 当前配置固定为 VirtioFS `/`、virtio-blk `/app`、virtio-blk state、virtio-blk `/usr/local`。

## Task 1: Add the hybrid path profiling runner

**Files:**

- Create: `scripts/32-profile-hybrid-paths.sh`

**Interfaces:**

- Inputs: `--state-loop DEV`, `--app-loop DEV`, `--runtime-loop DEV`, optional `--profile-image IMAGE`, `--repeats N`, `--result-dir DIR`.
- Produces: `results.json`, `results.ndjson`, generated specs, per-command stderr and mount evidence under the result directory.

- [ ] **Step 1: Add argument parsing and validation**

Require all three loop devices, positive repeat count, result directory, `jq`, `crictl`, `awk`, and `sudo`. Default profile image is `localhost/openclaw-kuasar:2026.6.11-virtiofs-strace`.

- [ ] **Step 2: Generate temporary VMM specs**

For every repeat, clone the base pod/container JSON, set a unique UID/log path, override the profiling image, remove existing `/app`, `/usr/local`, and state mounts, then add:

```json
[
  {"container_path":"/app","host_path":"APP_LOOP","readonly":true},
  {"container_path":"/usr/local","host_path":"RUNTIME_LOOP","readonly":true},
  {"container_path":"/home/node/.openclaw","host_path":"STATE_LOOP","readonly":false}
]
```

- [ ] **Step 3: Start an idle VMM container and capture mount evidence**

Run the container with a readiness wrapper that waits for `/home/node/.openclaw/openclaw.json`, then sleeps. Save `id`, `stat -f`, and `/proc/self/mountinfo` output before profiling.

- [ ] **Step 4: Trace the CLI probes inside the guest**

For each repeat and each command `config_validate`, `plugins_list`, and `models_status`, run:

```bash
strace -f -qq -ttt -T -e trace=%file \
  -o /tmp/hybrid-path-LABEL. \
  node openclaw.mjs COMMAND
```

Run the command output and trace aggregation inside the guest. The aggregation must classify absolute paths into `app`, `state`, `usr_local`, `usr_system`, `etc`, and `other_absolute`, returning event count and summed syscall milliseconds as compact JSON.

- [ ] **Step 5: Save results and clean resources**

Write one NDJSON record per command/repeat with `rc`, guest wall, host wall, transport residual, and path buckets. Always stop/remove the container and pod, including on failure.

## Task 2: Add static and local verification

**Files:**

- Test: `scripts/32-profile-hybrid-paths.sh`

- [ ] **Step 1: Run shell syntax and help checks**

```bash
bash -n scripts/32-profile-hybrid-paths.sh
scripts/32-profile-hybrid-paths.sh --help
```

- [ ] **Step 2: Validate generated jq mount transformation**

Use a temporary fixture copied from `containerd/openclaw-container-vmm.json` and assert that exactly one mount exists for each of `/app`, `/usr/local`, and `/home/node/.openclaw`, with the expected host paths and read-only flags.

- [ ] **Step 3: Run the profiling experiment**

Use `/dev/loop24`, `/dev/loop8`, and `/dev/loop26` for app, state, and runtime respectively, with three repeats. Expected result is a `results.json` containing nine command records and a mount evidence file for each repeat.

## Task 3: Interpret the first attribution result

**Files:**

- Result: `.artifacts/hybrid-path-profile-*`

- [ ] **Step 1: Compare path buckets**

For each command, compare summed syscall milliseconds and event counts across the six path buckets.

- [ ] **Step 2: Choose the next candidate**

Only if `usr_system` dominates the remaining cost, proceed to export `/usr` as one read-only image. If another bucket dominates, design that path-specific experiment instead; do not mount `/etc` or `/var` without evidence.
