# OpenClaw / Kuasar VMM 混合挂载实验

实验日期：2026-08-03  
平台：containerd CRI v1 + Kuasar VMM sandboxer + Cloud Hypervisor  
实验结果目录：

- `.artifacts/hybrid-app-state-fixed-20260803T033730Z`
- `.artifacts/hybrid-image-workload-20260803T061555Z`
- `.artifacts/union-image-workload-20260803T091706Z`
- `.artifacts/overlayfs-union-smoke-20260803T090831Z`
- `.artifacts/union-reuse-20260803T093038Z`

### 关键结果（3 轮新建实例，单位 s）

| 配置 | `start` | Gateway ready | health exec wall | Agent sample | 单轮 total |
| --- | ---: | ---: | ---: | ---: | ---: |
| VirtioFS `cache=never` | 0.068 | 38.680 | 31.802 | 54.336 | 126.039 |
| VirtioFS `cache=metadata` | 0.052 | 7.694 | 7.352 | 11.159 | 27.339 |
| 全 virtio-blk | 5.930 | 5.604 | 4.541 | 9.496 | 26.851 |
| 直接混合：virtio-blk `/app` + state | 0.067 | 7.380 | 6.973 | 9.825 | 25.454 |
| **union：VirtioFS lower + virtio-blk upper/work + state** | **0.070** | **7.724** | **6.438** | **11.357** | **26.778** |

表中每一行都是镜像已缓存后的 3 轮新建实例 workload；远端 pull 不在这些时间内。加入 `health exec wall` 后，表中的主要应用阶段已经覆盖从容器启动到 Agent sample 的大部分外层耗时；`runp`、`create`、CRI 就绪、cleanup 以及日志/结果收集仍未在此简表中单列，因此这些列相加不会严格等于 `total`。`total` 均来自相应 image-workload 脚本，适合做同一类新建实例的整体比较；若只比较阶段差异，应优先看 `start`、`Gateway ready`、`health exec wall` 和 `Agent sample`。

所有上述 workload 均为 3/3 PASS；Agent 实际完成 32×32→64×64 的本地 `image_upscale`，工具本身约 0.09--0.12 s，因此不是主要瓶颈。

### 简明结论

1. **根因**：`cache=never` 下 VirtioFS 的大量小文件 metadata 往返是主要启动瓶颈。
2. **直接 block**：应用侧最快，但 VMM `start` 约 5.9 s；适合追求单实例绝对性能、可以接受较高冷启动成本的场景。
3. **union**：`start` 约 70 ms，`Gateway ready` 约 7.7 s；本轮 Agent sample 比直接 block 慢约 1.5 s，但该端到端指标还包含 DeepSeek 网络/模型响应抖动，不能把差异全部归因于 union。union 同时保留 VirtioFS lower 的只读复用/共享语义，功能 smoke 和 workload 均通过。
4. **容器复用**：union 复用实验 3 个容器、15/15 请求通过；含启动成本的平均每请求 12.315 s。但每次仍新建 CLI/session，warm 请求不会自动显著变快；真正降低单请求延迟还需要常驻 Gateway/Agent RPC，而不是重复 `crictl exec`。
5. **建议**：把 union 定义为“当前平衡的原型方案”，把直接 virtio-blk 作为性能上界，把 `cache=metadata` 作为低改动基线；后续重点测常驻 Agent、并发和长时间稳定性。

### 远端镜像拉取的边界

远端 Registry 冷启动实验中，Kuasar VMM 平均 `pause pull` 约 6.4 s、目标镜像 pull 约 8.0 s；这些是网络/Registry 成本，必须与 rootfs 和 VMM breakdown 分开。本文的 rootfs/union 对照均在镜像已缓存后测量，避免把网络波动误归因于挂载方式。

## 1. 实验目的

在 containerd → Kuasar → Cloud Hypervisor 链路上，比较 VirtioFS、virtio-blk、直接混合挂载和 OverlayFS union，并进一步验证容器复用。

核心问题是：能否保留 VMM 启动速度，同时降低 OpenClaw 启动阶段大量小文件访问的开销；以及同一容器连续处理多个请求时，启动成本能否被摊薄。

## 2. 既有实验脉络

本报告承接前面的三类对照与远端冷启动实验，先固定解释各配置的角色：

| 阶段 | 配置/问题 | 得出的结论 |
| --- | --- | --- |
| 初始三路对照 | `runc`、`kuasar-runc`、`kuasar-vmm` | VMM 的 `runp/start` 本身可运行，但 VirtioFS rootfs 在 OpenClaw 大量小文件初始化时成为主要瓶颈；普通 runc 与 Kuasar runc 的应用侧初始化接近。|
| rootfs 控制变量 | VirtioFS、virtio-blk、VirtioFS + metadata cache | virtio-blk 能显著降低小文件 metadata/read 开销，但完整 virtio-blk 会把设备/文件系统准备成本移入 VMM 启动阶段。metadata cache 只能改善部分访问，不能消除 FUSE/virtiofs 往返。|
| 容器复用 | 同一容器内重复请求 | 复用后跳过 VMM/容器创建和大部分 agent 初始化，后续请求明显低于冷启动；因此冷启动与稳态请求必须分开报告。|
| 远端 Registry 冷拉取 | 每轮清空目标镜像缓存后再从内网 Registry pull | `pause pull`、目标镜像 pull、Gateway/health、Agent sample 是不同时间段，不能把网络拉取开销误归因于 VMM 或 rootfs。|
| 当前混合方案 | VirtioFS rootfs + virtio-blk `/app` + virtio-blk state | 保留约 66 ms 的 VMM `start`，同时把 Gateway ready 降至约 7.37 s；Agent image-upscale sample 3/3 通过。|
| OverlayFS union | VirtioFS lower + virtio-blk upper/work + virtio-blk state | guest 内 `/app` 形成 overlayfs merged view；smoke、冷 workload 和复用 workload 均通过。|

因此，本报告后续的 union 实验不是替换已有基线，而是更接近生产语义的组合：VirtioFS 只读 lower、virtio-blk 提供 writable upper/work，并在 guest 内形成 OverlayFS merged view。

## 3. 实验方法

固定条件：同一 containerd CRI endpoint、同一 OpenClaw 镜像、同一 `kuasar-vmm` handler，每次创建一个全新的 Pod/容器，共运行 3 轮。每轮执行：

```text
CRI ready → runp → create → start → Gateway ready → health → cleanup
```

挂载配置：

| 路径 | 实际介质 | 权限 | 说明 |
| --- | --- | --- | --- |
| `/` | VirtioFS rootfs | 由 rootfs 配置决定 | 保留 VMM 的原始启动路径 |
| `/app` | virtio-blk，`/dev/loop24` | 只读 | 从正常容器的合并 `/app` 视图导出后制作 ext4 镜像，大小 1.25 GiB |
| `/home/node/.openclaw` | virtio-blk，`/dev/loop8` | 读写 | OpenClaw 配置、插件、SQLite 和 workspace 状态 |

每轮挂载证据均显示：

```text
/app                  ext4 /dev/vda ro
/home/node/.openclaw  ext4 /dev/vdb rw
```

因此该实验确实使用了两个 virtio-blk 路径，而不是误把 overlayfs 单层目录当作完整应用目录。实验脚本为 `scripts/23-benchmark-hybrid-app-state.sh`。

本实验不包含远端镜像 pull；Agent sample 单独在同一混合挂载配置下运行 3 轮，用于避免把镜像拉取时间混入应用 workload。

### 时间口径

- `start` 是 host 侧 `StartContainer` 调用的 wall time；
- `Gateway ready` 从 `start` 返回后开始，到日志出现 `[gateway] ready` 为止，不包含 `start`；
- `health exec wall` 和 `Agent sample exec wall` 包含 host 发起 `crictl exec`、启动新的 Node/OpenClaw CLI、配置/插件初始化、Gateway/模型交互以及 CLI 退出；
- `health internal` 和 `Agent internal` 是 OpenClaw JSON 内部计时，不包含外层 CRI exec；
- `total` 是该 workload 脚本从本轮开始到 cleanup 完成的 host wall time，不包含远端 Registry pull。

## 4. 实验结果

三轮均通过（3/3 PASS）：

| 阶段 | 平均耗时 |
| --- | ---: |
| CRI ready | 24.7 ms |
| `runp` | 353.0 ms |
| `create` | 41.3 ms |
| `start` | 66.0 ms |
| Gateway ready | **7374.3 ms** |
| health exec wall | **6998.7 ms** |
| health internal | 15.7 ms |
| cleanup | 463.3 ms |
| 本批次 total | 15425.7 ms |

`health exec wall` 远大于 `health internal`，主要因为每次 `crictl exec` 都要重新启动 Node/OpenClaw CLI、加载配置和插件，再通过 CRI 连接本地 Gateway；不是 Gateway 内部 health 处理本身耗时。

## 5. 与已有 VMM 配置对比

三轮平均值，单位 ms：

| 配置 | `start` | Gateway ready | health exec wall |
| --- | ---: | ---: | ---: |
| VirtioFS 全路径（`cache=never`） | 67.7 | 38680.3 | 31802.0 |
| VirtioFS + virtio-blk state | 62.3 | 8418.7 | 8075.0 |
| **VirtioFS + virtio-blk `/app` + state** | **66.0** | **7374.3** | **6998.7** |
| 全 virtio-blk | 5930.3 | 5603.7 | 4540.7 |

相对“VirtioFS + virtio-blk state”，再把 `/app` 迁移到 virtio-blk 后：

- Gateway ready 减少约 **1044 ms（12.4%）**；
- health exec wall 减少约 **1076 ms（13.3%）**。

相对 VirtioFS 全路径：

- Gateway ready 减少约 **31.3 s（80.9%）**；
- health exec wall 减少约 **24.8 s（78.0%）**。

全 virtio-blk 的 Gateway/health 更快，但其 `start` 平均约 5.93 s；混合方案将 `start` 保持在 66 ms 左右，避免了全 virtio-blk 的 VMM 启动代价。

## 6. Agent image-upscale sample

每轮创建全新容器，要求 Agent 调用一次本地 `image_upscale` 工具，将 32×32 PGM 放大到 64×64（1024→4096 像素），并返回 `KUASAR_SAMPLE_OK`。Agent sample 是端到端时间，包含新的 CLI/session、DeepSeek API 请求和本地工具调用；三轮均满足：

- Agent 返回文本完全匹配；
- `fallbackUsed=false`，provider 为 `deepseek`；
- 工具 trace `ok=true`，输入/输出像素数和 `scale=2` 均正确。

| 阶段 | 平均耗时 |
| --- | ---: |
| Agent sample exec wall | **9825.3 ms** |
| Agent internal | **3997.7 ms** |
| 工具 read | 0.39 ms |
| 工具 compute | 114.27 ms |
| 工具 write | 0.37 ms |
| 工具 total | 115.03 ms |

与已有同 workload 结果对比，单位 ms：

| 配置 | Agent sample exec | Agent internal | 工具 total |
| --- | ---: | ---: | ---: |
| VirtioFS 全路径（`cache=never`） | 54335.7 | 14624.0 | 91.7 |
| VirtioFS + metadata cache | 11158.7 | 4696.7 | 89.5 |
| **VirtioFS + virtio-blk `/app` + state** | **9825.3** | **3997.7** | **115.0** |
| 全 virtio-blk | 9496.3 | 5135.0 | 94.7 |

相对 VirtioFS `cache=never`，混合方案将 Agent sample exec wall 降低约 **81.9%**，Agent internal 降低约 **72.7%**。工具本身只有约 115 ms，远小于 Agent exec wall，因此主要开销来自 CLI/Agent 初始化、文件访问、模型交互、网络等待和 CRI exec，而不是超分计算。比较不同挂载方式时，工具 timing 和 health internal 比端到端 Agent wall 更稳定，但仍需保留相同请求和相同模型条件。

本脚本的 `total` 包含 sample，但没有旧完整 workload 脚本中的额外 `exec true`、`exec node` 阶段，故不直接用 `total` 与旧报告总时间做结论；阶段指标可直接比较。


## 7. OverlayFS union smoke：当前能力边界

为验证“VirtioFS 只读 lower + virtio-blk writable upper/work”是否能直接由容器完成，我们准备了独立的 ext4 upper/work 镜像（`/dev/loop25`），并以 `kuasar-vmm` 启动一个只用于能力探测的容器。测试设计为：

```text
runp → create → start → bind /app 到 lower → mount overlay → 写入 upper → 校验 lower 不变
```

首轮使用 `privileged=true` 时，Kuasar VMM 在 `CreateContainer` 阶段直接拒绝：

```text
no privileged container allowed in sandbox
```

随后改为 `privileged=false` 并仅请求 `CAP_SYS_ADMIN`。该轮已经通过 `runp`、`create` 和 `start`，但 guest 内第一次操作：

```text
mount --bind /app /app.lower
```

返回 `permission denied`，因此真正的 `mount -t overlay`、upper 写入和 lower 不变校验均未执行。结果目录为：

```text
.artifacts/overlayfs-union-smoke-20260803T064646Z
```

结果摘要：

```json
{"status":"FAIL","note":"overlay-mount-failed","smoke_ms":513}
```

这不是 upper 镜像损坏，也不能直接解释为“VirtioFS lower 不支持 OverlayFS”。它说明当前 VMM 容器进程不能执行 mount，即使 CRI spec 请求了 `CAP_SYS_ADMIN`；而 `privileged` 又被 sandboxer 有意禁止。因而 union mount 必须由 Kuasar guest task/sandbox 初始化阶段以 guest root 完成，再把生成的 merged 路径以 bind mount 提供给容器。

随后已实现一个显式 union 配置驱动的 guest hook：host `vmm-sandboxer` 生成 synthetic `overlay-union` storage，guest `vmm-task` 负责 lower bind、OverlayFS mount 和逆序卸载；默认无 union 配置的容器路径不变。源码测试、release 构建和安装均已通过。

最初尝试把配置放进自定义 OCI `annotations/labels`，但 containerd CRI 会在传给 Kuasar 前过滤这两个字段，导致 sandboxer 看不到配置。最终改用 containerd 会保留的进程环境变量 `OPENCLAW_KUASAR_OVERLAY_UNION` 作为控制通道；StorageHandler 解析后会移除该内部变量，不传给应用进程。

运行时 smoke 已通过：

- 结果目录：`.artifacts/overlayfs-union-smoke-20260803T090831Z`；
- `/app`：`overlayfs`；
- `/app.lower`：VirtioFS lower；
- `/tmp`：virtio-blk upper/work；
- upper 写入成功，lower 内容保持不变；
- 容器非 privileged，最终退出码为 0。

因此 union 方案已经完成功能验收。

## 8. Union workload 实验

在 smoke 通过后，使用 `scripts/29-benchmark-union-image-workload.sh` 补跑与前面相同的 Agent image-upscale workload。每轮创建全新容器，执行 Gateway ready、health 和一次本地 `image_upscale`（32×32 PGM → 64×64 PGM，512 次计算 pass）。

配置如下：

| 路径 | 实际挂载 | 作用 |
| --- | --- | --- |
| `/app` | OverlayFS merged view | 容器看到的应用路径 |
| `/app.lower` | VirtioFS | 只读 lower，便于校验 lower 未被修改 |
| `/tmp` | virtio-blk `/dev/loop25` | writable upper/work |
| `/home/node/.openclaw` | virtio-blk `/dev/loop8` | state、SQLite、workspace |

三轮均通过（3/3 PASS）：

| 阶段 | 平均耗时 |
| --- | ---: |
| `runp` | 363.0 ms |
| `create` | 40.7 ms |
| `start` | 70.3 ms |
| Gateway ready | 7724.0 ms |
| health exec wall | 6437.7 ms |
| health internal | 22.3 ms |
| Agent sample exec wall | 11357.3 ms |
| Agent internal | 4623.7 ms |
| 工具 read / compute / write | 0.43 / 114.65 / 0.37 ms |
| 工具 total | 115.46 ms |
| total | 26777.7 ms |

与“直接把完整 `/app` 导出为 virtio-blk”相比：

| 配置 | `start` | Gateway ready | Agent sample exec | Agent internal |
| --- | ---: | ---: | ---: | ---: |
| 直接 virtio-blk `/app` + state | 67.3 ms | 7380.0 ms | 9825.3 ms | 3997.7 ms |
| **VirtioFS lower + union upper/work + virtio-blk state** | **70.3 ms** | **7724.0 ms** | **11357.3 ms** | **4623.7 ms** |

当前 union 版本相对直接 `/app` virtio-blk 的平均差异为：Gateway ready +344 ms、Agent sample exec +1532 ms、Agent internal +626 ms；但两者仍保持相同数量级的 VMM 启动成本，且 union 保留了原始 VirtioFS lower 的只读语义。工具本身仍约 115 ms，端到端差异由 union/upper 路径上的应用初始化、Agent/CLI 外层和模型网络抖动共同构成，不能全部归因于 OverlayFS。

### 8.1 两种混合挂载方案的区别

两种方案都保留 VirtioFS 作为 VMM rootfs，并把 `/home/node/.openclaw` 放到 virtio-blk；区别只在 `/app`：

```text
直接 /app：
VirtioFS rootfs + /app → virtio-blk ext4（完整复制的应用目录）

Union：
VirtioFS rootfs + /app.lower → VirtioFS 原始 lower
                  + /tmp → virtio-blk upper/work
                  = /app overlayfs merged view
```

| 对比项 | 直接 virtio-blk `/app` | VirtioFS lower + union |
| --- | --- | --- |
| 应用文件位置 | 完整复制到 ext4 block image | 保留在原始 VirtioFS lower，upper/work 单独放 block image |
| `/app` 访问路径 | 直接访问 ext4 | 先经过 OverlayFS，再访问 upper 或 VirtioFS lower |
| 应用更新 | 需要重新导出并制作 `/app` 镜像 | lower 随原始镜像更新，通常不需要复制整份 `/app` |
| `/app` 写入语义 | 只读，写入失败 | 写入通过 copy-up 进入 upper，删除通过 whiteout 隔离 |
| 实现复杂度 | 较低 | 需要 guest OverlayFS hook、upper/work 和额外 runtime 配置 |

因此，直接 `/app` 是“把应用整体搬到 block 上”；union 是“保留 VirtioFS 应用 lower，再用 block 提供可写层”。后者更接近镜像共享和容器写时隔离的生产语义，但不是简单地把 `/app` 替换成另一种文件系统。

### 8.2 为什么 union 比直接 `/app` 略慢

本轮数据中两者 `start` 分别为 70.3 ms 和 67.3 ms，只相差约 3 ms，说明 union mount 的创建本身不是主要成本。主要差异来自以下路径：

1. **union 的 lower 仍是 VirtioFS**：直接 `/app` 的所有应用文件都在 ext4 block image；union 中大部分首次读取会落到 VirtioFS lower，仍需经过 FUSE/virtiofsd 往返，因此没有完全获得 virtio-blk 的小文件访问优势。
2. **OverlayFS 增加路径解析层**：每次查找需要处理 merged view，并检查 upper/work；发生写入、copy-up 或 whiteout 时还会增加额外元数据操作。OpenClaw 启动阶段的大量目录遍历会放大这类固定开销。
3. **Agent sample 不是纯文件系统指标**：union 的 Agent sample exec wall 比直接 block 高 1532 ms，但该指标还包含 CLI 启动、DeepSeek API/模型响应和网络抖动；Agent internal 高 626 ms，也不能单独归因于 OverlayFS。
4. **本地工具耗时没有明显差异**：两者 `image_upscale` tool total 都约 115 ms，说明超分计算不是 union 变慢的原因。

因此，union 的实际代价主要是“VirtioFS lower 访问 + OverlayFS 路径层”，而不是 VMM 启动。它换取的是 lower 共享、upper 隔离和无需复制完整 `/app` 镜像的管理优势。

## 9. Union 容器复用实验

为区分“每次创建新容器的冷启动”和“同一容器内连续请求”的差异，使用 `scripts/30-benchmark-union-reuse.sh`。每轮创建一个全新的 `kuasar-vmm` 容器，然后在该容器内连续执行 5 次相同的 `image_upscale` Agent 请求；共 3 个容器、15 次请求。第 1 次标记为 `first`，第 2--5 次标记为同一容器内的 `warm`。这里的 `warm` 只表示复用容器和挂载，不表示复用一个常驻 Agent 进程；每次仍通过 `crictl exec` 启动新的 OpenClaw CLI，并使用新的 session key。

每个容器都验证了相同挂载：`/app=overlayfs`、`/app.lower=fuseblk`、`/home/node/.openclaw=ext2/ext3` 和 `/tmp=ext2/ext3`。其中 `stat -f` 对 lower 显示 `fuseblk`，而 mountinfo 同时确认其来源是 VirtioFS；两个 ext2/ext3 路径是 virtio-blk 设备。

实验结果为 15/15 PASS：

| 指标 | 平均耗时 |
| --- | ---: |
| 容器启动总段（runp + create + start + Gateway ready） | 8170.7 ms |
| Gateway ready | 7725.7 ms |
| health exec wall | 6527.3 ms |
| first Agent sample exec wall | 10672.0 ms |
| first Agent internal | 3571.3 ms |
| warm Agent sample exec wall（请求 2--5） | 10683.1 ms |
| warm Agent internal（请求 2--5） | 3983.2 ms |
| 工具 total | 115.5 ms |
| 含启动成本的平均每请求耗时 | 12314.7 ms |

在本实验中，warm 请求没有比 first 请求显著更快：`sample exec wall` 几乎相同，`Agent internal` 反而平均高约 412 ms。原因是实验刻意让每次请求都重新启动 CLI、创建新 session 并访问模型服务；容器复用只消除了下一次请求的 VMM/CRI/Gateway 启动成本，并没有复用常驻 Agent 或模型连接。因此本结果说明“复用容器可以摊薄启动成本”，但不能据此声称单次 Agent 推理本身会自动变快。

与已有 3 容器、每容器 5 请求的复用结果相比：

| 配置 | 启动总段 | first exec | warm exec | 含启动平均每请求 |
| --- | ---: | ---: | ---: | ---: |
| 直接 virtio-blk `/app` + state | 11793 ms | 8624 ms | 8372 ms | 10780 ms |
| VirtioFS + metadata cache | 7759 ms | 11014 ms | 11431 ms | 12899 ms |
| **VirtioFS lower + union upper/work + virtio-blk state** | **8171 ms** | **10672 ms** | **10683 ms** | **12315 ms** |

union 的复用表现接近 VirtioFS metadata cache，同时保留了 guest 内 OverlayFS 的 upper/work 隔离语义；相较直接 block `/app`，当前实现仍有约 1.5 s 的平均每请求差距，主要来自 `/app` union 层、Agent/CLI 外层和模型网络抖动，而不是 image_upscale 工具本身。

## 10. 结论与边界

1. **混合挂载方案功能正确**：直接 block `/app` + state 和 union `/app` + state 均 3/3 轮通过。
2. **union 语义已经实现并验证**：VMM 保持 VirtioFS lower，guest 内创建 OverlayFS merged `/app`，virtio-blk 只承载 upper/work 和可写 state。
3. **启动成本没有退化到全 virtio-blk**：union 的 `start` 约 70 ms，而全 virtio-blk 基线约 5.9 s；因此避免了将完整 rootfs 设备准备成本放到 VMM 启动阶段。
4. **union 当前不是直接 block `/app` 的无损性能替代**：本轮 `start` 只多约 3 ms，但 Gateway/Agent 指标略慢，主要因为应用读取仍要经过 VirtioFS lower 和 OverlayFS 路径层；Agent 端到端差异还包含模型网络抖动。它的优势是 lower 共享、upper 写时隔离和不必复制完整 `/app` 镜像。
5. **Agent sample 结果有效**：3/3 轮均完成实际 image_upscale，输出 4096 像素，`fallbackUsed=false`；工具计算约 115 ms，不是主要瓶颈。
6. **容器复用必须单独解释**：本轮 3 个容器、15 次请求全部通过，但 warm 请求仍通过新的 CLI/session 执行；复用主要摊薄 VMM、CRI 和 Gateway 启动成本，不等价于常驻 Agent 进程或模型连接复用。
7. **当前推荐**：union 适合作为“VirtioFS 只读 lower + virtio-blk 可写层”的原型，已完成功能与三轮 workload 验证；直接 virtio-blk 仍是性能上界，`cache=metadata` 是较低改动的对照方案。union 尚需并发、长生命周期和常驻 Agent RPC 验证后，才能作为生产默认配置。
