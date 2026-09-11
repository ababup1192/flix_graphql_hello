# ドメイン（src/cms、テナント、型の決まり）

読むタイミング: `src/cms/` を触る時、型（FieldKind）や id の持ち方を変える時、テナントの境界に関わる時。

## src/cms/model/ — ドメインの型

Auth（UserId / OrgId / Role / Permission / Actor / ApiKeyScope / Visibility）、Webhook（WebhookEvent / DeliveryStatus / Webhook / WebhookDelivery）、Schedule（ScheduleAction / ScheduleStatus / Schedule）、Ulid（配信記録など時刻順の記録の id）、Ids（TypeId / FieldId / ApiId / TypeName）、ContentType（enum・レコード・Draft / Changes・FieldConfig）、Entry（EntryId / Stage / EntryData / IdGen / EntryPage / PageInfo）、Cursor（一覧の位置。orderBy のキーの値 + id を base64url にした不透明な文字列。`pageStart` が after と skip の同時指定と orderBy の不一致を invalid にする。[../design/pagination.md](../design/pagination.md)）、Asset（AssetId / AssetStatus / Upload）、Preloaded（リクエストの間だけ持つ先読みの写しの effect と `Store`。一覧のページの entry id・版・content type。写しはヒントで、無ければ 1 件ずつ引く）

## src/cms/rules/ — 純粋な規則

Authz（役割 → 権限の Datalog。`can` は resource も受ける。read の PAT は viewer に落ちる）、SecretHash（API キー・PAT・プレビュートークンの pepper 付き hash と寿命）、Naming（予約名・衝突・kind と config）、EntryValidation（下書きは緩く、公開は required まで）、EntryLinks（中身から参照を取り出す）、AssetRules（置いてよい mime と大きさ）、RichText（doc の検査・平文・HTML）、Markdown（richText の doc ↔ Markdown。方言は GFM + alerts / `{#id}` / `asset:` / `entry:`。自前のパーサで依存なし）、AssetRefs（中身から asset を取り出す）、EntryDiff（2 つのバージョンの中身の差分。kind ごとの比べ方、many は位置、OBJECT / BLOCKS は再帰、RICH_TEXT は Markdown の行差分 LCS。管理 API の `Entry.diff` の中身）、PublishOrder（複数の entry を公開する順。参照先が先の深さ優先の後順、要求した順は保つ、重複は 1 回。循環と計画の外の未公開の参照先は違反。`publishPlan` / `publishMany` の順を決める）

## src/cms/db/ — 行とドメインの値の変換

EntryRows / ContentTypeRows / AssetRows / AuthRows / WebhookRows / ScheduleRows と、絞り込みと cursor の続き（`afterClause`）の SQL 化（EntryFilterSql）。列名と JSONB の式を知るのはここだけ。

## src/generated/sql/ — sqlfx の生成物（触らない）

`*Queries` / `Tables`。`make gen` が migrations/ + queries/*.q から作る。

## src/cms/ — ユースケース

ContentTypes / ContentEntries / Projects / Assets / Accounts / Members / ApiKeys / PersonalTokens / Webhooks / PreviewTokens / Schedules。

Publishing は公開・取り下げ・削除・型の変更の副作用の Facade: ユースケースは `PublishingEvent` を 1 つ作って `Publishing.notify(event)` を同じ Tx で 1 回呼び、中が純粋な表 `Publishing.effectsOf(event)` の順に Webhooks.emit（配信行を積む outbox）と Projects.bumpContentVersion（プロジェクトの版 `content_version`。下書きの保存では進めない）を呼ぶ。ユースケースから emit / bump を直に呼ばない。監査ログは Publishing を通さず、ユースケースが `Audit.record` を業務と同じ Tx で直に呼ぶ（消費者が 1 つで Tx の中で終わるので events の 1 表 + consumer にはしない。`Audit.flix` の WhyNot、[../design/audit-log.md](../design/audit-log.md)）。検索索引が来たら作り直しを考える（[../design/cdn.md](../design/cdn.md)）。
型を変える操作は `SchemaChange`（純粋な規則。操作 → 既存のデータに起きる影響の種類）と `SchemaGuard.withImpact`（Tx の中で件数を数え直し、`fieldImpact` で見た `expected` と食い違えば CmsErr）を通す。参照の索引 `entry_links` は `field_api_id` で持ち（`content_fields` への FK を持たない。フィールドを消しても索引が消えず、同じ apiId で足し直すと戻る）、「今もあるフィールドか」は読み取り時に突き合わせる。`Projects.contentVersion()` がコンテンツ API の GET の ETag に入る。PersonalTokens は本人に付く PAT で Tenant を取らない。

同じ階層に業務エラー（CmsErr）、今のプロジェクト（Tenant effect）、今の認証済みユーザー（Session effect。handler を入れるのは `DbRunner.transact` だけ。`Session.require(permission)` が既定拒否の入口、`Session.currentUser()` が書く人の入口）。

## プロジェクト（テナント）

1 つの DB に複数のプロジェクト（型と entry の集まり）を持つ。パスの先頭 `/p/{プロジェクト slug}/` か Host（`CMS_BASE_DOMAIN`）で選び、無ければ既定プロジェクト（`CMS_DEFAULT_PROJECT`。既定 `default`、空なら 404）。

言葉: **プロジェクト slug**（`ProjectSlug`。URL 用の人が読める名前）と **プロジェクト id**（主キー）を混ぜない。裸の「slug」とは呼ばない。

ユースケースは `Tenant.current()`（algebraic effect）で今のプロジェクトを読み、読み書きを全部そこに閉じる。Runner がリクエストごとに handler を入れ、テストは `PgTestSupport` が既定のプロジェクトで入れる。他のプロジェクトの id を渡しても notFound。

テナント分離は三重:

1. **型**（Tenant effect）
2. **生成器**（`make gen` の `--scope project_id`。project_id 列の表を触る query に条件が無ければ止まる。跨ぐ物は `// unscoped: 理由`）
3. **DB**（RLS。印は Tx を開く物が置く: `DbRunner.transact` / `withTx` が `TenantTx` で BEGIN の直後にプロジェクトの印を、transact は人なら本人の印（app.user_id / app.email）も置く。policy は app.project_id / user_id / email / token_hash の 4 つ。印の無い Tx は中身の表が 0 行）

## 型の決まり

- id はプリミティブで持ち回らない。`TypeId` / `FieldId`（Int64 を包む）、`EntryId`（文字列。parse 済み）で、GraphQL の `Id` との写しは admin 層だけ
- 識別子は `ApiId`（lowerCamel）、`TypeName`（UpperCamel）、`ProjectSlug`（DNS のラベル）で、`parse` を通した物しか作らない。規則外の文字列は境界で invalid になる
- ドメイン（src/cms）は GeneratedAdmin を知らない。enum と入力レコードはドメインが自分で持ち、写しは `AdminMapping`
- 外向きの id: 連番は出さない。組織や鍵は乱数の public_id、配信記録のように時刻順に読む物は ULID（作成時刻が読めるので鍵や組織には使わない）
- entry の中身は `EntryData = Map[ApiId, Json]`。GraphQL の `JSON` scalar（`Value`）との往復も `AdminMapping`
- `FieldKind` は TEXT / TEXT_AREA / SLUG / NUMBER / BOOLEAN / SELECT / REFERENCE / OBJECT / BLOCKS / ASSET / RICH_TEXT / DATE
- DATE に保存できる値は UTC の ISO 8601 ちょうど 1 通り（"2026-09-09T00:00:00Z"）。offset 付き・ミリ秒付き・秒なし・日付だけは受けてから直さず INVALID で断り、直せる値は言い分に送るべき形を載せる（規則は `DateValues`）。絞り込みの引数は保存しないので日付だけでも offset 付きでも読む。絞り込みと並び替えは `EntryFilterSql` が timestamptz にして比べ、一意（JSONB の `=`）は文字列で見るので形が 1 通りである事が要る
- DATE_ONLY（日付だけ）は DATE と別の種類。値は `"2026-09-09"` ちょうど 1 通りで、時刻付きは断る（規則は `DateOnlyValues`）。SQL は `::date`、cursor は epoch day（`CursorValue.Day`）。時刻を持たないので読む側のタイムゾーンで日がずれず、形が 1 通りなので unique もそのまま効く。microCMS には日付だけの型が無いので、取り込みは今まで通り DATE に写す
- SELECT は `many: true` で複数選択（値は選択肢の配列。コンテンツ API では `[Enum!]!` と `_contains`）

### FieldKind を足す時に触る所

ContentType（enum）・ContentTypeRows（DB の文字列）・migrations（CHECK）・Naming・EntryValidation・ContentSchemaBuilder・admin.graphql（`make generate`）・AdminMapping・MicrocmsSchema / MicrocmsImport の全部。
