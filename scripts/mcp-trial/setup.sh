#!/bin/sh
# MCP の使い倒し実験の準備: 型 2 つ（authors / posts）と鍵 2 つ（WRITE editor / READ_DRAFT）。サーバは起動済みの前提。
set -e
ADMIN=http://127.0.0.1:8080/admin/graphql
gql() { curl -s -X POST "$ADMIN" -H 'Content-Type: application/json' -H 'X-Dev-User: dev@localhost' -d "{\"query\":\"$1\"}"; echo; }

gql 'mutation { createContentType(input: { apiId: \"authors\", name: \"著者\" }) { id } }'
gql 'mutation { addField(typeId: \"1\", input: { apiId: \"name\", name: \"名前\", kind: TEXT, required: true }) { id } }'
gql 'mutation { addField(typeId: \"1\", input: { apiId: \"bio\", name: \"紹介\", kind: TEXT_AREA }) { id } }'

gql 'mutation { createContentType(input: { apiId: \"posts\", name: \"投稿\" }) { id } }'
gql 'mutation { addField(typeId: \"2\", input: { apiId: \"title\", name: \"題\", kind: TEXT, required: true }) { id } }'
gql 'mutation { addField(typeId: \"2\", input: { apiId: \"slug\", name: \"スラッグ\", kind: SLUG, required: true, unique: true, config: { sourceField: \"title\" } }) { id } }'
gql 'mutation { addField(typeId: \"2\", input: { apiId: \"summary\", name: \"要約\", kind: TEXT_AREA, required: true, config: { maxLength: 200 } }) { id } }'
gql 'mutation { addField(typeId: \"2\", input: { apiId: \"body\", name: \"本文\", kind: RICH_TEXT }) { id } }'
gql 'mutation { addField(typeId: \"2\", input: { apiId: \"tags\", name: \"タグ\", kind: SELECT, many: true, config: { options: [\"FLIX\", \"GRAPHQL\", \"CMS\", \"POSTGRES\"] } }) { id } }'
gql 'mutation { addField(typeId: \"2\", input: { apiId: \"publishedOn\", name: \"公開日\", kind: DATE }) { id } }'
gql 'mutation { addField(typeId: \"2\", input: { apiId: \"featured\", name: \"注目\", kind: BOOLEAN }) { id } }'
gql 'mutation { addField(typeId: \"2\", input: { apiId: \"author\", name: \"著者\", kind: REFERENCE, targetTypeId: \"1\" }) { id } }'

echo "--- keys"
gql 'mutation { createApiKey(name: \"editor\", scope: WRITE, role: EDITOR) { key } }'
gql 'mutation { createApiKey(name: \"reader\", scope: READ_DRAFT) { key } }'
