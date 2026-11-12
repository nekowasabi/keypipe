# keypipe daemon targets. Default `make` = stop, build, start (quick manual check).
#
# The daemon reads ~/.config/keypipe/config.json (or CONFIG=...). stdout and
# stderr go to LOG. The daemon runs from APP so that `make` can reset its Accessibility grant.

# Why: tccutil resets one app only by bundle id; a bare binary can't be named, and a reset with
# no id removes every app's grant.
APP     := .build/Keypipe.app
APP_ID  := dev.keypipe
BIN     := $(APP)/Contents/MacOS/keypipe
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
LOG     ?= $(HOME)/.local/state/keypipe/keypipe.log
CONFIG  ?=
CONFIG_FLAG := $(if $(CONFIG),--config $(CONFIG),)

.DEFAULT_GOAL := dev
.PHONY: help dev build reset-ax start stop restart status log test lint check-docs check verify verify-auto

# Why: Xcode ships the formatter as `swift format` without swift-format on PATH. Each verify
# script once looked the tool up on its own, missed this, and skipped the lint on every Mac
# (28de2bc, 8630c35). Scripts call `make lint`; `=` keeps the lookup out of other targets.
FORMAT = $(shell command -v swift-format 2>/dev/null || (swift format --version >/dev/null 2>&1 && echo "swift format"))

help: ## 利用可能なターゲット一覧を表示する
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

dev: stop build reset-ax start ## デーモンを止めて再ビルドし、アクセシビリティ許可を消して起動する（既定）

build: ## swift build と、デーモン用の $(APP) の作成
	swift build
	@mkdir -p "$(APP)/Contents/MacOS"
	@cp macos/Info.plist "$(APP)/Contents/Info.plist"
	@cp .build/debug/keypipe "$(BIN)"
	@codesign --force --sign - --identifier $(APP_ID) "$(APP)"
	@$(LSREGISTER) -f "$(APP)"

reset-ax: ## $(APP) のアクセシビリティ許可を消す（起動時に許可ダイアログが出る）
	@tccutil reset Accessibility $(APP_ID) || true

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

lint: ## swift-format lint --strict（Xcode の swift format も使う。道具が無ければ失敗）
	@test -n "$(FORMAT)" || { echo "make lint: neither swift-format nor swift format found" >&2; exit 1; }
	$(FORMAT) lint --strict --recursive Sources Tests

check-docs: ## README と SKILL.md が名指しする Swift のシンボルが実在するか
	scripts/check-doc-symbols.sh

check: build test lint check-docs ## 人手の要らない静的検査一式（CI と同じコマンド）

verify: ## 検証スキル（実機 M 項目を含む。--no-live は VERIFY_ARGS=--no-live）
	.claude/skills/verify-keypipe-rules/verify.sh $(VERIFY_ARGS)

verify-auto: build ## 人手もデーモン停止も要らない自動検証（rules と terminals の --no-live）
	.claude/skills/verify-keypipe-rules/verify.sh --no-live
	.claude/skills/verify-keypipe-terminals/verify.sh --no-live
