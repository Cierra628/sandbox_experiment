# Hybrid metadata-cache optimization design

## Goal

进一步优化 Kuasar VMM 的 OpenClaw 混合挂载方案，同时保持冷启动口径不变：

- `start` 接近纯 VirtioFS；
- Gateway ready 和 health exec wall 接近纯 virtio-blk；
- 不把 Agent/模型网络抖动误判为文件系统收益；
- 每轮使用全新的 Pod、VM 和容器。

当前候选基线是：VirtioFS rootfs、`cache=metadata`、virtio-blk `/app`（只读）和 virtio-blk `/home/node/.openclaw`（读写）。基线结果目录为 `.artifacts/plan1-fixed-hybrid-metadata-20260807T011407Z`。

## Baseline and target

当前三轮平均值（毫秒）为：

| 指标 | 当前混合基线 | 纯 VirtioFS | 纯 virtio-blk |
| --- | ---: | ---: | ---: |
| `start` | 64 | 55 | 6091 |
| Gateway ready | 6557 | 7881（`cache=metadata`） | 6490 |
| health exec wall | 7156 | 8104（`cache=metadata`） | 5777 |
| Agent sample exec wall | 10111 | 11639（`cache=metadata`） | 9133 |
| total | 25130 | 28859 | 28917 |

优化的首要判据是 `start` 不明显退化，并让 health exec wall 稳定下降。Agent sample 只作为端到端验证，不作为单独的文件系统优化判据。

## Experimental stages

### Stage A: exact-current path attribution

在当前 `cache=metadata` 配置和当前 `/app`、state、`/usr/local` 挂载下重新运行路径归因。该阶段只用于定位，不据此直接修改挂载。

决策规则：

- 若 `/usr` 路径仍只有毫秒级 syscall 时间，则跳过完整 `/usr` 镜像；
- 若 `/usr` 占据稳定的数百毫秒以上，再进入条件性的 `/usr` block 实验；
- 归因结果必须记录实际 VMM 配置和每个挂载的 mount evidence。

已有旧归因结果显示 `/usr/local` 和其他 `/usr` 路径只有毫秒级开销，因此完整 `/usr` 目前只是条件候选，不是默认下一步。

### Stage B: VirtioFS metadata worker sweep

只改变 `virtiofsd.thread_pool_size`，测试 `2`、`4`、`8` 三个值。以下内容保持不变：镜像、vCPU、内存、`cache=metadata`、`/app` loop、state loop、workload、运行次数和服务版本。

每个配置运行三轮，记录：

- `runp`、`create`、`start`；
- Gateway ready；
- health exec wall 和 health internal；
- Agent sample exec wall、Agent internal 和 tool timing；
- 当前有效 TOML、sandboxer hash、mount evidence。

如果 `thread_pool_size=8` 没有稳定收益或导致 `start`/CPU 负载上升，则保留 `4`。

### Stage C: conditional full `/usr` block

只有 Stage A 证明 `/usr` 是明显瓶颈时才执行。将同一镜像中完整、合并后的 `/usr` 导出为独立只读 ext4 镜像，并额外挂载到 `/usr`。因为 `/usr/local` 位于 `/usr` 内，不能再单独挂载 `/usr/local`。

该阶段必须：

- 从运行中容器导出完整合并目录，而不是直接复制 overlayfs 单层；
- 校验 `/usr/local/bin/node`、动态库和关键文件；
- 使用独立镜像、独立 loop 设备和临时 container spec；
- 不修改默认服务配置；
- 失败时只清理临时容器和 loop 设备。

验收条件是 `start` 不超过纯 VirtioFS 基线的约两倍，且 Gateway/health 至少有稳定改善；否则放弃该路径扩展。

### Stage D: separate warm-request study

常驻 Gateway/Agent 复用实验单独进行，不与冷启动结果混合。冷启动每轮重新创建 Pod/VM/container；warm 实验只启动一次 Gateway，然后连续发送多个请求，用于量化 CLI/CRI/Agent 初始化摊销。

## Measurement and reproducibility rules

- 镜像只在 measured phases 之外预拉取；远端 pull 不计入 rootfs 结果。
- `health internal` 与 `health exec wall` 分开报告，避免把 CLI/CRI 外层开销归因于 OpenClaw health 逻辑。
- Agent sample 使用相同 prompt、相同模型和相同工具输入；网络抖动通过三轮结果和 internal timing 单独解释。
- 每个 hybrid artifact 必须保存有效 `vmm.toml`、sandboxer hash、container spec 和 mount evidence；summary 中明确写出 cache 模式。
- 任一轮失败、挂载类型不符、工具 contract 不符或出现残留 CRI/VMM 资源，都标记该配置为无效，不与成功轮混平均。

## Reversibility

所有候选路径均使用独立 loop 镜像和临时 spec。实验结束后停止并删除临时容器、Pod，卸载 loop 镜像即可恢复当前基线；不覆盖现有 `/app`、state 镜像或默认服务配置。

## Out of scope

- 不把 OverlayFS union 作为本轮主要性能优化路径；它保留在功能/生产语义对照中。
- 不用 Agent sample wall 单独证明文件系统优化。
- 不把常驻 Gateway 的 warm latency 与冷启动 latency 合并成一个结论。
