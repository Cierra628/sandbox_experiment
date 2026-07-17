# OpenClaw / Kuasar 实施交接记录

> 最后更新：2026-07-17。导师要求的部署、固定样例和 runtime breakdown
> 已全部完成。后续工作属于可选性能优化，不再是部署阻塞。

## 目标

必须跑通以下真实链路，不允许静默回退到普通 runc：

    OpenClaw
      -> CRI
      -> 隔离 containerd v2
      -> Kuasar VMM sandboxer
      -> Cloud Hypervisor

导师要求：

- 上层交互使用 containerd。
- runtime 技术栈使用 Kuasar。
- VMM 使用 Cloud Hypervisor。
- 跑一个 OpenClaw 样例。
- 对执行过程做 breakdown，判断慢点在哪里。

以上要求均已完成。

## 最终 gate

| Gate | 状态 | 证据 |
| --- | --- | --- |
| 主机 OpenClaw | PASS | Gateway 监听 127.0.0.1:18789 |
| 隔离 containerd CRI | PASS | RuntimeReady、NetworkReady |
| 普通 runc | PASS | 容器 RUNNING，health ok |
| Kuasar runc | PASS | 容器 RUNNING，health ok |
| Kuasar VMM | PASS | Cloud Hypervisor guest、容器和 Gateway 正常 |
| VMM CNI | PASS | IPv4、默认路由、DNS、NAT 正常 |
| DeepSeek plugin/auth | PASS | provider profile 可用 |
| 固定模型样例 | PASS | 每种 runtime 三轮，共 9/9 成功 |
| runtime breakdown | PASS | 基础设施和模型分阶段数据已采集 |

固定模型样例九次均返回 KUASAR_SAMPLE_OK，provider 为 deepseek，model 为
deepseek-v4-flash，fallbackUsed=false。

完整报告：
docs/2026-07-17-runtime-breakdown.md

## 固定版本与关键路径

- OpenClaw：2026.6.11
- Kuasar：v1.1.0
- Cloud Hypervisor：v52.0
- 派生镜像：localhost/openclaw-kuasar:2026.6.11-virtiofs
- Pause 镜像：registry.k8s.io/pause:3.10
- CRI socket：unix:///run/openclaw-kuasar/containerd.sock
- runtime handlers：runc、kuasar-runc、kuasar-vmm
- 用户状态副本：
  $HOME/.local/share/openclaw-kuasar/openclaw-state
- VMM 状态目录：
  /var/lib/openclaw-kuasar/openclaw-state
- VMM：2 vCPU、2048 MiB、cold boot、virtiofs
- CNI：10.86.0.0/16，配置安装到 /etc/openclaw-kuasar/cni

不会替换或修改主机的 /usr/bin/containerd、/etc/containerd/config.toml、
/etc/crictl.yaml 或已有 Kata 服务。

## 最终性能结果

### 基础设施三轮

| 指标 | runc | Kuasar runc | Kuasar VMM |
| --- | ---: | ---: | ---: |
| runp | 69 ms | 24 ms | 306 ms |
| create | 28 ms | 26 ms | 36 ms |
| start | 68 ms | 64 ms | 70 ms |
| Gateway ready | 4.210 s | 4.207 s | 40.130 s |
| exec true | 61 ms | 62 ms | 70 ms |
| exec Node | 87 ms | 88 ms | 125 ms |
| health exec | 3.362 s | 3.399 s | 32.870 s |
| 基础 total | 8.137 s | 8.195 s | 74.127 s |

早期 runc 第一轮因复用旧 CRI 日志而错误命中 ready，已剔除。benchmark
之后已改为每轮唯一 log_path。

### 模型样例三轮

| 指标 | runc | Kuasar runc | Kuasar VMM |
| --- | ---: | ---: | ---: |
| sample exec 平均 | 5.775 s | 6.030 s | 48.312 s |
| sample exec 范围 | 5.733--5.802 s | 5.915--6.243 s | 46.457--50.468 s |
| agent internal | 2.027 s | 2.234 s | 9.770 s |
| exec 外层差值 | 3.748 s | 3.796 s | 38.542 s |
| 全流程 total | 13.949 s | 14.213 s | 119.371 s |
| sample CV | 0.52% | 2.50% | 3.42% |

Kuasar VMM sample exec 是 runc 的 8.37 倍，全流程是 8.56 倍，且三轮
稳定复现。Kuasar runc 与普通 runc 接近。

### 瓶颈结论

- 通用 CRI exec/vsock 不是主要瓶颈：VMM exec true 约 70 ms。
- create/start 不是主要瓶颈，两条路径差异只有毫秒级。
- 主要时间集中在 guest 内 OpenClaw：
  - Gateway ready 约 40 秒。
  - health exec 约 32 秒。
  - sample 外层开销约 38.5 秒。
- 优先调查方向：OpenClaw 配置加载、插件发现、SQLite 状态访问和
  virtiofs 元数据 I/O。
- 模型调用受公网和缓存影响，但 VMM 的 8 倍级差异在三轮中稳定存在。

这是当前可运行平台的端到端比较，不是纯 runtime 微基准。runc/Kuasar runc
使用 host network 和 UID 1002；VMM 使用 CNI、guest root 和独立状态目录。

## 最终实现要点

1. 隔离 runtime

   三个 systemd 单元均已安装并验证 active：

       openclaw-kuasar-runc.service
       openclaw-kuasar-vmm.service
       openclaw-kuasar-containerd.service

2. VMM 存储

   Kuasar v1.1.0 的 virtio-blk 路径曾在 guest mount /dev/vdb 时返回 EIO。
   最终使用官方默认 virtiofs。virtiofsd 位于 /usr/libexec/virtiofsd，
   cache=never。

3. SQLite 兼容

   Node SQLite WAL 在 virtiofs 上稳定返回 SQLITE_IOERR_SHMMAP。DELETE
   journal 测试成功，因此派生镜像将 OpenClaw 对网络文件系统的 SQLite
   journal 改为 rollback 模式。

4. youki/cpuset

   旧 OCI spec 会序列化空 cpuset 字段，guest youki 误判 cpuset controller
   为必需。最终移除容器 CRI linux.resources；VM 资源仍由 Cloud Hypervisor
   配置提供。

5. 状态与权限

   普通容器使用 UID/GID 1002。VMM 使用
   /var/lib/openclaw-kuasar/openclaw-state、root 和 VMM 专用 container spec，
   避免 virtiofs UID 映射导致 EACCES。

6. DeepSeek

   VMM 状态目录内已注册官方 DeepSeek provider，auth profile 可用。
   benchmark 使用 --local embedded agent，避免 Gateway scope-upgrade/pairing
   干扰耗时。

7. 网络

   VMM 使用专用 IPv4 CNI bridge openclaw-cni0，网段 10.86.0.0/16，
   DNS 10.2.0.1。CNI firewall 和 NAT 已验证；禁用 guest NIC IPv6，避免
   Kuasar guest netlink 对 IPv6 地址返回 EOPNOTSUPP。

## 常用验证命令

服务：

    sudo systemctl is-active \
      openclaw-kuasar-runc.service \
      openclaw-kuasar-vmm.service \
      openclaw-kuasar-containerd.service

CRI：

    EP=unix:///run/openclaw-kuasar/containerd.sock
    sudo crictl --runtime-endpoint "$EP" --image-endpoint "$EP" info

运行 VMM gate：

    OPENCLAW_RUNTIME_HANDLER=kuasar-vmm \
    AUTO_CLEANUP=0 RUN_CRICTL=1 \
      ./scripts/04-run-with-crictl.sh

健康检查：

    CID=$(jq -r .container_id .state/last-run.json)
    sudo crictl --runtime-endpoint "$EP" --image-endpoint "$EP" \
      exec "$CID" node openclaw.mjs gateway health --json

完整三轮 benchmark：

    BENCHMARK_RUNS=3 MODEL_SAMPLE_RUNS=3 \
      ./scripts/08-benchmark-runtimes.sh

查看最新汇总：

    RESULT_DIR=$(find .artifacts -maxdepth 1 -type d \
      -name 'breakdown-*' | sort | tail -n 1)
    jq . "$RESULT_DIR/summary.json"

## 已解决故障索引

- GHCR/registry reset、EOF、timeout：使用 127.0.0.1:17890 代理。
- pause 镜像拉取失败：通过专用 containerd namespace 导入。
- runc sandboxer systemd timeout：Type=notify 改为 Type=simple。
- hostname/UTS 错误：修正 Pod namespace。
- /proc/0/ns/pid：不再共享错误的 host PID/IPC namespace。
- 18789 EADDRINUSE：容器 Gateway 改用 18790。
- Kuasar virtio-blk /dev/vdb EIO：切换 virtiofs。
- youki cpuset controller：移除触发兼容问题的 CRI resources。
- SQLite WAL/SHM EIO：派生镜像使用 rollback journal。
- VMM 状态 EACCES：VMM 专用 root-owned 状态目录和 spec。
- DeepSeek plugin/auth 缺失：在 VMM state 中完成注册与数据库规范化。
- VMM 无路由/DNS：安装独立 IPv4 CNI、firewall、NAT。
- IPv6 netlink EOPNOTSUPP：CNI tuning 禁用 guest NIC IPv6。
- health 首次 timeout/1006：等待 Gateway ready 后再测。
- benchmark 旧 ready 误判：每轮使用唯一 CRI log_path。

## 当前剩余工作

导师本阶段要求已经全部完成，没有部署 blocker。

可选后续工作：

1. 对 guest 内 OpenClaw 初始化做函数级 profiling。
2. 分离插件扫描、SQLite 和 virtiofs 元数据 I/O 的耗时。
3. 尝试 guest-local block/state 或优化 virtiofs 缓存策略。
4. 修正仍较旧的 scripts/openclaw-platform；正式 benchmark 以
   scripts/08-benchmark-runtimes.sh 为准。

## Git 与凭据边界

.gitignore 已排除：

    .cache/
    .state/
    .artifacts/
    .secrets/
    images/openclaw/*.tar

当前目录约 317 MB，主要是 .cache；实际待提交源码和文档约 300 KB。
不要提交 OpenClaw 状态数据库、API key、token、原始诊断日志或运行时镜像。
