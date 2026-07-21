# Remote Registry cold-pull benchmark design

## Objective

新增一个独立的 benchmark 脚本，对服务器 B 上的 OpenClaw 镜像执行严格的“清空隔离 containerd 镜像缓存 → 远程拉取 → 启动并验证”实验。

实验矩阵固定为三个 runtime handler：

- `runc`
- `kuasar-runc`
- `kuasar-vmm`

每个 handler 执行 3 轮，共 9 个样本。每一轮都必须从空的 OpenClaw 专用 containerd root 开始，避免把上一轮的镜像层当作 pull 结果。

## Scope and non-goals

脚本只操作 OpenClaw 专用隔离 runtime：

- containerd socket：`/run/openclaw-kuasar/containerd.sock`
- containerd root：`/var/lib/openclaw-kuasar/containerd`
- containerd state：`/run/openclaw-kuasar/containerd-state`
- Kuasar runc/VMM sandboxer systemd services

脚本不得删除或修改：

- 服务器 B 的 Registry 或 Registry 中的镜像；
- 主机默认 Docker/containerd 的镜像和 root；
- `$HOME/.local/share/openclaw-kuasar/openclaw-state`；
- 仓库中的基础 CRI spec、配置和源码。

本脚本测量远程镜像获取、runtime 启动和 OpenClaw 样例，不测量 Registry 服务本身的构建或推送时间。

## Candidate approaches

### Image-reference eviction

逐个执行 `crictl rmi`、`ctr images rm` 和 content prune。

优点是快，缺点是共享层可能仍由其他镜像引用，无法严格证明下一轮重新下载。因此不作为主实验方案。

### Per-run dedicated containerd-root reset (selected)

每轮开始前停止隔离 containerd 和 sandboxer，移动专用 containerd root/state 到带时间戳的备份目录，创建空目录并重启服务。每轮结束后清理 Pod/容器，并在下一轮 reset 前回收上一轮缓存。

优点是能明确建立“空缓存”起点，仍然复用已有 systemd、CRI、CNI 和 sandboxer 配置。风险通过路径白名单、活动 Pod 检查、显式确认参数和失败时保留备份来控制。

### Disposable containerd instance

为每轮生成新的 containerd 配置、socket 和 root。

隔离更强，但会引入动态服务管理、CNI 和 sandboxer 地址切换，复杂度明显高于本实验需要，不采用。

## Script interface

新增 `scripts/15-benchmark-remote-coldstart.sh`。默认值来自现有配置，但远程镜像必须显式传入或通过环境变量提供：

```text
REMOTE_IMAGE=10.2.30.50:5000/openclaw-kuasar:2026.6.11-virtiofs
HANDLERS="runc kuasar-runc kuasar-vmm"
RUNS=3
CRI_ENDPOINT=unix:///run/openclaw-kuasar/containerd.sock
RESULT_DIR=.artifacts/remote-coldstart-<UTC timestamp>
```

脚本需要显式确认破坏性 reset，例如：

```text
--confirm-cold-reset
```

未提供确认参数时只执行参数、路径和服务状态检查，不停止服务、不移动 root、不拉取镜像。

可选参数包括：

- `--handlers`：覆盖 handler 列表；
- `--runs`：覆盖每个 handler 的轮数；
- `--result-dir`：指定 artifact 目录；
- `--skip-sample`：仅做启动和 health，不调用模型；
- `--keep-backups`：保留每轮 reset 前的 root 备份；默认在下一轮成功建立空 root 后删除上一轮备份；
- `--dry-run`：只展示将执行的服务、路径和实验矩阵。

## Per-run data flow

每一轮按以下顺序执行：

1. 检查 `crictl ps -a`、`crictl pods` 和 Cloud Hypervisor/virtiofsd 进程，拒绝在有活动工作负载时 reset。
2. 停止 `openclaw-kuasar-containerd.service`、`openclaw-kuasar-vmm.service` 和 `openclaw-kuasar-runc.service`。
3. 移动专用 containerd root/state，创建空目录；不触碰 OpenClaw 持久状态目录。
4. 按 runc/VMM 依赖顺序启动 sandboxer 和 containerd，验证 CRI `RuntimeReady`、`NetworkReady`。
5. 在计时窗口外拉取 `registry.k8s.io/pause:3.10`，记录 `pause_pull_ms`，避免 pause 网络下载污染 OpenClaw pull 时间。
6. 计时并拉取 `REMOTE_IMAGE`，记录 `pull_ms`、拉取前后 root 大小以及目标镜像 digest；拉取前必须确认目标镜像引用不存在。
7. 用远程镜像和唯一 UID 生成本轮 pod/container spec，并把副本保存到 artifact 目录。
8. 通过 CRI 依次执行 `runp`、`create`、`start`，分别记录 `runp_ms`、`create_ms` 和 `start_ms`。
9. 轮询容器日志中的 `[gateway] ready`，记录 `gateway_ready_ms`；超时则保存日志并将本轮标记为失败。
10. 通过 `crictl exec` 执行 `node openclaw.mjs gateway health --json`，记录宿主机 wall time、JSON 内部 `durationMs` 和 `ok`。
11. 默认执行一次 `--local` Agent 样例，要求最终可见文本严格为 `KUASAR_SAMPLE_OK`，记录模型、provider、内部耗时、宿主机 wall time、fallback 和错误分类。
12. 停止并删除容器和 Pod，验证没有残留 CRI 对象；本轮结果写入 NDJSON 和 JSON。

`--local` 样例用于验证 VMM guest 内的 OpenClaw、持久状态、DNS、网络和模型 API；Gateway transport 健康由独立 health 步骤验证，不把 operator scope/pairing 交互混入样例计时。

## Result schema

每轮一条记录，至少包含：

```json
{
  "handler": "kuasar-vmm",
  "run": 1,
  "status": "PASS",
  "image": "10.2.30.50:5000/openclaw-kuasar:2026.6.11-virtiofs",
  "cache_before": "empty-root",
  "pause_pull_ms": 0,
  "pull_ms": 8028,
  "lifecycle": {
    "runp_ms": 0,
    "create_ms": 0,
    "start_ms": 0,
    "gateway_ready_ms": 0
  },
  "health": {
    "ok": true,
    "host_wall_ms": 0,
    "internal_ms": 0
  },
  "sample": {
    "ok": true,
    "host_wall_ms": 0,
    "internal_ms": 0,
    "provider": "deepseek",
    "model": "deepseek-v4-flash",
    "text": "KUASAR_SAMPLE_OK",
    "fallback_used": false
  },
  "cleanup_ms": 0,
  "total_ms": 0,
  "note": ""
}
```

`summary.json` 按 handler 汇总 `runs`、`passed`、均值和失败分类。artifact 还保存：

- `results.ndjson`、`results.json`、`summary.json`；
- 每轮 pod/container spec；
- pull、Gateway 和 sample 日志；
- reset 前后 root 大小、镜像列表和 service 状态的诊断快照。

不得把 API key、完整环境变量或未脱敏的认证数据库复制到 artifact。

## Failure handling and recovery

- 任一轮 reset 前发现活动 Pod/容器，脚本停止并提示手动清理；
- 服务启动失败、CRI 不 ready、pull 失败、Gateway ready 超时、health 失败或 sample 失败都会记录失败原因；
- 本轮失败时先尽力清理 CRI 对象，再保留 reset 备份和日志，不自动删除用户数据；
- 若脚本中断，恢复方式是停止隔离服务、删除空 root、把最近的备份 root 移回固定路径，再按依赖顺序启动服务；
- 服务器 B 和 Registry 不在清理路径中。

## Validation plan

实现后按以下顺序验证：

1. `bash -n scripts/15-benchmark-remote-coldstart.sh`；
2. `--dry-run` 验证 3 handler × 3 runs、路径白名单和服务列表；
3. 用 `RUNS=1 HANDLERS=kuasar-vmm` 做一轮人工确认，检查 artifact、root reset 和 cleanup；
4. 再执行完整 9 轮；
5. 检查 `summary.json` 是否包含每个 handler 3 行、pull 前目标镜像为空、每轮 sample/health 判据和失败信息。

## Acceptance criteria

实验脚本只有同时满足以下条件才算完成：

- 默认矩阵生成 9 个结果记录，每个 handler 3 轮；
- 每轮 pull 前目标镜像不在专用 containerd root 中；
- 每轮记录远程 pull、runtime lifecycle、Gateway ready、health、sample 和 cleanup；
- 通过样例必须包含 `KUASAR_SAMPLE_OK` 且无 fallback/auth/network 错误；
- 失败时不删除 OpenClaw state 或服务器 B 数据，并留下可定位的 artifact；
- `git diff --check` 和 shell 语法检查通过。
