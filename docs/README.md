# 文档索引

主 README 只回答「这是什么、怎么跑起来」。这里回答「为什么这样设计、怎么长期运维、出问题怎么办」。

---

## 按「我想……」反查

| 我想 | 看这份 |
|---|---|
| 搞清楚容器里「用户」到底是什么、PUID 为什么不生效 | [puid-pgid.md](puid-pgid.md) |
| 把镜像长期跑在自己的服务器上，自动更新 | [podman-quadlet.md](podman-quadlet.md) |
| 知道 CI 什么时候构建、标签怎么取、怎么发版 | [ci-cd.md](ci-cd.md) |
| 从 superng6 / linuxserver 换过来 | [migration.md](migration.md) |
| 起不来 / 属主不对 / 端口不生效 / 改了没生效 | [troubleshooting.md](troubleshooting.md) |
| 给镜像加启动脚本、加伴生进程、升级 s6 | [s6-overlay.md](s6-overlay.md) |

---

## 文档清单

| 文件 | 类型 | 面向 | 一句话 |
|---|---|---|---|
| [puid-pgid.md](puid-pgid.md) | 技术专题 | 所有人 | 容器里没有「用户」只有 uid；userns 映射与三种场景 |
| [podman-quadlet.md](podman-quadlet.md) | 运维手册 | 部署者 | rootless 部署、Quadlet、自动更新、备份、升级回滚 |
| [s6-overlay.md](s6-overlay.md) | 技术专题 | 二次开发者 | v3 生命周期、目录约定、环境变量传递的坑、扩展点 |
| [ci-cd.md](ci-cd.md) | 流程说明 | 维护者 / 想自己构建的人 | 流水线、标签策略、validate 检查项、版本历史 |
| [migration.md](migration.md) | 迁移指南 | 从旧镜像过来的人 | 目录布局对照、环境变量对照、迁移与回退 |
| [troubleshooting.md](troubleshooting.md) | FAQ | 所有人 | 按症状查，每节先讲怎么确认 |

---

## 约定

- **主 README 不写部署细节与排障**：那些进 `podman-quadlet.md` 与 `troubleshooting.md`。
- **技术专题各管一件事**：`puid-pgid.md` 只讲身份与 userns，`s6-overlay.md` 只讲生命周期与扩展点。
  互相之间只做链接，不复制内容。
- **排障文档按症状组织**，每节以「怎么确认」开头 —— 先拿证据再改配置。
- **新增文档时请在「反查表」和「清单」两处各加一行**，否则等于没有被发现。
- 所有文档里的镜像名**必须全小写**（`ghcr.io/kashwan/...`）；CI 的
  `scripts/check-image-refs.sh` 会拦住大写写法。
