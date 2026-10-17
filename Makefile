# =============================================================================
#  Makefile · 本地开发常用操作
# =============================================================================

IMAGE       ?= qbittorrentee:dev
VERSION     ?= 5.2.4.10
S6_VERSION  ?= 3.2.3.2
PLATFORMS   ?= linux/amd64,linux/arm64,linux/arm/v7
RUNTIME     ?= docker

.PHONY: help build build-multi test test-rootless identity check run shell clean push

help:
	@printf '%s\n' \
	  'make build         构建本机架构镜像（$(IMAGE)，上游 $(VERSION)）' \
	  'make build-multi   用 buildx 构建多架构（不推送）' \
	  'make test          冒烟测试（A/B/C 三组用例）' \
	  'make test-rootless rootless podman 行为验证' \
	  'make identity      身份解析单元测试（无需容器）' \
	  'make check         shell / YAML 静态检查' \
	  'make run           用 docker-compose 起一个实例' \
	  'make shell         进容器交互式 shell' \
	  'make clean         清理临时文件与测试容器'

build:
	$(RUNTIME) build \
	  --build-arg QBITTORRENT_VERSION=$(VERSION) \
	  --build-arg S6_OVERLAY_VERSION=$(S6_VERSION) \
	  -t $(IMAGE) .

build-multi:
	$(RUNTIME) buildx build \
	  --platform $(PLATFORMS) \
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
	@make identity

run:
	$(RUNTIME) compose up -d

shell:
	$(RUNTIME) run --rm -it --entrypoint sh $(IMAGE)

clean:
	-$(RUNTIME) rm -f qbt-smoke-a qbt-smoke-b qbt-smoke-c qbt-rootless-1 qbt-rootless-2 >/dev/null 2>&1
	-rm -rf /tmp/qbt-smoke.* /tmp/qbt-rootless.*
