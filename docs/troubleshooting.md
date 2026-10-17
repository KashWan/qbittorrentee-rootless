# 排障

按「症状」查，别从头读。每节都以「怎么确认」开头 —— 先拿到证据，再改配置。

---

## 0. 先做这三件事

```bash
# 1. 看镜像自己判定的场景与身份（每次启动都会打印）
podman logs qbittorrentee 2>&1 | sed -n '/启动身份/,/─────$/p'

# 2. 看服务状态（s6 视角）
podman exec qbittorrentee /command/s6-svstat /run/service/qbittorrent

# 3. 看容器状态与健康检查输出
podman inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' qbittorrentee
```

第 1 条的输出长这样，后面所有判断都基于它：

```
[init] ──────────── 启动身份 ────────────
[init] 场景：rootless（rootless Podman，容器 root 映射到宿主非 root 用户）
[init] uid_map：0 1000 1 / 1 100000 65536
[init] 容器→宿主：uid 0 → 1000（宿主上的你）
[init] 运行身份：root（uid=0 gid=0）· 不降权
[init] 属主修正：跳过（rootless 下容器 root 即宿主用户，属主天然正确）
[init] umask：002
[init] ──────────────────────────────────
```

---

## 1. 容器起不来

### 1.1 `s6-overlay: /run is not writable`（或日志里提示 `/run` 不可写）

**原因**：用了 `--user` / `--userns=keep-id`，`/run` 仍属 root，s6 无法初始化。

**处理**（二选一）：

```bash
# A. 去掉 --user，让容器以 root 启动（rootless 下容器 root 就是宿主上的你）
podman run -e PUID=0 -e PGID=0 ...

# B. 坚持非 root，必须给 /run 挂一个 uid 正确的 tmpfs
podman run --user "$(id -u):$(id -g)" \
  --tmpfs "/run:rw,exec,mode=0755,uid=$(id -u),gid=$(id -g)" ...
```

容器内的 `docker-entrypoint.sh` 会在启动前探测这一点，并直接打印上面两条命令（不会再让你
对着 s6 的原始报错猜）。Kubernetes 的 `runAsNonRoot` 同理，需要给 `/run` 挂可写的 emptyDir。

### 1.2 `--read-only` 起不来

只读根文件系统 + 可写 `/run` 是受支持的组合：

```bash
podman run --read-only --tmpfs /run:rw,exec,mode=0755 \
  -v ~/qbt/config:/config:Z -v ~/qbt/downloads:/downloads:Z <镜像>
```

### 1.3 日志停在 `cont-init.d/10-config`，报「无法写入 /config/...」

**原因**：容器内运行身份对 `/config` 没有写权限。常见于：

- 宿主目录属于别的 uid（比如之前用 rootful Docker 跑过，文件属主是 1000，而你 uid 1001）；
- 绑定挂载是只读的；
- NFS 开了 `root_squash`；
- SELinux 标签不匹配（少写 `:Z`）。

**确认**：

```bash
ls -lnd ~/qbt/config                     # 看宿主属主与权限
ls -ln  ~/qbt/config | head -3           # 看里面文件的属主（可能是 subuid）
mount | grep qbt                         # 看是不是 ro
getenforce 2>/dev/null                   # SELinux 是否 Enforcing
```

**处理**：

```bash
# rootless：把目录属主改成「容器 root = 你」
podman unshare chown -R 0:0 ~/qbt/config

# rootful：直接改成运行身份
sudo chown -R 1001:1001 ~/qbt/config

# SELinux：挂载加 :Z
-v ~/qbt/config:/config:Z
```

### 1.4 日志停在 `/init`，什么都没有

`/init` 没变成 PID 1。**不要**用 `--entrypoint /init` 覆盖入口脚本，
镜像的 `ENTRYPOINT` 已经是「预检 → exec /init」；直接 `podman run <镜像>` 即可。

---

## 2. 身份与属主不对

### 2.1 宿主上属主是 `101000` 这种数字

**原因**：rootless 下把 `PUID` 设成了宿主 uid。容器内 uid 1000 在 rootless 里映射到
subuid（如 `101000`），不是宿主上的你。

**确认**：

```bash
podman logs qbittorrentee 2>&1 | grep "对应 宿主 uid"
```

**处理**：`PUID=0 PGID=0`。

```bash
podman unshare chown -R 0:0 ~/qbt        # 顺便把已经写坏属主的文件改回来
```

原理见 [puid-pgid.md](puid-pgid.md) 第 3 节。

### 2.2 日志里出现「PUID/PGID 已被忽略」

**原因**：`--user` / `--userns=keep-id` / K8s `runAsNonRoot` 下，`/init` 不是 root，
既不能 chown 也不能降权。这是**设计上的明确告警**，不是 bug。

**处理**：去掉 `--user`，让容器以 root 启动；或接受该身份，在宿主上预先 `chown` 好目录。

### 2.3 设了 `CHOWN_DOWNLOADS=dir` 但没生效

rootless（`PUID=0`）下**任何 chown 都不会执行**，包括显式的 `CHOWN_DOWNLOADS`。
日志里会打印「rootless 场景：忽略 CHOWN_DOWNLOADS=...」和一条 `podman unshare chown` 命令。
这是刻意的：在 userns 里 chown 只会把别人的文件改成你的，与预期相反。

---

## 3. 端口与 WebUI

### 3.1 容器 healthy，但宿主上打不开 WebUI

**原因**：容器内监听端口与 `PublishPort` / `ports` 不一致。

本项目**容器内监听的就是 `WEBUI_PORT`**，所以两侧必须同一个值：

```yaml
# compose：正确
- "${WEBUI_PORT:-8080}:${WEBUI_PORT:-8080}"
```

```ini
# quadlet：正确（两边都改了）
Environment=WEBUI_PORT=8090
PublishPort=8090:8090
```

**确认**：

```bash
podman port qbittorrentee                 # 实际映射
podman exec qbittorrentee sh -c 'sed -n "s/^WebUI.Port=//p" /config/qBittorrent/config/qBittorrent.conf'
```

### 3.2 容器一直 `unhealthy`

healthcheck 依次探测：`HEALTHCHECK_PORT` → `WEBUI_PORT` → 配置文件里的 `WebUI\Port` → `8080`，
任一端口 HTTP/HTTPS/TCP LISTEN 通过即健康。所以 unhealthy 基本只有三种原因：

1. qBittorrent 还没起来（`start_period=30s` 不够时，看日志里有没有报错）；
2. 配置里的端口和实际监听端口都不在上述候选里 —— 用 `HEALTHCHECK_PORT` 显式指定；
3. 容器内 wget 不可用（不该发生，镜像基于 busybox）。

```bash
podman exec qbittorrentee /usr/local/bin/healthcheck.sh; echo "rc=$?"
```

### 3.3 在 WebUI 里改了端口，重启后又变回去

**原因**：环境里显式写了 `WEBUI_PORT`。只要设置了它，启动时就会用
`--webui-port=` 覆盖配置文件。

**处理**：删掉 `WEBUI_PORT` 环境变量（让它完全尊重配置文件），或者把它的值改成你想要的新端口。

> 这条设计是为了迁移：不设就不会覆盖你在 WebUI 里改过的端口。

### 3.4 `bind: address already in use`

宿主端口被占。

```bash
ss -lntp | grep -E ':8080|:6881'
```

改 `WEBUI_PORT` / `BT_PORT`，同时改对应的 `PublishPort`。

### 3.5 rootless 下绑定 1024 以下端口失败

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=1024
# 持久化到 /etc/sysctl.d/99-unprivileged-ports.conf
```

---

## 4. Quadlet / systemd

| 现象 | 原因 | 处理 |
|---|---|---|
| `Error: unable to connect to podman.sock` | 用了 `sudo systemctl` | 用户级单元必须 `systemctl --user` |
| `Unit qbittorrentee.service not found` | 忘了 reload | `systemctl --user daemon-reload` |
| 开机不启动 | 没 enable / 没 linger | `systemctl --user enable qbittorrentee && loginctl enable-linger $USER` |
| `Error: short name: auto updates require fully-qualified image reference` | `Image=` 用了短名，但写了 `AutoUpdate=registry` | 改成 `ghcr.io/...` 全限定引用，或删掉 `AutoUpdate=registry` |
| `Error: invalid reference format` / `repository name must be lowercase` | 镜像名里含大写字母 | 全部改成小写 |
| 单元跑起来但立刻退出 | `TimeoutStopSec` 太小 / 环境变量写错 | `journalctl --user -u qbittorrentee -n 100` |

> `scripts/install-quadlet.sh` 会在渲染前校验镜像名大小写，并在短名时自动去掉
> `AutoUpdate=registry`，直接用它生成单元可以避开上表一半的问题。

---

## 5. 下载相关

| 现象 | 确认 | 处理 |
|---|---|---|
| 所有任务都「缺失文件」 | `ls -lnd ~/qbt/downloads` 宿主属主 | rootless：`podman unshare chown -R 0:0 ~/qbt/downloads` |
| 能连上但没有速度 | 端口是否放行：6881/tcp + 6881/udp | 防火墙/NAT 放行；确认 `BT_PORT` 与映射一致 |
| 日志 `无法创建 /downloads/incomplete` | 挂载点缺失或只读 | 检查 `DOWNLOADS_DIR` 是否存在、是否 `:ro` |
| 下载完别人看不到文件 | umask 022 | 共享目录用 `UMASK=002`（+ 目录 gid 设成共享组） |

---

## 6. 改了代码却「没生效」

按出现频率排序，逐条排除：

1. **改了 `rootfs/` 但没重新 `docker build`**。`rootfs/` 是构建时 `COPY` 进镜像的，
   改宿主文件对已构建的镜像没有任何影响。
2. **用了旧 tag 运行**。`make build` 默认 tag 是 `qbittorrentee:dev`；如果你 `podman run`
   的是 `:latest`，跑的还是从 registry 拉的旧镜像。
3. **`docker compose up -d` 没重新拉镜像**。`latest` 有变化时要先 `docker compose pull`。
4. **改了 `cont-init.d` 脚本但忘了 `chmod +x`**。s6 只执行可执行文件；Dockerfile 里统一
   `chmod 0755`，自己加的脚本要自己处理。
5. **脚本读不到 `-e` 变量**。s6-overlay v3 的 stage1 会用干净环境重新 exec，`-e` 变量落在
   `/run/s6/container_environment/`。脚本里必须先
   `. /usr/local/bin/qbt-lib.sh && qbt_load_container_env`。详见 [s6-overlay.md](s6-overlay.md) 第 4 节。
6. **改了 `docker-compose.yml` 的端口但没改容器内端口**。见 3.1。
7. **Quadlet 改了文件但没 `daemon-reload`**。Quadlet 只在 reload 时重新生成 service 单元。

```bash
# 确认容器里跑的到底是哪个镜像、哪份脚本
podman inspect -f '{{.ImageName}} {{.Image}}' qbittorrentee
podman exec qbittorrentee head -5 /etc/cont-init.d/00-identity
```

---

## 7. 收集信息求助

```bash
{
  echo "== 版本 =="
  podman --version; uname -m; cat /etc/os-release | head -2
  echo "== 容器 =="
  podman inspect -f '{{.ImageName}} {{.State.Status}}' qbittorrentee
  echo "== 启动身份 =="
  podman logs qbittorrentee 2>&1 | sed -n '/启动身份/,/─────$/p'
  echo "== 最近日志 =="
  podman logs --tail 50 qbittorrentee 2>&1
  echo "== 属主 =="
  ls -lnd ~/qbt/config ~/qbt/downloads
} > /tmp/qbt-diag.txt
```

贴 issue 时把 `/tmp/qbt-diag.txt` 一起附上，「启动身份」那一段通常就能直接定位问题。
