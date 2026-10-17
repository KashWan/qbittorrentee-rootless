# PUID / PGID 为什么"不生效"，以及本镜像怎么修

## 1. 先厘清一件事：容器里没有"用户"，只有 uid

Linux 的内核权限判断只看 **uid/gid 数字**，不看用户名。镜像里 `/etc/passwd` 的 `abc` 只是
给 `ls`、`ps` 这类工具做数字→名字的翻译。

所以 PUID/PGID 的本质是：

> **在容器里以哪个数字 uid 运行进程** —— 这个数字再经过 userns 映射，落到宿主机上成为文件属主。

"不生效"通常不是数字没传进去，而是**传进去的数字经映射后不是你**。

---

## 2. 上游为什么修不好（代码级）

`SuperNG6/Docker-qBittorrent-Enhanced-Edition` 的 `Dockerfile` 只做两件事：

```dockerfile
FROM superng6/alpine:3.22          # ← 不透明，PUID/PGID 逻辑在这里面
COPY root/etc /etc                 # ← 只有 cont-init.d/30-config 等几个脚本
```

它的 `root/etc/cont-init.d/30-config` 内容大致是：

```sh
chown -R abc:abc /config
[ "$(ls -A /config)" ] || ...      # 首次初始化
```

问题出在四处：

1. **PUID/PGID → `usermod -u` 的转换发生在基镜像的 s6 v2 启动链里**，不在该仓库。
   基镜像不公开，无法改、无法测、无法审计。
2. **只 chown `/config`**。你额外挂的 `/media/movies`、`/data`，属主完全没动。
3. **s6 v2 的 `cont-init.d` 与 `s6-setuidgid` 都要求 PID 1 是 root**。
   一旦 `--user`、`--userns=keep-id` 或 K8s `runAsNonRoot`，启动链第一步就失败。
4. **rootless 下 PUID 语义与直觉相反**（见下一节），而镜像既不检测也不提示，
   用户只能看到 `ls -n` 里一堆 101000 之类的陌生数字。

---

## 3. 关键：userns 映射

### rootful（Docker 默认）

```
容器 uid  ────────────────►  宿主 uid
   0      ─── 1:1 映射 ───►     0
1000      ─── 1:1 映射 ───►  1000

/proc/self/uid_map  →  "0 0 4294967295"
```

`PUID=1000` 直接等于宿主 1000，符合直觉。

### rootless Podman（默认 userns）

```
容器 uid  ────────────────►  宿主 uid
   0      ─── 1:1 ────────►  1000   ← 你本人！
   1      ────────────────► 100000
  ...
1000      ────────────────► 100999  ← 你设成 1000 的 PUID 落到这里
```

```
/proc/self/uid_map  →  "0 1000 1"
                       "1 100000 65536"
```

于是：

- 你写 `PUID=1000`，期望文件归你，**实际归 100999**（subuid）；
- 你写 `PUID=0`，文件反而归**你本人** —— 因为容器 root 被映射到了你。

这就是"PUID 配了没用"最普遍的真相。**rootless 下正确的 PUID 是 0。**

### `--userns=keep-id`

```
容器 uid 1000 ──────────► 宿主 uid 1000   （1:1）
容器 uid 0    ──────────► 宿主 subuid     （你不再是 root）
```

此时 `/init` 的 uid 是 1000，s6-overlay 只能以"受限模式"运行（见 `docs/s6-overlay.md`），
chown 和降权都做不了。**能用，但没必要** —— 默认 userns 已经把容器 root 变成你了。

---

## 4. 三种场景的正确配置

| 场景 | 启动方式 | PUID/PGID | 说明 |
|---|---|---|---|
| rootful | `docker run` / `podman run`（root） | `1000:1000`（默认） | 想换成任何人：填他的 uid/gid |
| rootless | `podman run`（普通用户） | **`0:0`**（默认） | 宿主上文件归你 |
| 非 root | `--user N` / `runAsNonRoot` | 被忽略 | 只能要求宿主目录预先 `chown N` |

本项目启动时会自动判定并打印一段固定格式的「启动身份」，排障时直接整段复制即可：

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

如果你在 rootless 下硬要写 `PUID=1000`，它会**明确告警**：

```
[init] 警告: rootless userns 下 PUID=1000 对应 宿主 uid 100999，不是你自己。
[init] 警告: rootless 场景请用 PUID=0 PGID=0：容器内 root 即宿主 uid=1000。
[init] 警告: 若必须用 PUID=1000，请在宿主机执行： podman unshare chown -R 1000:1000 <目录>
```

> **rootless 下不做任何 chown。** 容器 root 已经是宿主上的你，`/config` 里原本属于你的
> 文件在容器里看着就是 root 的，属主天然正确。此时即使设了 `CHOWN_DOWNLOADS=dir`
> 也会被忽略并打印提示 —— 在 userns 里 chown 只会把「别人（其它 subuid）的文件」
> 改成你的，与预期相反。确有属主问题请用第 5.3 节的 `podman unshare chown`。

---

## 5. 如果确实需要"指定某个宿主 uid"

三种办法，按推荐顺序：

### 5.1 改映射（最干净）

让容器 root 映射到你想要的宿主 uid：

```bash
podman run --uidmap 0:1001:1 --uidmap 1:200000:65536 ...
```

Quadlet 里对应 `UIDMap=0:1001:1` / `GIDMap=0:1001:1`。

### 5.2 直接抬权（最简单）

```bash
sudo chown -R 1001:1001 /srv/qbt
```

然后用 `PUID=0`。rootless 下容器 root = 你这台机器上的用户，但 `/srv/qbt` 属于 1001 时，
rootless Podman 的容器 root 仍然读写不了它 —— 这时才需要 `--uidmap`（5.1）。

### 5.3 `podman unshare chown`

```bash
podman unshare chown -R 1000:1000 /srv/qbt/downloads
```

这条命令里的 1000 是**容器内 uid**，落到宿主上会变成 subuid。它解决的是
"容器内某个 PUID 需要对目录有写权限"，而不是"文件在宿主上归 1000"。
两者容易混淆，看 `ls -n` 验证最可靠。

---

## 6. 本镜像的实现

`00-identity` 是 stage2 的第一个 oneshot，只做判定与准备，不启动进程：

```
读 /proc/self/uid_map
        │
        ├── uid 0 且完整映射 ──────────► privileged : 默认 1000:1000，chown + s6-setuidgid
        │
        ├── uid 0 且 0→宿主非 0 ───────► rootless   : 默认 0:0，不 chown，不降权
        │
        └── uid ≠ 0 ────────────────────► unprivileged: 忽略 PUID，仅告警，验证目录可写
        │
        └──► 写 /run/qbittorrentee/state.env
                   │
                   ├─ 10-config     建目录、落配置、装搜索插件、chown（rootless 跳过）、以真实身份试写
                   ├─ 20-downloads  下载目录属主策略（none/dir/recursive，rootless 恒为 none）
                   └─ services.d/qbittorrent/run   umask + 降权 + exec qbittorrent-nox
```

几个刻意的细节：

- **rootless 下完全不 chown**：`00-identity` 判定出 `rootless` 且运行身份为 uid 0 时写
  `QBT_SKIP_CHOWN=1`，10-config / 20-downloads 一律不动属主。这是「属主天然正确」的落地方式，
  也避免误改历史遗留的 subuid 属主文件。
- **不递归 chown 整个 `/config`**：先 `find ... ! -user ! -group -print -quit` 做快路径，
  全部一致时只做一次 stat 遍历，不会在几千个 resume 文件上耗时间。
- **不改用户的账号密码/家目录**：复用已有相同 uid 的账号，只校正主组，避免 `usermod -u` 触发大规模 chown。
- **失败要早**：写不进 `/config/qBittorrent/config` 直接退出码非 0 + 明确建议，
  而不是让 qBittorrent 在启动 3 秒后报一个看不懂的错。

---

## 7. 验证清单

```bash
# 1. 容器看到的是谁
podman exec qbittorrentee id

# 2. 真正跑 qbittorrent 的进程是谁（不是 exec 的 shell）
podman exec qbittorrentee sh -c \
  'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = qbittorrent-nox ] && \
   awk "/^Uid:/{print \$2}" $p/status; done'

# 3. 宿主上文件的属主
ls -ln ~/qbt/config/qBittorrent/config/qBittorrent.conf
stat -c '%u:%g %n' ~/qbt/config/qBittorrent/config/qBittorrent.conf

# 4. 看镜像自己的判定
podman logs qbittorrentee | grep -E "场景|运行身份"
```
