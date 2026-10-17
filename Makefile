# =============================================================================
#  Makefile · 本地开发常用操作
#
#  版本号不在这里写死：VERSION / S6_VERSION 都从 Dockerfile 的 ARG 默认值读，
#  Dockerfile 是唯一来源（见 scripts/dockerfile-arg.sh）。
# =============================================================================

IMAGE      ?= qbittorrentee:dev
RUNTIME    ?= docker
VERSION    ?= $(shell bash scripts/dockerfile-arg.sh Dockerfile QBITTORRENT_VERSION)
S6_VERSION ?= $(shell bash scripts/dockerfile-arg.sh Dockerfile S6_OVERLAY_VERSION)

.PHONY: help versions build buildx test test-rootless identity check lint run shell clean

help:
	@printf '%s\n' \
	  'make versions      显示将从 Dockerfile 使用的上游 / s6-overlay 版本' \
	  'make build         构建镜像（$(IMAGE)）' \
	  'make buildx        用 buildx 构建 linux/amd64（与 CI 一致，不推送）' \
	  'make test          冒烟测试（A/B/C 三组用例）' \
	  'make test-rootless rootless podman 行为验证' \
	  'make identity      身份解析单元测试（无需容器）' \
	  'make check         shell / Dockerfile / 镜像引用 / 版本控制的静态检查（无需网络）' \
	  'make lint          shellcheck + hadolint（与 CI 完全一致，需要 docker）' \
	  'make run           用 docker-compose 起一个实例' \
	  'make shell         进容器交互式 shell' \
	  'make clean         清理临时文件与测试容器'

versions:
	@printf '上游 qBittorrent-EE : %s\n' "$(VERSION)"
	@printf 's6-overlay          : %s\n' "$(S6_VERSION)"

build:
	$(RUNTIME) build \
	  --platform linux/amd64 \
	  --build-arg QBITTORRENT_VERSION=$(VERSION) \
	  --build-arg S6_OVERLAY_VERSION=$(S6_VERSION) \
	  -t $(IMAGE) .

buildx:
	$(RUNTIME) buildx build \
	  --platform linux/amd64 \
	  --build-arg QBITTORRENT_VERSION=$(VERSION) \
	  --build-arg S6_OVERLAY_VERSION=$(S6_VERSION) \
	  -t $(IMAGE) .

test:
	IMAGE=$(IMAGE) RUNTIME=$(RUNTIME) bash tests/smoke.sh

test-rootless:
	IMAGE=$(IMAGE) bash tests/rootless.sh

identity:
	sh tests/identity.sh
	bash tests/resolve-upstream.sh

check:
	@echo "== bash -n =="
	@for f in scripts/*.sh tests/*.sh; do printf '%-40s' "$$f"; bash -n "$$f" && echo OK; done
	@echo "== sh -n =="
	@for f in rootfs/usr/local/bin/*.sh rootfs/etc/cont-init.d/* rootfs/etc/services.d/*/run \
	          rootfs/etc/services.d/*/finish; do printf '%-40s' "$$f"; sh -n "$$f" && echo OK; done
	@echo "== Dockerfile 的 RUN 块 =="
	@bash scripts/check-dockerfile-runs.sh Dockerfile
	@echo "== 镜像引用（小写 + 全限定）=="
	@bash scripts/check-image-refs.sh
	@echo "== 源文件是否都纳入版本控制 =="
	@bash scripts/check-tracked-files.sh
	@echo "== 版本来源 =="
	@make --no-print-directory versions
	@make --no-print-directory identity

# 与 .github/workflows/validate.yml 的 lint job 逐条对齐：
# 本地跑一遍就和 CI 的结论一致，避免 push 之后才发现 shellcheck/hadolint 报错
lint:
	@echo "== shellcheck（POSIX sh）=="
	@docker run --rm -v "$$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -s sh -x \
	  rootfs/usr/local/bin/docker-entrypoint.sh \
	  rootfs/usr/local/bin/healthcheck.sh \
	  rootfs/usr/local/bin/qbt-lib.sh \
	  rootfs/etc/cont-init.d/00-identity \
	  rootfs/etc/cont-init.d/10-config \
	  rootfs/etc/cont-init.d/20-downloads \
	  rootfs/etc/services.d/qbittorrent/run \
	  rootfs/etc/services.d/qbittorrent/finish
	@echo "== shellcheck（bash）=="
	@docker run --rm -v "$$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -s bash -x \
	  scripts/resolve-upstream.sh \
	  scripts/install-quadlet.sh \
	  scripts/check-dockerfile-runs.sh \
	  scripts/check-tracked-files.sh \
	  scripts/check-image-refs.sh \
	  scripts/dockerfile-arg.sh \
	  tests/smoke.sh \
	  tests/rootless.sh \
	  tests/resolve-upstream.sh
	@echo "== hadolint（挂载仓库以读取 .hadolint.yaml）=="
	@docker run --rm -v "$$PWD:/mnt" -w /mnt hadolint/hadolint:latest hadolint Dockerfile

run:
	$(RUNTIME) compose up -d

shell:
	$(RUNTIME) run --rm -it --entrypoint sh $(IMAGE)

clean:
	-$(RUNTIME) rm -f qbt-smoke-a qbt-smoke-b qbt-smoke-c qbt-rootless-1 qbt-rootless-2 >/dev/null 2>&1
	-rm -rf /tmp/qbt-smoke.* /tmp/qbt-rootless.*
