.DEFAULT_GOAL := help

# Command Line Tools ship the Swift Testing macro plugin, but SwiftPM does not find it on its own.
CLT_TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
TEST_FLAGS := -Xswiftc -plugin-path -Xswiftc $(CLT_TESTING_PLUGINS)
endif

.PHONY: help app run-app cli test clean

help: ## ターゲット一覧を表示
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

app: ## アプリ dist/DeckReel.app をビルド (macOS 14+)
	./scripts/build-app.sh

run-app: app ## アプリをビルドして起動
	open dist/DeckReel.app

cli: ## CLI dist/deckreel をビルド
	./scripts/build-cli.sh

test: ## テストを実行 (Swift Testing)
	swift test $(TEST_FLAGS)

clean: ## ビルド成果物を削除
	rm -rf dist .build
