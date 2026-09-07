# ロードマップ（2026-09-07 時点）

目標は 2 段。**(A) 今月中に自社の 2 サイト（Consumer / Business）が microCMS 無しで回る。(B) その後、他社に出せる。**
見積もりは「この進め方（Claude が書き、人が仕様と優先順位を決める）での作業時間」。暦の上では実データの検証や外部設定の待ちが加わる。

## 済み

管理 API / コンテンツ API（動的スキーマ、where / orderBy、参照、OBJECT / BLOCKS）、公開・版・一意（advisory lock）、
テナント、asset（S3 互換、署名付き URL）、richText（doc / html / text / 目次 / 抜粋 / 埋め込み / 表 / callout）、
Docker（起動時 migration、JSON ログ、/health の版）、deploy/ の compose。

## 優先度順（上から着手）

### 必須: 無いと乗り換え候補にならない

| # | 機能 | 誰に | 時間 | 中身 |
|---|---|---|---|---|
| 1 | dry-run（`publishCheck`）済み 2026-09-07 | 編集者 | 2 時間 | 検査を `publishReport` に切り出し、required / unique / 参照 / asset の違反と未公開の参照先を全部一度に返す |
| 2 | 影響の見える化（`impact`）済み 2026-09-07。本文内のリンクも entry_links に載せた | 編集者 | 半日 | 取り下げ・削除で壊れる entry（フィールドの参照・本文内の `entryId` リンク・asset の使用先）と、一緒に動く物を返す。**microCMS には無い** |
| 3 | 認証・組織・権限（2026-09-07 に実装済み。表、Authz の Datalog、JWT / JWKS、Session effect で既定拒否、me / メンバー / 招待 / 鍵、visibility、Host でプロジェクト slug、Account API `/account/graphql`、`CMS_DEFAULT_PROJECT` / `CMS_SIGNUP`） | 全員 | 1〜2 時間 | [auth-and-organizations.md](auth-and-organizations.md)。`TokenVerifier`（JWKS。最初は Cloudflare Access）、`Actor` effect、memberships、`me`、Host で slug、API キー。`Authz.can(actor, permission, resource)` は最初から resource を受け、`Authz.readFilter(actor)` は空を返す（後の属性ベース権限のため） |
| 3b | テナント分離の三重化（2026-09-07 に実装済み）: RLS（中身の 6 表、Runner が Tx の先頭に印、`cms_app` ロール）と sqlfx `gen --scope project_id`（条件の無い query は生成失敗。書き忘れ 11 本を発見）。外向きの id は乱数の public_id | 全員 | 済み | [auth-and-organizations.md](auth-and-organizations.md) |
| 3c | auth の表（memberships / invitations / api_keys）の RLS（2026-09-07 に実装済み）。`Accounts.resolveUser` が `app.user_id` / `app.email` の印を置き、自分の行だけプロジェクトを跨いで見える | 全員 | 済み | migration 013、TestRlsPg |
| 4 | Webhook（2026-09-07 に実装済み）| サイト運営者 | 済み | outbox（公開などと同じ Tx に配信行を積み、dispatcher が別スレッドで POST）。`entry.published` / `entry.unpublished` / `entry.deleted` / `schema.changed`、`X-Cms-Signature`（HMAC-SHA256）、再試行 1 分 → 5 分 → 30 分 → 2 時間、管理 API で再送。配信 id は ULID |
| 5 | プレビュー トークン | 編集者 | 半日 | HMAC 署名、期限付き、参照先も下書きで辿れる。`previewUrl` と組み合わせ |
| 6 | 予約公開・公開停止予約 | 編集者 | 半日 | `publishAt` / `unpublishAt` と compose の cron サービス |
| 7 | GraphQL の GET 対応 | サイト運営者 | 1 時間 | `GET /graphql?query=` と `Cache-Control`。CDN に乗せる |
| 8 | microCMS 移行ツール | 自社 | 1 時間 + 実データの検証 | 型と entry と画像を読み、HTML → doc に変換して流し込む。実データで想定外を潰す時間が支配 |
| 9 | 管理画面（Elm、別リポジトリ） | 編集者 | 1〜2 日 + 目で見る往復 | ログイン、プロジェクト切り替え、型の編集、entry の一覧・編集、TipTap、画像、公開、プレビュー、dry-run と impact の表示 |
| 10 | 公開サイトの載せ替え | 自社 | 半日 | elm-pages を GraphQL に。`headings` で目次、`html` で本文。Cloudflare Pages の再ビルドは Webhook |

ここまでで **(A) 達成**。microCMS を解約できる。

### 入れたい: 差別化になる（他社に出す前に）

| # | 機能 | 誰に | 時間 | 中身 |
|---|---|---|---|---|
| 11 | 公開計画（まとめて dry-run、一括公開の `plan`） | 編集者 | 半日 | 複数件の `publishReport` と依存順。**microCMS には無い** |
| 12 | 公開の巻き戻し（`revertPublish`）と時点指定の読み出し（`at`） | 編集者・監査 | 1.5 日 | 版から 1 Tx で戻す。コンテンツ API に `at` を足す。**microCMS には無い** |
| 13 | 型の export / apply | 開発者 | 半日 | SDL に寄せた書式で往復。差分の計画、削除の保護、`@renamedFrom` |
| 14 | codegen の手順と CI の雛形 | 開発者 | 1 日 | elm-graphql / graphql-codegen に委ねる。Webhook で PR を開く |
| 15 | 版の差分（`diff`） | 編集者 | 1 日 | JSON の差分と、richText は平文の差分 |
| 16 | 画像の `usedBy`（済み）、pending の掃除 cron、asset の先読み | 編集者・運用 | 半日 | 既存の query を出すだけ + 孤児の削除 |
| 17 | 課金（Stripe）と組織の上限 | サービス | 1〜2 日 | [hosting-and-externalized-risk.md](hosting-and-externalized-risk.md) |
| 18 | 監査ログ | 企業 | 半日 | `Actor` が入れば mutation の入口 1 か所 |
| 19 | 編集中の表示（在席） | 編集者 | 半日 | 楽観ロックは済み。誰が開いているかを出す |
| 20 | AI 補助（alt / 抜粋 / 見出し） | 編集者 | 半日 | `Assistant` effect。セルフホストでは無効化できる |

### 後回し: 並ぶための物、または規模が要る物

| # | 機能 | 時間 | 備考 |
|---|---|---|---|
| 21 | 多言語（locale） | 1 日 | `localized` フラグは済み。値の持ち方と `locale` 引数 |
| 22 | レビュー・承認ワークフロー | 1 日 | 役割が入ってから |
| 22b | 属性ベースの権限（記事のグルーピング: 「このタグの記事だけこのユーザー / キーに」） | 1 日 | `access_rules(project_id, subject, field, allowed_values)` を足し、Datalog の事実と `Authz.readFilter` の SQL 条件で。参照展開と impact にも通す |
| 23 | 読み取り REST + OpenAPI | 半日 + 1 時間 | [read-only-rest.md](read-only-rest.md) |
| 24 | MCP サーバ（AI エージェントから読み書き） | 半日 | 管理 API を tool に写す |
| 25 | 画像変換（srcset） | 半日 | Cloudflare Images に委ねる。セルフホストは imgproxy |
| 26 | entry id をプロジェクトごとに、RLS、読み取りレプリカ | 2〜3 日 | 段階 3 |
| 27 | persisted query、`QUERY` メソッド | 半日 | 普及を待つ |

## やらない

- 書き込みの REST、microCMS 互換の `filters`
- gRPC / tRPC（動的スキーマと合わない）
- 自前の画像変換、自前の全文検索エンジン（PostgreSQL の範囲で）
- Kubernetes の Helm 等（セルフホストは compose まで）

## 差別化の言い方（表と一緒に使う）

- 上: 動的スキーマの GraphQL、richText の返し方（json / html / text / 目次 / 抜粋）、参照と asset の整合が構造的に壊れない、セルフホストと価格
- 編集者向けに新しく作る: 影響の見える化（#2）、公開計画（#11）、巻き戻しと時点指定（#12）。「壊れない・戻せる・押す前に分かる」
- 並ぶ: プレビュー、予約公開、差分、Webhook、権限、多言語
- 追いつかない: 管理画面の完成度、画像変換、日本語ドキュメント、ISMS

## 関連

- 費用と段階: [hosting-and-externalized-risk.md](hosting-and-externalized-risk.md)
- 認証: [auth-and-organizations.md](auth-and-organizations.md)
- 開発者向け 4 機能の詳細: https://claude.ai/code/artifact/7708cad0-835e-4668-9750-e1e5bdfd33f6
