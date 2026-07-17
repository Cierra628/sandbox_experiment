# OpenClaw + Kuasar + Cloud Hypervisor 实验平台

本目录提供一个可重复的基础平台，用于展示同一个 OpenClaw Gateway 在普通 `runc`、Kuasar runc sandboxer 和 Kuasar VMM（Cloud Hypervisor）上的运行链路。

```text
openclaw-platform -> CRI -> 隔离 containerd v2 -> Kuasar sandboxer -> Cloud Hypervisor -> OpenClaw
```

实验运行时使用专用 socket `unix:///run/openclaw-kuasar/containerd.sock`，不会替换主机已有的 `/usr/bin/containerd`、`/etc/containerd/config.toml` 或 Kata 配置。

## 当前状态（2026-07-16）

- 主机 OpenClaw Gateway：PASS（`127.0.0.1:18789`）
- 普通 `runc`：PASS，容器内 Gateway 健康检查 `ok: true`
- `kuasar-runc`：PASS，容器内 Gateway 健康检查 `ok: true`
- `kuasar-vmm`：PASS；正式容器持续 RUNNING，Gateway health 稳定，DeepSeek 固定样例返回 `KUASAR_SAMPLE_OK`
- DeepSeek 固定样例：PASS，精确返回 `KUASAR_SAMPLE_OK`
- 三种 runtime 的分阶段耗时 breakdown：PASS；完整结果见 [`docs/2026-07-17-runtime-breakdown.md`](docs/2026-07-17-runtime-breakdown.md)

Breakdown 脚本：`scripts/08-benchmark-runtimes.sh`。默认每种 runtime 三轮且不调用模型；设置 `MODEL_SAMPLE_RUNS=1` 时，每种 runtime 的第一轮额外运行一次固定 DeepSeek 样例。

完整诊断状态和上下文压缩恢复入口见 [`HANDOFF.md`](HANDOFF.md)。VMM 的 cpuset、virtiofs SQLite、状态权限、插件认证和 CNI 网络问题均已解决；当前工作已转入性能 breakdown。

## 固定版本

- Kuasar：v1.1.0
- Cloud Hypervisor：v52.0
- OpenClaw 镜像：`ghcr.io/openclaw/openclaw:2026.6.11`
- Pause 镜像：`registry.k8s.io/pause:3.10`
- 最终 handler：`kuasar-vmm`（禁止静默回退到 runc）

哈希、下载地址和 CRI endpoint 统一在 [`config/versions.env`](config/versions.env) 中维护。

## 从零部署工作流

先做只读预检和源码测试：

```bash
./scripts/00-check-host.sh
bash tests/test-runtime-config.sh
bash tests/test-cri-specs.sh
bash tests/test-platform-cli.sh
```

准备运行时文件（下载写入项目 `.cache/`，不会修改系统）：

```bash
./scripts/05-fetch-runtime.sh
```

安装步骤会写 `/usr/local/libexec/openclaw-kuasar`、`/etc/openclaw-kuasar`、`/var/lib/openclaw-kuasar`，并安装三个 systemd 服务：

```bash
sudo ./scripts/06-install-runtime.sh
```

准备不暴露凭据的 OpenClaw 状态副本：

```bash
./scripts/07-prepare-openclaw-state.sh
```

拉取镜像并生成 CRI 规格：

```bash
RUN_CRICTL=1 ./scripts/02-build-openclaw-image.sh
OPENCLAW_DATA_DIR="$HOME/.local/share/openclaw-kuasar/openclaw-state" \
  ./scripts/03-generate-cri-specs.sh
```

若 registry 直连失败，当前可用主机代理为 `127.0.0.1:17890`。Pause 镜像此前通过以下方式成功拉入专用 containerd：

```bash
sudo env \
  HTTP_PROXY=http://127.0.0.1:17890 \
  HTTPS_PROXY=http://127.0.0.1:17890 \
  http_proxy=http://127.0.0.1:17890 \
  https_proxy=http://127.0.0.1:17890 \
  ALL_PROXY= all_proxy= \
  NO_PROXY=localhost,127.0.0.1,::1 \
  no_proxy=localhost,127.0.0.1,::1 \
  ctr --address /run/openclaw-kuasar/containerd.sock \
  --namespace k8s.io images pull \
  --platform linux/amd64 \
  registry.k8s.io/pause:3.10
```

## 平台 CLI

```bash
./scripts/openclaw-platform deploy
./scripts/openclaw-platform status
./scripts/openclaw-platform demo
./scripts/openclaw-platform logs
./scripts/openclaw-platform delete
```

`demo` 会在 VMM guest 内执行固定的 OpenClaw agent 请求，并记录 handler、Cloud Hypervisor PID、镜像 digest、guest `uname -a` 和响应耗时；不会打印环境变量或配置文件。

## 运行时 gate

直接运行单个 handler：

```bash
OPENCLAW_RUNTIME_HANDLER=runc AUTO_CLEANUP=0 RUN_CRICTL=1 \
  ./scripts/04-run-with-crictl.sh

OPENCLAW_RUNTIME_HANDLER=kuasar-runc AUTO_CLEANUP=0 RUN_CRICTL=1 \
  ./scripts/04-run-with-crictl.sh

OPENCLAW_RUNTIME_HANDLER=kuasar-vmm AUTO_CLEANUP=0 RUN_CRICTL=1 \
  ./scripts/04-run-with-crictl.sh
```

容器内健康检查：

```bash
EP=unix:///run/openclaw-kuasar/containerd.sock
CID=$(jq -r .container_id .state/last-run.json)
sudo crictl --runtime-endpoint "$EP" --image-endpoint "$EP" \
  exec "$CID" node openclaw.mjs gateway health --json
```

最终验收需要完成普通 runc baseline、`kuasar-runc`、`kuasar-vmm`，并连续执行三轮 `deploy -> demo -> delete`。未完成前，不把“脚本已就绪”表述为“VMM 已跑通”。

## 当前 VMM 诊断

cpuset workaround 已实测使 VMM 容器进入 RUNNING。当前剩余边界是 Node SQLite WAL/SHM/锁在 virtiofs 上返回 EIO；普通 write、fsync、rename、unlink 均已在同一 sandbox 中验证成功。不要先增加内存、反复清理状态目录或回退 virtio-blk。下一步按 [`HANDOFF.md`](HANDOFF.md) 运行最小 Node SQLite WAL 事务，再决定 guest-local state storage 或进一步调查 OpenClaw SQLite 初始化。

## 网络代理说明

隔离 containerd systemd 单元显式使用当前代理 `127.0.0.1:17890`。若代理端口改变，请同步修改 `systemd/openclaw-kuasar-containerd.service`，执行 `systemctl daemon-reload`，然后只重启实验 containerd。主机原有 containerd 不使用此实验单元的代理设置。

## 凭据和回滚

主机凭据只从 `$HOME/.openclaw` 复制到 `$HOME/.local/share/openclaw-kuasar/openclaw-state`（权限 0700），不进入仓库、镜像层或诊断归档。

回滚只停用实验服务，不自动删除运行时数据：

```bash
sudo systemctl disable --now openclaw-kuasar-containerd.service \
  openclaw-kuasar-vmm.service openclaw-kuasar-runc.service
sudo systemctl daemon-reload
```
