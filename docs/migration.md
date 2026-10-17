# 从 superng6 / linuxserver 迁移

目标是「把旧的 config 目录搬过来，尽量不重下、不丢种子」。多数情况下只需要启动一次容器，
本项目会自己把配置文件挪到新位置。

---

## 1. 最关键的一件事：目录布局变了

qBittorrent 用 `--profile=/config` 启动后，配置在 `qBittorrent/` 子目录里
（来源：`src/base/profile_p.cpp` 的 `CustomProfile`）。不同镜像把 `--profile` 指向的位置
不一样，所以**配置文件在新旧镜像里的相对路径不同**：

| 镜像 | 配置文件实际位置 | 说明 |
|---|---|---|
| 本项目 | `/config/qBittorrent/config/qBittorrent.conf` | `--profile=/config` |
| superng6 | `/config/qBittorrent/qBittorrent.conf` | `--profile=/config/qBittorrent` |
| linuxserver | `/config/qBittorrent/qBittorrent.conf` | 同上 |

`10-config` 在启动时会做一次自动迁移：

```
如果 /config/qBittorrent/qBittorrent.conf 存在
且 /config/qBittorrent/config/qBittorrent.conf 不存在
→ mv 到新位置，日志打印「已迁移旧配置」
```

也就是说**你什么都不用改**，把旧的 `/config` 挂进来即可。迁移只发生一次；之后
`/config/qBittorrent/config/` 是唯一权威位置。

其它东西（`data/` 里的 resume、`torrents/`、`nova3/` 搜索插件、`cache/`）布局一致，
不需要动。

---

## 2. 环境变量对照

| 旧镜像 | 本项目 | 备注 |
|---|---|---|
| `PUID` / `PGID` | `PUID` / `PGID` | 语义相同；**rootless 下请用 `0:0`** |
| `UMASK_SET` | `UMASK` | `UMASK_SET` 仍然被识别（作为 `UMASK` 的兜底） |
| `UMASK` | `UMASK` | 同上 |
| `WEBUI_PORT` | `WEBUI_PORT` | 注意两侧端口必须一致，见下 |
| `WEBUIPORT` | `WEBUI_PORT` | `WEBUIPORT` 仍被识别为别名 |
| `TORRENTING_PORT` | `BT_PORT` | `TORRENTING_PORT` 仍被识别为别名（仅首次生成配置时写入） |
| `TZ` | `TZ` | 相同 |
| — | `CHOWN_DOWNLOADS` | 新增：`none` / `dir` / `recursive` |
| — | `EXTRA_GROUPS` | 新增：额外组 gid |
| — | `SEED_CONFIG` | 新增：首次是否写默认配置 |
| — | `QBITTORRENT_LOCALE` | 新增：WebUI 语言 |
| — | `QBT_EXTRA_ARGS` | 新增：追加命令行参数 |

> **`WEBUI_PORT` 有个细节**：本项目只有在**显式设置** `WEBUI_PORT` 时才会用命令行
> `--webui-port=` 覆盖配置文件里的端口；不设则完全尊重 `qBittorrent.conf` 里已存在的值。
> 这样从旧镜像迁移时，你在 WebUI 里改过的端口不会被容器默认值悄悄盖回去。
> 但 compose / Quadlet 的端口映射要跟它对齐，否则宿主上连不上。

---

## 3. 端口对照

| 用途 | 旧镜像 | 本项目 |
|---|---|---|
| WebUI | 8080 | 8080（`WEBUI_PORT`） |
| BT TCP | 6881 | 6881（`BT_PORT`） |
| BT UDP | 6881 | 6881（`BT_PORT`） |

端口号默认值一致，所以旧的防火墙规则和端口映射通常可以直接沿用。

---

## 4. 迁移步骤（rootless Podman + Quadlet）

### 4.1 停旧容器、备份

```bash
# 旧容器（名字按你的实际情况）
podman stop <旧容器名>
tar czf ~/qbt-config-before-migrate.tar.gz -C <旧config的父目录> config
```

**先备份再动手。** 迁移逻辑只做一次，但备份是唯一的后悔药。

### 4.2 确认旧 config 的属主

```bash
ls -ln <旧config目录> | head
```

- 如果属主是**你自己**（rootless 常态）→ 直接进入 4.3。
- 如果属主是 `1000` 但你当前 uid 不是 1000（之前用 rootful Docker 跑的）→ 需要改属主：

```bash
podman unshare chown -R 0:0 <旧config目录>
# 0:0 在 rootless 里就是「宿主上的你」
```

### 4.3 用新镜像启动

```bash
./scripts/install-quadlet.sh --image ghcr.io/kashwan/qbittorrentee-rootless:latest
# 或者手工指定旧的 config 目录
CONFIG_DIR=<旧config目录> DOWNLOADS_DIR=<旧下载目录> \
  ./scripts/install-quadlet.sh --image ghcr.io/kashwan/qbittorrentee-rootless:latest
```

### 4.4 校验

```bash
# 1. 迁移日志
journalctl --user -u qbittorrentee | grep -E "已迁移旧配置|启动身份|属主修正"

# 2. 配置文件在新位置
ls -l <config目录>/qBittorrent/config/qBittorrent.conf

# 3. 种子还在
ls <config目录>/qBittorrent/data/BT_backup/ | head
```

WebUI 能打开、任务列表在、做种数恢复 → 迁移完成。

---

## 5. 从 linuxserver 迁移的额外注意

| 项 | 说明 |
|---|---|
| 容器内路径 | linuxserver 用 `/config` 与 `/downloads`，与本项目一致，挂载参数可直接照搬 |
| `FILE__` 系列变量 | linuxserver 支持 `FILE__WEBUI_PORT` 之类从文件读值，本项目**不支持**；请改为直接给 `WEBUI_PORT` |
| `PGID` 默认值 | linuxserver 默认 `911`，本项目 rootful 下默认 `1000`。迁移时请显式写清楚 |
| 自定义脚本 | linuxserver 的 `/config/custom-cont-init.d/` 机制本项目**没有**。需要启动前脚本请参考 [s6-overlay.md](s6-overlay.md) 第 4 节，做进自己的镜像 |

---

## 6. 回退

任何一步不对都可以退回去，旧数据不会被删除：

```bash
systemctl --user disable --now qbittorrentee
# 恢复旧 config（如果迁移过程动过它）
rm -rf <config目录> && tar xzf ~/qbt-config-before-migrate.tar.gz -C <父目录>
```

然后把旧容器用原来的命令重新 `podman run` 即可 —— 本项目的迁移动作只涉及
**config 目录内的一次 `mv`**，不会改下载目录里的任何文件（rootless 下甚至不执行 chown）。

---

## 7. 迁移后的常见"以为坏了"

| 现象 | 解释 |
|---|---|
| WebUI 里种子显示「缺失文件」 | 下载目录的宿主路径变了。在 WebUI 里改保存路径，或保证 `DOWNLOADS_DIR` 与旧的一致 |
| 端口变成 8080 了 | 你在环境里显式写了 `WEBUI_PORT=8080`，它覆盖了配置文件里的值。删掉该变量或改成正确值 |
| 属主显示成一串数字 | 那是 subuid。见 [puid-pgid.md](puid-pgid.md) 第 3 节 |
