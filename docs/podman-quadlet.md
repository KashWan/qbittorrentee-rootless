# rootless Podman + Quadlet 部署指南

## 1. 前置检查

```bash
podman --version            # Quadlet 需要 >= 4.4，建议 4.9+
id -u                       # 必须非 0，否则不是 rootless
grep "^$USER:" /etc/subuid /etc/subgid   # 两行都要有输出
```

缺少 subuid/subgid：

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate
```

想让容器在你**未登录**时也运行（服务器场景必做）：

```bash
loginctl enable-linger "$USER"
```

---

## 2. 为什么用 Quadlet 而不是 `podman generate systemd`

`podman generate systemd` 已被标记为弃用。Quadlet 是 Podman 内置的 systemd 单元生成器：
你写一个 `.container` 文件，systemd 在 `daemon-reload` 时自动把它变成 service 单元。
好处是**声明式**、跟着 Podman 版本走、支持 `AutoUpdate=registry` 与健康检查。

---

## 3. 三种安装方式

### 3.1 脚本一键装（推荐）

```bash
./scripts/install-quadlet.sh \
  --image ghcr.io/<你的用户名>/qbittorrentee:latest
```

它会：建 `~/qbt/{config,downloads}` → 渲染单元到 `~/.config/containers/systemd/` → `daemon-reload` → 启动。

先看看会生成什么：

```bash
./scripts/install-quadlet.sh --image ghcr.io/you/qbittorrentee:latest --dry-run
```

### 3.2 手工装

```bash
mkdir -p ~/.config/containers/systemd ~/qbt/config ~/qbt/downloads
cp quadlet/qbittorrentee.container ~/.config/containers/systemd/
# 把里面的 YOUR_GITHUB_USER 换成你的用户名
systemctl --user daemon-reload
systemctl --user start qbittorrentee
systemctl --user enable qbittorrentee
```

### 3.3 直接用 podman run

见 README 第四节。适合先验证再落成单元。

---

## 4. 单元文件逐项解释

```ini
[Container]
ContainerName=qbittorrentee
Image=ghcr.io/you/qbittorrentee:latest
AutoUpdate=registry              # podman auto-update 会检查并拉新

Environment=PUID=0               # ← rootless 的关键
Environment=PGID=0
Environment=UMASK=002
Environment=CHOWN_DOWNLOADS=none

PublishPort=8080:8080
PublishPort=6881:6881
PublishPort=6881:6881/udp

Volume=%h/qbt/config:/config:Z
Volume=%h/qbt/downloads:/downloads:Z
```

| 项 | 说明 |
|---|---|
| `PUID=0` `PGID=0` | rootless 下容器 root 已映射成你，写 0 才能让宿主文件归你。设成 1000 会变成 subuid |
| `UMASK=002` | 同组可写，适合多容器共享下载目录；单人用 `022` 也行 |
| `CHOWN_DOWNLOADS=none` | 下载目录里已有数据时别每次启动都遍历 chown |
| `Volume=...:Z` | SELinux 重新打标签；非 SELinux 系统上无副作用 |
| `%h` | systemd 的 specifier，展开成用户家目录 |
| `AutoUpdate=registry` | 配合 `podman auto-update`（下方 systemd timer） |

`TimeoutStopSec=70` 必须大于 `S6_KILL_GRACETIME`（15s），否则 systemd 会在 qBittorrent
还没写完 resume 数据时就 SIGKILL。

---

## 5. 自动更新

```bash
# 手动跑一次
podman auto-update

# 或交给 systemd timer（Podman 自带）
systemctl --user enable --now podman-auto-update.timer
systemctl --user list-timers | grep podman
```

`AutoUpdate=registry` 只对**标签**生效：`latest` 会被重新拉取；`5.2.4.10` 这种固定标签
不会变化，也就不用更新 —— 这正是我们的标签策略想要的。

---

## 6. 端口与网络

- 8080 是 WebUI，6881 是 BT（TCP + UDP），两个都要放行。
- rootless 下绑定 **1024 以下**端口需要：

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=1024
# 持久化：/etc/sysctl.d/99-unprivileged-ports.conf
```

- IPv6：Quadlet 里加 `Network=host` 或 `PublishPort=[::]:8080:8080`。

---

## 7. 排障速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `s6-overlay: /run is not writable` | 用了 `--user` 但 `/run` 属 root | 去掉 `--user`，或挂 `--tmpfs /run:rw,exec,mode=0755,uid=$(id -u)` |
| 日志里 `PUID 已被忽略` | 同上，非 root 无法切换身份 | 去掉 `--user` |
| 宿主上属主是 101000 之类 | rootless 下 PUID 设成了宿主 uid | 改 `PUID=0 PGID=0` |
| 容器 healthy 但下载失败 | `/downloads` 不可写 | `ls -ld` 检查宿主目录；或 `CHOWN_DOWNLOADS=dir` |
| `Error: unable to connect to podman.sock` | 用了 `sudo systemctl` | 用户级单元必须 `systemctl --user` |
| 单元不存在 | 忘了 `daemon-reload` | `systemctl --user daemon-reload` |
| 开机不启动 | 没 enable / 没 linger | `systemctl --user enable qbittorrentee && loginctl enable-linger $USER` |
| WebUI 能开但登录不了 | 不知道一次性密码 | `journalctl --user -u qbittorrentee \| grep -i "temporary password"` |
| `bind: address already in use` | 8080 被占 | 改 `Environment=WEBUI_PORT=` 与 `PublishPort=` |

---

## 8. 与 docker compose 的对应关系

| compose | quadlet |
|---|---|
| `image:` | `Image=` |
| `environment:` | `Environment=KEY=VALUE`（每行一个） |
| `ports:` | `PublishPort=` |
| `volumes:` | `Volume=` |
| `restart: unless-stopped` | `[Service] Restart=always` |
| `healthcheck:` | `HealthCmd=` / `HealthInterval=` / `HealthRetries=` |
| `stop_grace_period` | `TimeoutStopSec=` |

仓库里的 `docker-compose.yml` 保留给 Docker 用户；两者环境变量完全一致。
