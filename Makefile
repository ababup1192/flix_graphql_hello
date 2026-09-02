.PHONY: run check test query

run:
	bin/flix run

check:
	bin/flix check

test:
	bin/flix test

# 起動中のサーバへサンプルのクエリと mutation を投げる
query:
	curl -s -X POST localhost:8080/graphql -H 'Content-Type: application/json' \
		-d '{"query": "{ add(a: 1, b: 2) fibonacci(n: 10) }"}'
	@echo
	curl -s -X POST localhost:8080/graphql -H 'Content-Type: application/json' \
		-d '{"query": "mutation { increment(by: 1) }"}'
	@echo
