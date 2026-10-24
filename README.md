# qbittorrentee-rootless

> 自建 qBittorrent Enhanced Edition 容器镜像：s6-overlay v3 作为 PID 1，**PUID/PGID 真正生效**，
> 为 rootless Podman + Quadlet 而设计，并由 GitHub Actions 自动跟随上游发版。

```
ghcr.io/kashwan/qbittorrentee-rootless:latest     # linux/amd64 · GPL-2.0-or-later
```

---

## 这是什么

一个把 [qBittorrent Enhanced Edition](https://github.com/c0re100/qBittorrent-Enhanced-Edition)
打包成容器的小项目。它存在的唯一原因：既有的同类镜像在 **rootless Podman** 下
PUID/PGID 会静默失效（配了等于没配），而 rootless 恰恰是个人服务器上最该用的形态。

本项目把「判定运行场景 → 解析 PUID/PGID → 修正属主 → 降权启动」这条链路全部写成仓库里
可读的 shell 脚本，并在启动时把结论打印成一段固定格式的日志 —— 出问题时一眼能看出它认成了
什么场景、以什么身份在跑。

如果你用的是 rootful Docker，它同样能用，只是没那么多戏。

---

## 核心特性

| 特性 | 说明 |
|---|---|
| **三种场景自适应** | 读 `/proc/self/uid_map` 自动判定 `rootful` / `rootless` / 非 root，默认 PUID 随场景变化 |
| **rootless 下零 chown** | 容器 root 就是宿主上的你，属主天然正确，一个 `chown` 都不执行 |
| **配错会告警** | rootless 下写 `PUID=1000` 会明确告诉你它会映射成哪个 subuid，而不是静默失效 |
| **Quadlet 原生** | 附带 `.container` 模板与一键安装脚本，`AutoUpdate=registry` 开箱可用 |
| **启动日志结构化** | 每次启动打印「场景 / uid_map / 容器→宿主 / 运行身份 / 属主策略 / umask」 |
| **端口自适应健康检查** | healthcheck 依次探测 `HEALTHCHECK_PORT` → `WEBUI_PORT` → 配置文件里的端口 |
| **优雅停机** | `SIGTERM` 后给 15 秒落盘 resume 数据；崩溃最多重启 5 次，不无限 crash-loop |
| **零编译** | 直接用上游 musl 静态二进制，构建约 1 分钟，失败面极小 |
| **版本跟随上游** | 每 6 小时检查一次 release，有新版本才构建；标签与上游版本一一对应 |

支持 **linux/amd64** 单一架构。用 `--platform linux/arm64` 构建会直接失败，不会产出一个跑错
二进制的镜像。

---

## 快速开始

### rootless Podman（推荐形态）

```bash
podman run -d --name qbittorrentee \
  -p 8080:8080 -p 6881:6881 -p 6881:6881/udp \
  -e PUID=0 -e PGID=0 -e UMASK=002 \
  -v ~/qbt/config:/config:Z \
  -v ~/qbt/downloads:/downloads:Z \
  ghcr.io/kashwan/qbittorrentee-rootless:latest
```

首次启动会生成**一次性随机密码**并打印在日志里（镜像刻意不预置默认密码）：

```bash
podman logs qbittorrentee | grep -i "temporary password"
```

> `PUID=0` 就是「以容器 root 运行」，而在 rootless 下容器 root 就是宿主机上的你。

### Docker / Compose

```bash
git clone https://github.com/KashWan/qbittorrentee-rootless.git
cd qbittorrentee-rootless
cp .env.example .env          # 按需改 PUID/PGID/端口
docker compose up -d
```

### Quadlet（systemd 用户级单元，长期运行首选）

```bash
./scripts/install-quadlet.sh --image ghcr.io/kashwan/qbittorrentee-rootless:latest
loginctl enable-linger "$USER"     # 未登录也能跑
systemctl --user status qbittorrentee
```

完整部署、自动更新、反向代理、备份与回滚：**[docs/podman-quadlet.md](docs/podman-quadlet.md)**

---

## 镜像地址与标签

| 标签 | 含义 |
|---|---|
| `5.2.4.10` | 不可变，与上游 release 严格一致 |
| `sha-abc1234` | 不可变，对应本仓库某次提交 |
| `5.2` / `5` | 该主/次版本线的最新 |
| `latest` | 最新**通过冒烟测试**的稳定版 |
| `edge` | `main` 分支最新构建（可能未充分验证） |

包是公开的，`podman pull` / `docker pull` 无需登录。

每个上游版本还会在 [Releases](https://github.com/KashWan/qbittorrentee-rootless/releases)
建一个同号发布（tag 就是 `5.2.4.10`），想看「上游什么时候发了新版」盯那里即可。

---

## 配置

常用环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PUID` / `PGID` | 随场景自适应 | 运行身份。rootful 一般 `1000:1000`；rootless 用 `0:0` |
| `UMASK` | `022` | 文件权限掩码，共享下载目录常用 `002` |
| `WEBUI_PORT` | `8080` | WebUI 端口，容器内外必须是同一个值 |
| `BT_PORT` | `6881` | BT 监听端口（TCP + UDP） |
| `TZ` | 容器默认 | 时区，如 `Asia/Shanghai` |
| `CHOWN_DOWNLOADS` | `none` | `none` / `dir` / `recursive`；rootless 下恒为 no-op |
| `EXTRA_GROUPS` | 空 | 额外组 gid，逗号分隔，如 `44,109` |
| `SEED_CONFIG` | `true` | 首次启动是否写入默认配置文件 |
| `QBITTORRENT_LOCALE` | `zh` | WebUI 语言 |
| `QBT_EXTRA_ARGS` | 空 | 追加给 `qbittorrent-nox` 的参数 |
| `S6_VERBOSITY` | `2` | 调成 `5` 可看 s6 的完整调试输出 |

完整列表与含义见 **[docs/podman-quadlet.md](docs/podman-quadlet.md)** 与
**[docs/puid-pgid.md](docs/puid-pgid.md)**。

---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/README.md](docs/README.md) | 文档索引（按「我想……」反查） |
| [docs/puid-pgid.md](docs/puid-pgid.md) | 容器里没有「用户」只有 uid、userns 映射、三种场景 |
| [docs/podman-quadlet.md](docs/podman-quadlet.md) | rootless 部署、Quadlet、自动更新、备份、升级回滚 |
| [docs/s6-overlay.md](docs/s6-overlay.md) | s6-overlay v3 生命周期、扩展点、环境变量传递的坑 |
| [docs/ci-cd.md](docs/ci-cd.md) | 流水线、标签策略、如何发版、如何自己构建 |
| [docs/migration.md](docs/migration.md) | 从 superng6 / linuxserver 迁移 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 起不来、属主不对、端口不生效、改了没生效 |

---

## 许可证

本项目自身代码：**GPL-2.0-or-later**（与所打包的 qBittorrent 保持一致），见 [LICENSE](LICENSE)。

镜像内包含第三方组件，各自遵循其原始许可：
qBittorrent Enhanced Edition（GPL-2.0）、s6-overlay（ISC）、Alpine Linux（MIT 等）。
