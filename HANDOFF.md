# OpenClaw / Kuasar 实施交接记录

> 上下文恢复入口：最后更新于 2026-07-17。核心部署、固定样例和三种 runtime 的分阶段耗时 breakdown 均已完成。

## 2026-07-16 最终功能进展

- `runc`、`kuasar-runc`、`kuasar-vmm` 三条 OpenClaw 运行链路均已通过。
- `kuasar-vmm` 确认使用 Kuasar + Cloud Hypervisor，没有回退到普通 runc。
- VMM guest 已具备 CNI IPv4 地址、默认路由、NAT 和 DNS；DeepSeek API 请求返回 HTTP 200。
- 固定样例返回精确文本 `KUASAR_SAMPLE_OK`，provider=`deepseek`，model=`deepseek-v4-flash`，fallbackUsed=`false`。
- 本次样例：provider fetch 711 ms，OpenClaw agent `durationMs=9316`，宿主观测总耗时 55227 ms。
- 2026-07-17 三轮基础 breakdown：runc 成功轮平均 8.137s，kuasar-runc 8.195s，kuasar-vmm 74.127s；VMM 约为 runc 的 9.1 倍。
- VMM `exec true` 仅 70ms、Node probe 125ms，但 Gateway ready 40.130s、health exec 32.870s（health 内部 524ms）。因此主要慢点不是通用 CRI/vsock exec，而是 VMM guest 内 OpenClaw 启动以及配置、插件、SQLite/virtiofs 状态访问。
- runc 第一轮因复用旧 CRI 日志而过早判定 ready，已从平均值剔除；benchmark 已改为每轮唯一 `log_path`，后续不会再命中旧 ready。
- 模型样例每种 runtime 三轮、共九次全部精确返回 KUASAR_SAMPLE_OK，无 fallback；VMM sample exec 平均 48.312s，是 runc 的 8.37 倍；完整报告见 docs/2026-07-17-runtime-breakdown.md。
- 当前要求已完成；若继续优化，下一步是细分 guest 内 OpenClaw 初始化、插件发现和 SQLite/virtiofs I/O。
- 已新增 `scripts/08-benchmark-runtimes.sh`：记录 CRI、Gateway readiness、`exec true`、Node、health、可选 agent sample 和 cleanup；输出到 `.artifacts/breakdown-*`。
- 基础设施三轮命令：`BENCHMARK_RUNS=3 MODEL_SAMPLE_RUNS=0 ./scripts/08-benchmark-runtimes.sh`。模型每 handler 一轮：`BENCHMARK_RUNS=3 MODEL_SAMPLE_RUNS=1 ./scripts/08-benchmark-runtimes.sh`。

## 目标与硬约束

在不替换主机现有 containerd/Kata 的前提下，跑通：

```text
OpenClaw -> CRI -> 隔离 containerd v2 -> Kuasar -> Cloud Hypervisor
```

导师要求上层使用 containerd、runtime 技术栈使用 Kuasar、VMM 选择 Cloud Hypervisor。最终展示路径必须使用 `kuasar-vmm`，不接受静默回退到普通 runc。用户明确要求必须跑通。

## 固定版本与路径

- OpenClaw：2026.6.11
- Node.js：v24.18.0（用户目录安装）
- Kuasar：v1.1.0
- Kuasar archive SHA-256：`05b1aa9048ff2267302b4f16077c0b0bd73c3616d62644003a67ea33df72ca8b`
- Cloud Hypervisor：v52.0
- Cloud Hypervisor SHA-256：`829af01ff075bb96c4f183905134c453a88d68cbabdc6b87df21098842581ee9`
- OpenClaw 镜像：`ghcr.io/openclaw/openclaw:2026.6.11`
- 已拉取 content digest：`sha256:9fc86851bca7364b8572f544d17346ed6c02dea3222f4da859a2197ac2aaabf7`
- Pause 镜像：`registry.k8s.io/pause:3.10`，已拉入专用 containerd 的 `k8s.io` namespace
- CRI socket：`unix:///run/openclaw-kuasar/containerd.sock`
- handlers：`runc`、`kuasar-runc`、`kuasar-vmm`
- OpenClaw 状态副本：`$HOME/.local/share/openclaw-kuasar/openclaw-state`（0700，不进入仓库）
- 当前有效代理：`http://127.0.0.1:17890`
- VMM：cold boot；environment/warmfork/continuation restore 全部关闭

实验栈不会修改 `/usr/bin/containerd`、`/etc/containerd/config.toml`、`/etc/crictl.yaml` 或现有 Kata 服务。

## 当前 gate 状态

| Gate | 状态 | 证据 |
| --- | --- | --- |
| 主机 OpenClaw | PASS | systemd user Gateway running，`127.0.0.1:18789` probe ok |
| 版本与静态隔离检查 | PASS | `bash tests/test-runtime-config.sh` |
| CRI JSON 与秘密安全检查 | PASS | `bash tests/test-cri-specs.sh` |
| CLI 合同/禁止 runc 回退 | PASS | `bash tests/test-platform-cli.sh` |
| 运行时下载与校验 | PASS | Kuasar/Cloud Hypervisor artifacts 均通过 SHA-256 |
| 隔离服务 | PASS | runc sandboxer、VMM sandboxer、containerd 三个 systemd 单元 active |
| 普通 runc/OpenClaw | PASS | 容器 RUNNING，`gateway health --json` 返回 `ok: true` |
| Kuasar runc | PASS | handler=`kuasar-runc`，容器 RUNNING，健康检查返回 `ok: true` |
| Cloud Hypervisor VMM | PASS | 正式容器 RUNNING，连续 health ok，DeepSeek 固定样例返回 KUASAR_SAMPLE_OK |
| runtime breakdown | PASS | 基础设施三轮和每种 runtime 一轮 DeepSeek 固定样例均已完成；详见 docs/2026-07-17-runtime-breakdown.md |

## 已跑通的运行记录

### 主机 OpenClaw

- Gateway systemd user 服务 active
- bind：`127.0.0.1:18789`
- connectivity probe：ok
- 主机 Gateway 不需要停止；容器 Gateway 已改用 18790 避免端口冲突

### 普通 runc baseline

- handler：`runc`
- 已观察到 `CONTAINER_RUNNING`
- 容器内执行 `node openclaw.mjs gateway health --json` 返回 `"ok": true`
- 容器 Gateway：`127.0.0.1:18790`

### Kuasar runc

- handler：`kuasar-runc`
- 成功容器：`58dac1aacbcfe00f1c2d789a3430aa5a33b10f31b610dc03a5de72a23867fe63`
- 成功 Pod sandbox：`c818b7a8060fd390860fac4147cd32c1da612bf46f168786369dd0a3a8cbba2e`
- 状态：`CONTAINER_RUNNING`
- 健康检查：`"ok": true`
- 上述资源随后已由用户清理；ID 仅作为历史证据，不能直接复用

Pod CRI namespace 目前只设置 `network: 2`（host network）。不要恢复 host PID/IPC：Kuasar runc 在非 Pod PID 模式下会将 sandbox PID 记为 0，容器随后尝试 `/proc/0/ns/pid` 并失败。

## 历史故障记录：kuasar-vmm（均已解决）

### 2026-07-15 收工时的准确边界

cpuset workaround 已实测有效。Cloud Hypervisor cold boot、guest task、Pod sandbox 和 OpenClaw 容器均已成功启动，容器曾进入 `CONTAINER_RUNNING`。当前故障已从 VMM/youki 创建阶段收敛到 OpenClaw 状态数据库。

最近一次运行的 Pod sandbox 是 `864dd104d780543477746e761cecb438a9fe34fc46c499c52d7ae72958060d67`，OpenClaw container 是 `3900123b4b00d25ffcc639d017c48bcada3cd25f2ce78d6a8fee59bfbf42be38`。容器最终 `CONTAINER_EXITED`，reason=`Error`；日志为 `Config health-state write failed: disk I/O error`，随后 CLI 因同一错误退出。DeepSeek plugin 未安装只是 warning，不是退出原因。

更早一次运行中 health exec 返回 137，随后容器退出。guest 日志证明 signal 9 是运行时的清理请求，没有 guest OOM 证据，因此不要继续按内存不足处理。

virtiofsd 日志包含 `Client connected, servicing requests`，没有 disconnect、broken pipe 或 socket closed。宿主状态目录位于本地 rw ext4，权限正常。同一 VMM sandbox 内对 `/home/node/.openclaw` 执行普通 write、fsync、rename、unlink 均成功，排除了整个挂载失联和基础写入失败。

本机 OpenClaw 2026.6.11 代码确认 health-state 使用共享 SQLite，路径是 `OPENCLAW_STATE_DIR/state/openclaw.sqlite`，初始化涉及 SQLite pragmas、schema 和写事务。当前首要假设是 Kuasar v1.1.0 virtiofs 对 Node SQLite WAL/SHM/锁或 mmap 操作返回 EIO。更换为较干净状态副本后错误不变，旧 session/缓存损坏不是首要嫌疑。


执行：

```bash
OPENCLAW_RUNTIME_HANDLER=kuasar-vmm \
AUTO_CLEANUP=0 \
RUN_CRICTL=1 \
./scripts/04-run-with-crictl.sh
```

`runp` 能创建 VMM sandbox，失败发生在 `StartContainer`：

```text
failed to mount Some("/dev/vdb") to /run/kuasar/storage/containers/storage10,
err: EIO: I/O error
```

首次失败容器 ID：`6b2cd583e390712efadbce137f699fa578d46834b4916f88522f2c61e2a36288`；`direct_io=false` 重试失败容器 ID：`c80cbfccdbcbd5943fd8c1c6858d836c9fc05c49f81793d783ac636a821b8182`。

### virtiofs 后的最新进展

2026-07-15 21:34 的 virtiofs 重试已越过 storage mount，进入 guest youki 创建容器阶段，最新错误为：

```text
cgroup cpuset is required to fulfill the request, but is not supported by this system
```

根因是 Kuasar v1.1.0 host 侧使用旧 OCI spec：`SpecHandler` 将 cpuset 清成空字符串并仍序列化该字段；guest 内 youki/libcgroups 0.6.0 把空字符串解析为“字段存在”，因此错误地把 cpuset controller 判为必需。当前 CRI spec 的 CPU quota/period 会促使 containerd 生成 CPU resources 对象，从而触发该兼容问题。

源码复核确认 containerd 在 CRI resources 非空时会无条件创建空 OCI CPU 对象，因此“仅保留内存限制”仍会触发问题。最终 workaround 是暂时移除 OpenClaw 容器的整个 `linux.resources`；Cloud Hypervisor 仍由 VMM 配置提供 `vcpus = 2` 和 `memory_in_mb = 2048`。三个静态测试均 PASS，真实状态目录 spec 已重新生成；尚待运行验证。

注意：失败脚本不会把该 ID 写入 `.state/last-run.json`。该文件目前可能仍指向上一次成功的 `kuasar-runc`，不能用它判断本次 VMM 状态。

### 已确认的诊断事实

- `openclaw-kuasar-vmm.service` active；sandboxer PID 曾为 `158212`
- `/dev/kvm` 可用，Cloud Hypervisor v52.0 能启动；失败后没有残留 Cloud Hypervisor 进程
- `/var/lib/openclaw-kuasar` 位于 host ext4；主机直接 I/O 测试成功
- Kuasar v1.1.0 的 `virtio-blk` 路径把 containerd overlay/bind mount 制作为 ext4 镜像，热插入 VM 后由 guest 挂载
- 原 virtio-blk 错误发生在热插入后的 guest mount 阶段；切换 virtiofs 后该边界已通过
- 原配置：`container_storage_backend = "virtio-blk"`、`direct_io = true`
- 2026-07-15 21:11 已同步并验证 `direct_io = false`；错误完全不变，仍在 guest 挂载 `/dev/vdb` 时返回 `EIO`，因此 O_DIRECT 假设已被否定
- 同次 host kernel 日志显示两个 loop17 ext4 镜像均能正常 mount/unmount，说明 host 侧 ext4 镜像创建和复制成功；故障边界位于 virtio-blk 热插入后的 guest mount
- Kuasar v1.1.0 官方实现默认使用 `virtiofs`；workspace 现已切换为 `container_storage_backend = "virtiofs"`
- virtiofsd 1.10.0 已安装，实际路径 `/usr/libexec/virtiofsd`，其 CLI 支持 Kuasar 所需参数；workspace 已同步修正该路径
- 已确认 virtiofs 配置已安装到 `/etc/openclaw-kuasar/vmm.toml`，VMM sandboxer 重启后 active
- 首次 virtiofs 重试没有进入 VMM：重启 VMM 时实验 containerd 同时重启，脚本抢在 `/run/openclaw-kuasar/containerd.sock` 重建前调用 CRI，报 `no such file or directory`
- 当前三个服务均 active，CRI socket 已恢复；`scripts/04-run-with-crictl.sh` 已增加最长 60 秒的 socket + CRI API readiness wait，避免该竞态
- Codex 当前用户无法读取 root systemd/kernel journal，相关日志需用户执行 `sudo journalctl`

## 下一步：明天从这里继续

不要继续清空状态目录、不要先增加 VM 内存、不要回退 virtio-blk。第一步是在 VMM 诊断容器中运行最小 Node SQLite WAL 测试。完整命令已记录在 2026-07-15 对话；恢复时先检查 sandbox `864dd104d780543477746e761cecb438a9fe34fc46c499c52d7ae72958060d67` 是否仍存在。

测试目标文件为 `/home/node/.openclaw/.sqlite-vfs-test.db`，使用 Node `DatabaseSync` 执行 `PRAGMA journal_mode=WAL`、建表、`BEGIN IMMEDIATE`、INSERT 和 COMMIT。

判定：

- 输出 `{ n: 1 }`：WAL 基础功能正常，继续对照 OpenClaw 的具体 PRAGMA/schema 初始化。
- 输出 `disk I/O error`：确认 Kuasar virtiofs 与 Node SQLite WAL 不兼容；下一方案应把 `OPENCLAW_STATE_DIR/state` 放到 guest-local tmpfs/块存储，或修复 virtio-blk，不再反复删除状态文件。
- 若旧 Pod 不存在：重新运行 `kuasar-vmm` gate 并使用 `AUTO_CLEANUP=0` 保留新 Pod 做诊断。

VMM Gateway health 通过后，最后执行三轮 `deploy -> demo -> delete`。

## 历史故障与已完成修复

- GHCR/registry 直连会 reset/EOF；通过 `127.0.0.1:17890` 代理已成功拉取 OpenClaw 与 pause 镜像
- `runc-sandboxer` 不发送 `READY=1`，旧单元 `Type=notify` 会超时；已改为 `Type=simple`
- 初版 Pod 使用 host UTS/PID/IPC，普通 runc 报 hostname namespace 错误，Kuasar runc 报 `/proc/0/ns/pid`；现只保留 `network: 2`
- 容器与主机共享 host network，最初都监听 18789 导致 `EADDRINUSE`；容器已改为 18790
- `openclaw` 命令在镜像内应使用 `node openclaw.mjs ...`，已通过该方式验证健康状态

## 剩余特权动作

安装、三个 systemd 服务、运行时 artifacts 和 CRI 镜像拉取均已完成。当前只剩：

1. 完成 guest 内 Node SQLite WAL 最小测试
2. 根据结果选择 guest-local state storage 或继续缩小 OpenClaw SQLite PRAGMA 差异
3. VMM Gateway health 通过后完成三轮 `deploy -> demo -> delete`

## 凭据边界

真实配置只复制到 `$HOME/.local/share/openclaw-kuasar/openclaw-state`，权限 0700。诊断输出需避免暴露 token、password、secret、API key 或 authorization 内容。不要把凭据粘贴到聊天或提交到仓库。
