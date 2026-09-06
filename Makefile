.PHONY: run check test test-unit test-pg db-up db-down query generate scaffold gen gen-check migrate migrate-status migrate-new

# 実 PG 用の接続。docker-compose.yml と同じ値。run と test-pg の両方で使う
PG_ENV = CMS_DSN=jdbc:postgresql://127.0.0.1:5432/cms CMS_DB_USER=cms CMS_DB_PASSWORD=cms

# サーバ起動。PG は make db-up で立てておく
run:
	$(PG_ENV) bin/flix run

check:
	bin/flix check
	cd schemagen && ../bin/flix check

# 既定は DB 無しのテスト
test: test-unit

# DB 無しのテスト。build/unit/ に test/Pg を除いた写しを作って回す（元のファイルには触らない）。
# WhyNot: test/Pg/ を test/ の外に置かないのは、VSCode の Flix 拡張が src/ と test/ しか LSP に渡さないため。
UNIT_DIR = build/unit

test-unit:
	mkdir -p $(UNIT_DIR)
	cp flix.toml $(UNIT_DIR)/flix.toml
	cp schema.graphql admin.graphql $(UNIT_DIR)/
	ln -sfn $(CURDIR)/migrations $(UNIT_DIR)/migrations
	rsync -a --delete src/ $(UNIT_DIR)/src/
	rsync -a --delete --exclude Pg test/ $(UNIT_DIR)/test/
	cd $(UNIT_DIR) && $(CURDIR)/bin/flix test
	cd schemagen && ../bin/flix test

# 実 PostgreSQL に当たるテスト。コンテナを立て、test/ を全部（test/Pg/ 込み）回し、終わったら止める
test-pg:
	docker compose up -d --wait
	$(PG_ENV) bin/flix test; status=$$?; docker compose down -v; exit $$status

db-up:
	docker compose up -d --wait

db-down:
	docker compose down -v

# SDL から src/generated/ を作り直す。schema.graphql → Generated、admin.graphql → GeneratedAdmin
generate:
	cd schemagen && ../bin/flix run
	cd schemagen && SCHEMAGEN_SDL=../admin.graphql SCHEMAGEN_MODULE=GeneratedAdmin ../bin/flix run

# ---- sqlfx（生成器と migrate は flix_db 側の main で動かす。.fpkg には入っていない）----
FLIX_DB = $(HOME)/Desktop/flix_db

# migrations/ と queries/*.q から src/generated/sql/ を作り直す
gen:
	cd $(FLIX_DB) && bin/flix run -- gen $(CURDIR)/migrations $(CURDIR)/queries $(CURDIR)/src/generated/sql

# 生成物が最新か（書かない。CI 用）
gen-check:
	cd $(FLIX_DB) && bin/flix run -- gen --check $(CURDIR)/migrations $(CURDIR)/queries $(CURDIR)/src/generated/sql

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

# 起動中のサーバへサンプルのクエリと mutation を投げる
query:
	curl -s localhost:8080/health
	@echo
	curl -s -X POST localhost:8080/graphql -H 'Content-Type: application/json' \
		-d '{"query": "{ add(a: 1, b: 2) fibonacci(n: 10) post(id: \"p1\") { title author { name } } }"}'
	@echo
	curl -s -X POST localhost:8080/graphql -H 'Content-Type: application/json' \
		-d '{"query": "mutation { increment(by: 1) }"}'
	@echo
