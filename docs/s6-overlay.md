# s6-overlay v3 在本镜像里的用法

## 1. 为什么是 s6-overlay v3

单进程容器用 `tini` 就够了，但这个镜像有两个"必须在启动前完成、且必须在容器内是 root 才能做"的动作：

1. 按 PUID/PGID 建账号并 `chown` 目录；
2. 以另一个 uid 降权启动 qBittorrent。

`tini` 只做 PID 1 回收，不提供初始化钩子；`s6-overlay` 提供 **stage1 → stage2 → stage3** 的完整生命周期，
且 v3 起支持以非 root 运行（受限模式）。所以选 v3，不用 v2，也去掉了 `fix-attrs.d` 这类已废弃机制。

> **只用 v3，不含任何 v2 兼容代码。** 仓库里没有 `/etc/fix-attrs.d`、没有
> `s6-overlay-v2` 的 `/etc/services.d/*/finish` 旧约定差异处理、也没有 `with-contenv` 的 v2 形式。
>
> 版本号只有一处来源：`Dockerfile` 的 `ARG S6_OVERLAY_VERSION`
> （当前 `3.2.3.2`，s6-overlay 最新稳定版）。CI 用 `scripts/dockerfile-arg.sh` 读取它，
> `validate.yml` 里还会校验「`build.yml` 不得再写死 s6 版本」，防止两处默认值分叉。

---

## 2. v3 的启动阶段

```
/init  (s6-overlay stage1：装好 s6-svscan、准备 /run、设置 stage2 的运行环境)
  └── stage2
        ├── 1. /etc/cont-init.d/*            按文件名顺序，oneshot        ← 本镜像的身份/配置/目录
        ├── 2. s6-rc 服务（user bundle）      本镜像未使用
        ├── 3. /etc/services.d/*/run          长期服务，由 s6-supervise 托管 ← 本镜像的 qbittorrent
        └── 4. s6-rc 服务（user2 bundle）     本镜像未使用
  └── stage3（关机）
        ├── 向 services.d 的 longrun 发 TERM
        ├── 关闭 s6-rc 服务
        ├── /etc/cont-finish.d/*
        └── 宽限期后 KILL 残留进程
```

关键行为：

- **stage2 里任何 cont-init.d 脚本返回非 0**，配合 `S6_BEHAVIOUR_IF_STAGE2_FAILS=2`（本镜像默认）
  会让容器直接失败，而不是带着坏状态继续跑。
- **`/init` 必须是 PID 1**，所以 `docker-entrypoint.sh` 最后一行是 `exec /init`。
- **关机信号**：`STOPSIGNAL SIGTERM` → s6 走 stage3 → 先给 qBittorrent 发 TERM，
  `S6_KILL_GRACETIME=15000` 给它 15 秒落盘 resume 数据。

---

## 3. 镜像内的目录布局

```
/init                              s6-overlay 自带
/command/*                         s6 全套工具（s6-setuidgid、s6-svscanctl…）
/etc/cont-init.d/
  00-identity                      身份判定 + PUID/PGID 解析，写 state.env
  10-config                        建目录、落默认配置、装搜索插件、chown、试写
  20-downloads                     下载目录属主策略
/etc/services.d/qbittorrent/
  run                              umask + 降权 + exec qbittorrent-nox
  finish                           退出码处置：正常退出停容器，崩溃最多重启 5 次
/usr/local/bin/
  docker-entrypoint.sh             预检 → exec /init
  qbt-lib.sh                       身份/权限公共函数
  healthcheck.sh                   三层探活
/run/qbittorrentee/state.env       00-identity 的输出，供后续脚本读取
                                   （QBT_SCENARIO / QBT_RUN_UID / QBT_SKIP_CHOWN / QBT_UMASK …）
```

### 为什么用 legacy `cont-init.d` / `services.d`，而不是 s6-rc

v3 里两种写法都官方支持。选择 legacy 目录的理由很实际：

| | legacy `cont-init.d` | s6-rc (`/etc/s6-overlay/s6-rc.d/`) |
|---|---|---|
| 脚本形态 | 任意 shell 脚本 | `up` 必须是**单行 execlineb 命令** |
| 依赖排序 | 靠文件名前缀 | 显式 `dependencies.d/` |
| 出错定位 | 直接看 shell 报错 | 需要理解 s6-rc 编译产物 |
| 本镜像需要 | ✅ 复杂 shell 逻辑 | ❌ 只有一个长驻进程，不需要服务依赖图 |

本镜像的初始化逻辑需要 shell 的分支、`find`、`awk`，写进 `up` 里会变成难以维护的
execline 单行；而"服务编排"需求为零。所以用 legacy 目录，**这是 v3 官方支持的形态，不是 v2 遗留写法**。

如果你想加带依赖的 s6-rc 服务，完全可以在本项目基础上加：

```bash
mkdir -p rootfs/etc/s6-overlay/s6-rc.d/myoneshot
echo oneshot > rootfs/etc/s6-overlay/s6-rc.d/myoneshot/type
echo /usr/local/bin/my-oneshot.sh > rootfs/etc/s6-overlay/s6-rc.d/myoneshot/up
mkdir -p rootfs/etc/s6-overlay/s6-rc.d/myoneshot/dependencies.d && : > rootfs/etc/s6-overlay/s6-rc.d/myoneshot/dependencies.d/base
mkdir -p rootfs/etc/s6-overlay/user-bundles.d/user/contents.d && : > rootfs/etc/s6-overlay/user-bundles.d/user/contents.d/myoneshot
```

---

## 4. 加自己的东西

### 启动前跑一段脚本

```dockerfile
COPY my-init.sh /etc/cont-init.d/15-my-init
RUN chmod +x /etc/cont-init.d/15-my-init
```

它会在 `10-config` 之后、`20-downloads` 之前执行，**以 /init 的身份（通常是 root）**。
脚本里可以直接读 `/run/qbittorrentee/state.env` 拿到运行身份：

```sh
. /run/qbittorrentee/state.env
echo "运行身份是 ${QBT_RUN_USER} (${QBT_RUN_UID})"
```

### 加一个长期运行的伴生进程

```dockerfile
COPY my-daemon.sh /etc/services.d/mydaemon/run
RUN chmod +x /etc/services.d/mydaemon/run
```

`run` 必须 `exec` 前台进程，否则 s6-supervise 会认为它立刻退出并重启。

### ⚠️ 自己写的脚本读不到 `-e` 传进来的变量（必读）

这是 s6-overlay v3 最容易踩的坑，也是本项目「PUID 配了却不生效」的真正根因：

- stage1 会用**干净的环境**重新 `exec` 成 PID 1，`/proc/1/environ` 里只剩 `PATH`；
- 用户 `-e` 传进来的变量被写进 `/run/s6/container_environment/`（每个变量一个文件）；
- stage2 的 `cont-init.d` / `services.d` **默认不会自动导入**这些变量。

所以 `PUID=1234` 明明在 `/run/s6/container_environment/PUID` 里躺着，
脚本里 `${PUID}` 却是空的 —— 静默退回默认值，看起来就像「配置不生效」。

本镜像的公共库里有一个函数解决它：

```sh
. /usr/local/bin/qbt-lib.sh
qbt_load_container_env     # 之后 $PUID / $WEBUI_PORT / $TZ 才有值
```

它逐个读取 `/run/s6/container_environment/*` 并 `export`，已显式赋值的变量不覆盖。
等价于官方的 `#!/usr/bin/with-contenv sh`，但不需要改 shebang，用户脚本里直接调用即可。

验证方法：

```bash
docker exec <容器> cat /proc/1/environ | tr '\0' '\n'   # 只有 PATH —— 正常
docker exec <容器> ls /run/s6/container_environment      # 你的变量都在这里
```

---

## 5. 环境变量速查

| 变量 | 本镜像值 | 作用 |
|---|---|---|
| `S6_BEHAVIOUR_IF_STAGE2_FAILS` | `2` | stage2 失败立即停容器 |
| `S6_KILL_GRACETIME` | `15000` | 关机时给进程的宽限（毫秒） |
| `S6_SERVICES_GRACETIME` | `15000` | 同上，作用域是 services.d |
| `S6_VERBOSITY` | `2` | `0`~`5`，`5` 可看 s6-rc 的调试输出 |
| `S6_READ_ONLY_ROOT` | 未设 | 只读根文件系统时设为 `1` |
| `S6_YES_I_WANT_A_WORLD_WRITABLE_RUN_BECAUSE_KUBERNETES` | 未设 | `/run` 属 root 且 0777 时强制启动（不安全，官方原话） |

---

## 6. 非 root 模式（`--user`）的注意事项

s6-overlay 从 **3.2.3.2** 起才对"以非 root 运行"提供**有限**支持，且要求 `/run` 可写：

```bash
podman run --user "$(id -u):$(id -g)" \
  --tmpfs "/run:rw,exec,mode=0755,uid=$(id -u),gid=$(id -g)" \
  ...
```

此时的限制：

- `fix-attrs` / `logutil-service` 不工作（本项目没用）
- syslogd 模拟不可用（本项目没用）
- 我们的 `00-identity` 会跳过 chown、跳过降权，并明确告警

如果你的 `/run` 是 root 所有且权限 0777，s6 会拒绝启动并让你设那个很长的 K8s 变量 ——
本项目宁愿让你挂一个 uid 正确的 tmpfs，也不建议开那个开关。

---

## 7. 调试

```bash
# 进容器不启动 s6
podman run --rm -it --entrypoint sh <镜像>

# 看 s6 到底在干什么
podman run --rm -e S6_VERBOSITY=5 ... <镜像>

# 容器起来后看服务状态
podman exec qbittorrentee /command/s6-svstat /run/service/qbittorrent

# 手工重启 qbittorrent（不重启容器）
podman exec qbittorrentee /command/s6-svc -r /run/service/qbittorrent

# 优雅停机（等价于 stage3）
podman exec qbittorrentee /command/s6-svscanctl -t /run/service
```
