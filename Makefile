.PHONY: run check test test-unit test-pg import-microcms db-up db-down query generate scaffold gen gen-check migrate migrate-status migrate-new fatjar image

# 実 PG と MinIO 用の接続。docker-compose.yml と同じ値。run と test-pg の両方で使う
PG_ENV = CMS_DSN=jdbc:postgresql://127.0.0.1:5432/cms CMS_DB_USER=cms CMS_DB_PASSWORD=cms \
	ASSET_ENDPOINT=http://127.0.0.1:9000 ASSET_BUCKET=cms ASSET_ACCESS_KEY=cms ASSET_SECRET_KEY=cms-secret \
	ASSET_REGION=us-east-1 ASSET_PUBLIC_URL=http://127.0.0.1:9000/cms \
	CMS_AUTH=dev CMS_BOOTSTRAP_OWNER=dev@localhost CMS_API_KEY_PEPPER=dev-pepper

# サーバ起動。PG は make db-up で立てておく
run:
	$(PG_ENV) bin/flix run

# microCMS の API スキーマ（import/microcms/schema/*.json）を既定プロジェクトに写し、ダミーの entry を積んで公開する。PG は make db-up で
import-microcms:
	$(PG_ENV) CMS_MODE=import-microcms CMS_IMPORT_DIR=import/microcms/schema bin/flix run

check:
	bin/flix check
	cd schemagen && ../bin/flix check
	scripts/check-cmserr.sh
	scripts/check-tx.sh
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

# 実 PostgreSQL と MinIO に当たるテスト。コンテナを立て、test/ を全部（test/Pg/ 込み）回し、終わったら止める
test-pg:
	$(COMPOSE_UP)
	$(PG_ENV) bin/flix test; status=$$?; docker compose down -v; exit $$status

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
MIGRATE_ENV = SQLFX_DSN=jdbc:postgresql://127.0.0.1:5432/cms SQLFX_USER=cms SQLFX_PASSWORD=cms

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
