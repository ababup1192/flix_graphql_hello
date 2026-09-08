# 障害の実験 2 回目（対策 5 / 6 / 7 を入れた後の計測）

2026-09-08。1 回目（[failure-experiment-round1-2026-09-08.md](failure-experiment-round1-2026-09-08.md)）と同じ台本を、
対策 5（pool の可視化）・6（自己回復）・7（再接続の backoff と error.kind）を入れた後に回して前後を比べた。コードは変更していない。

生ログは `/Users/abab/.claude/jobs/4993073b/tmp/failure-round2/` に残す。

| ファイル | 中身 |
| --- | --- |
| `server.log` | S1〜S4・S6 のサーバの JSON ログ |
| `server-oom-noexit.log` | S5（`-Xmx64m`、`CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS=20`。自己回復の否定確認も含む） |
| `probe.log` | 1 秒間隔の /health と通常リクエスト（492 行） |
| `probe.sh` / `load.sh` / `load-oom.sh` / `start.sh` / `start-oom.sh` / `slow-receiver.py` | 使った道具 |
| `load-healthy.txt` / `load-paused.txt` / `load-oom.txt` | 同時リクエストの結果 |
| `s1-single-request.txt` / `s2-single-request.txt` | S1・S2 の 1 本ぶんの応答と所要秒 |
| `s2-health.txt` / `s3-health-samples.txt` | 障害中の `/health` の本文 |
| `sigterm-inflight.txt` | S6 の処理中リクエストの応答 |

## 環境

| 項目 | 値 |
| --- | --- |
| コミット sha | `ecef28d`（1 回目は `bd0b7c7`） |
| sqlfx | `github:ababup1192/sqlfx` **0.3.0**（1 回目は 0.2.0）。`Pool.defaultConfig` = maxConnections 10 / borrowTimeoutMs 5000、`Retry.defaultPolicy` = attempts 3 / baseMs 100 / maxMs 2000 |
| HikariCP | 5.1.0（`slf4j-nop`） |
| pgjdbc | 42.7.4 |
| Flix | 0.75.3。実行は `make fatjar` の `artifact/flix_graphql_hello.jar` |
| JVM | OpenJDK 23、`-Xss32m`（S5 だけ `-Xmx64m`） |
| Docker | `postgres:16` / `minio`（`make db-up`） |
| 起動の環境変数 | Makefile の `PG_ENV` + `CMS_VERSION=dev CMS_LOG_LEVEL=debug`。S5 だけ `CMS_SELF_HEAL=on CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS=20` |
| 通常リクエスト | `POST /admin/graphql`（`X-Dev-User: dev@localhost`）で `{ entries(typeId: "1") { totalCount nodes { id } } }`。公開済みの entry 1 件 |
| データ | `Article`（typeId 1、TEXT の `title` が required）と公開済みの entry `e950032a5be8` |

---

## S1 PG の停止 → 再起動

**操作**: 14:43:13 `docker compose stop postgres` → 14:44:21 `docker compose start postgres`（68 秒）。

**probe の推移**: `/health` も通常リクエストも curl の `--max-time 10` で打ち切られ（`000:10.00`）、PG の起動後に戻る。1 回目と同じ形。

**1 本ぶんの計測**（`s1-single-request.txt`。`--max-time 120`）:

```
{"data":null,"errors":[{"extensions":{"classification":"DataFetchingException","code":"INTERNAL","requestId":"01M1ZRNVR9PYT12R9D9RZJSTFF"},"locations":[{"column":3,"line":1}],"message":"データベースの処理に失敗しました","path":["entries"]}]}
200:15.219469
```

**message が固定文になった**。1 回目は `database error: Permanent(retryExhausted timeout 0 after 3 attempts)` が外に出ていた。詳細は `requestId` でログに寄っている。

**サーバのログ**（`server.log` 37〜38 行）:

```json
{"time":"2026-09-08T05:43:41.944Z","severity":"error","message":"field failed","error.code":"INTERNAL","error.kind":"timeout","error.message":"database error: Permanent(retryExhausted timeout 0 after 3 attempts)","request.id":"01M1ZRNVR9PYT12R9D9RZJSTFF",…}
{"time":"2026-09-08T05:43:41.946Z","severity":"info","message":"request","db.pool.active":0,"db.pool.waiting":3,"db.retries":2,"duration_ms":15217,"graphql.error_codes":["INTERNAL"],"http.response.status_code":200,…}
```

`error.kind` / `db.retries` / `db.pool.waiting` / `db.pool.active` が**全部出た**。

**`/health` の本文**（停止中）:

```json
{"connections":{"active":3,"max":256},"db":"Transient(timeout 0)","jobs":{…},"pool":{"active":0,"idle":0,"max":10,"total":0,"waiting":3},"status":"error","version":"dev"}
```

**復帰**: `docker compose start` 14:44:21 → `/health` が `status: ok` 14:44:26。**約 5 秒**（PG 自身の起動を含む。1 回目の 1〜2 秒との差は PG の起動待ちで、pool の側の差ではない）。

**1 回目との差**:

| 観点 | 1 回目 | 2 回目 | 判定 |
| --- | --- | --- | --- |
| GraphQL の message | 内部の文言が漏れる | `データベースの処理に失敗しました` の固定文 | 良くなった |
| `error.kind` | 無い | `timeout` が出る | 良くなった（ただし S2 と同じ値。下記） |
| `db.retries` | 無い | `2` | 良くなった |
| pool の数字 | 1 行も無い | リクエストの行と `/health` に出る | 良くなった |
| 1 リクエストの所要 | 15.02 秒 | **15.22 秒** | 変わらない（むしろ backoff のぶん微増） |

**backoff が所要時間を縮めなかった理由**: `Retry.defaultPolicy` は `baseMs = 100 / maxMs = 2000` で、full jitter の待ちは
1 回目の再試行が 0〜100 ms、2 回目が 0〜200 ms。合計 0.3 秒までしか増えない。時間を支配しているのは `borrowTimeoutMs = 5000` × 3 回のままで、
**「早く諦めて SERVICE_UNAVAILABLE を返す」形にはなっていない**。

**残る弱点**: DB の失敗が HTTP 200 で返る（`graphql.error_codes` を見ないと分からない）。`/health` が 15〜20 秒返らない（`deploy/README.md` に「sqlfx に borrow の上限を渡す口が無い」として残っている）。

---

## S2 PG が遅い（docker pause）

**操作**: 14:44:40 `docker compose pause postgres` → 14:46:20 `unpause`（100 秒）。

**1 本ぶんの計測**（`s2-single-request.txt`）: 同じ固定文、`200:15.155600`。

**サーバのログ**（`server.log` 85〜86 行）:

```json
{"time":"2026-09-08T05:45:01.315Z","severity":"error","message":"field failed","error.code":"INTERNAL","error.kind":"timeout","error.message":"database error: Permanent(retryExhausted timeout 0 after 3 attempts)","request.id":"01M1ZRR9AKYNFW33C0643ZK8VN",…}
{"time":"2026-09-08T05:45:01.318Z","severity":"info","message":"request","db.retries":2,"duration_ms":15153,…}
```

**`error.kind` では S1 と S2 を区別できない。** どちらも `timeout` になる。`/health` の `pool` も
S1（停止）と S2（pause）で同じ `{"active":0,"idle":0,"total":0,"waiting":3}` だった（`s2-health.txt`）。

**原因**（コードを読んで確認。直していない）: `Pool.borrow`（sqlfx 0.3.0 の `src/Db/Jdbc/Pool.flix:116`）は、
HikariCP が投げる `SQLException` の message に `"request timed out"` が含まれるかどうかだけで種類を分けている。

```flix
if (String.contains(substr = "request timed out", text))
    TransientDbErr.timeout(0)
else
    TransientDbErr.connectionLost(text)
```

HikariCP は接続できない時も上限で待った時も `Connection is not available, request timed out after 5000ms` を出すので、
**borrow の失敗は必ず `timeout` になり、`connectionLost` は出ない**。
`deploy/README.md` の「`connectionLost` なら DB に届いていない（落ちている）、`timeout` なら届くが遅い」は、
少なくとも borrow の段では成り立っていない。

**復帰**: unpause 14:46:20 → `status: ok` 14:46:25（`/health` の 1 本が in-flight だったぶんを含む。実質 0〜5 秒）。

**1 回目との差**: 所要も復帰も変わらない。読み分けの狙いは**達成できていない**。

---

## S3 pool の枯渇

`Pool.defaultConfig` の `maxConnections` を環境変数で下げる口は無い（`DbConfig.poolFromEnv` は
`leakDetectionThresholdMs` だけ上書きし、接続数と待ちは sqlfx の既定のまま）。そこで**PG を pause した状態で同時 50 本**を投げ、
借り待ちを作って測った。

**正常時**（`load-healthy.txt`。同時 50）: 全部 200、最遅 **0.30 秒**（1 回目 0.27 秒）。

**pause 中に同時 50**（`load-paused.txt`）: 全 50 本が HTTP 200 + `INTERNAL`、**15.05〜15.32 秒**。
1 回目の「揃って 15.02 秒」とほぼ同じで、backoff の jitter は 0.3 秒ぶんの散らばりしか作っていない。

**待ちの数が数字で出るか**: **出た。** これが 2 回目の一番の収穫。

`/health`（`s3-health-samples.txt`）:

```json
14:45:40 {"connections":{"active":53,"max":256},"db":"Transient(timeout 0)","pool":{"active":0,"idle":0,"max":10,"total":0,"waiting":53},"status":"error","version":"dev"}
```

リクエストの行にも `db.pool.waiting` が最大 **53** で乗った（`server.log`）。

```json
{"message":"request","db.pool.active":0,"db.pool.waiting":53,"db.retries":2,"duration_ms":15xxx,…}
```

1 回目は「pool を指す行が 0 行」で、待ちが起きているのかどうかすら分からなかった。今は
`waiting` の数字だけで「借り待ちの行列がある」と言える。

**1 回目との差**: 可視化は良くなった。応答時間の形（全員が 15 秒待ってから諦める）は変わらない。

**残る弱点**: `maxConnections` / `borrowTimeoutMs` を環境変数で動かす口が無いので、
「pool は満杯だが DB は健在」という純粋な枯渇（`active = max`、`waiting > 0`、`total = max`）は
この台本では作れない。作るなら遅い query（`pg_sleep`）を打つ口か、`CMS_DB_MAX_CONNECTIONS` が要る。

---

## S4 Webhook の受け手が落ちている

対策の範囲外なので短く。`http://127.0.0.1:19999/hook` に登録し、14:47:00 に再公開。

```json
{"time":"2026-09-08T05:47:01.531Z","severity":"warn","message":"job retry","detail":"接続できませんでした: java.net.ConnectException","error.message":"接続できませんでした: java.net.ConnectException","job.id":"01M1ZRWC35Y3WGM9SKCCP85D2H","job.kind":"webhook","job.outcome":"retry","project":"default","webhook.id":"7d764354178b"}
```

**1 回目とまったく同じ**。公開から 1.5 秒（tick の周期）で `job.outcome = retry`。
1 回目に挙げた `job.attempts` / `job.next_attempt_at` / `job.tick.duration_ms` は**今も無い**。

---

## S5 OOM と自己回復

`-Xmx64m` / `CMS_SELF_HEAL=on` / `CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS=20` で別プロセスを起動（14:48:18）。
warmup は `SelfHeal.defaultWarmupMs()` の 5 分固定で、環境変数の口は無い。

### (a) DB が本当に落ちている時は落ちない事（否定確認）

warmup を過ぎた 14:54:32 に `docker compose stop postgres`、14:57:10 に `start`。
**149 秒**（`minUnhealthyMs` 20 秒 + jitter 上限 30 秒よりずっと長い）止めても、
`self-heal: exiting` の行は **0 行**だった。`SelfHeal.decide` の条件 3（プールを通さない新しい接続では届く）が
偽のままなので終わらない。仕様どおり。

### (b) OOM の後の自己回復（本番）

14:57:24 に 900 KB の `createEntry` を同時 50 本（`load-oom.sh`）。応答は 200 が 13 本、500 が 22 本、接続断が 15 本。

最初の OOM（`server-oom-noexit.log` 751 行）:

```json
{"time":"2026-09-08T05:57:25.589Z","severity":"error","message":"request","duration_ms":207,"exception.message":"Java heap space","exception.type":"java.lang.OutOfMemoryError","exception.stacktrace":"HttpServer.Def$readBody…","http.response.status_code":500,…}
```

以後 1 回目と同じで、プロセスは生き残るのに pool が壊れる。tick も落ちる:

```json
{"time":"2026-09-08T05:58:40.221Z","severity":"error","message":"jobs tick failed","error.message":"回復と掃除ができません: Permanent(retryExhausted timeout 0 after 3 attempts)"}
```

**ここからが 2 回目の差**（888〜890 行）:

```json
{"time":"2026-09-08T05:58:45.241Z","severity":"error","message":"self-heal: exiting","db.pool.active":10,"db.pool.idle":0,"db.pool.max":10,"db.pool.total":10,"db.pool.waiting":3,"reason":"DB の接続プールから 52357 ms 続けて届かず、プールを通さない新しい接続では届いている"}
{"time":"2026-09-08T05:58:45.241Z","severity":"info","message":"shutting down"}
{"time":"2026-09-08T05:58:45.242Z","severity":"info","message":"jobs drained"}
```

- **終了コード 3**（バックグラウンドのプロセスが exit 3 で終わった）
- drain は `jobs drained`（S6 の `jobs drain timed out` と違い、待たずに済んだ）
- `db.pool.active: 10` / `idle: 0` / `total: 10` が**接続の漏れをそのまま示している**。OOM で死んだスレッドが 10 本すべてを掴んだまま返していない。1 回目に「pool が壊れた」としか言えなかった所が、数字で「借りたまま返っていない」と読める
- probe（`probe.log` 485〜489 行）: 14:57:25 から `000`（10 秒の打ち切り）、14:58:46 から `000:0.0003`（接続拒否 = プロセスが消えた）

**OOM から exit までの秒数**: 05:57:25.589 → 05:58:45.241 = **79.7 秒**。
内訳は「不健康が 52.4 秒続く」+「jitter（この回は 0〜30 秒のどこか）」+ 観測の粒度。
観測の粒度は 2 秒ではなく**約 17 秒**になる（`BackgroundJobs.runForever` は `round`（15 秒詰まる tick）の**後**に
`healCheck` を呼ぶので、DB が返らない間は 1 周が 17 秒になる）。`MIN_UNHEALTHY_SECONDS` を 20 に落としても、
実際に効く粒度は 17 秒刻みという事。

**1 回目との差**: **復帰しない → 79.7 秒で自分から exit 3**。本番（compose の `restart: unless-stopped`）なら
ここから再起動が始まる。今回の 3 つの対策の中で、いちばんはっきり効いた。

**残る弱点**: OOM そのものは防げていない（1 MiB の body を 50 本で 64m の heap を使い切る）。
`-XX:+ExitOnOutOfMemoryError` が付いている本番では自己回復より先に JVM が落ち、最後の行は JSON でないままである
（1 回目の S5 (b) と同じ。`deploy/README.md` に記載済み）。自己回復が効くのは
`ExitOnOutOfMemoryError` が無い時か、OOM 以外で pool が壊れた時。

---

## S6 処理中の SIGTERM

対策の範囲外。1 回目と同じ手順（PG を pause して 15 秒掛かるリクエストを 1 本投げ、その最中に `kill -TERM`）。

**操作**: 14:47:28.593 に `kill -TERM`。

```json
{"time":"2026-09-08T05:47:28.595Z","severity":"info","message":"shutting down"}
{"time":"2026-09-08T05:47:39.204Z","severity":"warn","message":"request","duration_ms":20240,"http.response.status_code":503,"url.path":"/health"}
{"time":"2026-09-08T05:47:40.031Z","severity":"error","message":"field failed","error.code":"INTERNAL","error.kind":"timeout","request.id":"01M1ZRX4AZQANGGTZP2X4787MH"}
{"time":"2026-09-08T05:47:40.033Z","severity":"info","message":"request","db.retries":2,"duration_ms":15138,"graphql.error_codes":["INTERNAL"],"http.response.status_code":200,…}
{"time":"2026-09-08T05:47:43.658Z","severity":"warn","message":"jobs drain timed out (claimed_at で拾い直す)"}
```

| 項目 | 1 回目 | 2 回目 |
| --- | --- | --- |
| `shutting down` | シグナルの 2 ms 後 | シグナルの **2 ms 後** |
| 処理中のリクエスト | 完走（15.05 秒） | 完走（15.14 秒） |
| drain | `jobs drain timed out` | `jobs drain timed out` |
| 終了コード | 0 | **0** |
| 終了までの秒数 | 15.49 秒 | **約 15.1 秒** |

**まったく変わらない。** 1 回目に挙げた弱点（HTTP を drain しない、`shutting down` の後の接続を 503 で断らない、
drain が timeout でも終了コード 0）はそのまま残っている。

---

## 1 回目 → 2 回目の比較表

| # | 障害 | 復帰秒数 1 回目 | 復帰秒数 2 回目 | 出た行 1 回目 | 出た行 2 回目 | 判定 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | PG の停止 → 再起動 | PG 起動から 1〜2 秒。1 リクエスト 15.02 秒 | PG 起動から約 5 秒（PG 自身の起動込み）。1 リクエスト **15.22 秒** | `field failed`（内部の文言が message に漏れる） | `error.kind=timeout` / `db.retries=2` / `db.pool.waiting=3` / `db.pool.active=0`、message は固定文 | ログは良くなった / 時間は変わらない |
| 2 | PG の pause → unpause | unpause から 0〜1 秒。15.02 秒 | unpause から 0〜5 秒。**15.16 秒** | S1 と同一 | **S1 と同一（`error.kind` も `timeout` で同じ）** | 変わらない（狙いは未達） |
| 3 | 同時 50（正常） | 全部 200、最遅 0.27 秒 | 全部 200、最遅 **0.30 秒** | pool の行なし | — | 変わらない |
| 3b | pause 中に同時 50 | 全部 `INTERNAL`、揃って 15.02 秒 | 全部 `INTERNAL`、**15.05〜15.32 秒** | pool の行なし | `/health` の `pool.waiting = 53`、リクエストの行の `db.pool.waiting = 53` | **可視化は大きく良くなった** / 時間は変わらない |
| 4 | Webhook の受け手なし | 2 秒で `job retry`、以後 1 分 → 5 分 → … | 1.5 秒で `job retry`（同じ） | `job.kind` / `job.outcome` / `webhook.id` | 同じ（`job.attempts` は今も無い） | 変わらない |
| 5 | OOM（ExitOnOOM 無し） | **復帰しない**（2 分観測して回復せず） | **79.7 秒で自分から終了（exit 3）** | `exception.type=OutOfMemoryError` だけ | `self-heal: exiting` に `reason` と `db.pool.active=10 / idle=0 / total=10 / waiting=3`、`jobs drained` | **良くなった** |
| 5c | DB 停止中の自己回復 | （対策なし） | 149 秒止めても **落ちない**（0 行） | — | — | 仕様どおり |
| 6 | 処理中の SIGTERM | 15.49 秒、exit 0、`jobs drain timed out` | 約 15.1 秒、exit 0、`jobs drain timed out` | 同じ | 同じ | 変わらない |

## 残る弱点

| # | 弱点 | 根拠 | 直す所 | 1 回目から |
| --- | --- | --- | --- | --- |
| 1 | **`error.kind` が `connectionLost` にならない**。borrow の失敗は HikariCP の message に `request timed out` が入るので必ず `timeout`。「DB が落ちた」と「DB が遅い」は今もログで読み分けられない。`deploy/README.md` の説明と実際が食い違う | S1・S2 の `field failed` が両方 `error.kind: "timeout"`。sqlfx 0.3.0 `src/Db/Jdbc/Pool.flix:116` の `borrow` | sqlfx の `borrow`（`SQLTransientConnectionException` の cause を見る）か、cms 側で pool の `total = 0` と併せて判定 | 新規（対策 7 の狙いが未達） |
| 2 | **backoff が待ち時間を支配していない**。`baseMs 100 / maxMs 2000` に対し `borrowTimeoutMs` が 5000 なので、3 回で 15 秒に張り付く形は変わらない。「早く諦める」形になっていない | S1・S2・S3b の所要が 15.0〜15.3 秒 | `Retry.defaultPolicy` を渡し直すか、`DbRunner` が pool の `waiting` を見て即 `SERVICE_UNAVAILABLE` を返す | 新規（対策 7 の狙いが未達） |
| 3 | **DB の失敗が HTTP 200 で返る**。`graphql.error_codes` を読まないと落ちている事が分からない | S1・S3b の `http.response.status_code: 200` | 監視で `graphql.error_codes` を見る、または GraphQL 越しの 5xx を決める | 1 回目から |
| 4 | **`/health` が 15〜20 秒返らない**。Dockerfile の `HEALTHCHECK --timeout=3s` は毎回 timeout 扱い | S1・S2・S6 の `duration_ms: 20240` | sqlfx に borrow の上限を渡す口（`deploy/README.md` に理由付きで残っている） | 1 回目から |
| 5 | **停止時に HTTP を drain しない**。終了コードは `jobs drain timed out` でも 0 | S6 | `Main` / `HttpServer` / `BackgroundJobs.installShutdownHook` | 1 回目から |
| 6 | **OOM で HTTP と DB の接続が漏れる**。今回は `db.pool.active: 10 / total: 10` が返らないまま | S5 の `self-heal: exiting` の行 | `HttpServer` の接続の閉じ方（自己回復は「漏れた事」を見せるだけで塞いではいない） | 1 回目から（見え方だけ改善） |
| 7 | **自己回復の観測の粒度が約 17 秒**。`healCheck` は 15 秒詰まる `round` の後に呼ばれるので、`MIN_UNHEALTHY_SECONDS` を小さくしても 17 秒刻みでしか反応しない | `BackgroundJobs.runForever` / S5 の 79.7 秒 | `healCheck` を tick と別の周にする | 新規 |
| 8 | **warmup（5 分）を環境変数で動かせない**。実験や短命なコンテナでは長い | `SelfHeal.defaultWarmupMs()` が 300000 固定 | `SelfHeal.settingsFrom` に環境変数を足す | 新規 |
| 9 | **job の属性が足りない**。`job.attempts` / `job.next_attempt_at` / `job.tick.duration_ms` が今も無い | S4 | `JobLog` / `WebhookDispatcher` | 1 回目から |
| 10 | **`maxConnections` / `borrowTimeoutMs` を環境変数で渡せない**。純粋な枯渇（`active = max` で DB は健在）を作れず、負荷に合わせた調整もできない | S3。`DbConfig.poolFromEnv` は leak のしきい値だけ上書き | `DbConfig` に `CMS_DB_MAX_CONNECTIONS` / `CMS_DB_BORROW_TIMEOUT_MS` | 1 回目から |
