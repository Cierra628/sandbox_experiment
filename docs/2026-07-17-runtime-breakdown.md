# OpenClaw / Kuasar runtime breakdown

测试日期：2026-07-17

## 测试目标

比较同一套隔离 containerd CRI 上的三条 OpenClaw 路径：

1. 普通 runc
2. Kuasar runc sandboxer
3. Kuasar VMM sandboxer + Cloud Hypervisor

镜像已缓存，镜像下载时间不计入测试。固定 agent 样例要求只返回
KUASAR_SAMPLE_OK。样例使用 DeepSeek deepseek-v4-flash，通过
--local 执行 embedded agent，避免 Gateway pairing 对测量的干扰。

## 基础设施三轮结果

以下平均值只统计 PASS 轮次。runc 第一轮因 benchmark 复用了旧 CRI
日志而过早命中 Gateway ready，该轮已剔除；脚本随后改为每轮唯一 log_path。

| 阶段 | runc | kuasar-runc | kuasar-vmm |
| --- | ---: | ---: | ---: |
| runp | 69 ms | 24 ms | 306 ms |
| create | 28 ms | 26 ms | 36 ms |
| start | 68 ms | 64 ms | 70 ms |
| Gateway ready | 4,210 ms | 4,207 ms | 40,130 ms |
| exec true | 61 ms | 62 ms | 70 ms |
| exec Node | 87 ms | 88 ms | 125 ms |
| health exec wall | 3,362 ms | 3,399 ms | 32,870 ms |
| health internal | 9 ms | 9 ms | 524 ms |
| cleanup | 193 ms | 264 ms | 459 ms |
| total | 8,137 ms | 8,195 ms | 74,127 ms |

kuasar-vmm 的基础端到端时间约为普通 runc 的 **9.1 倍**。普通 runc
与 Kuasar runc 相差不足 1%，在本次测试精度下可视为接近。

## 固定模型样例（每种 runtime 三轮）

九次调用全部精确返回 KUASAR_SAMPLE_OK，provider 均为 deepseek，model 均为 deepseek-v4-flash，fallbackUsed=false。下表为均值，括号内为三轮范围。

| 指标 | runc | kuasar-runc | kuasar-vmm |
| --- | ---: | ---: | ---: |
| sample exec wall | 5,775 ms（5,733--5,802） | 6,030 ms（5,915--6,243） | 48,312 ms（46,457--50,468） |
| agent internal | 2,027 ms（1,992--2,073） | 2,234 ms（2,163--2,350） | 9,770 ms（9,024--10,641） |
| exec 外层差值 | 3,748 ms | 3,796 ms | 38,542 ms |
| 全流程 total | 13,949 ms | 14,213 ms | 119,371 ms |
| sample exec 标准差 / CV | 30 ms / 0.52% | 151 ms / 2.50% | 1,651 ms / 3.42% |

VMM sample exec 是 runc 的 **8.37 倍**，全流程是 runc 的 **8.56 倍**。VMM 的 exec 外层差值是 runc 的 **10.28 倍**，且三轮稳定复现。Kuasar runc 的 sample exec 只比 runc 高约 4.4%，全流程高约 1.9%。

模型响应仍受公网和服务端调度影响，但九次调用的输出、provider、model 与 fallback 状态完全一致；VMM sample exec 的 CV 仅 3.42%，因此 8 倍级差异不能用一次性网络抖动解释。

## 瓶颈判断

- 通用 CRI exec/vsock 不是主瓶颈：VMM exec true 只有 70 ms，启动
  Node 也只有 125 ms。
- 容器创建本身不是主瓶颈：VMM 的 create 和 start 与另外两条路径
  接近；runp 虽较慢，但只增加约 0.2--0.3 秒。
- 主要时间集中在 guest 内 OpenClaw 路径：
  - Gateway ready：约 40.1 秒，而容器路径约 4.2 秒。
  - health 外层开销：VMM 约 32.3 秒，容器路径约 3.4 秒。
  - sample 外层开销：VMM 约 39.4 秒，容器路径约 3.7 秒。
- 当前 VMM 使用 virtiofs 挂载 OpenClaw 状态，且此前已确认 SQLite WAL
  SQLITE_IOERR_SHMMAP，需要派生镜像强制回滚日志。因此最值得继续拆分的
  是 guest 内配置加载、插件发现、SQLite 状态访问和 virtiofs 元数据 I/O。

## 公平性边界

这是“当前可运行平台”的端到端比较，不是纯 runtime 微基准：

- runc 和 kuasar-runc 使用 host network、UID 1002 和用户状态目录。
- kuasar-vmm 使用 CNI、guest root 和 /var/lib/openclaw-kuasar 状态目录。
- VMM 路径包含 guest OS、Cloud Hypervisor 和 virtiofs 的实际成本。
- 模型响应还受公网、服务端调度和缓存状态影响。

## 结论

导师要求的 containerd + Kuasar + Cloud Hypervisor + OpenClaw 样例已经
跑通。Kuasar runc 的开销与普通 runc 接近；Cloud Hypervisor 提供更强隔离，
但当前 OpenClaw 端到端启动与样例耗时约增加到 8--9 倍。下一阶段若继续优化，
应优先对 guest 内 OpenClaw 初始化和 virtiofs/SQLite 状态访问做更细粒度 profiling，
而不是优化 runp/create/start 或通用 CRI exec。
