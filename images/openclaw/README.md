# OpenClaw 镜像策略

默认使用与主机 CLI 对齐的官方 GHCR 镜像：

```text
ghcr.io/openclaw/openclaw:2026.6.11
```

`./scripts/02-build-openclaw-image.sh` 在没有显式 `OPENCLAW_IMAGE_DIR` 时走 CRI pull，避免
把主机凭据复制进 Dockerfile 或镜像层。拉取完成后，用下面的命令记录 containerd 看到的 digest：

```bash
sudo crictl --runtime-endpoint unix:///run/openclaw-kuasar/containerd.sock \
  --image-endpoint unix:///run/openclaw-kuasar/containerd.sock \
  images --digests | grep -F ghcr.io/openclaw/openclaw
```

只有显式设置 `OPENCLAW_IMAGE_DIR` 且其中存在 Dockerfile 时，脚本才执行本地 custom build：

```bash
OPENCLAW_IMAGE_DIR="$PWD/images/openclaw-custom" \
  OPENCLAW_IMAGE=localhost/openclaw-custom:experiment \
  ./scripts/02-build-openclaw-image.sh
```

不要把 `openclaw.json`、`.env`、OAuth 文件或 provider key 放进此目录或镜像上下文。
