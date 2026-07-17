# OpenClaw + Kuasar + Cloud Hypervisor 实验平台

本项目在不替换主机现有 containerd/Kata 配置的前提下，搭建了一套隔离的
containerd v2 + Kuasar v1.1.0 平台，并在三种 runtime 上运行同一个
OpenClaw 2026.6.11 样例：

    OpenClaw
      -> CRI
      -> 隔离 containerd
      -> runc / Kuasar runc / Kuasar VMM
      -> Cloud Hypervisor（VMM 路径）

专用 CRI endpoint：

    unix:///run/openclaw-kuasar/containerd.sock

## 当前状态（2026-07-17）

所有功能 gate 和 breakdown 均已完成：

| 项目 | 状态 |
| --- | --- |
| 主机 OpenClaw Gateway | PASS |
| 普通 runc + OpenClaw | PASS |
| Kuasar runc + OpenClaw | PASS |
| Kuasar VMM + Cloud Hypervisor + OpenClaw | PASS |
| Gateway health | PASS |
| DeepSeek 固定样例 | 9/9 PASS |
| 三种 runtime 分阶段 breakdown | PASS |

九次模型调用全部精确返回 KUASAR_SAMPLE_OK，使用
deepseek/deepseek-v4-flash，且没有 fallback。

完整实验结论见
[docs/2026-07-17-runtime-breakdown.md](docs/2026-07-17-runtime-breakdown.md)，
故障处理与上下文恢复见 [HANDOFF.md](HANDOFF.md)。

## 最终性能结果

基础设施测试每种 runtime 三轮：

| 指标 | runc | Kuasar runc | Kuasar VMM |
| --- | ---: | ---: | ---: |
| Gateway ready | 4.210 s | 4.207 s | 40.130 s |
| health exec | 3.362 s | 3.399 s | 32.870 s |
| 基础流程 total | 8.137 s | 8.195 s | 74.127 s |

固定模型样例每种 runtime 三轮：

| 指标 | runc | Kuasar runc | Kuasar VMM |
| --- | ---: | ---: | ---: |
| sample exec 平均 | 5.775 s | 6.030 s | 48.312 s |
| sample 范围 | 5.733--5.802 s | 5.915--6.243 s | 46.457--50.468 s |
| 全流程平均 | 13.949 s | 14.213 s | 119.371 s |

Kuasar runc 与普通 runc 接近。Kuasar VMM 的 sample exec 是 runc 的
8.37 倍，全流程是 8.56 倍。VMM 的 exec true 仅约 70 ms、Node probe
约 125 ms，因此瓶颈不在普通 CRI exec/vsock，而集中在 guest 内 OpenClaw
初始化、插件发现、SQLite 状态访问和 virtiofs 元数据 I/O。

## 固定版本

- OpenClaw：2026.6.11
- Kuasar：v1.1.0
- Cloud Hypervisor：v52.0
- 最终 OpenClaw 镜像：localhost/openclaw-kuasar:2026.6.11-virtiofs
- Pause 镜像：registry.k8s.io/pause:3.10
- VMM：2 vCPU、2048 MiB、cold boot、virtiofs
- CNI IPv4 网段：10.86.0.0/16

下载地址、校验值和 CRI endpoint 位于 config/versions.env。

## 从零部署

先执行只读预检和静态测试：

    ./scripts/00-check-host.sh
    bash tests/test-runtime-config.sh
    bash tests/test-cri-specs.sh
    bash tests/test-platform-cli.sh
    bash tests/test-openclaw-virtiofs-image.sh

下载并安装隔离 runtime：

    ./scripts/05-fetch-runtime.sh
    sudo ./scripts/06-install-runtime.sh

准备 OpenClaw 状态：

    ./scripts/07-prepare-openclaw-state.sh

构建或导入派生镜像，并生成 CRI specs：

    RUN_CRICTL=1 ./scripts/02-build-openclaw-image.sh
    OPENCLAW_DATA_DIR="$HOME/.local/share/openclaw-kuasar/openclaw-state" \
      ./scripts/03-generate-cri-specs.sh

服务安装后应全部为 active：

    sudo systemctl is-active \
      openclaw-kuasar-runc.service \
      openclaw-kuasar-vmm.service \
      openclaw-kuasar-containerd.service

## 运行单个 runtime

    OPENCLAW_RUNTIME_HANDLER=runc AUTO_CLEANUP=0 RUN_CRICTL=1 \
      ./scripts/04-run-with-crictl.sh

    OPENCLAW_RUNTIME_HANDLER=kuasar-runc AUTO_CLEANUP=0 RUN_CRICTL=1 \
      ./scripts/04-run-with-crictl.sh

    OPENCLAW_RUNTIME_HANDLER=kuasar-vmm AUTO_CLEANUP=0 RUN_CRICTL=1 \
      ./scripts/04-run-with-crictl.sh

健康检查：

    EP=unix:///run/openclaw-kuasar/containerd.sock
    CID=$(jq -r .container_id .state/last-run.json)
    sudo crictl --runtime-endpoint "$EP" --image-endpoint "$EP" \
      exec "$CID" node openclaw.mjs gateway health --json

## 重复 breakdown

只测试基础设施，每种 runtime 三轮：

    BENCHMARK_RUNS=3 MODEL_SAMPLE_RUNS=0 \
      ./scripts/08-benchmark-runtimes.sh

基础设施和模型样例均测试三轮：

    BENCHMARK_RUNS=3 MODEL_SAMPLE_RUNS=3 \
      ./scripts/08-benchmark-runtimes.sh

结果写入 .artifacts/breakdown-*/results.json 和 summary.json。
.artifacts 已被 Git 忽略；整理后的实验报告保存在 docs 中。

## 已解决的关键兼容问题

- registry reset/EOF：通过主机 HTTP 代理完成镜像拉取。
- runc sandboxer systemd 超时：服务类型改为 simple。
- host UTS/PID/IPC 导致的 namespace 错误：使用正确 Pod namespace。
- 主机与容器端口冲突：容器 Gateway 攏到 18790。
- Kuasar virtio-blk guest mount EIO：切换为 virtiofs。
- youki cpuset controller 错误：移除会触发旧 OCI 兼容问题的 CRI resources。
- Node SQLite WAL 在 virtiofs 上返回 SQLITE_IOERR_SHMMAP：派生 OpenClaw
  镜像，将网络文件系统改用 rollback journal。
- VMM 状态目录 UID/权限问题：VMM 使用专用 root-owned 状态目录和 spec。
- DeepSeek plugin/auth：在 VMM 状态目录中注册插件并规范化 SQLite journal。
- VMM 无网络：启用独立 IPv4 CNI、DNS、NAT 和 firewall forwarding。

## 数据与凭据边界

以下路径不会进入 Git：

- .cache/：运行时二进制、内核和 VM 镜像
- .state/：临时 runtime ID
- .artifacts/：原始 benchmark JSON 和日志
- .secrets/：本地秘密
- images/openclaw/*.tar：导出的镜像

主机凭据只存在于仓库外的 OpenClaw 状态目录，不应复制到文档、镜像层或
Git 历史中。当前工作目录约 317 MB，但排除上述忽略项后，源码与文档约
300 KB。

## 回滚

回滚只停止实验服务，不删除主机现有 containerd/Kata：

    sudo systemctl disable --now \
      openclaw-kuasar-containerd.service \
      openclaw-kuasar-vmm.service \
      openclaw-kuasar-runc.service
    sudo systemctl daemon-reload
