# rootless Podman + Quadlet 部署与运维

面向「要把这个镜像长期跑在一台服务器上」的场景。目标读者不需要看过本项目的开发过程。

内容包括：前置检查 → 三种安装方式 → 单元文件逐项解释 → 环境变量 → 端口与反向代理 →
自动更新 → 备份 → 升级与回滚 → 卸载。排障请直接看
[troubleshooting.md](troubleshooting.md)。

---

## 1. 前置检查

| 项 | 要求 | 检查命令 |
|---|---|---|
| 架构 | **linux/amd64**（x86_64），镜像不含其它架构 | `uname -m` |
| 容器运行时 | Podman 4.4+（Quadlet 需要；建议 4.9+）或 Docker 20.10+ | `podman --version` |
| rootless | 当前用户非 root，且有 subuid/subgid | `id -u` · `grep "^$USER:" /etc/subuid /etc/subgid` |
| 磁盘 | 镜像约 145 MB + 你的下载量 | — |
| 网络 | 能访问 `ghcr.io`；BT 端口可出站 | — |

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

服务器场景**必做**（否则退出登录后容器被杀）：

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
# 1. 取部署文件（其实只需要 quadlet/ 与 scripts/install-quadlet.sh）
git clone https://github.com/KashWan/qbittorrentee-rootless.git
cd qbittorrentee-rootless

# 2. 先看会生成什么
./scripts/install-quadlet.sh \
  --image ghcr.io/kashwan/qbittorrentee-rootless:latest --dry-run

# 3. 正式安装并启动
./scripts/install-quadlet.sh \
  --image ghcr.io/kashwan/qbittorrentee-rootless:latest

# 4. 确认
systemctl --user status qbittorrentee
journalctl --user -u qbittorrentee -n 50
```

脚本会：建 `~/qbt/{config,downloads}` → 渲染单元到 `~/.config/containers/systemd/`
→ `daemon-reload` → 启动。

它只有 `--image` 与 `--dry-run` 两个开关，目录与端口用**环境变量**覆盖：

```bash
CONFIG_DIR=/srv/qbt/config \
DOWNLOADS_DIR=/srv/qbt/downloads \
WEBUI_PORT=8080 \
BT_PORT=6881 \
TZ=Asia/Shanghai \
  ./scripts/install-quadlet.sh --image ghcr.io/kashwan/qbittorrentee-rootless:latest
```

> 这是**用户级**单元：所有命令都要 `systemctl --user`，不要用 `sudo`
> （脚本本身也会拒绝以 root 运行）。
>
> 镜像名会做校验：含大写字母直接报错退出（OCI 规范要求仓库名小写，
> 否则 `podman pull` 会报 `repository name must be lowercase`）。

### 3.2 手工装

```bash
mkdir -p ~/.config/containers/systemd ~/qbt/config ~/qbt/downloads
cp quadlet/qbittorrentee.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start qbittorrentee
systemctl --user enable qbittorrentee
```

### 3.3 直接用 `podman run`

适合先验证再落成单元：

```bash
podman run -d --name qbittorrentee \
  -p 8080:8080 -p 6881:6881 -p 6881:6881/udp \
  -e PUID=0 -e PGID=0 -e UMASK=002 \
  -v ~/qbt/config:/config:Z \
  -v ~/qbt/downloads:/downloads:Z \
  ghcr.io/kashwan/qbittorrentee-rootless:latest
```

---

## 4. 单元文件逐项解释

```ini
[Container]
ContainerName=qbittorrentee
Image=ghcr.io/kashwan/qbittorrentee-rootless:latest
AutoUpdate=registry

Environment=PUID=0
Environment=PGID=0
Environment=UMASK=002
Environment=WEBUI_PORT=8080
Environment=BT_PORT=6881
Environment=CHOWN_DOWNLOADS=none

PublishPort=8080:8080
PublishPort=6881:6881
PublishPort=6881:6881/udp

Volume=%h/qbt/config:/config:Z
Volume=%h/qbt/downloads:/downloads:Z

[Service]
Restart=always
TimeoutStopSec=70
```

| 项 | 说明 |
|---|---|
| `PUID=0` `PGID=0` | rootless 下容器 root 已映射成你，写 0 才能让宿主文件归你。写 1000 会变成 subuid |
| `UMASK=002` | 同组可写，适合多容器共享下载目录；个人独占用 `022` 也行 |
| `CHOWN_DOWNLOADS=none` | 下载目录里已有数据时别每次启动都遍历；rootless 下三档都不会 chown |
| `Volume=...:Z` | SELinux 重新打标签；非 SELinux 系统上无副作用 |
| `%h` | systemd specifier，展开成用户家目录 |
| `AutoUpdate=registry` | 配合 `podman auto-update`（见第 6 节） |
| `TimeoutStopSec=70` | 必须大于 `S6_KILL_GRACETIME`（15s），否则 systemd 会在 resume 数据写完前 SIGKILL |

---

## 5. 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PUID` / `PGID` | 随场景自适应 | rootful 常用 `1000:1000`；rootless 用 `0:0` |
| `UMASK` | `022` | 文件权限掩码；共享下载目录常用 `002` |
| `WEBUI_PORT` | `8080` | WebUI 端口。**只有显式设置时才覆盖配置文件里的端口** |
| `BT_PORT` | `6881` | BT 监听端口（仅首次生成配置时写入） |
| `TZ` | 容器默认 | 时区，如 `Asia/Shanghai` |
| `CHOWN_DOWNLOADS` | `none` | `none` / `dir` / `recursive`；rootless 下恒为 no-op 并打印提示 |
| `EXTRA_GROUPS` | 空 | 额外组 gid，逗号分隔，如 `44,109`（访问第二块磁盘常用） |
| `SEED_CONFIG` | `true` | 首次启动是否写入默认 `qBittorrent.conf` |
| `QBITTORRENT_LOCALE` | `zh` | WebUI 语言 |
| `QBT_EXTRA_ARGS` | 空 | 追加给 `qbittorrent-nox` 的参数 |
| `S6_VERBOSITY` | `2` | 调成 `5` 可看到 s6-rc 的完整调试输出 |
| `HEALTHCHECK_PORT` | 空 | 强制 healthcheck 探测指定端口（默认按候选列表逐个试） |
| `CONFIG_DIR` / `DOWNLOADS_DIR` | `/config` `/downloads` | 容器内挂载点，一般不需要改 |

`.env.example` 是给 compose 用的模板，变量语义完全一致。

---

## 6. 自动更新

`latest` 只在**冒烟测试通过后**才被推送，所以跟着 `latest` 走是安全的。

```bash
# 手动跑一次
podman auto-update

# 只看会做什么
podman auto-update --dry-run

# 交给 systemd timer（Podman 自带，每天检查）
systemctl --user enable --now podman-auto-update.timer
systemctl --user list-timers | grep podman
```

`AutoUpdate=registry` 只对**标签**生效：`latest` 会被重新拉取；`5.2.4.10` 这种固定标签
不会变化，也就不会被更新 —— 这正是标签策略想要的效果。

固定在某个上游版本（不被自动更新带走）：

```ini
Image=ghcr.io/kashwan/qbittorrentee-rootless:5.2.4.10
# 同时删掉 AutoUpdate=registry
```

> **`AutoUpdate=registry` 要求镜像是「全限定引用」**（含 registry/repo，例如
> `ghcr.io/kashwan/qbittorrentee-rootless:latest`）。写成短名 `qbittorrentee:dev` 时
> 单元会直接启动失败：
>
> ```
> Error: short name: auto updates require fully-qualified image reference: "qbittorrentee:dev"
> ```
>
> `scripts/install-quadlet.sh` 会自动识别短名并去掉这一行，同时在输出里提示。

---

## 7. 端口与网络

| 端口 | 协议 | 用途 | 是否必须暴露到公网 |
|---|---|---|---|
| 8080 | TCP | WebUI | 建议只对内网 / 反代暴露 |
| 6881 | TCP | BT 连接 | 需要，否则做不了种 |
| 6881 | UDP | DHT / uTP | 需要 |

```bash
sudo ufw allow 6881/tcp
sudo ufw allow 6881/udp
# 8080 不开放公网，走反向代理
```

rootless 下绑定 **1024 以下**端口需要：

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=1024
# 持久化：/etc/sysctl.d/99-unprivileged-ports.conf
```

IPv6：Quadlet 里加 `Network=host`，或写成 `PublishPort=[::]:8080:8080`。

### 反向代理（可选）

qBittorrent 需要知道自己在反代后面：

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

WebUI 里把「启用 Host header 校验」按需关闭，或在「服务器域名」里填上域名。

---

## 8. 备份

只需要备份两处：

| 路径 | 内容 | 说明 |
|---|---|---|
| `~/qbt/config` | `qBittorrent.conf`、resume 数据、搜索插件 | **必须**，丢了要重新做种 |
| `~/qbt/downloads` | 下载的文件 | 按需 |

```bash
# 停容器再备份，保证 resume 数据完整
systemctl --user stop qbittorrentee
tar czf ~/qbt-config-$(date +%F).tar.gz -C ~/qbt config
systemctl --user start qbittorrentee
```

不停容器也能备份，但建议先在 WebUI 里「暂停全部」并等几秒，让 resume 落盘。

---

## 9. 升级与回滚

### 9.1 升级

```bash
podman auto-update
systemctl --user status qbittorrentee
journalctl --user -u qbittorrentee -n 50 | grep -E "场景|运行身份|属主"
```

### 9.2 回滚镜像

`latest` 是**移动标签**，回滚必须指向不可变标签（`5.2.4.10` 或 `sha-abc1234`）。

Quadlet：改 `~/.config/containers/systemd/qbittorrentee.container`

```ini
Image=ghcr.io/kashwan/qbittorrentee-rootless:5.2.4.9
```

```bash
systemctl --user daemon-reload
systemctl --user restart qbittorrentee
```

Compose：改 `docker-compose.yml` 的 `image:` 后 `docker compose up -d`。

### 9.3 回滚配置

```bash
systemctl --user stop qbittorrentee
mv ~/qbt/config ~/qbt/config.bad
tar xzf ~/qbt-config-2026-10-01.tar.gz -C ~/qbt
systemctl --user start qbittorrentee
```

> **跨大版本降级**（如 5.x → 4.x）时 resume 数据可能不兼容。这种回滚要连同 `config`
> 一起退回降级前的备份，否则可能出现任务全部丢失。

### 9.4 完全卸载

```bash
systemctl --user disable --now qbittorrentee
rm ~/.config/containers/systemd/qbittorrentee.container
systemctl --user daemon-reload
podman rmi ghcr.io/kashwan/qbittorrentee-rootless:latest
# ~/qbt 里的数据不会自动删除
```

---

## 10. 从源码构建并部署到本机

```bash
make build IMAGE=qbittorrentee:local     # 版本号自动取 Dockerfile 里的 ARG
make test  IMAGE=qbittorrentee:local     # 真实容器冒烟
```

再把单元里的 `Image=` 指向 `qbittorrentee:local`。注意**短名不支持 `AutoUpdate=registry`**，
记得把那一行删掉（`install-quadlet.sh` 也会自动处理）。

构建细节与 CI 一致性见 [ci-cd.md](ci-cd.md)。

---

## 11. 与 docker compose 的对应关系

| compose | Quadlet |
|---|---|
| `image:` | `Image=` |
| `environment:` | `Environment=KEY=VALUE`（每行一个） |
| `ports:` | `PublishPort=` |
| `volumes:` | `Volume=` |
| `restart: unless-stopped` | `[Service] Restart=always` |
| `healthcheck:` | `HealthCmd=` / `HealthInterval=` / `HealthRetries=` |
| `stop_grace_period` | `TimeoutStopSec=` |

仓库里的 `docker-compose.yml` 保留给 Docker 用户；两者环境变量完全一致，
连默认值都相同。
