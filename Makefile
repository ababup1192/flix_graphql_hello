.PHONY: run check test query generate

run:
	bin/flix run

check:
	bin/flix check
	cd schemagen && ../bin/flix check

test:
	bin/flix test
	cd schemagen && ../bin/flix test

# schema.graphql から src/generated/GeneratedSchema.flix を作り直す
generate:
	cd schemagen && ../bin/flix run

# 起動中のサーバへサンプルのクエリと mutation を投げる
query:
	curl -s -X POST localhost:8080/graphql -H 'Content-Type: application/json' \
		-d '{"query": "{ add(a: 1, b: 2) fibonacci(n: 10) post(id: \"p1\") { title author { name } } }"}'
	@echo
	curl -s -X POST localhost:8080/graphql -H 'Content-Type: application/json' \
		-d '{"query": "mutation { increment(by: 1) }"}'
	@echo
