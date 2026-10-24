# CI/CD：流水线、标签策略与发版

三件事：**怎么构建**、**什么时候推送**、**版本怎么标**。
你只是使用镜像的话，看第 7 节标签策略和第 8 节 Release 就够；要改仓库或排查流水线，从第 1 节看起。

---

## 1. 流水线总览

`.github/workflows/build.yml`

```
schedule  23 */6 * * *        每 6 小时查一次上游
workflow_dispatch             手动触发（可指定版本 / 强制重建 / 指定 s6 版本）
push(main) / tag v*           代码或标签变更

  ┌──────────┐   ┌───────────────┐   ┌────────────┐   ┌──────────┐
  │ resolve  │──►│ build         │──►│ smoke      │──►│ push     │
  │ 查版本   │   │ 构建 amd64    │   │ 真实容器   │   │ 推全部   │
  │ 查是否已 │   │ **不推送**    │   │ 冒烟 A/B/C │   │ 标签     │
  │ 存在     │   │ load 到本地   │   │ + D        │   │          │
  └──────────┘   └───────────────┘   └────────────┘   └──────────┘
                                                           │
                                                           ▼
                                          ┌────────────┐  ┌────────────┐
                                          │ rootless   │─►│ release    │
                                          │ podman     │  │ GitHub     │
                                          │ 再验一遍   │  │ Release    │
                                          └────────────┘  └────────────┘
```

只在 **linux/amd64** 上构建与测试，不使用 QEMU。单次构建约 1 分钟。

---

## 2. resolve：决定「要不要构建」

`scripts/resolve-upstream.sh`（纯 bash，无需 jq 之外的依赖）：

1. 取上游最新非 prerelease、且 tag 形如 `release-x.y.z.w` 的发布；
2. 校验该 release 里存在 `qbittorrent-enhanced-nox_x86_64-linux-musl_static.zip`
   —— 缺资产直接失败，避免构建出一个下载 404 页的镜像；
3. 组装标签；
4. 用 GHCR v2 `HEAD /manifests/<tag>` 检查 `<version>` 标签是否已存在。
   已存在且不是 `push` 事件、也没开 `force_rebuild` → **SKIP**，零构建开销。

`push` 到 `main` 时无条件重建（并额外产出 `edge`）；推 `v*` tag 同样触发重建，
但不产出 `edge`（`edge` 只代表 `main` 的最新构建）。手动触发可用 `force_rebuild` 强推。

> **版本号只有一个来源：上游 release tag。**
> 本仓库自己的 tag（例如 `v0.1.0`）只用来触发 CI，不参与镜像版本计算。
> 把 `v0.1.0` 传给 `upstream_version` 会被直接拒绝 —— `tests/resolve-upstream.sh`
> 有两个用例专门守这条（tag push 不产 `edge`、`v0.1.0` 不得成为版本号）。

---

## 3. build：构建，但**不推送**

用 `docker/build-push-action` + `push: false` + `load: true` 把镜像装进 runner 本地的
docker daemon，标签一次性打全（`version` / `sha` / `edge` / `5.2` / `5` / `latest`）。

`S6_OVERLAY_VERSION` 默认从 **Dockerfile 的 ARG** 读（`scripts/dockerfile-arg.sh`），
workflow 里不再抄一份默认值 —— 两处默认值分叉是这类项目最常见的版本漂移来源。
`validate.yml` 里有一条专门检查「build.yml 不得写死 s6 版本」。

---

## 4. smoke：真实容器冒烟

`tests/smoke.sh` 用刚构建的本地镜像起 4 个容器：

| 用例 | 内容 | 断言 |
|---|---|---|
| A | 默认启动（rootful） | PID 1 是 `s6-svscan`；进程 uid/gid = 1000；配置属主 1000:1000；WebUI 200；日志含「场景：rootful」「运行身份：abc」 |
| B | `PUID=1234 PGID=2345 UMASK=027` | 进程 uid/gid = 1234/2345；引擎目录属主 1234:2345；WebUI 200 |
| C | `--user 65534` + 可写 `/run` tmpfs | 能起来；进程 uid = 65534；日志含「已被忽略」（PUID 无法生效时明确告警） |
| D | `WEBUI_PORT=8090` | 配置文件里端口 = 8090；宿主映射端口 200；清空 `WEBUI_PORT` 后 healthcheck 仍能从配置读到端口 |

用例 C 是「尽力而为」：该模式本身受限，失败只记 WARN。

---

## 5. push：冒烟通过后一次性推全部标签

```
[version] [sha-xxxxxxx] [edge]  ←  不可变（edge 会移动）
[major.minor] [major] [latest]  ←  移动标签
```

**没有 `docker buildx imagetools create`、没有任何 registry manifest 改写。**
旧做法是「先推不可变标签 → 冒烟 → 再用 imagetools 把 `latest` 指过去」；现在改成
「构建不推 → 冒烟 → 一次 `docker push` 全部标签」，效果更严格：
镜像没跑通就根本不会出现在 registry 里，`latest` / `5.2` / `5` 不可能指向坏镜像。

---

## 6. rootless：用 rootless Podman 再验一遍

`tests/rootless.sh` 在普通用户下跑，断言：

- 日志识别为 `场景：rootless`；
- 日志含「属主修正：跳过」—— rootless 下**没有执行任何 chown**；
- 运行身份是容器 root（`uid=0`），即宿主上的当前用户；
- 宿主上配置文件属主 = 当前用户；
- WebUI 可访问。

环境不满足（无 subuid、podman 不可用）时退出码 `77`，workflow 转成 `::notice::` 跳过。

---

## 7. 标签策略

| 标签 | 可变性 | 何时更新 |
|---|---|---|
| `5.2.4.10` | 不可变 | 上游发这个版本时创建一次 |
| `sha-abc1234` | 不可变 | 每次构建 |
| `5.2` / `5` | 移动 | 每次冒烟通过后 |
| `latest` | 移动 | 每次冒烟通过后 |
| `edge` | 移动 | 每次 `push` 到 `main`（推 tag 不更新它） |

**镜像版本号与上游 release 严格一致**：上游发 `5.2.4.10`，这里就是 `5.2.4.10`，
不做自己的版本编排。想钉死就用不可变标签，想跟随就 `latest`。

**仓库 tag 与镜像 tag 是两件事**。`v0.1.0` 打在 commit 上，作用只是「跑一次 CI」；
镜像里不会出现 `0.1.0`，也不会出现 `v0.1.0`。两套编号各走各的，互不推导。

---

## 8. GitHub Release

镜像标签只在 GHCR 里，Registries 页面的标签列表不适合用来观察「上游什么时候发了新版」。
所以每次上游出现新版本、且构建与全部测试通过后，`release` job 会在仓库里建一个
**与该版本同号的 Release**：

```
Release tag   5.2.4.10        ← 与镜像不可变标签同名
Release 标题  5.2.4.10
指向 commit   触发出这次构建的 main 提交
```

Releases 页面因此成为一条按版本排好的时间线，`/releases/latest` 直接指向当前版本。

### 为什么 tag 不带 `v` 前缀

`build.yml` 的 `on.push.tags` 里有 `v*`。若 Release tag 叫 `v5.2.4.10`，
任何一次手动 `git push tag` 都会额外触发一整轮完整构建（GitHub 对 tag push
不评估 `paths` 过滤）。纯版本号不匹配 `v*`，没有这层耦合。

第二道保险：CI 用 `GITHUB_TOKEN` 创建的 tag 本身不会触发新的 workflow run ——
这是 GitHub 的既定行为，但我们不依赖它，前缀隔离是更明确的那道。

### 什么时候创建、什么时候跳过

| 场景 | `build` | Release |
|---|---|---|
| 上游发了新版本（schedule 或手动发现） | 跑 | **创建** |
| `push` 到 `main`（重建同一版本） | 跑 | 已存在 → 跳过 |
| 推 `v*` tag（如 `v0.1.0`） | 跑 | 已存在 → 跳过 |
| 上游无新版本（schedule 空跑） | 跳过 | 不执行 |
| 冒烟或 rootless 失败 | 跑但失败 | **不执行**（`needs` 里带了 rootless） |

`scripts/publish-release.sh` 自身是幂等的：先 `gh release view` 探一次，
存在就打印「已存在，跳过」并退出 0。所以重复构建不会产生重复 Release，
也不会把已经写好的发布说明覆盖掉。

`--latest` 只在**本次版本大于已有最大版本**时才传。手动 `force_rebuild`
一个旧版本不会把 Releases 页面的 Latest 指回旧版 —— 镜像的 `latest` 标签
也是同样的判定顺序。

### Release 里写了什么

| 内容 | 来源 |
|---|---|
| 上游版本链接 | `https://github.com/c0re100/.../releases/tag/release-x.y.z.w` |
| 上游发布时间 | 上游 API 的 `published_at` |
| 镜像 digest | build job 的 `docker buildx imagetools inspect` 输出 |
| 拉取命令 | `docker pull` / `podman pull` 各一行 |
| 本次推送的镜像标签 | resolve 的 `push_tags`，只列短名（`5.2.4.10` / `latest` / `edge` …） |

生成逻辑在 `scripts/publish-release.sh`，说明用 `printf` 逐段拼装 ——
Release 正文里含 ``` 代码块，heredoc 会把反引号当命令替换，引号包裹的 heredoc
又无法展开变量，两者都不合适。

### 手动补发

Release 只跟着构建走，`build=false` 时不会单独执行。要给一个已构建过的版本补发：

```
Actions → build → Run workflow → force_rebuild = true
```

会重建镜像（覆盖同名标签，digest 可能变化）并创建 Release。若只想看说明
不实际创建，本地可以这样验证：

```bash
VERSION=5.2.4.10 DRY_RUN=true REPO=owner/repo bash scripts/publish-release.sh
```

### 删除与重发

Release 页面删除后，tag 会保留（GitHub 默认行为）。下次 `force_rebuild`
时会因「tag 已存在」而省略 `--target`，直接复用现有 tag 创建 Release。
若想把 tag 也一起重置，先在仓库 Tags 页面删除 tag 再走上面补发流程。

`tests/publish-release.sh` 用桩件覆盖了幂等、`--latest` 判定、`--target` 省略
三类分支，离线可跑。

---

## 9. 几个设计取舍

| 决定 | 原因 |
|---|---|
| **只构建 amd64** | 目标机是 x86_64；多架构要 QEMU、镜像体积翻倍、测试矩阵翻倍。Dockerfile 里有架构守卫，`--platform linux/arm64` 会直接失败 |
| **零编译** | 上游直接发布 musl 静态二进制；构建失败面从「Qt/libtorrent 编译」缩到「下载 + 解包」 |
| **`provenance: false` / `sbom: false`** | attestation 会往 index 里塞 `unknown/unknown` 平台 manifest，老版本 Podman（如 Ubuntu 22.04 的 3.4）拉取时报 `no image found in manifest list for architecture` |
| **先冒烟后推送** | 见第 5 节 |
| **`8 小时内` 检查一次而不是实时** | 上游发版不频繁；6 小时足够，也不会刷爆 Actions 额度 |
| **不改写 git 历史** | 历史里没有敏感信息或构建产物；改写只会让所有 clone/fork 失效 |

---

## 10. 手动触发

Actions → `build` → Run workflow：

| 参数 | 说明 |
|---|---|
| `upstream_version` | 指定上游版本（如 `5.2.4.10` 或 `release-5.2.4.10`），留空则自动取最新 |
| `force_rebuild` | 忽略「标签已存在」，强制重建（用于修 CI 脚本后重发同一版本） |
| `s6_overlay_version` | 覆盖 Dockerfile 里的 s6-overlay 版本，留空则用默认值 |

---

## 11. validate.yml 检查了什么

只在 PR 与手动触发时跑（`main` 的构建/测试由 `build.yml` 负责，避免重复）。

| 检查 | 工具 | 拦什么 |
|---|---|---|
| POSIX sh 脚本 | shellcheck `-s sh` | 语法、未定义变量、可移植性问题 |
| bash 脚本 | shellcheck `-s bash` | 同上 |
| Dockerfile RUN 块 | `scripts/check-dockerfile-runs.sh` | 每个 `RUN` 抽出来过 `sh -n`，拦截引号不闭合这类只有 build 才暴露的错 |
| 源文件是否纳入版本控制 | `scripts/check-tracked-files.sh` | `.gitignore` 规则写得过宽，把 `qbt-lib.sh` 这种源文件挡在仓库外 |
| 镜像引用 | `scripts/check-image-refs.sh` | 大写仓库名（`repository name must be lowercase`）、短名配 `AutoUpdate=registry` |
| 版本来源一致性 | `scripts/dockerfile-arg.sh` | 版本格式非法、`build.yml` 又写死 s6 版本 |
| Hadolint | hadolint | Dockerfile 最佳实践 |
| YAML 语法 | python3 + pyyaml | workflow / compose / 配置文件写坏 |
| 单元测试 | `tests/identity.sh`、`tests/resolve-upstream.sh` | 身份映射、版本解析与标签组装 |
| 单架构构建 + 冒烟 | buildx + `tests/smoke.sh` | 与 build.yml 同样的冒烟 |

---

## 12. 维护者需要人工确认的两件事

1. **包可见性**：GHCR 新包的默认可见性跟着仓库走。若 `podman pull` 返回 401，
   去 `Packages → qbittorrentee-rootless → Package settings → Change visibility` 改成 `Public`。

   ```bash
   T=$(curl -s "https://ghcr.io/token?scope=repository:kashwan/qbittorrentee-rootless:pull&service=ghcr.io" \
       | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
   curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $T" \
       "https://ghcr.io/v2/kashwan/qbittorrentee-rootless/manifests/latest"     # 期望 200
   ```

2. **schedule 会被停用**：GitHub 对「60 天无提交」的仓库会停止定时工作流，
   期间不会自动跟随上游发版。可在 Actions 里手动 Run workflow 恢复。

---

## 13. 本地复现 CI

```bash
make check     # sh/bash 语法 + Dockerfile RUN 块 + 镜像引用 + 文件追踪 + 单元测试（无需网络）
make lint      # shellcheck(sh/bash) + hadolint（与 validate.yml 逐条一致，需要 docker）
make test      # 冒烟 A/B/C/D（需要先 make build）
make test-rootless   # rootless 行为验证（普通用户执行）
make versions  # 显示将从 Dockerfile 使用的上游 / s6-overlay 版本
```

---

## 14. 版本历史

镜像版本 = 上游 qBittorrent Enhanced Edition 的版本号。

| 镜像版本 | 对应上游 | 变更 |
|---|---|---|
| `5.2.4.10` | release-5.2.4.10 | 首个可用版本：s6-overlay v3、PUID/PGID 三场景、rootless/Quadlet 支持、CI 自动跟随上游 |
| （下一版） | — | 收敛为 amd64 单架构；rootless 下完全不 chown；healthcheck 端口自适应；版本来源单一化；文档收敛为 7 份 |

上游发新版本时，本仓库不需要改任何代码 —— CI 会自己发现并发布同名镜像标签。
