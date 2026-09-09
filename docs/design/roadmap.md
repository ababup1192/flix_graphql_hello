# ロードマップ（2026-09-09 更新）

目標は 2 段。**(A) 今月中に自社の 2 サイト（Consumer / Business）が microCMS 無しで回る。(B) その後、他社に出せる。**
見積もりは「この進め方（Claude が書き、人が仕様と優先順位を決める）での作業時間」。暦の上では実データの検証や外部設定の待ちが加わる。

見積もりの係数: **テストで殴れる物（純粋・入出力が決まる）は表の通り、目で見る往復が要る物（管理画面・UI）は数倍を見る。**

## (A) の残り

| # | 機能 | 誰に | 時間 | 中身 |
|---|---|---|---|---|
| 9 | 管理画面（Elm、`admin-ui/`） | 編集者 | 目で見る往復が律速 | ログイン、プロジェクト切り替え、型の編集、entry の一覧・編集、TipTap、画像、公開、プレビュー、dry-run と impact の表示。API の試し打ち（GraphiQL の埋め込み。ログイン済みの JWT で叩く。エンドポイントには同梱しない。introspection と CORS は既にある）。仕様は [admin-ui-spec.md](admin-ui-spec.md)、段取りは [admin-ui-phases.md](admin-ui-phases.md) |
| 10 | 公開サイトの載せ替え | 自社 | 半日 | elm-pages を GraphQL に。`headings` で目次、`html` で本文。Cloudflare Pages の再ビルドは Webhook |

ここまでで **(A) 達成**。microCMS を解約できる。

## (B) 入れたい: 差別化になる

| # | 機能 | 誰に | 時間 | 中身 |
|---|---|---|---|---|
| 12 | 公開の巻き戻し（`revertPublish`）と時点指定の読み出し（`at`） | 編集者・監査 | 1.5 日 | 版から 1 Tx で戻す。コンテンツ API に `at` を足す。**microCMS には無い** |
| 13 | 型の export / apply | 開発者 | 半日 | SDL に寄せた書式で往復。差分の計画、削除の保護、`@renamedFrom` |
| 14 | codegen の手順と CI の雛形 | 開発者 | 1 日 | elm-graphql / graphql-codegen に委ねる。Webhook で PR を開く |
| 15a | richText の doc に本文の穴を塞ぐ node（gallery / image の alt / linkCard / codeBlock の fileName と highlightLines） | 編集者 | 半日 | microCMS でカスタムフィールドに追い出されている物を本文の中に持てるようにする。バックエンドは doc の形・validate・HTML・Markdown の方言まで。エディタは管理画面で。脚注は後 |
| 15b | richText の doc の第 2 弾（数式 / Mermaid / タスクリスト / 動画） | 編集者 | 半日 | 15a と同じ型。動画は AssetRules に mime ごとの上限。entryEmbed（本文に別の entry）は参照展開が絡むので単独で |
| 16 | pending の asset の掃除 cron、asset の先読み | 編集者・運用 | 半日 | 既存の query を出すだけ + 孤児の削除。`usedBy` は済み |
| 16d | 集計（`<plural>Aggregate`: count と SELECT / REFERENCE / BOOLEAN / DATE（年月）の groupBy。where は EntryFilterSql を再利用） | 編集者 | 1 日 | #9 の管理画面で内訳が要る時に入れる。**microCMS には無い** |
| 17 | 課金（Stripe）と組織の上限 | サービス | 1〜2 日 | [hosting-and-externalized-risk.md](hosting-and-externalized-risk.md) |
| 18 | 監査ログ | 企業 | 半日 | mutation の入口 1 か所。4 つ目の消費者になるので、Publishing の表を events の 1 表 + consumer に作り直す判断も一緒に（[cdn.md](cdn.md)） |
| 19 | 編集中の表示（在席） | 編集者 | 半日 | 楽観ロックは済み。誰が開いているかを出す |
| 20 | AI 補助（alt / 抜粋 / 見出し） | 編集者 | 半日 | `Assistant` effect。セルフホストでは無効化できる |

## 後回し: 並ぶための物、または規模が要る物

| # | 機能 | 時間 | 備考 |
|---|---|---|---|
| 21 | 多言語（locale） | 1 日 | `localized` フラグは済み。値の持ち方と `locale` 引数 |
| 22a | レビュー・承認ワークフロー | 1 日 | プロジェクトごとの status（[admin-ui-spec.md](admin-ui-spec.md) の決め） |
| 22b | 属性ベースの権限（記事のグルーピング: 「このタグの記事だけこのユーザー / キーに」） | 1 日 | `access_rules(project_id, subject, field, allowed_values)` を足し、Datalog の事実と `Authz.readFilter` の SQL 条件で。参照展開と impact にも通す |
| 23 | 読み取り REST + OpenAPI | 半日 + 1 時間 | [read-only-rest.md](read-only-rest.md) |
| 24 | MCP v2 | 半日 | modern（2026-07-28。server/discover、ヘッダ照合）と、主体が呼べるツールだけを出す tools/list。upload_asset と schedule もここで（v1 に入れなかったのは confirm と cancel の対が要るため） |
| 25 | 画像変換（srcset） | 半日 | Cloudflare Images に委ねる。セルフホストは imgproxy |
| 26 | entry id をプロジェクトごとに、読み取りレプリカ | 2〜3 日 | 段階 3 |
| 27 | persisted query、`QUERY` メソッド | 半日 | 普及を待つ |

### 発火条件付きで保留

- **java-dataloader で `Preloaded` を置き換える**（1〜2 日。調査済みで、同じスレッドの前提は崩れず Schema の DSL を future 対応にする）→ **実際の query で 2 段以上の参照が出て SQL が 20 本を超えたら**。上限は `TestQueryBudgetPg` が見張る
- **CDN の詰め（各半日以下）**: DB 障害時の匿名 GET を 503 + `stale-if-error` にして CDN が古い物を返し続ける、200 の ETag をリクエスト Tx の版で組んで窓を消す → **他社の利用者が付いてから**

## 実験で見つかって未対応の物（2026-09-08 の障害注入と MCP の試用から）

生ログは畳んだ（[trials/](trials/)）。ここが追う先。

| 見つけた物 | 誰に | 時間 | 直す所 |
|---|---|---|---|
| **存在しない entry id を REFERENCE に入れても create / update が通る**。存在確認が `publish_check` まで遅れる | 編集者 | 半日 | 今は意図的（`EntryValidation` は DB を見ない純粋な規則で、参照先は publish が見る）。書いた時に気付ける方が良いなら、ユースケース側で存在を引く |

### 直した物（2026-09-09）

| 見つけた物 | どう直したか |
|---|---|
| 接続の漏れが自己回復と `/health` に映らない | `Health.saturation` で使用中の割合が 9 割以上なら `status: degraded`（200 のまま。503 にするとロードバランサから外れて事態が悪くなる）。`/health` の行は reason が付いていれば Warn にして、既定の `info` でも出るようにした（Debug のままだと誰にも届かない） |
| DB の失敗が HTTP 200 で返る | 5xx にはしない（GraphQL のクライアントが壊れる）。リクエストの行にスカラーの `error.code = "INTERNAL"` を積んで率のアラートを書けるようにした（`graphql.error_codes` は配列で Loki の json が展開してしまう）。severity は上げない（プール枯渇で 1 分に数百行出て本当に見る行が埋もれる） |
| job の行に再試行の情報が無い | `JobLog.retryFields` で `job.attempts` と `job.retry_delay_seconds`（次の時刻は SQL 側が決めるので秒数で出す）。予約公開は再試行しないので付かない。合わせて `BackgroundJobs.round` に `job.tick.duration_ms` を足し、15 秒（`/health` が止まったと見なす 30 秒の半分）を超えた周だけ `jobs tick slow` の Warn |
| MCP の `search_entries` にフィールド条件と並び替えが無い | `where` と `orderBy` を引数に。`ArgType` に `Arr` と `Any` を足して、配列と「op で型が決まる値」を JSON Schema に出せるようにした |
| MCP の `stage` 絞り込みがサーバ側でない | DRAFT はサーバ側で絞り切る。PUBLISHED / CHANGED は `where.stage = PUBLISHED`（SQL の上では CHANGED が公開中の部分集合）まで絞ってからページの中で分ける |
| MCP の `search_entries` が本文を全文返す | `body`（`full` / `excerpt`）を追加。**既定は `full` のまま**（切り詰めに気付かないエージェントが嘘の要約を出すため）で、description で一覧には `excerpt` を勧める。切った本文には末尾に「先頭 200 文字。全 N 文字」と印を置く |

MCP の asset・予約公開・主体ごとの tools/list は #24（MCP v2）、公開側の巻き戻しは #12 に入っている。

## やらない

- 書き込みの REST、microCMS 互換の `filters`
- gRPC / tRPC（動的スキーマと合わない）
- 自前の画像変換、自前の全文検索エンジン（PostgreSQL の範囲で）
- Kubernetes の Helm 等（セルフホストは compose まで）
- **microCMS の実データの変換**（HTML → doc、画像の取り直し）。2026-09-08 に決めた: 入口（管理 API / Markdown / MCP）が揃っていれば AI と利用者が移せるし、変換規則は人ごとに違って責任を持ちきれない。microCMS 以外から来る人にも同じ入口で通じる
- **予約の Release（`schedulePublishMany`）**。2026-09-09 に決めた: 1 件ずつの予約のまま tick 側をチャンク化した

## 差別化の言い方（表と一緒に使う）

- 上: 動的スキーマの GraphQL、richText の返し方（json / html / text / 目次 / 抜粋）、参照と asset の整合が構造的に壊れない、セルフホストと価格
- 編集者向けに新しく作る: 影響の見える化（`impact`）、公開計画（`publishPlan` / `publishMany`）、巻き戻しと時点指定（#12）。「壊れない・戻せる・押す前に分かる」
- 並ぶ: プレビュー、予約公開、差分、Webhook、権限、多言語
- 追いつかない: 管理画面の完成度、画像変換、日本語ドキュメント、ISMS

## 済み

機能の中身は SDL（`admin.graphql` / `account.graphql`）と [../architecture/](../architecture/) にあるので、ここには一覧だけ置く。

**API と機能** — 管理 API / コンテンツ API（動的スキーマ、where / orderBy / after、参照、OBJECT / BLOCKS）、公開・版・一意（advisory lock）、dry-run（`publishCheck`）、影響の見える化（`impact`）、公開計画（`publishPlan` / `publishMany`）、バージョン間の差分（`Entry.diff`）、テナント、asset（S3 互換、署名付き URL、`usedBy`）、richText（doc / html / text / 目次 / 抜粋 / 埋め込み / 表 / callout）と Markdown、DATE と複数選択の SELECT、GraphQL の GET 対応、MCP v1（12 ツール）、microCMS の API スキーマの取り込み。

**認証と権限** — 組織・メンバー・招待、JWT / JWKS、Authz の Datalog、権限の証明 `Granted[p]`、API キー（scope: WRITE + role、期限、last_used_at）、PAT、プレビュートークン、visibility、Host でプロジェクト slug、Account API。テナント分離の三重（Tenant effect / `make gen --scope project_id` / RLS）。

**運用** — Docker（起動時 migration、JSON ログ、/health の版）、deploy/ の compose、Webhook（outbox + 署名 + 再試行）、予約公開（outbox + チャンク化した tick）、CDN（`content_version` の weak ETag と 304、purge の outbox）、cursor ページネーション、ルート表と middleware、エラーの分類（`extensions.code`）、同時接続の上限と keep-alive、停止（Shutdown）と自己回復（SelfHeal）。

### 実測（作り直す時の判断材料）

- **予約公開**: 同じ時刻の 1000 件が 1 tick・10 チャンクで run_at から 4.7 秒で全部 done（tick が来るまで 1.3 秒 + 実行 3.4 秒、100 件あたり約 0.33 秒）。チャンク化の前は 20 件 / 2 秒で末尾が 100 秒後
- **一覧の N+1**: 管理 API の `entries` 50 件 × 10 フィールドが JWT で 209 → 12 本、API キーで 204 → 7 本。Tx は「読むだけの文書は 1 リクエスト 1 Tx」で 504 → 2
- **障害注入**: 復帰秒数と OOM / SIGTERM の挙動は [trials/](trials/)

### 分かった事

- microCMS のエンドポイント名は複数形とは限らない（plural を `<apiId>List` に）。custom field と同名の子がある（子に `Value` を付ける）
- MCP の実機（`claude mcp add`）は legacy（2025-06-18）に落ちて来る。これが v1 の合否条件だった
- MCP は admin engine への GraphQL クライアントにする（管理 API と同じ形を 2 度書かないため。権限は証明 `Granted[p]` を引数で受けるので素通りはできない）

## 関連

- 費用と段階: [hosting-and-externalized-risk.md](hosting-and-externalized-risk.md)
- 認証: [auth-and-organizations.md](auth-and-organizations.md)
- 開発者向け 4 機能の詳細: https://claude.ai/code/artifact/7708cad0-835e-4668-9750-e1e5bdfd33f6
