# ランタイム（src/app、Tx、仕事、HTTP、ログ）

読むタイミング: Tx の張り方・接続・再試行に関わる時、ルートを足す時、バックグラウンドの仕事を触る時、ログや /health を変える時、停止と自己回復に関わる時。

## 起動と環境

- **AppEnv** — リクエストと仕事に共通の環境の handler。`runWith`（IdGen / Tenant / ObjectStore / Http（Deps の HttpClient で `OutboundHttp.runWith`）/ Clock / Log の span と sink）と Account API 用の `runWithoutProject`。Runner と MicrocmsCli はこれを呼び、その中で `DbRunner.transact` を張る
- **Deps** — storage / auth / http / log。http はプロセスで 1 つの HttpClient、log は Runner がリゾルバの中で Log を入れ直す sink（graphql-java の Java コールバックの中なので dispatch の handler は届かない）
- **StorageConfig**（ASSET_*。無ければ asset 無し）、**AuthConfig**（CMS_AUTH=jwks|dev|none）、**AppRole**（cms_app の作成）
- **DbConfig** — 所有者とアプリ用ロール。`withTimeouts` が JDBC の URL に pgjdbc の `options` で idle_in_transaction_session_timeout / statement_timeout / lock_timeout を付ける（CMS_DB_TIMEOUT_SECONDS、既定 30、0 で無効）。`poolFromEnv` が CMS_DB_MAX_CONNECTIONS / CMS_DB_BORROW_TIMEOUT_SECONDS（既定 2）/ CMS_DB_LEAK_DETECTION_SECONDS を足す。読み取りは純粋な `maxConnections` / `borrowTimeoutSeconds` / `leakDetectionSeconds`
- **Main** — Sink を組み（CMS_LOG_LEVEL → service / version → JSON）、dispatch が request id と span を張ってリクエストの行を出す（[../logging.md](../logging.md)）

## HTTP とルート

- **Server** — ルート表 `Server.routes`。1 行 = メソッド・パス・engine・handler。`/p/{projectSlug}/` は `Router.withProjectPrefix` が複製。**行を足したら TestServer の describe の一覧にも 1 行**。/health・Host のプロジェクト slug の middleware `wrapProjectFromHost`。Main は表の engine を見てエンジンを入れる。表の行: `POST/GET /graphql`、`POST/GET /admin/graphql`、`POST /account/graphql`、`GET /health`、`POST /jobs/tick`、`POST /mcp`、`GET /admin/audit.csv`、`GET /admin/audit.jsonl`
- **AuditExport** — 監査の書き出し（`GET /admin/audit.csv` / `audit.jsonl`。引数は `auditEvents` と同じ actorKind / action / since / until）。`mcpRoute` と同じく管理 API のエンジンへの GraphQL クライアントで、`auditEventsCount` で上限（100,000 件。超えたら 413 `TOO_MANY`）を見てから `auditEvents` を 200 件ずつ cursor で回し（ページごとに読むだけの Tx）、最後に `recordAuditExport`（別の Tx）で `audit.exported` を積む。CSV は UTF-8 with BOM・`\r\n`・全セル `"` 囲み・detail は JSON の文字列、JSON Lines は detail が入れ子のまま。どちらも `url`（Host があれば絶対）付き、`Content-Disposition: attachment`、no-store。断りは `{"error": {"code", "message"}}`（401 / 400 / 403 / 413。code は管理 API の extensions.code の写し）。ファイル名の今日の日付は `Health` の `now`
- **src/http/** — 手書き HTTP/1.1（接続ごとのスレッドは Throwable で受けて 500。OutOfMemoryError だけ再送出。`close` で accept をやめ、`connections` が今の接続数。停止は Shutdown が使う）、Router（純粋なルート表。Method / Pattern / Route / Match、`find` は上から当てて 405 の Allow を表の順で出す）、Cors（`Cors.wrap` が preflight と 404 / 503 込みの CORS ヘッダ。Allow-Methods は表から）、JvmErrors（スレッドの境界で受けた Throwable の扱い。`isFatal` は VirtualMachineError から StackOverflowError を除いた物で、graphql-java が包む CompletionException のような cause の連鎖の中も見る、`describe` は message か class 名）、OutboundHttp（外へ出す HTTP の `Net.Http.Http` の handler。プロセスで 1 つの HttpClient を使い回す。**標準ライブラリの `Net.Http.runWithIO` は handler ごとに HttpClient を作ってスレッドが残るので src/ では使わない**）
- **RequestId** — `X-Request-Id` を受けるか捨てるか（64 字・`[A-Za-z0-9_-]`）、無ければ ULID、`RequestId.wrap` が応答ヘッダで返す middleware

## キャッシュと CDN

コンテンツ API の匿名の GET は RouteRequest の `contentVersion`（Main.runRoute が認証と同じ Tx で読む。`Server.wantsContentVersion`）で weak な ETag を組み、If-None-Match が合えば GraphQL を実行せず 304、リクエストの行に `cache.status`（hit / miss / bypass）。

- **CacheHeaders**（純粋）— `CachePolicy`（s-maxage / max-age / stale-while-revalidate。`policyOf` が CMS_CACHE_* を読む）、`etagOf`（版 + query / variables / operationName の sha256）、`matches`（If-None-Match。weak comparison、`*`、複数値）
- **CdnPurge** — CDN の purge の outbox `cdn_purges`。`targetOf` が CMS_CDN_PURGE_URL / TOKEN を読み、`enqueue` が `content_version > purged_version` のプロジェクトを拾って積み、`tick` が Cloudflare の `purge_everything` を POST。再試行・回復・掃除は WebhookDispatcher と同じ

決めた事は [../design/cdn.md](../design/cdn.md)。

## Tx と DB

Tx の入口は 3 つ:

| 入口 | 用途 |
|---|---|
| `DbRunner.transact(pool, scope, actor, f)` | Runner・仕事・エンジンの組み直し・テストの mutate。認証済みユーザー付きで業務エラー込み。結果は `Result[ApplicationFailure, a]` |
| `DbRunner.withTx(pool, scope, f)` | 仕事の tick・プロジェクトの解決と認証のような CmsErr も Session も無い物 |
| `DbRunner.withRequestTx(pool, scope, actor, observe, lastClosedAt, body)` | 読むだけの文書。`openRequestTx` で Handle を作り、body の後に `closeRequestTx`（body が JVM の例外で抜けても閉じる）。フィールドは `transactShared(handle, observe, actor, f)` → `toSharedFieldResult`。Broken の後は `Attempt.Skipped` で Error の行を出さない |

- **RequestTx**（純粋）— `State`（Idle / Open / Broken）の遷移 `afterField` / `canRun` / `transactionsOf` / `outcomeOf`、`Handle`、`Closed`
- **TenantTx** — RLS の印付き Tx
- `transact` は BEGIN の直後に RLS の印（scope のプロジェクトと、人なら本人）を置き、CmsErr → Session → SQL の数え → `Db.guard(f)` の順に handler を入れる（**Session の handler はここだけ**）
- 業務エラーは `Pool.withLazyTxResult` で Tx の中で受けて ROLLBACK。JVM の例外は sqlfx の `Db.guard` を一番内側の handler の直下に置いて `DbErr` にする（withLazyTx の catch は、内側に handler が入ると素通りされる）
- 再試行は `retryPolicy()`（3 回・200 ms・上限 2 秒・full jitter）で、回数は db.retries、SQL と Tx の数は db.statements / db.transactions、待ちが出ていれば db.pool.* を observe でリクエストの行に（受ける側の `LogFields.mergeCounts` が足す）。DB の失敗は Error の行（error.kind）と INTERNAL の requestId。`toFieldResult` は ApplicationFailure の 3 腕の平らな match
- **PoolActivity** — 接続がプールに最後に返った時刻 `LastReturnedAt`。HikariCP の IMetricsTracker で記録し、SelfHeal が「満杯か作り直しの最中」と「壊れて戻らない」を分けるのに読む。Main が起動時に `attach`

### 破ると事故る所

- src/ で `withLazyTx`（と Tx を手で組む `Pool.borrow` / `Tx.begin` / `Jdbc.executeStatement` / `Jdbc.runWithConnection`）を直に呼べるのは `scripts/tx-allowlist.txt`（DbRunner / TenantTx）だけ。`make check` の `scripts/check-tx.sh` が増減を見張る
- 業務エラー（CmsErr）のような再開しない effect を `withLazyTx` の外で受けると COMMIT / ROLLBACK と接続の返却が飛び、接続が漏れる（TestTxLeakPg が見張る）
- 業務エラー（CmsErr）を値に潰す handler は Tx の境界（`DbRunner` の private `runCmsErr`）とテストの `CmsTestKit.runWithResult` にしか無い（`CmsErr.runWithResult` は無い）。ユースケースの途中で潰すと失敗が Tx の中で握り潰される

### GraphQL の Unit of Work

文書の種類で 2 つ。

- **読むだけの文書（mutation の無い物）は 1 リクエスト 1 Tx**（READ ONLY, REPEATABLE READ）。`DbRunner.withRequestTx` が `Main.executeDocument` で張り、Context の `tx`（`RequestTx.Handle`）を Runner が `transactShared` で使う。接続は最初の SQL で借りて応答の直前に COMMIT。一時的な失敗の再試行は借りる時だけ。DB の失敗（DbFailure）が 1 度出れば Broken で、残りのフィールドは SQL を出さず INTERNAL、最後に ROLLBACK。業務エラーは続けて最後に COMMIT。リクエストの行に `db.tx.outcome` / `db.tx.held_ms`。MCP の読むだけの tools/call も同じ道
- **mutation を含む文書はルートフィールドごとの Tx**。1 リクエストに mutation を並べても互いに独立で、2 つ目が失敗しても 1 つ目は COMMIT されている（DbFailure も他のフィールドに波及しない）。まとめたい操作は 1 つの mutation にする

1 リクエストの SQL と Tx の数は `test/Pg/TestQueryBudgetPg` が上限で見張る（読むだけの文書は Tx 2 = 認証 1 + リクエスト 1）。

## バックグラウンドの仕事

仕事の表（webhook_deliveries / scheduled_actions）は outbox: 業務の Tx で積み、tick が `FOR UPDATE SKIP LOCKED` で拾う（複数台でも二重にならない）。実行中に落ちた行は claimed_at で回復する。

- **BackgroundJobs** — プロセス内のバックグラウンドワーカー。2 秒ごとに回復・掃除 → Scheduler.tick → WebhookDispatcher.tick → CdnPurge（State の `purge` がある時だけ。enqueue → tick）→ LinkCardRefresh.tick。heartbeat は lastTick / lastWatch（/health が古さを見る）。外部トリガー POST /jobs/tick も同じ tick。JVM の例外の catch は 3 つ: tick 全体の `guarded`（Log の sink を try の内側に入れる）、予約公開と Webhook の部分ごとの `guardedPart`（handler の入れ子に依らない）、watch の `guardedWatch`。置き方の規則は [../flix-conventions.md](../flix-conventions.md)
- **Scheduler** — 予約公開の実行。1 回の tick はチャンク（既定 100 件）の claim と実行を予算（既定 10 秒）に達するまで繰り返し、満杯でない claim で終わる。判断は純粋な `canClaimMore`。CMS_SCHEDULER_CHUNK_SIZE / CMS_SCHEDULER_TICK_BUDGET_SECONDS
- **WebhookDispatcher** — 配信行を拾って POST
- **LinkCardRefresh** — richText の linkCard の OGP の取り直し。`link_cards` の古い行（fetched_at が 7 日より前）と失敗した行（1 時間より前）を 1 tick に最大 20 件拾い、`LinkCards.fetchOver`（HTTP は Tx の外）→ `LinkCards.store`（そのプロジェクトの Tx）。初回の取得は管理 API の `fetchLinkCard`。`link_cards` は仕事が跨いで拾うので RLS 無し（TestTenantGuardPg の一覧）
- **JobLog** — 仕事 1 件の Log の行。job.kind / job.id / job.outcome

## 停止と自己回復

- **Shutdown** — SIGTERM / SIGINT の停止。listen を閉じる → 接続を待つ → 仕事の drain → プールを閉じる、の順で、間に合えば exit 0、待ち切れなければ `shutdown timed out` と exit 2。順番の判断は純粋な `decide` / `exitCode`。`Outcome.Crashed` は main スレッドが死んだ時（Main の `listenGuarded` が Throwable で受け、`main thread died` を出して exit 3。drain はしない）。CMS_SHUTDOWN_TIMEOUT_SECONDS、既定 20
- **SelfHeal** — 接続プールが壊れたまま戻らないかの判断。`decide` は純粋（窓の間にリクエストの Tx が 1 度でも閉じていれば満杯なだけなので Keep。`lastTxClosedAt` は `closeRequestTx` が置く）、外に触るのは観測を作る `observe`（プール経由の ping の結果は呼ぶ側から受ける）だけで、`step` はそれを積んで決める（観測の列の `at` で決まるので呼ばれる間隔は問わない）。終わりの道は `claimExit` で 1 回だけ。CMS_SELF_HEAL / CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS / CMS_SELF_HEAL_WARMUP_SECONDS / CMS_SELF_HEAL_JITTER_SECONDS（既定 10。Main は 0.0〜1.0 の乱数を渡すだけ）
- watch `healCheck` は `watchForever` の別スレッド（2 秒ごと）と /health の 2 経路から呼ぶ（別スレッドだけだと OOM で死んで無効になる）。決まったら drain して exit 3。印で 1 回だけ

## 失敗の分類

層ごとに 1 種類:

| 層 | 型 |
|---|---|
| 認証 | `Rejection` |
| ドメイン | `CmsFailure`（CmsErr) |
| DB | `DbFailure` |
| Tx の境界 | `ApplicationFailure` の Infrastructure / Domain。`describe` |

ドメインは UNAUTHENTICATED を出せない（CmsErr に無い）。

**GraphqlErrors** が ApplicationFailure → errors[].extensions の code / violations / entity / id / 版に写す。分類を決めるのはここだけ（[../design/error-codes.md](../design/error-codes.md)）。

## ログと観測

- **src/log/** — 構造化ログのライブラリ（logfx の元。cms / http / app に依存しない）。`eff Log`（emit）、Severity、Fields（Map[String, Value]。ビルダーは `Log.Fields`）、Record、Sink（`Record -> Unit \ IO`。合成は `Log.Sink` の json / minSeverity / enrich / collect）、withFields（span。内側が勝つ）、runWith（スレッドの入口。sink の例外は捨てる）、runWithList（テスト）、exception（Java の例外 → exception.type / message / stacktrace）、toJsonLine（time / severity / message を先頭に名前順、ms 固定の ISO 8601、制御文字を落とす）。HttpServer は Log を知らず `Served` の値を `listen` の onServed に渡す
- **LogFields** — CMS の値 → Log.Fields。request の span、credential.kind、応答の行と重さ、graphql.*、ApplicationFailure / CmsFailure → error.code / entity / id、observe の合わせ方 `mergeCounts`（db.* の数は和）。キーは [../logging.md](../logging.md)、`scripts/check-log-keys.sh` が見張る
- **Observe** — Route の handler と 404 / 405 の分岐からリクエストの行に属性を積む effect。`Observe.note`。Main が `extra` の Ref で受ける
- **Health** — /health と /jobs/tick が読む関数のレコード `Health[ef]`。checkDb / jobsSummary / runJobs / connections / poolStats / stall / heal（heal は checkDb の結果を受ける。DB が落ちている間に ping を 2 回打たないため。checkDb は `pingWithin`（`Pool.withConnectionTimeout`。借り待ちの上限は CMS_DB_BORROW_TIMEOUT_SECONDS）で、プールの列に並んで張り付かない。起動時の確認と自己回復の watch は `ping`）。tick が止まっていないかの判断は純粋な `stalled`（上限は間隔の 3 倍。ただし 30 秒は待つ）で、止まっていれば 503 と `reason`。本番は `ofPool`、テストは `HealthFake.ok()` / `failing`。ログは持たず、Route は `Log` と `Observe` の effect を持つ。テストは `ServerTestKit.quietly` で捨てる

## その他の層

- **src/crypto/** — Sha256（sha256 / HMAC / 16 進）と Base64Url。署名と鍵のハッシュが共通で使う。ドメインは storage や auth に依存しない
- **src/storage/** — asset の置き先。SigV4（純粋な署名）、ObjectStore effect（署名付き URL / HEAD / DELETE。MinIO と R2 は同じ handler）
- **src/auth/** — JWT の検証（RS256 固定。kid / iss / aud / exp / nbf）と TokenVerifier effect（JWKS の取得とキャッシュ）
