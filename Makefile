.DEFAULT_GOAL := help

GO ?= go

# macOSではネイティブヘルパーを埋め込まないとmacOS専用テストが失敗するため、先にビルドする
ifeq ($(shell uname -s),Darwin)
TEST_DEPS := build
endif

.PHONY: help build app run-app test vet fmt fmt-check check clean

help: ## ターゲット一覧を表示
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## ネイティブヘルパーと dist/deckreel をビルド (macOS)
	./scripts/build.sh

app: ## SwiftUIアプリ dist/DeckReel.app をビルド (macOS 14+)
	./scripts/build-app.sh

run-app: app ## アプリをビルドして起動
	open dist/DeckReel.app

test: $(TEST_DEPS) ## Goのテストを実行 (-race、macOSでは先にbuild)
	$(GO) test -race ./...

vet: ## go vet を実行
	$(GO) vet ./...

fmt: ## gofmt でコードを整形
	gofmt -w cmd internal

fmt-check: ## gofmt の差分がないか確認
	@out="$$(gofmt -l cmd internal)"; \
	if [ -n "$$out" ]; then echo "gofmt が必要なファイル:"; echo "$$out"; exit 1; fi

check: fmt-check vet test ## CIのGoジョブ相当 (fmt-check, vet, test)

clean: ## ビルド成果物と生成したヘルパーを削除
	rm -rf dist
	rm -f internal/native/assets/deckreel-native-*
