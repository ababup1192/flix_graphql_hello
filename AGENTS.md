# flix_graphql_hello

Flix から graphql-java（Java の GraphQL ライブラリ）を Java interop で叩けるか試す
最小プロジェクト。ゲームエンジン（flix_game_engine）の Flix のお約束だけを持ち込んでいる。

## 会話ポリシー

日本語で会話してください。途中報告なども含めて、日本語で回答してください。

単語は業界の言葉をそのまま使う（カタカナ・英語のまま。和語へ言い換えない・造語を作らない）。
説明は平易に書く。独自の比喩で名付けない。

## Flix のお約束

- **Flix を書く前・テストを書く前に `/flix-docs` を引く**（本文は `.claude/skills/flix-docs/SKILL.md`）
- **コンパイルエラーが出たら `/compile-fix`**（本文は `.claude/skills/compile-fix/SKILL.md`）
- 予約語・コメントの流儀・型の設計・二乗を書かない、の本文: [docs/flix-conventions.md](docs/flix-conventions.md)

## コーディングポリシー

コードには **How** / テストコードには **What** / コミットログには **Why** / コードコメントには **WhyNot**

特にコードコメントは WhyNot を重視し、How・What を書かない。実装の由来や旧実装などの歴史背景も書かない。

## ビルドと実行

Flix コンパイラは flix_game_engine の devbox が持つ jar を借りる（`bin/flix` が解決する）。
DB 層は sqlfx（github:ababup1192/sqlfx）を `flix.toml` の `[dependencies]` で取る。PostgreSQL は docker compose。

```bash
make check     # 型検査
make test      # DB 無しのテスト（test/Pg を除く）
make test-pg   # 実 PostgreSQL 込み（コンテナの起動と停止まで）
make db-up     # PostgreSQL を起動
make run       # サーバ起動（CMS_DSN 等は Makefile が渡す）
```

実 PG が要るテストは `test/Pg/` に置く。`make test` はそれを除いた写しを `build/unit/` に作って回す。
