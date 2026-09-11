# ロードマップ（2026-09-11 更新）

目標は 2 段。**(A) 今月中に自社の 2 サイト（Consumer / Business）が microCMS 無しで回る。(B) その後、他社に出せる。**
見積もりは「この進め方（Claude が書き、人が仕様と優先順位を決める）での作業時間」。暦の上では実データの検証や外部設定の待ちが加わる。

見積もりの係数: **テストで殴れる物（純粋・入出力が決まる）は表の通り、目で見る往復が要る物（管理画面・UI）は数倍を見る。**

## (A) の残り

| # | 機能 | 誰に | 時間 | 中身 |
|---|---|---|---|---|
| 9 | 管理画面（Elm、`admin-ui/`） | 編集者 | 目で見る往復が律速 | プロジェクト切り替え・型の編集（消す前・締める前の影響と見本、消したフィールドの復元）・entry の一覧とボード・⌘K・エディタ（TipTap。表の行列の入れ替え、上付き / 下付き / 蛍光ペン、チェックリスト、本文のリンクの行き先）・バージョン履歴と差分・メディア・メンバー・API キーと PAT（GitHub と同じ発行の形）・Webhook・監査ログ（絞り込み、CSV / JSON Lines、行の固定 URL）・API プレビュー・dry-run と impact の表示は入った（ログイン画面は Cloudflare Access が持つので作らない）。文言は 7.1 の表に揃え `wording-check.mjs` が見張り、反応は 7.2 の 4 つ（`Ui.Reply` / `Ui.Confirm` / Esc）。残りは **richText の編集部品の穴**（linkCard / 動画 / callout / details / embed は素通しで保持するだけ。note 風の書き心地は [richtext-note-style.md](richtext-note-style.md) で作業中）、**まとめて公開の導線**（`publishPlan` / `publishMany` / `deleteEntry` / `createPreviewToken` を画面から呼んでいない）、GraphiQL の埋め込み。ワークフローの画面は #22a 待ち。仕様は [admin-ui-spec.md](admin-ui-spec.md)、段取りは [admin-ui-phases.md](admin-ui-phases.md) |
| 10 | 公開サイトの載せ替え | 自社 | 半日 | elm-pages を GraphQL に。`headings` で目次、`html` で本文。Cloudflare Pages の再ビルドは Webhook |

ここまでで **(A) 達成**。microCMS を解約できる。

## (B) 入れたい: 差別化になる

| # | 機能 | 誰に | 時間 | 中身 |
|---|---|---|---|---|
| 12 | 公開の巻き戻し（`revertPublish`）と時点指定の読み出し（`at`） | 編集者・監査 | 1.5 日 | 版から 1 Tx で戻す。コンテンツ API に `at` を足す。**microCMS には無い** |
| 13 | 型の export / apply | 開発者 | 半日 | SDL に寄せた書式で往復。差分の計画、削除の保護、`@renamedFrom` |
| 14 | codegen の手順と CI の雛形 | 開発者 | 1 日 | elm-graphql / graphql-codegen に委ねる。Webhook で PR を開く。自社の admin-ui は `admin-ui.yml` が `ui-gen-check` で SDL とのずれを落としているので、要るのは**利用者向けの手順書と雛形** |
| 15c | richText の entryEmbed（本文に別の entry）と脚注 | 編集者 | 半日 | entryEmbed は参照展開と impact に通す必要があるので単独で。脚注は footnote mark（Markdown は `[^1]`） |
| 16 | pending の asset の掃除 cron、asset の先読み | 編集者・運用 | 半日 | 既存の query を出すだけ + 孤児の削除。`usedBy` は済み |
| 16d | 集計（`<plural>Aggregate`: count と SELECT / REFERENCE / BOOLEAN / DATE（年月）の groupBy。where は EntryFilterSql を再利用） | 編集者 | 1 日 | #9 の管理画面で内訳が要る時に入れる。**microCMS には無い** |
| 17 | 課金（Stripe）と組織の上限 | サービス | 1〜2 日 | [hosting-and-externalized-risk.md](hosting-and-externalized-risk.md) |
| 18 | 監査ログの残り | 企業 | 半日 | 表・記録・読み出し・画面・書き出しまで入った（下の「済み」と [audit-log.md](audit-log.md)）。残りは **組織レベル**（Account API の組織メンバー・プロジェクト作成・PAT。`Audit.record` が `Tenant` を要求するので project_id の持ち方を先に決める）、**MCP の actor 種別**（`actor_kind` に `mcp`。#24 と一緒に）、**変更前の姿から戻す口**（`detail.before` は残るが押して戻す mutation が無い）、予約公開の `scheduledBy`。全プランで出し、差は読める期間と持ち出しで付ける |
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

### 直した物（2026-09-11）

| 見つけた物 | どう直したか |
|---|---|
| `impact` と `publishCheck` が「壊れる物は無い」と答えたまま実際に壊れる（`entry_links.field_id` が `content_fields` への FK で、フィールドを消すと参照の索引ごと消え、同じ apiId で足し直しても戻らない） | 索引を `field_api_id` に変えて FK を外し、行が JSONB と一緒に動くようにした。「今もあるフィールドか」は読み取り時に `content_fields` と突き合わせる（`TestSchemaGuardPg`） |
| `entry_contents` に project_id が無く RLS の対象から漏れていた（条件を書き忘れた query 1 本で他のプロジェクトが読めた） | 列を足して RLS に入れ、`TestRlsPg` の対象を 8 表に。`TestTenantGuardPg` が見張る |
| AGENTS.md の「Session の handler は DbRunner だけ」「テナントは三重」「CmsErr は Tx の境界だけ」に強制力が無かった（mod の外から `run … with handler Tenant` や `Granted.Granted(Seal)` を書けば通る） | `scripts/check-handlers.sh` が allowlist（3 ファイル）と突き合わせる。`check-tx.sh` の正規表現も素通りしていた 8 通りの入口を塞いだ |

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

- 上: 動的スキーマの GraphQL、richText の返し方（json / html / text / 目次 / 抜粋 / links）、本文のリンクが最初から踏める href になる（型ごとの `linkPath`。Contentful と Sanity はサイト側に id → path の対応を書かせる）、参照と asset の整合が構造的に壊れない、セルフホストと価格
- 編集者向けに新しく作る: 影響の見える化（`impact`）、公開計画（`publishPlan` / `publishMany`）、**スキーマ変更の影響と確認した物だけ通す口**（`fieldImpact` / `expected`。Contentful が「間違えると壊滅的」と言う所を、押す前に件数と見本で見せ、Tx の中で数え直して止める）、巻き戻しと時点指定（#12）。「壊れない・戻せる・押す前に分かる」
- 企業向け: 監査ログ（append-only、主体の種類、変更前の姿、CSV / JSON Lines、書き出し自体も記録）。microCMS は Enterprise プランだけ
- 並ぶ: プレビュー、予約公開、差分、Webhook、権限、多言語
- 追いつかない: 管理画面の完成度、画像変換、日本語ドキュメント、ISMS

## 済み

機能の中身は SDL（`admin.graphql` / `account.graphql`）と [../architecture/](../architecture/) にあるので、ここには一覧だけ置く。

**API と機能** — 管理 API / コンテンツ API（動的スキーマ、where / orderBy / after、参照、OBJECT / BLOCKS）、公開・版・一意（advisory lock）、dry-run（`publishCheck`）、影響の見える化（`impact`）、公開計画（`publishPlan` / `publishMany`）、スキーマ変更の影響（`fieldImpact`。純粋な規則 `SchemaChange` + Tx の中の数え直し `SchemaGuard`。`expected` と食い違えば止める）、バージョン間の差分（`Entry.diff`）、テナント、asset（S3 互換、署名付き URL、`usedBy`、動画は mp4 / webm で上限 200 MB）、richText（doc / html / text / 目次 / 抜粋 / links / wordCount と readingTimeMinutes）と Markdown の双方向変換、DATE と複数選択の SELECT、GraphQL の GET 対応、MCP v1（15 ツール）、microCMS の API スキーマの取り込み、型のアイコン。

**richText の node** — 段落 / 見出し / リスト / タスク（listItem の checked）/ 引用 / codeBlock（language・fileName・highlightLines。language が mermaid なら `data-diagram`）/ 表（セルの寄せ。HTML は結合を落とさない）/ callout / details / gallery（columns 2〜4）/ image（alt・caption）/ video（poster）/ embed（YouTube・Vimeo・X）/ linkCard / 数式（`math` mark と `mathBlock`。TeX のまま持ち描画はサイト側）。mark は bold / italic / strike / underline / code / link / math / sub / sup / highlight。**型ごとのパスの形**（`ContentType.linkPath` の型紙 `/blog/{slug}`。`{id}` と `{slug}`）から `Entry.path` と本文の href を作る。

**監査ログ** — 表 `audit_events`（RLS で append-only、保持は無期限）、`Audit.record` を業務と同じ Tx で（型 / フィールド / メンバー / 招待 / API キー / Webhook / asset / 公開範囲 / entry の取り下げ・削除・予約公開の実行）、主体の種類と id（USER / API_KEY / PAT / SYSTEM）、消した物の変更前の姿（`detail.before`。Webhook の URL は host / pathHint / urlHash に落とし、asset のファイル名は入れない）、読み出し（`auditEvents` の actorKind / action 前方一致 / since / until、`auditEventsCount`。ULID の範囲で引く）、書き出し（`GET /admin/audit.csv` / `audit.jsonl`。上限 100,000 件、`audit.exported` を積む）、画面（プロジェクト設定 › 監査ログ。行を人の言葉で読める形に、行の固定 URL）。残りは #18。

**認証と権限** — 組織・メンバー・招待、JWT / JWKS、Authz の Datalog、権限の証明 `Granted[p]`、API キー（scope: WRITE + role、期限、last_used_at、末尾 4 文字の `keyHint`、生きている鍵の中で同名を断る）、PAT、プレビュートークン、visibility、Host でプロジェクト slug、Account API。テナント分離の三重（Tenant effect / `make gen --scope project_id` / RLS。`entry_contents` を含む 8 表）。決まりの機械の見張り（`check-tx.sh` / `check-handlers.sh` / `check-log-keys.sh`）。

**運用** — Docker（起動時 migration、JSON ログ、/health の版）、deploy/ の compose、Webhook（outbox + 署名 + 再試行）、予約公開（outbox + チャンク化した tick）、CDN（`content_version` の weak ETag と 304、purge の outbox）、cursor ページネーション、ルート表と middleware、エラーの分類（`extensions.code`）、同時接続の上限と keep-alive、停止（Shutdown）と自己回復（SelfHeal）。

### 実測（作り直す時の判断材料）

- **予約公開**: 同じ時刻の 1000 件が 1 tick・10 チャンクで run_at から 4.7 秒で全部 done（tick が来るまで 1.3 秒 + 実行 3.4 秒、100 件あたり約 0.33 秒）。チャンク化の前は 20 件 / 2 秒で末尾が 100 秒後
- **一覧の N+1**: 管理 API の `entries` 50 件 × 10 フィールドが JWT で 209 → 12 本、API キーで 204 → 7 本。Tx は「読むだけの文書は 1 リクエスト 1 Tx」で 504 → 2
- **障害注入**: 復帰秒数と OOM / SIGTERM の挙動は [trials/](trials/)

### 分かった事

- microCMS のエンドポイント名は複数形とは限らない（plural を `<apiId>List` に）。custom field と同名の子がある（子に `Value` を付ける）
- MCP の実機（`claude mcp add`）は legacy（2025-06-18）に落ちて来る。これが v1 の合否条件だった
- MCP は admin engine への GraphQL クライアントにする（管理 API と同じ形を 2 度書かないため。権限は証明 `Granted[p]` を引数で受けるので素通りはできない）。監査ログの書き出しも同じ道
- Flix は非 pub の enum も pub eff も他の mod から隠せない（2026-09-11 に実測）。「作れるのはこの mod の中だけ」は型では表せないので、`Granted` の組み立てと handler の置き場は allowlist の見張りで守る。effect のハンドラを `Db.guard` の catch の内側に置くと例外が網を素通りして接続が漏れるので、スキーマの守りも Tx の中で数え直す形にした

## 関連

- 費用と段階: [hosting-and-externalized-risk.md](hosting-and-externalized-risk.md)
- 認証: [auth-and-organizations.md](auth-and-organizations.md)
- 開発者向け 4 機能の詳細: https://claude.ai/code/artifact/7708cad0-835e-4668-9750-e1e5bdfd33f6
