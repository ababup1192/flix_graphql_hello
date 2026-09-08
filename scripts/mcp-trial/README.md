# MCP の使い倒し実験

別プロセスの Claude Code（`claude -p`）に MCP のツールだけで CMS を操作させ、足りない API と description の抜けを拾う。
テストでは見えない「仕様が使う側に伝わっているか」を見る物。結果は `docs/design/trials/` に日付で残す。

```bash
make db-up && make migrate && make run          # 別の端末で
sh scripts/mcp-trial/setup.sh                    # 型 2 つ（authors / posts）と鍵 2 つ。最後の 2 行が鍵
cat > /tmp/mcp-config.json <<EOF
{ "mcpServers": {
    "cms":        { "type": "http", "url": "http://127.0.0.1:8080/mcp", "headers": { "X-Api-Key": "<editor の鍵>" } },
    "cms-reader": { "type": "http", "url": "http://127.0.0.1:8080/mcp", "headers": { "X-Api-Key": "<reader の鍵>" } } } }
EOF
cd /tmp && claude -p --mcp-config mcp-config.json --strict-mcp-config \
  --allowedTools "mcp__cms__*,mcp__cms-reader__*,Write" --output-format text "$(cat <repo>/scripts/mcp-trial/prompt.txt)"
```

途中で `API Error: Output blocked by content filtering policy` で落ちたら、同じディレクトリで `claude -p --continue …` に「残りを続けて report.md を保存」と頼む。
終わったら `docker compose down -v` と鍵の設定ファイルの削除。
