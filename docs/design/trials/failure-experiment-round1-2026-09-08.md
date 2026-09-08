# 障害の実験 1 回目（対策を入れる前の計測）

2026-09-08。対策（pool の可視化 / 自己回復 / 再接続の backoff）を入れる**前**の姿を測り、後で同じ手順を回して前後を比べられるようにする。コードは変更していない。

生ログは `/Users/abab/.claude/jobs/4993073b/tmp/failure-round1/` に残す。

| ファイル | 中身 |
| --- | --- |
| `server.log` | S1〜S4・S6 のサーバの JSON ログ |
| `server-oom-noexit.log` | S5 の 1 回目（`-XX:+ExitOnOutOfMemoryError` 無し） |
| `server-oom-exit.log` | S5 の 2 回目（`-XX:+ExitOnOutOfMemoryError` 有り） |
| `probe.log` | 1 秒間隔の /health と通常リクエスト（307 行） |
| `probe.sh` / `load.sh` / `slow-receiver.py` | 使った道具 |
| `load-healthy.txt` / `load-200.txt` / `load-paused.txt` | S3 の同時リクエストの結果 |
| `sigterm-inflight.txt` | S6 の処理中リクエストの応答 |

## 環境

| 項目 | 値 |
| --- | --- |
| コミット sha | `bd0b7c7` |
| sqlfx | `github:ababup1192/sqlfx` 0.2.0（`Pool.defaultConfig` = maxConnections 10 / borrowTimeoutMs 5000 / leakDetectionThresholdMs 0） |
| HikariCP | 5.1.0（SLF4J の束縛は `slf4j-nop`） |
| pgjdbc | 42.7.4 |
| Flix | 0.75.3。実行は `make fatjar` の `artifact/flix_graphql_hello.jar` |
| JVM | OpenJDK 23.0.1+11-39、`-Xss32m`（S5 だけ `-Xmx64m`） |
| Docker | 29.7.2。`postgres:16` / `minio RELEASE.2025-04-22`（`make db-up`） |
| 起動の環境変数 | Makefile の `PG_ENV` に `CMS_VERSION=dev CMS_LOG_LEVEL=debug` を足した物。`CMS_AUTH=dev` / `CMS_BOOTSTRAP_OWNER=dev@localhost` |
| 通常リクエスト | `POST /admin/graphql`（`X-Dev-User: dev@localhost`）で `{ entries(typeId: "1") { totalCount nodes { id } } }`。公開済みの entry 1 件 |
| リトライ | `DbRunner` は 3 回。待ち時間は無し（borrowTimeout 5 s × 3 = 15 s が実測の待ち） |

## 復帰秒数のまとめ

| # | 障害 | 停止中の応答 | 復帰までの秒数 |
| --- | --- | --- | --- |
| 1 | PG の停止 → 再起動 | `/health` 503（20 s）、GraphQL は HTTP 200 + `INTERNAL`（15 s） | PG 起動から **1〜2 秒** |
| 2 | PG の pause → unpause | 同上（S1 と区別が付かない） | unpause から **0〜1 秒** |
| 3 | 同時 50 / 200 リクエスト | 全部 200、最遅 0.27 s（枯渇せず） | — |
| 3b | pause 中に同時 50 | 全部 HTTP 200 + `INTERNAL`、揃って 15.02 s | unpause から即 |
| 4 | Webhook の受け手が落ちている | 配信は `job retry`、10 s で timeout | 60 s 後に再試行（1 分 → 5 分 → 30 分 → 2 時間、5 回目で failed） |
| 5 | OOM（ExitOnOOM 無し） | プロセスは生き残るが pool が壊れ、`/health` 503 が続く | **復帰しない**（2 分観測して回復せず） |
| 5b | OOM（ExitOnOOM 有り） | プロセスが終了（exit code 3） | 再起動に依存（手元では約 25 秒で起動） |
| 6 | 処理中の SIGTERM | 処理中のリクエストは完走 | 終了まで **15.49 秒**（exit code 0） |
| 7 | リゾルバの VerifyError | 再現はやらない（下記） | — |

---

## S1 PG の停止 → 再起動

**操作**: 14:00:27 `docker compose stop postgres` → 14:02:37 `docker compose start postgres`（130 秒。当初の 30 秒より長くなったが、観測に影響は無い）。

**probe の推移**（`probe.log`）:

```
14:00:27 health=200:0.005 req=…totalCount":1…       200:0.020
14:00:28 health=000:10.004  req= 000:10.004          ← curl の --max-time 10 で打ち切り
14:00:49 health=000:10.006  req= 000:10.004
…（14:02:13 まで同じ）
14:02:34 health=200:3.795  req=…totalCount":1…      200:0.027
```

**サーバのログ**（`server.log` 67〜95 行）:

```json
{"time":"2026-09-08T05:00:48.564Z","severity":"warn","message":"request","duration_ms":20026,"http.response.status_code":503,"url.path":"/health",…}
{"time":"2026-09-08T05:00:53.575Z","severity":"error","message":"field failed","error.code":"INTERNAL","error.message":"database error: Permanent(retryExhausted timeout 0 after 3 attempts)","request.id":"01M1ZP7FS3175GJ15FDEAFYPSP",…}
{"time":"2026-09-08T05:00:53.579Z","severity":"info","message":"request","duration_ms":15016,"graphql.error_codes":["INTERNAL"],"http.response.status_code":200,…}
{"time":"2026-09-08T05:01:13.354Z","severity":"error","message":"jobs tick failed","error.message":"回復と掃除ができません: Permanent(retryExhausted timeout 0 after 3 attempts)"}
{"time":"2026-09-08T05:02:38.669Z","severity":"debug","message":"request","duration_ms":3794,"http.response.status_code":200,"url.path":"/health",…}
```

**クライアントに返る形**: HTTP 200、`errors[0].extensions.code = "INTERNAL"`、`requestId` 付き。`message` は `database error: Permanent(retryExhausted timeout 0 after 3 attempts)` で、**内部の再試行の言葉がそのまま外に出る**。

**復帰**: PG 起動 05:02:37 → 最初の 200 が 05:02:38.669（`/health`）。**1〜2 秒**。pool に古い接続が残って失敗し続ける事は無く、Hikari が死んだ接続を捨てて張り直した。

**pool に何が起きたか**: **ログからは分からない**。`slf4j-nop` を入れているので HikariCP は 1 行も出さない（`server.log` に `Hikari` / `pool` を含む行は 0）。分かるのは「3 回試して timeout」だけで、接続を張りに行ったのか、上限まで使われて待ったのかは区別できない。

**出るべきなのに出なかった行 / 属性**:

- pool の状態（`db.pool.active` / `idle` / `waiting` / `max`）。`/health` の本文にも DB の pool は無い（`connections` は HTTP の接続数）
- 「DB に繋がらなくなった」「戻った」という状態遷移の 1 行。今は各リクエストが個別に error を出すだけで、**障害の開始と終了の時刻がログから直接は読めない**
- 再試行の 1 回ずつ（`db.retry.attempt`）と、次の待ち時間
- `/health` の 503 に理由の属性（`db` の状態は本文にあるがログのフィールドには無い）

**効く対策**: 5（pool の可視化）が本命。7（backoff）は「15 秒待たせてから諦める」を早く諦めさせる形にも使える。

---

## S2 PG が遅い（docker pause）

**操作**: 14:03:14 `docker pause` → 14:04:02 `docker unpause`（48 秒）。

**probe の推移**:

```
14:03:13 health=200:0.005  req=…totalCount":1…
14:03:14 health=000:10.004 req= 000:10.006
14:03:36 health=000:10.006 req= 000:10.006
14:03:57 health=200:5.492  req=…totalCount":1…    ← health は unpause を跨いで完走
```

**サーバのログ**（`server.log` 163〜173 行）: S1 と**まったく同じ**行しか出ない。

```json
{"severity":"warn","message":"request","duration_ms":20024,"http.response.status_code":503,"url.path":"/health"}
{"severity":"error","message":"field failed","error.code":"INTERNAL","error.message":"database error: Permanent(retryExhausted timeout 0 after 3 attempts)"}
```

**timeout との絡み**:

- `CMS_DB_TIMEOUT_SECONDS`（既定 30。`statement_timeout` / `lock_timeout` / `idle_in_transaction_session_timeout`）は**一度も効かない**。pause では TCP が固まるので、`statement_timeout` を返すはずの PG 自身が止まっており、こちらは borrow の段で先に諦める
- 効いたのは `borrowTimeoutMs = 5000` だけ。それが 3 回で 15 秒
- `/health` の 20 秒はさらに別（Health は `DbRunner` の再試行を通らず `Pool.withConnection` を直に呼ぶが、20 秒待ってから 503 を返す）

**復帰**: unpause から **0〜1 秒**。

**出るべきなのに出なかった行 / 属性**: 「遅い」と「落ちた」を**ログでは区別できない**。区別に要るのは、borrow に掛かった時間（`db.pool.wait_ms`）と、接続はできたが query が遅いのか、そもそも接続できないのか（`db.phase = connect | acquire | execute`）。

**効く対策**: 5。6（自己回復）はこの場面では要らない（放っておけば戻る）。

---

## S3 pool の枯渇

**設定**: `Pool.defaultConfig` の `maxConnections = 10` / `borrowTimeoutMs = 5000`（`flix_db/src/Db/Jdbc/Pool.flix:47`）。CMS 側は上書きしていない。

**正常時**:

| 同時数 | 結果 | 最遅 |
| --- | --- | --- |
| 50 | 全部 200 | 0.27 s |
| 200 | 全部 200 | 0.20 s |

通常リクエストが 20〜30 ms で終わるため、10 本の pool でも待ち行列が観測できるほど溜まらなかった。**この負荷では枯渇を再現できていない**（2 回目は、意図的に遅い query を用意するか `maxConnections` を 1〜2 に落として測る）。

**待ちを強制した形**（PG を pause して同時 50。`load-paused.txt`）: 50 本すべてが HTTP 200 + `INTERNAL` を **15.02 秒**で返した。50 本が 10 本の pool を奪い合ったなら後続はもっと待つはずだが、そうならない。borrow が全部 5 秒で失敗して接続を占有しないため、**待ち行列そのものが出来ない**。

**ログから待ちの数は読めるか**: **読めない**。`server.log` に pool を指す行は 1 行も無い。分かるのはリクエストの `duration_ms` が 15000 前後という事だけで、それが「pool が満杯で待った」のか「DB が落ちている」のかは同じ文言（`retryExhausted timeout 0 after 3 attempts`）になる。

**出るべきなのに出なかった行 / 属性**: `db.pool.active` / `idle` / `waiting` / `max` の定期的な行（tick ごと）と、リクエストごとの `db.pool.wait_ms`。`/health` の本文にも足すべき（今は HTTP の `connections.active/max` だけがある）。

**効く対策**: 5。これが対策 5 の一番強い動機。

---

## S4 Webhook の受け手が落ちている / 遅い

### (a) 受け手なし（接続拒否）

`http://127.0.0.1:19999/hook` に webhook を登録し、14:05:55 に entry を再公開。

```json
{"time":"2026-09-08T05:05:57.193Z","severity":"warn","message":"job retry","detail":"接続できませんでした: java.net.ConnectException","error.message":"接続できませんでした: java.net.ConnectException","job.id":"01M1ZPH54DPN9M6X2WVP4812B5","job.kind":"webhook","job.outcome":"retry","project":"default","webhook.id":"0afb12e8a2f6"}
```

公開から 2 秒（tick の周期）で 1 回目の配信が走り、`job.outcome = retry`。

### (b) 60 秒応答しない受け手（`slow-receiver.py`）

14:06:27 に再公開。

```json
{"time":"2026-09-08T05:06:37.395Z","severity":"warn","message":"job retry","detail":"応答がありませんでした（タイムアウト）: request timed out","error.message":"応答がありませんでした（タイムアウト）: request timed out","job.id":"01M1ZPJ4B18P23ZFBVAF8B7FSP","job.kind":"webhook","job.outcome":"retry","project":"default","webhook.id":"4ac415121cbe"}
```

`HttpRequest.withTimeout(10 秒)` が効いて 10.4 秒で諦めた。DB の行は次のとおり:

```json
{"attempts":1,"lastStatus":0,"lastError":"応答がありませんでした（タイムアウト）: request timed out","nextAttemptAt":"2026-09-08T05:07:37.396181Z","status":"PENDING"}
```

**出るべきなのに出なかった行 / 属性**:

- `job.attempts` と `job.next_attempt_at`。DB の行には両方あるのに、**ログの行には無い**。「何回目の失敗か」「あと何回で諦めるか」がログだけでは追えない
- 遅い受け手が `BackgroundJobs.tick` を **10 秒止める**。その間、予約公開と回復も進まない。「tick が何秒掛かったか」の行（`job.tick.duration_ms`）が無いので、詰まりに気付けない
- 諦めた時（`job.outcome = failed`）の行は今回の観測時間では出ていない（5 回目まで 2 時間以上掛かる）

**効く対策**: 7（backoff）は既に配信側に実装済み（1 分 → 5 分 → 30 分 → 2 時間）。足りないのは属性であって仕組みではない → 対策 5 の範囲を「pool だけでなく job にも」広げると効く。

---

## S5 OOM

Dockerfile の `JAVA_OPTS` は `-Xss32m -XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError`。手元では `-Xmx64m` を足して、その有無で 1 回ずつ。

**誘発の仕方**: 1 リクエストの body は `Http.maxBodyBytes()` = 1 MiB で 413 に切られる（4 MB の body は 0.9 ms で 413）。そこで 900 KB の `createEntry` を同時 50 本投げた。Flix の `Util.Json` のパーサが `StringBuilder` に積むので、これで heap を使い切る。

### (a) `-XX:+ExitOnOutOfMemoryError` 無し

応答: 200 が 10 本、500 が 19 本、繋がらず（000）が 21 本。

```json
{"time":"2026-09-08T05:09:18.287Z","severity":"error","message":"request","duration_ms":981,"exception.message":"Java heap space","exception.stacktrace":"StringBuilder.Def$append…Util.Json.Def$scanString…","exception.type":"java.lang.OutOfMemoryError","http.request.body.size":900117,"http.response.status_code":500,"url.path":"/admin/graphql",…}
```

**その後プロセスは生き残るが、二度と直らない。** 2 分後の `/health`:

```
503:20.037
{"connections":{"active":43,"max":256},"db":"Transient(timeout 0)","jobs":{"failedDeliveries":-1,…,"pendingDeliveries":-1,…},"status":"error","version":"dev"}
```

- DB の pool が壊れたまま（`db: Transient(timeout 0)`）。PG は健在なのに、以後すべてのリクエストが `INTERNAL` を返し続ける
- HTTP の接続が 43 本掴まれたまま返らない（OOM で死んだスレッドの接続が閉じられていない）
- `/health` は 20 秒掛けて 503 を返す。**復帰しない**

`src/http/JvmErrors.isFatal` は `OutOfMemoryError` を fatal として再送出する設計だが、実際にはスレッド境界で受け止められて `error` の行になり、**プロセスは落ちない**。落ちないのに直らないのが一番悪い。

### (b) `-XX:+ExitOnOutOfMemoryError` 有り

同じ負荷で全 50 本が 000（接続断）。プロセスは **exit code 3** で終了。最後のログ行:

```
Terminating due to java.lang.OutOfMemoryError: Java heap space
```

**これは JSON ではない。** OOM の事実が構造化ログの外に出るので、JSON を読む収集器（`docs/logging.md` の「1 行 1 JSON」）には落ちた理由が届かない。直前の行は普通の 200 のリクエストで、予兆は無い。

**出るべきなのに出なかった行 / 属性**: heap の使用率（`jvm.memory.used` / `max`）を tick ごとに 1 行。OOM の直前に増えている事が見えれば、原因の切り分けが要らなくなる。

**効く対策**: 6（自己回復）。本番は `ExitOnOutOfMemoryError` が付いているので (b) の形になるが、それは「回復＝再起動」で、プロセス内では回復しない。(a) が示すのは、**pool が一度壊れたら自力では戻らない**という事で、これは OOM 以外の原因でも起きうる。対策 6 は「`/health` が db=error を一定回数続けたら pool を作り直す」か、少なくとも「`/health` が error のまま N 秒続いたら自分で exit する」の形が要る。

---

## S6 処理中の SIGTERM

**操作**: PG を pause して 15 秒掛かるリクエストを 1 本投げ、その最中の 14:07:59.316 に `kill -TERM`。

```json
{"time":"2026-09-08T05:07:59.318Z","severity":"info","message":"shutting down"}
{"time":"2026-09-08T05:08:09.992Z","severity":"error","message":"field failed","error.code":"INTERNAL","request.id":"01M1ZPMSY4D6QPT780WSTHJB9K",…}
{"time":"2026-09-08T05:08:10.000Z","severity":"info","message":"request","duration_ms":15052,"graphql.error_codes":["INTERNAL"],"http.response.status_code":200,"request.id":"01M1ZPMSY4D6QPT780WSTHJB9K",…}
{"time":"2026-09-08T05:08:10.035Z","severity":"warn","message":"request","duration_ms":20028,"http.response.status_code":503,"url.path":"/health",…}
{"time":"2026-09-08T05:08:14.350Z","severity":"warn","message":"jobs drain timed out (claimed_at で拾い直す)"}
```

| 項目 | 結果 |
| --- | --- |
| `shutting down` | シグナルの **2 ms 後**。速い |
| 処理中のリクエスト | 完走した（15.05 秒。中身は `INTERNAL`。PG を止めていたので当然） |
| `jobs drained` | **出ない**。代わりに `jobs drain timed out`（tick が pause した PG で 15 秒詰まっていたため） |
| 終了コード | **0** |
| 終了までの秒数 | **15.49 秒**（14:07:59.316 → 14:08:14.803） |

**probe の推移**: `shutting down` の後も接続は受け付けており、14:08:11 の `/health` は 3.69 秒待たされてから切られた（`000`）。`System.exit(0)` の瞬間に開いていた接続がそのまま切れる。

**出るべきなのに出なかった行 / 属性**:

- **HTTP の drain が無い**。待つのは `BackgroundJobs` の tick だけで、処理中のリクエストも新しい接続も見ていない。今回リクエストが完走したのは、tick の drain がたまたま 15 秒待ったからにすぎない
- `shutting down` の後に来た接続へ 503 を返す形が無く、いきなり接続断になる。LB から見ると reset
- `jobs drain timed out` でも終了コードが 0。デプロイの側から「綺麗に落ちたか」を判定できない
- drain の残り時間 / 待った秒数（`shutdown.drain_ms`）

**効く対策**: 6 の範囲を「pool の自己回復」から「停止の drain」まで広げるなら効く。今回の 3 つの対策のどれにも当たらない**別の弱点**。

---

## S7 リゾルバの VerifyError

**再現はやらない。** 今の守りで十分に見張られている事を確認した:

- `test/admin/TestApiSurface.flix` が管理 API と Account API の object 型とフィールドの一覧を introspection で読み、SDL と突き合わせる。スキーマが組める事（リゾルバの当て損ない）もここで落ちる。冒頭のコメントに「フィールドを足したら Pg テストの selection にも足す事」と、VerifyError が型検査でもスキーマの組み立てでも出ない事が明記されている
- 全フィールドを選ぶ Pg テスト: `test/Pg/TestAdminMutationsPg.flix`、`test/Pg/TestAccountPg.flix`、`test/Pg/TestPersonalTokenPg.flix`、`test/Pg/TestAssetsPg.flix`、`test/Pg/TestMcpPg.flix`（whoami）
- CI（`.github/workflows/test.yml`）は push ごとに `make check` と `make test-pg` を回す

再現するにはリゾルバのラムダに effect を使う式を書き込む必要があり、それはコードの変更に当たるので、この実験ではやらない。

---

## 対策 5 / 6 / 7 に期待する事

| 対策 | 今の姿（測った物） | 入れた後に見たい物 | 2 回目で比べる指標 |
| --- | --- | --- | --- |
| **5 pool の可視化** | pool を指すログが 0 行。HikariCP は `slf4j-nop` で黙る。「DB が落ちた」「DB が遅い」「pool が満杯」がすべて同じ `retryExhausted timeout 0 after 3 attempts` になる。`/health` にも DB pool の数字が無い | tick ごとに `db.pool.active` / `idle` / `waiting` / `max` の 1 行。リクエストごとに `db.pool.wait_ms` と `db.phase`。`/health` の本文に pool の数字。job にも `job.attempts` / `job.next_attempt_at` / `job.tick.duration_ms` | S1 と S2 のログを**別物として読み分けられるか**。S3 で待ちの本数が数字で出るか |
| **6 自己回復** | OOM の後、プロセスは生きたまま pool が壊れ、PG が健在でも**永久に** `/health` 503。HTTP の接続 43 本も掴まれたまま。`ExitOnOutOfMemoryError` 有りなら exit 3 で落ちるが、最後の行は JSON ではない | `/health` の db が error のまま N 秒続いたら pool を作り直す（または自分で exit する）。fatal な `Throwable` を掴んだら JSON の 1 行を出してから落ちる | S5 (a) の「復帰しない」が**何秒で復帰するか**に変わるか。落ちる時に JSON の行が最後に残るか |
| **7 再接続の backoff** | 再試行 3 回に待ちが無く、borrowTimeout 5 s × 3 = **15 秒**ぶん全リクエストが張り付く。PG が落ちている間、全スレッドが 15 秒ずつ無駄に待つ | 早く諦めて `SERVICE_UNAVAILABLE` を返し、裏で間隔を空けて張り直す。同時 50 本が揃って 15 秒待つ形をやめる | S1・S3b の応答時間（今は 15.02 秒で揃う）。停止中に PG へ張りに行く回数 |

## その他に見つかった弱点

| # | 弱点 | 根拠 | 直す所 |
| --- | --- | --- | --- |
| 1 | **DB の失敗が HTTP 200 で返る**。`errors[].extensions.code = INTERNAL` を読まないと落ちている事が分からない | S1・S3b の `http.response.status_code: 200` + `graphql.error_codes: ["INTERNAL"]` | 監視の側で `graphql.error_codes` を見る、または GraphQL 越しの 5xx を決める |
| 2 | **内部の文言がそのまま外に出る**。`message: "database error: Permanent(retryExhausted timeout 0 after 3 attempts)"` | `load-paused.txt` の応答本文 | `GraphqlErrors`。`INTERNAL` の `message` は固定文にして、詳細は `requestId` でログに寄せる |
| 3 | **`/health` が 20 秒返らない**。Dockerfile の HEALTHCHECK は `--timeout=3s` なので、実際には毎回 timeout 扱いになる | S1・S2・S5 の `duration_ms: 20026` | `Health.ofPool` に短い上限（2 秒程度）を入れる |
| 4 | **クライアントの切断がサーバの error として 500 で記録される**。`request.id` も `url.path` も無い行がノイズになる | `server.log` 70 / 77 / 90 行の `exception.type: java.net.SocketException` `Connection reset` | `HttpServer`。切断は `debug` か、専用の message に |
| 5 | **停止時に HTTP を drain しない**。待つのは job の tick だけ | S6。`shutting down` の後も接続を受け、`System.exit` で切る | `Main` / `HttpServer` |
| 6 | **`jobs drain timed out` でも終了コードが 0** | S6 | `BackgroundJobs.installShutdownHook` |
| 7 | **OOM で HTTP の接続が漏れる**（43/256 が返らないまま） | S5 (a) の `/health` 本文 | `HttpServer` の接続の閉じ方 |
| 8 | **障害の開始と終了の 1 行が無い**。個々のリクエストの error からしか読めない | S1・S2 のログ全体 | 対策 5 と同じ場所 |
| 9 | S3 の枯渇を**この負荷では再現できていない**。2 回目は `maxConnections` を 1〜2 にするか、遅い query を用意する | `load-healthy.txt` / `load-200.txt` | 実験の手順 |
