# ロードマップ（2026-09-07 時点）

目標は 2 段。**(A) 今月中に自社の 2 サイト（Consumer / Business）が microCMS 無しで回る。(B) その後、他社に出せる。**
見積もりは「この進め方（Claude が書き、人が仕様と優先順位を決める）での作業時間」。暦の上では実データの検証や外部設定の待ちが加わる。

## 済み

管理 API / コンテンツ API（動的スキーマ、where / orderBy、参照、OBJECT / BLOCKS）、公開・版・一意（advisory lock）、
テナント、asset（S3 互換、署名付き URL）、richText（doc / html / text / 目次 / 抜粋 / 埋め込み / 表 / callout）、
Docker（起動時 migration、JSON ログ、/health の版）、deploy/ の compose。

HTTP サーバの同時接続の上限（`CMS_MAX_CONNECTIONS`。超えたら 503 + `Retry-After`。`/health` の `connections`）と keep-alive（HTTP/1.1、1 接続 100 回、idle 15 秒、エラー応答の後は閉じる）は 2026-09-08 に実装済み。`spawn` は virtual thread なので接続ごとのスレッドは platform thread を食わない。

ルーティングの表化（2026-09-08 に実装済み）: `Router`（純粋。`find` / `describe` / `withProjectPrefix`）と `Server.routes` の表、middleware（`Cors.wrap` / `Credentials.wrap` / `Server.wrapProjectFromHost`）。404 / 405 / 503 にも CORS が付き、preflight の `Allow-Methods` は表から、`Allow-Headers` に `X-Api-Key` / `X-Preview-Token`。`/mcp` と `/api/…` は表に 1 行足すだけ。

エラーの分類（2026-09-08 に実装済み）: `errors[].extensions.code`（`INVALID` / `NOT_FOUND` / `FORBIDDEN` / `CONFLICT` / `REQUIRES_LOGIN` / `UNAUTHENTICATED` / `INTERNAL`）と `violations` / `entity` / `id` / `expectedVersion` / `actualVersion`。message は日本語のままで、クライアント・CLI・MCP は code で分岐する（[error-codes.md](error-codes.md)）。

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
| 5 | プレビュートークン（2026-09-07 に実装済み）| 編集者 | 済み | `createPreviewToken(entryId)` → `pv_...`（無状態、HMAC 署名、既定 1 時間・最長 1 日）。`X-Preview-Token` でコンテンツ API のその entry（と参照先）の下書きだけ読める。一覧の下書きと他の entry は不可。`previewUrl` から url を組む |
| 6 | 予約公開・公開停止予約（2026-09-07 に実装済み）| 編集者 | 済み | `schedulePublish` / `scheduleUnpublish` / `cancelSchedule` / `schedules`。outbox（scheduled_actions）をプロセス内のバックグラウンドワーカー（BackgroundJobs。Webhook と同じ tick）が拾い、通常の publish と同じ検査で実行。失敗は FAILED に理由。実行中に落ちた行は 10 分で回復、記録は 30 日で掃除。外部トリガー `POST /jobs/tick`（`CMS_JOBS_TOKEN`）、`CMS_JOBS=off`、`/health` の `jobs.lastTickAt` |
| 7 | GraphQL の GET 対応（2026-09-07 に実装済み）| サイト運営者 | 済み | `GET /graphql?query=&variables=&operationName=`。mutation は 405。身元無しで errors が無ければ `Cache-Control: public, max-age / s-maxage / stale-while-revalidate`（`CMS_CACHE_MAX_AGE`。既定 60 秒）、鍵やトークン付きは `private, no-store`。`Vary: X-Api-Key, X-Preview-Token, Authorization` |
| 8 | microCMS 移行ツール（2026-09-07 にスキーマの写しとダミー投入を実装。実データの変換は**やらない**）| 自社 | 済み（残りは背負わない） | `make import-microcms` が API スキーマの export（import/microcms/schema）を型に写し、ダミーの entry を作って公開する。実物の 9 API で通した。実データ（HTML → doc、画像の取り直し）は 2026-09-08 に「うちで背負わない」と決めた: 入口（管理 API / Markdown / MCP）が揃っていれば AI と利用者が移せるし、変換規則は人ごとに違って責任を持ちきれない。microCMS 以外から来る人にも同じ入口で通じる。分かった事: エンドポイント名は複数形とは限らない（plural を `<apiId>List` に）、custom field と同名の子がある（子に Value を付ける） |
| 8b | DATE と複数選択の SELECT（2026-09-07 に実装済み）| 自社 | 済み | microCMS の date / 複数選択を写すための kind。DATE は ISO 8601 の文字列（日付だけは UTC の 0 時に揃える）で、コンテンツ API に `_eq` / `_gt` / `_gte` / `_lt` / `_lte`（timestamptz で比較）と `_ASC` / `_DESC`。SELECT は `many: true` で選択肢の配列になり、`[Enum!]!` と `_contains` |
| 9 | 管理画面（Elm、別リポジトリ） | 編集者 | 1〜2 日 + 目で見る往復 | ログイン、プロジェクト切り替え、型の編集、entry の一覧・編集、TipTap、画像、公開、プレビュー、dry-run と impact の表示。API の試し打ち（GraphiQL の埋め込み。ログイン済みの JWT で叩く。エンドポイントには同梱しない。introspection と CORS は既にある） |
| 10 | 公開サイトの載せ替え | 自社 | 半日 | elm-pages を GraphQL に。`headings` で目次、`html` で本文。Cloudflare Pages の再ビルドは Webhook |

ここまでで **(A) 達成**。microCMS を解約できる。

### 入れたい: 差別化になる（他社に出す前に）

| # | 機能 | 誰に | 時間 | 中身 |
|---|---|---|---|---|
| 11 | 公開計画（まとめて dry-run、一括公開。2026-09-08 に実装済み） | 編集者 | 済み | `publishPlan(ids, withDependencies)` が entry ごとの `publishReport` を参照先が先の順（`steps`。REQUESTED / DEPENDENCY）に並べ、`publishMany(ids, withDependencies)` が同じ順で 1 つの mutation（1 つの Tx）で全部公開する。1 つでも通らなければ何も公開せず INVALID（path は `b1.fields.title` のように entry id 付き）。順は純粋な `PublishOrder`（深さ優先の後順。循環と、`withDependencies: false` の計画の外の参照先は計画の違反）。**microCMS には無い**。予約の Release `schedulePublishMany(ids, at)` は作らない（2026-09-09。1 件ずつの予約のまま tick 側をチャンク化した: 100 件の claim を 1 回の tick が 10 秒に達するまで繰り返す。`Scheduler.canClaimMore`、CMS_SCHEDULER_CHUNK_SIZE / CMS_SCHEDULER_TICK_BUDGET_SECONDS）。実測（手元の docker の PG、fat jar）: 同じ時刻の 1000 件が 1 tick・10 チャンクで run_at から 4.7 秒で全部 done（tick が来るまで 1.3 秒 + 実行 3.4 秒、100 件あたり約 0.33 秒）。以前は 20 件 / 2 秒で末尾が 100 秒後だった |
| 12 | 公開の巻き戻し（`revertPublish`）と時点指定の読み出し（`at`） | 編集者・監査 | 1.5 日 | 版から 1 Tx で戻す。コンテンツ API に `at` を足す。**microCMS には無い** |
| 13 | 型の export / apply | 開発者 | 半日 | SDL に寄せた書式で往復。差分の計画、削除の保護、`@renamedFrom` |
| 14 | codegen の手順と CI の雛形 | 開発者 | 1 日 | elm-graphql / graphql-codegen に委ねる。Webhook で PR を開く |
| 15 | entry のバージョン間の差分（`Entry.diff(from, to)`） | 編集者・エージェント | 1 日 | 純粋な `EntryDiff`（kind ごとに等値、OBJECT は再帰、many と BLOCKS は位置、richText は Markdown の行差分）。MCP の `diff_entry` と管理画面の履歴が使う。Markdown 変換の直後にテストファーストで |
| 15a | richText の doc に本文の穴を塞ぐ node（gallery / image の alt / linkCard / codeBlock の fileName と highlightLines） | 編集者 | 半日 | microCMS でカスタムフィールドに追い出されている物を本文の中に持てるようにする。バックエンドは doc の形・validate・HTML・Markdown の方言まで。エディタは管理画面で。脚注は後 |
| 15b | richText の doc の第 2 弾（数式 / Mermaid / タスクリスト / 動画） | 編集者 | 半日 | 15a と同じ型。動画は AssetRules に mime ごとの上限。entryEmbed（本文に別の entry）は参照展開が絡むので差分と MCP の後に単独で |
| 16 | 画像の `usedBy`（済み）、pending の掃除 cron、asset の先読み | 編集者・運用 | 半日 | 既存の query を出すだけ + 孤児の削除 |
| 16a | 一覧の N+1 を先読みで塞ぐ（2026-09-08 に実装済み） | 運用 | 済み | 管理 API の `entries` の行の versions / diff をリクエスト単位の写し（`Preloaded`。Context の `preload`）からまとめて引く。JWT の一覧 50 件 × 10 フィールドが 209 → 12 本、API キーで 204 → 7 本。コンテンツ API の参照先は `Entry.linked` の先読みが既にあり 5 本。上限は `TestQueryBudgetPg`。Tx の数は同日に「読むだけの文書は 1 リクエスト 1 Tx」で 504 → 2。残り: コンテンツ API の 2 段目以降の参照、diff の PUBLISHED 側。java-dataloader で `Preloaded` を置き換える案は調査済み（同じスレッドの前提は崩れず、Schema の DSL を future 対応にする 1〜2 日）だが、実際の query で 2 段以上の参照が出て SQL が 20 本を超えるまでやらない |
| 16c | 一覧の cursor（keyset）ページネーション（2026-09-09 に実装済み） | サイト運営者・エージェント | 済み | コンテンツ API の `<plural>` と管理 API の `entries` / `assets` に `after`、`pageInfo { hasNextPage endCursor }` と `edges { cursor node }`（GitHub の形。`first` / `skip` / `totalCount` はそのまま）。管理 API の `entries` に `where` / `orderBy`。`webhookDeliveries` / `schedules` は id（ULID）が cursor。MCP の `search_entries` は `after` と `next_cursor`。cursor は orderBy のキーの値 + id の base64url で、orderBy と対（不一致は INVALID）、`after` と `skip` の同時指定も INVALID。migration は無し（既存の索引に乗る）。決めた事は [pagination.md](pagination.md) |
| 16d | 集計（`<plural>Aggregate`: count と SELECT / REFERENCE / BOOLEAN / DATE（年月）の groupBy。where は EntryFilterSql を再利用） | 編集者 | 1 日 | #9 の管理画面で内訳が要る時に入れる。**microCMS には無い** |
| 16b | 公開側を CDN に乗せる（2026-09-08 に実装済み） | サイト運営者 | 済み | プロジェクトの版（`projects.content_version`。公開・取り下げ・削除・型の変更で進む）を weak な `ETag` に入れ、`If-None-Match` が合えば 304（SQL は版の 1 本）。`Cache-Control` は `s-maxage=10, max-age=0, stale-while-revalidate=60` が既定。purge は任意（`CMS_CDN_PURGE_URL` / `CMS_CDN_PURGE_TOKEN`。outbox `cdn_purges` を tick が送る）。deploy/ に Caddy と Cloudflare の cache rule の見本。決めた事は [cdn.md](cdn.md)。残り（他社の利用者が付いてから、各半日以下）: DB 障害時の匿名 GET を 503 + `stale-if-error` にして CDN が古い物を返し続ける、200 の ETag をリクエスト Tx の版で組んで窓を消す |
| 17 | 課金（Stripe）と組織の上限 | サービス | 1〜2 日 | [hosting-and-externalized-risk.md](hosting-and-externalized-risk.md) |
| 18 | 監査ログ | 企業 | 半日 | `Actor` が入れば mutation の入口 1 か所 |
| 19 | 編集中の表示（在席） | 編集者 | 半日 | 楽観ロックは済み。誰が開いているかを出す |
| 20 | AI 補助（alt / 抜粋 / 見出し） | 編集者 | 半日 | `Assistant` effect。セルフホストでは無効化できる |

### 後回し: 並ぶための物、または規模が要る物

| # | 機能 | 時間 | 備考 |
|---|---|---|---|
| 21 | 多言語（locale） | 1 日 | `localized` フラグは済み。値の持ち方と `locale` 引数 |
| 22 | API キーの write（役割付き・期限・最終使用時刻）と Personal Access Token（2026-09-07 に実装済み） | 済み | `createApiKey(scope: WRITE, role, expiresAt)` で CI から管理 API を叩ける（メンバー・鍵・プロジェクトの管理は不可）。`createPersonalAccessToken` → `Authorization: Bearer cmspat_...` で本人として叩く（READ は読むだけ、既定 90 日・最長 365 日）。[auth-and-organizations.md](auth-and-organizations.md) |
| 22a | レビュー・承認ワークフロー | 1 日 | 役割が入ってから |
| 22b | 属性ベースの権限（記事のグルーピング: 「このタグの記事だけこのユーザー / キーに」） | 1 日 | `access_rules(project_id, subject, field, allowed_values)` を足し、Datalog の事実と `Authz.readFilter` の SQL 条件で。参照展開と impact にも通す |
| 23 | 読み取り REST + OpenAPI | 半日 + 1 時間 | [read-only-rest.md](read-only-rest.md) |
| 24 | MCP サーバ（AI エージェントから読み書き。2026-09-08 に v1 を実装済み） | 済み | `POST /mcp`。legacy（MCP 2025-06-18 の形。initialize の握手、セッション無し、tools だけ）を喋る。12 のツール（list_types / get_type / search_entries / get_entry / diff_entry / create_entry / update_entry / publish_check / impact / publish / unpublish / preview_url）を admin.graphql に写す GraphQL クライアント。業務エラーは全部 `isError` の content に `extensions` をそのまま。modern（2026-07-28。server/discover、ヘッダ照合）と、主体が呼べるツールだけを出す tools/list は v2。手順は `deploy/README.md` |
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

### 決めた事（2026-09-08、MCP のレビューから）

- MCP v1 は legacy（2025-06-18 の形。initialize 握手、セッション無し）を喋る。modern（2026-07-28。server/discover、ヘッダ照合）は v2。実機の `claude mcp add` が legacy に落ちて来る事が v1 の合否条件
- MCP は admin engine への GraphQL クライアント。ユースケースを直に呼ばない（管理 API と同じ形を 2 度書かないため。権限は証明 `Granted[p]` を引数で受けるので素通りはできない）
- upload_asset（confirm が無いと pending のまま）と schedule（cancel と list を対にしないと事故）は v1 に入れない
- Session を持たない pub のユースケース関数（ContentEntries.get / ContentTypes.get / getField / versionData）は「呼べば漏れる」ので、MCP の後に private 化して pub の入口を Session 付きに揃える（済み。その後 2026-09-08 に pub の入口を権限の証明 `Granted[p]` を引数で受ける形にし、check-session.sh と allowlist は廃止）
