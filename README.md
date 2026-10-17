# qbittorrentee · 自建 qBittorrent Enhanced Edition 镜像

> s6-overlay **v3** 作为 PID 1，**PUID/PGID 真正生效**，原生适配 **rootless Podman + Quadlet**，
> GitHub Actions 自动跟踪上游版本并推送到 GHCR，**只构建 `linux/amd64`**。

镜像地址：`ghcr.io/KashWan/qbittorrentee-rootless`

---

## 一、为什么要自己造一个

上游 `SuperNG6/Docker-qBittorrent-Enhanced-Edition` 的 PUID/PGID 失效不是配置错误，而是**结构性问题**：

| # | 根因 | 后果 |
|---|---|---|
| 1 | PUID/PGID 的解析逻辑不在该仓库里，而在不透明的基镜像 `superng6/alpine:3.22` 的 s6-overlay **v2** 启动链中 | 仓库内怎么改都没用 |
| 2 | `cont-init.d/30-config` 只 `chown -R abc:abc /config`，可选 `/downloads` | 额外挂载点、已有文件的属主不会被修正 |
| 3 | s6 v2 的 `cont-init.d` + `s6-setuidgid` 要求 PID 1 是 root | `--user` / `--userns=keep-id` / K8s `runAsNonRoot` 第一步就崩 |
| 4 | rootless 默认 userns 下，容器内 uid 1000 映射到宿主 subuid（如 101000） | `ls -n` 看到陌生数字，于是「PUID 没生效」 |

本项目的做法是把这四件事全部摊开、显式处理，而不是藏在基镜像里。

---

## 二、技术选择

| 决策 | 理由 |
|---|---|
| **s6-overlay v3.2.3.2** 作为 PID 1 | 官方推荐形态；stage2 的 `cont-init.d` 按文件名顺序执行，任一步失败可让容器直接失败（`S6_BEHAVIOUR_IF_STAGE2_FAILS=2`），不会带着坏状态硬跑 |
| **直接用 c0re100 发布的 musl 静态二进制** | 上游已提供 `qbittorrent-enhanced-nox_x86_64-linux-musl_static.zip`，CI 里**无需编译 Qt/libtorrent**，一次构建 ≈ 60 秒 |
| **只做 `linux/amd64`** | 目标机是 x86_64 VPS；不含 QEMU、不含架构分支，CI 更快、镜像更小、故障面更窄 |
| **入口只做预检，不碰身份** | `docker-entrypoint.sh` 校验完 `/run` 可写就 `exec /init`；降权交给 stage2，避免「entrypoint 里 setuid 后 s6 起不来」的经典坑 |
| **默认 `USER root`** | 只有 root 才能 chown / 降权。rootless Podman 下**容器 root 已经就是宿主上的你**，并不越权 |
| **`--profile=/config`** | 布局由 qBittorrent 源码 `CustomProfile` 确定：`/config/qBittorrent/{config,data,cache}`，路径可预期 |

---

## 三、PUID/PGID 三种场景

镜像会在启动时读 `/proc/self/uid_map` 自动判定场景，并给出明确日志。**这是与上游最大的区别：不再静默失败。**

| 场景 | 判定依据 | PUID/PGID 默认 | 行为 |
|---|---|---|---|
| **rootful**（Docker / root Podman） | uid_map = `0 0 4294967295` | `1000:1000` | 建/复用账号 → `chown` → `s6-setuidgid` 降权 |
| **rootless**（Podman 默认 userns） | uid 0 映射到非 0 的宿主 uid | **`0:0`** | 不降权（容器 root = 宿主你），chown 到 0:0，宿主上属主正确 |
| **非 root**（`--user` / keep-id / K8s） | `/init` 的 uid ≠ 0 | 取当前 uid | 跳过 chown，明确告警「PUID 已被忽略」 |

一句话记住 rootless：

```
PUID=0 就是「以容器 root 运行」，而容器 root 就是宿主机上的你。
```

详细推导、`ls -n` 看到 101000 的原因、以及 `podman unshare chown` 的用法见
👉 **[docs/puid-pgid.md](docs/puid-pgid.md)**

---

## 四、快速开始

### 4.1 rootless Podman（推荐）

```bash
podman run -d --name qbittorrentee \
  -p 8080:8080 -p 6881:6881 -p 6881:6881/udp \
  -e PUID=0 -e PGID=0 -e UMASK=002 \
  -v ~/qbt/config:/config:Z \
  -v ~/qbt/downloads:/downloads:Z \
  ghcr.io/KashWan/qbittorrentee-rootless:latest
```

首次启动 qBittorrent 会生成**一次性随机密码**并打印在日志里：

```bash
podman logs qbittorrentee | grep -i "temporary password"
```

> 镜像刻意不预置任何默认密码 —— 硬编码 `admin/adminadmin` 是很多镜像被扫的历史原因。

### 4.2 Quadlet（systemd 用户级单元）

```bash
git clone <本仓库> && cd qbittorrentee
./scripts/install-quadlet.sh --image ghcr.io/KashWan/qbittorrentee-rootless:latest
loginctl enable-linger "$USER"      # 未登录也能跑
journalctl --user -u qbittorrentee -f
```

单元模板见 [quadlet/qbittorrentee.container](quadlet/qbittorrentee.container)，逐项解释见
👉 **[docs/podman-quadlet.md](docs/podman-quadlet.md)**

### 4.3 Docker / Compose

```yaml
services:
  qbittorrentee:
    image: ghcr.io/KashWan/qbittorrentee-rootless:latest
    environment:
      PUID: 1000
      PGID: 1000
    volumes:
      - ./config:/config
      - ./downloads:/downloads
    ports: ["8080:8080", "6881:6881", "6881:6881/udp"]
```

---

## 五、环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PUID` / `PGID` | 随场景自适应 | 运行身份。rootful 一般 `1000:1000`，rootless 用 `0:0` |
| `UMASK` | `022` | 文件权限掩码；共享下载目录常用 `002` |
| `WEBUI_PORT` | `8080` | WebUI 端口。**只有显式设置时才会覆盖配置文件里的端口** |
| `BT_PORT` | `6881` | BT 监听端口（仅首次生成配置时写入） |
| `TZ` | 容器默认 | 时区，如 `Asia/Shanghai` |
| `CHOWN_DOWNLOADS` | `none` | `none` / `dir` / `recursive`。下载目录已有大量数据时保持 `none` |
| `EXTRA_GROUPS` | 空 | 额外组 gid，逗号分隔，如 `44,109`（访问第二块磁盘时常用） |
| `SEED_CONFIG` | `true` | 首次启动是否写入默认 `qBittorrent.conf` |
| `QBITTORRENT_LOCALE` | `zh` | WebUI 语言 |
| `QBT_EXTRA_ARGS` | 空 | 追加给 `qbittorrent-nox` 的参数 |
| `S6_VERBOSITY` | `2` | 调成 `5` 可看到 s6-rc 的完整调试输出 |

---

## 六、目录结构

```
/config
└── qBittorrent
    ├── config/qBittorrent.conf     ← 配置文件
    ├── data/                       ← resume、torrents、nova3（搜索插件）
    └── cache/
/downloads
└── incomplete/                     ← 未完成文件（可在 WebUI 里改）
```

从旧镜像（superng6 / linuxserver）迁移时，`/config/qBittorrent/qBittorrent.conf`
会被**自动**搬到 `/config/qBittorrent/config/`，其余数据原地可用。

---

## 七、自动化流水线

```
schedule: 23 */6 * * *        （每 6 小时）
        │
        ├─ resolve   取上游最新 release → 校验 x86_64 静态包存在
        │            → 查 GHCR 是否已有 <version> 标签 → 有则 SKIP（零构建开销）
        │
        ├─ build     buildx 构建 linux/amd64，只推「不可变标签」：5.2.4.10 / sha-xxxxxxx
        │            → 跑 tests/smoke.sh（真实容器，3 组用例）
        │
        ├─ promote   冒烟通过后才把 5.2 / 5 / latest 指过去
        │            （latest 永远不会指向没跑通的镜像）
        │
        └─ rootless  用 rootless podman 再验一遍 PUID=0 的文件属主
```

- 推代码到 `main`：无条件重建并产出 `edge` 标签
- 手动：Actions → build → Run workflow，可指定上游版本 / 强制重建 / s6-overlay 版本
- PR：`validate.yml` 跑 shellcheck + hadolint + YAML + 身份解析单元测试 + 单架构构建冒烟

### 标签策略

| 标签 | 含义 |
|---|---|
| `5.2.4.10` | 不可变，对应上游 release |
| `sha-abc1234` | 不可变，对应本仓库提交 |
| `5.2` / `5` | 该主/次版本最新 |
| `latest` | 最新通过冒烟测试的稳定版 |
| `edge` | `main` 分支最新构建（可能未充分验证） |

---

## 八、本地构建与测试

```bash
make build VERSION=5.2.4.10    # 构建 linux/amd64
make buildx                    # 与 CI 一致的 buildx 构建（不推送）
make identity                  # 身份解析 + 版本解析单元测试（不需要容器）
make test                      # 冒烟测试 A/B/C
make test-rootless             # rootless podman 行为验证（普通用户执行）
make check                     # shell 语法 + Dockerfile RUN 块 + YAML
```

### 实测记录

以下组合是真机跑过的（Ubuntu 24.04 / x86_64），不是"应该可以"：

| 环境 | 验证内容 | 结果 |
|---|---|---|
| Docker 29（rootful） | 冒烟 A/B/C | 全过：PID 1 = `s6-svscan`，`PUID=1234 PGID=2345` → 进程 1234:2345、配置属主 1234:2345、WebUI 200 |
| Podman 4.9.3 rootless（默认 userns） | `tests/rootless.sh` | 全过：识别为 rootless 场景、宿主属主 = 普通用户、`PUID=1000` 明确告警会被映射到 subuid |
| Podman + Quadlet（用户级单元） | `scripts/install-quadlet.sh` | `active (running)`，`healthy`，WebUI 200，宿主属主 = 普通用户 |

`make check` 里的「Dockerfile RUN 块」检查是踩坑后补的：`RUN` 里的 shell 引号错误
只有 `docker build` 才会暴露，现在 lint 阶段用 `sh -n` 就能拦住。

---

## 九、常见问题

**Q：`ls -n` 看到属主是 101000 这种数字？**
说明你在 rootless userns 里把 PUID 设成了宿主 uid。改成 `PUID=0 PGID=0` 即可。原理见 `docs/puid-pgid.md`。

**Q：容器起不来，日志停在 `s6-overlay: /run is not writable`？**
你用 `--user` 启动了，但 `/run` 还是 root 所有。两个选择：去掉 `--user`（推荐），或给 `/run` 挂 tmpfs：

```bash
--tmpfs /run:rw,exec,mode=0755,uid=$(id -u),gid=$(id -g)
```

**Q：为什么 `docker run -it 镜像 sh` 能直接进 shell？**
入口脚本发现第一个参数不是 `/init` 就 `exec` 它，方便排障。

**Q：怎么加自己的初始化脚本？**
放 `/etc/cont-init.d/NN-xxx`（按文件名排序执行）或 `/etc/services.d/<name>/run`（长期服务）。
**注意 s6-overlay v3 不会把 `-e` 变量传给 stage2**，脚本里要先
`. /usr/local/bin/qbt-lib.sh && qbt_load_container_env`，否则读不到 `PUID`、`TZ` 等。
详见 👉 **[docs/s6-overlay.md](docs/s6-overlay.md)**

**Q：支持哪些架构？**
只支持 `linux/amd64`（x86_64）。`Dockerfile` 里有架构守卫，用其他 `--platform` 构建会直接报错而不是产出错镜像。
确有需要时，把 `QBITTORRENT_PKG` / `S6_ARCH` 两个 ARG 改成 `aarch64-linux-musl_static` / `aarch64` 即可。

---

## 十、把项目推到 GitHub（Ubuntu VPS）

仓库里已经带 `.git`，`origin` 指向 `https://github.com/KashWan/qbittorrentee-rootless.git`。

从 Windows 拷到 VPS 后，**先修可执行位**（Windows 文件系统不保留 `+x`，不修的话
`./scripts/install-quadlet.sh` 会 permission denied；镜像构建本身不受影响，因为
`Dockerfile` 里统一 `chmod 0755`）：

```bash
cd ~/qbittorrentee-rootless

# 1. 修可执行位（幂等，可重复执行）
find . -type f \( -name '*.sh' -o -path './rootfs/etc/cont-init.d/*' \
     -o -path './rootfs/etc/services.d/*/*' \) -exec chmod +x {} +

# 2. 检查并提交（VPS 上若没配过 git 身份，先执行下面两行）
#    git config --global user.name  "Your Name"
#    git config --global user.email "you@example.com"
git status
git add -A
git commit -m "ci: 仅构建 linux/amd64"

# 3. 推送（密码处必须填 Personal Access Token，GitHub 已不接受账号密码）
git push origin main
```

推送成功后要做的两件事：

1. **Actions** 里 `build` 会自动跑一次（`push` 触发），产出 `edge` 与版本标签；
2. 打开 **Packages → qbittorrentee-rootless → Package settings → Change visibility**，
   改成 `Public`，否则 VPS 上 `podman pull` 会 401。

> 定时构建（每 6 小时）依赖 GitHub 的 schedule，**仓库 60 天无提交会被自动停掉**。
> 想长期免维护，可加一个每月空提交，或改用 `workflow_dispatch` 手动触发。

---

## 十一、许可

本项目自身代码：GPL-2.0-or-later（与所打包的 qBittorrent 保持一致）。
镜像内包含 qBittorrent Enhanced Edition（GPL-2.0）、s6-overlay（ISC）、Alpine Linux（MIT 等）。
