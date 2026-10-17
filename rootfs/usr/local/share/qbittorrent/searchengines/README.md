# 搜索引擎插件预置目录

把 Nova3 搜索插件（`.py` 文件，例如 `sukebei.py`、`nyaa.py`）放进这个目录，
镜像首次启动时 `10-config` 会把它们复制到：

```
/config/qBittorrent/data/nova3/engines/
```

已经存在的同名文件不会被覆盖，所以你随时可以在 WebUI 的「搜索」页里删装插件。

## 为什么默认是空的

- 搜索插件大多由第三方维护，版本与站点结构强相关，打进镜像会很快过期；
- 插件会发起外部 HTTP 请求，默认不预置更符合「最小惊讶」原则。

## 怎么加

**方式一：挂载（无需重建镜像，推荐）**

```bash
podman run ... -v ~/qbt/searchengines:/config/searchengines:Z ...
```

`10-config` 同样会扫描 `/config/searchengines/*.py`。

**方式二：打进镜像**

```bash
mkdir -p searchengines && cp ~/plugins/*.py searchengines/
# 然后在 Dockerfile 里取消这一行的注释：
# COPY searchengines/ /usr/local/share/qbittorrent/searchengines/
```

**方式三：直接在 WebUI 里装**

搜索 → 「搜索插件」→ 「检查更新」/ 手动安装。适合只用一两个插件的场景。

## 注意

搜索功能需要 `python3`。镜像默认 `WITH_PYTHON=1`（已包含）。如果你为了瘦身关掉：

```bash
docker build --build-arg WITH_PYTHON=0 ...
```

那么搜索页会提示缺少 Python，属于预期行为。
