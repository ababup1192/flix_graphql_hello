.PHONY: run check test test-unit test-pg test-pg-ci import-microcms import-blog-example db-up db-down query generate scaffold gen gen-check migrate migrate-status migrate-new fatjar image

# **テストの DB は開発の DB と分ける。** 同じ物を使うと、テストが終わりに消す時に
# 手元のデータ（見本のコンテンツ、発行した鍵、招待）まで消える（実際に消えた）。
# 同じ postgres の中でデータベースを分け、コンテナは落とさない。
DEV_DB = cms
TEST_DB = cms_test

# 実 PG と MinIO 用の接続。docker-compose.yml と同じ値。
# **DSN 以外をここに置く**（DSN を二重に渡すと、どちらが効くかがシェル任せになる）。
PG_BASE = CMS_DB_USER=cms CMS_DB_PASSWORD=cms \
	ASSET_ENDPOINT=http://127.0.0.1:9000 ASSET_BUCKET=cms ASSET_ACCESS_KEY=cms ASSET_SECRET_KEY=cms-secret \
	ASSET_REGION=us-east-1 ASSET_PUBLIC_URL=http://127.0.0.1:9000/cms \
	CMS_AUTH=dev CMS_BOOTSTRAP_OWNER=dev@localhost CMS_API_KEY_PEPPER=dev-pepper

# 開発（make run / make import-microcms）が使う DB
PG_ENV = CMS_DSN=jdbc:postgresql://127.0.0.1:5432/$(DEV_DB) $(PG_BASE)

# テスト（make test-pg）が使う DB。**中身を毎回消すので、開発の物と別にする**
PG_TEST_ENV = CMS_DSN=jdbc:postgresql://127.0.0.1:5432/$(TEST_DB) $(PG_BASE)

# サーバ起動。PG は make db-up で立てておく
run:
	$(PG_ENV) bin/flix run

# microCMS の API スキーマ（import/microcms/schema/*.json）を既定プロジェクトに写し、ダミーの entry を積んで公開する。PG は make db-up で
import-microcms:
	$(PG_ENV) CMS_MODE=import-microcms CMS_IMPORT_DIR=import/microcms/schema bin/flix run

# サンプルブログ（別リポジトリの flix-cms-example）が前提にしている blogs / authors / tags を
# 専用のプロジェクトに写し、ダミーの entry を積んで公開する。PG は make db-up で。
# プロジェクト（BLOG_EXAMPLE_PROJECT）は先に作っておく（Account API の createProject）。
BLOG_EXAMPLE_PROJECT = blog-example

import-blog-example:
	$(PG_ENV) CMS_DEFAULT_PROJECT=$(BLOG_EXAMPLE_PROJECT) CMS_MODE=import-microcms CMS_IMPORT_DIR=import/blog-example/schema bin/flix run

check:
	bin/flix check
	cd schemagen && ../bin/flix check
	scripts/check-tx.sh
	scripts/check-handlers.sh
	scripts/check-log-keys.sh

# 既定は DB 無しのテスト
test: test-unit

# DB 無しのテスト。build/unit/ に test/Pg を除いた写しを作って回す（元のファイルには触らない）。
# WhyNot: test/Pg/ を test/ の外に置かないのは、VSCode の Flix 拡張が src/ と test/ しか LSP に渡さないため。
UNIT_DIR = build/unit

test-unit:
	mkdir -p $(UNIT_DIR)
	cp flix.toml $(UNIT_DIR)/flix.toml
	cp schema.graphql admin.graphql account.graphql $(UNIT_DIR)/
	ln -sfn $(CURDIR)/migrations $(UNIT_DIR)/migrations
	rsync -a --delete src/ $(UNIT_DIR)/src/
	rsync -a --delete --exclude Pg test/ $(UNIT_DIR)/test/
	cd $(UNIT_DIR) && $(CURDIR)/bin/flix test
	cd schemagen && ../bin/flix test

# PostgreSQL と MinIO を立て、バケットを作る。
# WhyNot: `docker compose up -d --wait` 1 発にしないのは、バケットを作る minio-init が終了する（exit 0）のを --wait が失敗と見るため
COMPOSE_UP = docker compose up -d --wait postgres minio && docker compose up minio-init

# 実 PostgreSQL と MinIO に当たるテスト。**開発の DB は触らない**（$(TEST_DB) を作り直して使う）。
# コンテナも落とさないので、make run を上げたまま回せる。
test-pg:
	$(COMPOSE_UP)
	@docker compose exec -T postgres psql -U cms -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$(TEST_DB)'" | grep -q 1 || \
		docker compose exec -T postgres psql -U cms -d postgres -c "CREATE DATABASE $(TEST_DB) OWNER cms" > /dev/null
	$(PG_TEST_ENV) bin/flix test

# CI 用。テストの後にコンテナごと片付ける（CI には手元のデータが無い）
test-pg-ci:
	$(COMPOSE_UP)
	$(PG_TEST_ENV) bin/flix test; status=$$?; docker compose down -v; exit $$status

db-up:
	$(COMPOSE_UP)

db-down:
	docker compose down -v

# SDL から生成物を作り直す。admin.graphql → src/generated/graphql/GeneratedAdminSchema.flix、account.graphql → GeneratedAccountSchema.flix、
# schema.graphql（graphql-java の境界のテスト用の見本）→ test/sample/GeneratedSchema.flix
generate:
	cd schemagen && ../bin/flix run
	cd schemagen && SCHEMAGEN_SDL=../account.graphql SCHEMAGEN_MODULE=GeneratedAccount SCHEMAGEN_EFF=AccountEff ../bin/flix run
	cd schemagen && SCHEMAGEN_SDL=../schema.graphql SCHEMAGEN_MODULE=Generated SCHEMAGEN_OUT=../test/sample/GeneratedSchema.flix ../bin/flix run

# ---- sqlfx（生成器と migrate は flix_db 側の main で動かす。.fpkg には入っていない）----
FLIX_DB = $(HOME)/Desktop/flix_db

# migrations/ と queries/*.q から src/generated/sql/ を作り直す
gen:
	cd $(FLIX_DB) && bin/flix run -- gen --scope project_id $(CURDIR)/migrations $(CURDIR)/queries $(CURDIR)/src/generated/sql

# 生成物が最新か（書かない。CI 用）
gen-check:
	cd $(FLIX_DB) && bin/flix run -- gen --check --scope project_id $(CURDIR)/migrations $(CURDIR)/queries $(CURDIR)/src/generated/sql

# migrations/ を PG に当てる（db-up の後で。make run の前に 1 回）
MIGRATE_ENV = SQLFX_DSN=jdbc:postgresql://127.0.0.1:5432/$(DEV_DB) SQLFX_USER=cms SQLFX_PASSWORD=cms

migrate:
	cd $(FLIX_DB) && $(MIGRATE_ENV) bin/flix run -- migrate $(CURDIR)/migrations

migrate-status:
	cd $(FLIX_DB) && $(MIGRATE_ENV) bin/flix run -- migrate --status $(CURDIR)/migrations

migrate-new:   # make migrate-new NAME=add_entries
	cd $(FLIX_DB) && bin/flix run -- migrate new $(CURDIR)/migrations $(NAME)

# 型ごとのリゾルバの雛形 src/resolvers/XResolvers.flix を書く（既にあるファイルは触らない）
#   make scaffold                 全型
#   make scaffold TYPE=Post       1 型
#   make scaffold DEFAULTS=no     既定リゾルバを使わず全フィールドを吐く（source が enum の型向け）
scaffold:
	cd schemagen && SCHEMAGEN_MODE=scaffold SCAFFOLD_TYPE=$(TYPE) SCAFFOLD_DEFAULTS=$(DEFAULTS) ../bin/flix run

# 実行可能な fat jar（artifact/flix_graphql_hello.jar）。Dockerfile の build 段と同じ物
fatjar:
	bin/flix build-fatjar

# 手元でイメージを作る。CI（.github/workflows/image.yml）は amd64 / arm64 の両方を ghcr.io に置く
image:
	docker build --build-arg CMS_VERSION=$$(git rev-parse --short HEAD) -t flix_graphql_hello:local .

# 起動中のサーバへ /health と、管理 API・コンテンツ API のサンプルを投げる
query:
	curl -s localhost:8080/health
	@echo
	curl -s -X POST localhost:8080/admin/graphql -H 'Content-Type: application/json' \
		-d '{"query": "{ contentTypes { apiId singular fields { apiId kind } } }"}'
	@echo
	curl -s -X POST localhost:8080/graphql -H 'Content-Type: application/json' \
		-d '{"query": "{ __schema { queryType { fields { name } } } }"}'
	@echo

# ---- 管理画面（admin-ui。node は devbox が持つ）----

UI := cd admin-ui && devbox run --

ui-install: ## 管理画面の依存を入れる
	$(UI) npm ci

ui-gen: ## SDL → Elm の型（admin.graphql / account.graphql）
	$(UI) npm run gen

ui-gen-check: ## SDL と生成物のずれを見張る（CI）
	$(UI) npm run gen
	@git diff --exit-code -- admin-ui/generated || \
	  (echo ""; echo "生成物が SDL とずれています。直し方: make ui-gen && git add admin-ui/generated"; exit 1)

ui-dev: ## 管理画面の dev サーバ（CMS は別ターミナルで make run）
	$(UI) npm run dev

ui-check: ## elm-format の検査・elm-review・elm-test・tsc
	$(UI) npm run check

ui-contract: ## 実際の CMS に document を投げて通るか（CMS を上げてから）
	$(UI) npm run contract

ui-smoke: ## ブラウザで画面を触る（CMS と make ui-dev を上げてから）
	$(UI) npm run smoke

ui-audit: ## 各機能が仕様どおり動くかを一通り触って確かめる
	$(UI) npm run audit

ui-verify: ## ui-check + ui-contract + ui-smoke
	$(UI) npm run verify

ui-build: ## admin-ui/dist を作る
	$(UI) npm run build

ui-no-dev-headers: ## 本番のビルドに dev のヘッダが混ざっていないか（CI）
	@! grep -ril "x-dev" admin-ui/dist || (echo "dist に dev のヘッダが残っています"; exit 1)
	@echo "dist に dev のヘッダ無し"

.PHONY: ui-install ui-gen ui-gen-check ui-dev ui-check ui-contract ui-smoke ui-audit ui-verify ui-build ui-no-dev-headers
