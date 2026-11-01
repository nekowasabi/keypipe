# keypipe daemon targets. Default `make` = stop, build, start (quick manual check).
#
# The daemon reads ~/.config/keypipe/config.json (or CONFIG=...). stdout and
# stderr go to LOG. Rebuilding keeps the Accessibility grant (measured).

BIN     := .build/debug/keypipe
LOG     ?= $(HOME)/.local/state/keypipe/keypipe.log
CONFIG  ?=
CONFIG_FLAG := $(if $(CONFIG),--config $(CONFIG),)

.DEFAULT_GOAL := dev
.PHONY: help dev build start stop restart status log test verify

help: ## 利用可能なターゲット一覧を表示する
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

dev: stop build start ## デーモンを止めて再ビルドし起動する（既定）

build: ## swift build
	swift build

start: ## デーモンを裏で起動し、`keypipe started` が出るまで最大 5 秒待つ
	@mkdir -p "$(dir $(LOG))"
	@if pgrep -x keypipe >/dev/null; then echo "keypipe already running (pid $$(pgrep -x keypipe)); run make stop first" >&2; exit 1; fi
	@nohup "$(BIN)" $(CONFIG_FLAG) > "$(LOG)" 2>&1 &
	@for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'keypipe started' "$(LOG)" 2>/dev/null && break; sleep 0.5; done
	@if grep -q 'keypipe started' "$(LOG)"; then \
		echo "started (pid $$(pgrep -x keypipe)), log: $(LOG)"; \
	else \
		echo "keypipe did not start; log follows" >&2; cat "$(LOG)" >&2; exit 1; \
	fi

stop: ## 起動中のデーモンを止める
	@pkill -x keypipe && echo "stopped" || echo "not running"
	@sleep 0.3

restart: stop start ## ビルドせずに再起動する

status: ## 起動状態と直近のログ
	@pgrep -x keypipe >/dev/null && echo "running (pid $$(pgrep -x keypipe))" || echo "not running"
	@[ -f "$(LOG)" ] && tail -n 10 "$(LOG)" || true

log: ## ログを追いかける
	tail -f "$(LOG)"

test: ## swift test
	swift test

verify: ## 検証スキル（実機 M 項目を含む。--no-live は VERIFY_ARGS=--no-live）
	.claude/skills/verify-keypipe-rules/verify.sh $(VERIFY_ARGS)
