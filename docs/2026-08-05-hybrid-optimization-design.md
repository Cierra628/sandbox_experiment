# 混合挂载 Gateway/health 优化实验设计

## 1. 背景与当前结论

当前混合方案为 VirtioFS rootfs，并将 `/app`、`/home/node/.openclaw` 和 `/usr/local` 分别放到 virtio-blk 设备上。最新三轮实验确认挂载正确且 workload 全部通过，但 `/usr/local` 单独迁移没有降低 Gateway ready：

| 配置 | VMM start | Gateway ready | health exec | Agent sample |
|---|---:|---:|---:|---:|
| `/app` + state blk | 67 ms | 7380 ms | 6973 ms | 9825 ms |
| 再加 `/usr/local` blk | 72 ms | 7379 ms | 7462 ms | 9740 ms |
| 全 virtio-blk rootfs | 5930 ms | 5604 ms | 4541 ms | 9496 ms |

因此，当前瓶颈不是 `/usr/local` 单一路径；VirtioFS 根文件系统中剩余的系统运行时访问仍可能占据主要时间。

## 2. 目标与非目标

目标：

1. 在不破坏现有实验环境的前提下定位 Gateway/health 仍访问的 VirtioFS 路径。
2. 验证将完整 `/usr` 作为只读 virtio-blk 挂载后，是否能降低 Gateway/health。
3. 将 VMM start 增量控制在约 1 秒以内。
4. 保持 OpenClaw health、image-upscale Agent sample 和挂载完整性通过。

非目标：

- 本轮不直接修改系统服务或覆盖现有 `/usr/local`、`/etc` 配置。
- 不把一次性 profiling 的绝对 wall time 当作最终性能结论。
- 不在没有路径归因证据时继续盲目增加挂载点。

## 3. 实验矩阵

### 3.1 路径归因阶段

保持当前配置不变：

```text
VirtioFS /
/app                  -> virtio-blk, read-only
/home/node/.openclaw  -> virtio-blk, read-write
/usr/local            -> virtio-blk, read-only
```

使用 profiling 镜像，分别观察 `config validate`、Gateway 启动、health exec 和 Agent sample 的文件访问，将路径归类为：

```text
/app
/home/node/.openclaw
/usr/local
/usr/lib、/lib、/usr/bin
/etc
其他 VirtioFS 路径
```

该阶段只收集证据，不改变挂载配置。`strace` 会放大 VirtioFS 往返，因此只用于定位访问集合和相对热点。

### 3.2 `/usr` 只读 virtio-blk 阶段

从运行中的同一 OpenClaw 镜像导出完整 `/usr`，制作只读 ext4 镜像并作为一个 virtio-blk 设备挂载：

```text
VirtioFS /
/usr                  -> virtio-blk, read-only
/app                  -> virtio-blk, read-only
/home/node/.openclaw  -> virtio-blk, read-write
```

不再额外挂载 `/usr/local`，因为它已经包含在 `/usr` 中。这样同时覆盖：

- `/usr/local/bin/node`；
- `/usr/local/lib`；
- `/usr/lib`；
- `/usr/bin`；
- `/usr/share`；
- Debian 中 `/lib -> /usr/lib` 的目标路径。

在启动前验证镜像内存在 Node、OpenClaw 入口和动态链接器；运行时验证 `/etc/hosts`、`/etc/resolv.conf`、`/etc/hostname` 等 CRI 注入文件仍可见。

### 3.3 三轮 A/B 阶段

使用相同镜像、相同 32x32 -> 64x64 image-upscale workload，每种配置运行 3 轮：

1. 当前 `/app + state + /usr/local` blk 基线；
2. `/app + state + /usr` blk 候选；
3. 全 virtio-blk rootfs 性能参考。

每轮记录 `cri_ready`、`runp`、`create`、`start`、`gateway_ready`、`health_exec`、`health_internal`、`sample_exec`、`sample_internal`、工具内部三段和 `total`。

## 4. 成功判据

`/usr` 候选只有同时满足以下条件才判为有效优化：

- 3/3 轮通过；
- Gateway ready 和 health exec 相对当前混合基线均有稳定下降；
- VMM `start` 增量不超过约 1 秒；
- Agent sample exec 没有超过 10% 的回归；
- mount evidence 确认 `/usr` 为只读 virtio-blk；
- OpenClaw health、Agent sample、SQLite 写入和 CRI 注入文件均正常。

如果 `/usr` 仍无稳定收益，则停止扩大路径级挂载，结论转为：当前 Gateway/health 的剩余开销来自 VirtioFS 根文件系统中分散的系统访问；若只追求阶段性能，应使用完整 virtio-blk rootfs，并单独报告其较高的 VMM start 代价。

## 5. 可逆性与故障处理

- 新的 `/usr` 镜像使用独立路径和独立 loop 设备，不覆盖现有 app/state 镜像。
- 每轮使用唯一 CRI pod/container 名称，并在结束时清理资源。
- 任何挂载、权限、入口或 health 失败都保留 result 目录、生成的 spec 和 VMM 日志。
- 恢复当前环境只需停止并清理候选容器，重新使用现有 `containerd/openclaw-container-vmm.json` 和原有 app/state loop；不需要修改系统服务。

## 6. 预期产物

- 路径归因结果目录：`.artifacts/hybrid-path-profile-*`；
- `/usr` 镜像准备目录：`.artifacts/hybrid-usr-prep-*`；
- `/usr` 候选三轮结果：`.artifacts/hybrid-usr-runtime-*`；
- mount evidence、health/sample 输出和每轮 summary；
- 最终在实验报告中明确记录“有效优化”或“负结果”。
