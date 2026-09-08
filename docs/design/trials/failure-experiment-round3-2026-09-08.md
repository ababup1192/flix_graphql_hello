# 障害の実験 3 回目（早く諦める・自己回復の 2 秒刻み・HTTP の drain を入れた後の計測）

2026-09-08。2 回目（[failure-experiment-round2-2026-09-08.md](failure-experiment-round2-2026-09-08.md)）と同じ台本で
シナリオ 1 / 2 / 3b / 5 / 6 だけを測り直した。間に入った変更は次の 4 つ。

| コミット | 中身 |
| --- | --- |
| `2702fc0` | DB が落ちている時に 15 秒張り付かず 7〜8 秒で諦める（`CMS_DB_MAX_CONNECTIONS` / `CMS_DB_BORROW_TIMEOUT_SECONDS`。既定 10 / 2 秒） |
| `c334dd6` | 自己回復の観測を仕事の周から切り離して 2 秒刻みにする（`BackgroundJobs.watchForever` を別スレッドで spawn） |
| `85521d8` | 停止で HTTP も drain し、待ち切れなければ終了コード 2（`CMS_SHUTDOWN_TIMEOUT_SECONDS`。既定 20 秒） |
| `3add147` | sqlfx 0.3.1。borrow の失敗を pool の stats と cause で `timeout` / `connectionLost` に分ける |

生ログは `/Users/abab/.claude/jobs/4993073b/tmp/failure-round3/` に残す。

| ファイル | 中身 |
| --- | --- |
| `server.log` | S1・S2・S3b（既定の pool）のサーバの JSON ログ |
| `server-max2.log` | `CMS_DB_MAX_CONNECTIONS=2` の回 |
| `server-sigterm.log` / `server-sigterm-clean.log` / `server-sigterm-t5.log` | S6 の 3 回（既定 20 秒・正常時・`CMS_SHUTDOWN_TIMEOUT_SECONDS=5`） |
| `server-oom-run1.log` / `server-oom-noexit.log` | S5 の 1 回目・2 回目 |
| `probe.log` | 1 秒間隔の `/health` と通常リクエスト（511 行） |
| `probe.sh` / `load.sh` / `load-oom.sh` / `start.sh` / `start-max2.sh` / `start-shut5.sh` / `start-oom.sh` | 使った道具（2 回目からの写し。パスと環境変数だけ変えた） |
| `load-healthy.txt` / `load-paused.txt` / `load-max2-*.txt` / `load-oom*.txt` | 同時リクエストの結果 |
| `s1-single-request.txt` / `s2-single-request.txt` / `s1-health.txt` / `s2-health.txt` / `s3b-max2-health.txt` | 1 本ぶんの応答と障害中の `/health` |
| `sigterm-inflight.txt` / `sigterm-t5-inflight.txt` | S6 の処理中リクエストの応答 |

## 環境

| 項目 | 値 |
| --- | --- |
| コミット sha | `3add147`（2 回目は `ecef28d`、1 回目は `bd0b7c7`） |
| sqlfx | `github:ababup1192/sqlfx` **0.3.1**（2 回目は 0.3.0、1 回目は 0.2.0） |
| pool の既定 | maxConnections 10 / borrowTimeoutMs **2000**（2 回目は 5000）。`Retry.defaultPolicy` は attempts 3 / baseMs 100 / maxMs 2000 |
| HikariCP | 5.1.0（`slf4j-nop`）。pgjdbc 42.7.4 |
| Flix | 0.75.3。実行は `make fatjar` の `artifact/flix_graphql_hello.jar` |
| JVM | OpenJDK 23、`-Xss32m`（S5 だけ `-Xmx64m`） |
| Docker | `postgres:16` / `minio`（`make db-up`） |
| 起動の環境変数 | 2 回目と同じ。S5 だけ `CMS_SELF_HEAL=on CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS=20 CMS_SELF_HEAL_WARMUP_SECONDS=10` |
| 通常リクエスト | `POST /admin/graphql`（`X-Dev-User: dev@localhost`）で `{ entries(typeId: "1") { totalCount nodes { id } } }` |
| データ | `Article`（typeId 1、TEXT の `title` が required）と公開済みの entry `0940f0574ffc` |

---

## S1 PG の停止 → 再起動

**操作**: 15:23:43 `docker compose stop postgres` → 15:24:14 `docker compose start postgres`（31 秒）。

**1 本ぶんの計測**（`s1-single-request.txt`。`--max-time 120`）:

```
{"data":null,"errors":[{"extensions":{"classification":"DataFetchingException","code":"INTERNAL","requestId":"01M1ZTZRB80J5N6569PR75QJBE"},"locations":[{"column":3,"line":1}],"message":"データベースの処理に失敗しました","path":["entries"]}]}
200:6.314131
```

**15.22 秒 → 6.31 秒**。`borrowTimeoutMs` を 5000 から 2000 に落とした 3 回ぶん（6 秒）+ backoff（0.3 秒）で、狙いどおりの形。

**サーバのログ**（`server.log` 29〜30 行）:

```json
{"time":"2026-09-08T06:23:54.384Z","severity":"error","message":"field failed","error.code":"INTERNAL","error.kind":"connectionLost","error.message":"database error: Permanent(retryExhausted connectionLost HikariPool-1 - Connection is not available, request timed out after 2004ms (total=0, active=0, idle=0, waiting=3) after 3 attempts)","request.id":"01M1ZTZRB80J5N6569PR75QJBE",…}
{"time":"2026-09-08T06:23:54.385Z","severity":"info","message":"request","db.pool.active":0,"db.pool.waiting":3,"db.retries":2,"duration_ms":6312,"graphql.error_codes":["INTERNAL"],"http.response.status_code":200,…}
```

**`error.kind` が `connectionLost` になった**（2 回目は `timeout`）。sqlfx 0.3.1 が
`total=0`（プールは空いているのに接続が作れない）を見て分けている。`error.message` にその時の stats がそのまま入るので、
ログ 1 行で「プールは空で、DB に届いていない」まで読める。

**`/health` の本文**（停止中。`s1-health.txt`）:

```json
{"connections":{"active":2,"max":256},"db":"Transient(connectionLost HikariPool-1 - Connection is not available, request timed out after 2003ms (total=0, active=0, idle=0, waiting=3))","jobs":{"failedDeliveries":-1,…},"pool":{"active":0,"idle":0,"max":10,"total":0,"waiting":3},"status":"error","version":"dev"}
```

**probe の推移**（`probe.log` 9 行・11 行）: 停止の直後の `/health` が **`503:8.351966`**。
2 回目は `000:10.00`（curl の打ち切り）だったので、**遅いなりに 503 を返すようになった**。

```
15:23:44 health=503:8.351966 req=…INTERNAL… 200:6.470706
15:24:15 health=200:3.315535 req={"data":{"entries":…}} 200:0.035702
```

**復帰**: `docker compose start` 15:24:14.4 → 次の probe の周（15:24:15）でもう `200`。**約 1 秒**。
（別に測った `/health` のポーリングでは 4.9 秒だったが、これは in-flight の 1 本を待っていたぶんで、実際の復帰は 1 秒。）

---

## S2 PG が遅い（docker pause）

**操作**: 15:24:23 `docker compose pause postgres` → 15:25:30 `unpause`（67 秒）。

**1 本ぶんの計測**（`s2-single-request.txt`）: 同じ固定文、**`200:12.495363`**。

**サーバのログ**（`server.log` 53〜54 行）:

```json
{"time":"2026-09-08T06:24:40.915Z","severity":"error","message":"field failed","error.code":"INTERNAL","error.kind":"connectionLost","error.message":"database error: Permanent(retryExhausted connectionLost HikariPool-1 - Connection is not available, request timed out after 2005ms (total=0, active=0, idle=0, waiting=3) after 3 attempts)","request.id":"01M1ZV0ZR6K6Y5VH4HSFSW6TEV",…}
{"time":"2026-09-08T06:24:40.916Z","severity":"info","message":"request","db.retries":2,"duration_ms":12494,…}
```

**「停止と pause が kind で分かれるか」の答え: 分かれない。** どちらも `connectionLost` になる。
理由は 2 回目とは逆で、**pause でもプールが空になる**ため。pause の間に HikariCP が持っていた接続は
検証に失敗して捨てられ、`total` が 0 に落ちる。0.3.1 の規則（プールが満杯でないなら `connectionLost`）に照らせば
これは正しい判定で、「DB に届いていない」という意味自体は pause でも合っている。
分かれないのは `timeout`（借り待ちの上限）と `connectionLost` の対比であって、
**停止と pause は元々この 2 値で分ける物ではなかった**、というのが今回の答え。

読み分けの手掛かりになるのは **所要時間**の方だった。停止は 6.31 秒（接続の拒否が即返る）、
pause は 12.49 秒（TCP は繋がるので、pgjdbc の startup が返らないぶん 1 回あたり 2 秒を超える）。
`duration_ms` で 2 倍の差が付く。

**`/health`**（`s2-health.txt`）: `pool` は S1 と同じ `{"active":0,"idle":0,"max":10,"total":0,"waiting":3}`。

**復帰**: unpause 15:25:30.9 → `status: ok` 15:25:35.2。**約 4.3 秒**（in-flight の 1 本を含む）。

---

## S3b pool の待ちと枯渇

### (a) 正常時の同時 50（`load-healthy.txt`）

全部 200、最遅 **0.29 秒**（2 回目 0.30 秒、1 回目 0.27 秒）。変わらない。

### (b) pause 中に同時 50（`load-paused.txt`）

全 50 本が HTTP 200 + `INTERNAL`、**6.02〜6.54 秒**（2 回目は 15.05〜15.32 秒）。

`error.kind` は **50 本すべて `connectionLost`**。`db.pool.waiting` は最大 **52**。

```json
{"message":"request","db.pool.active":0,"db.pool.waiting":51,"db.retries":2,"duration_ms":6xxx,…}
```

### (c) `CMS_DB_MAX_CONNECTIONS=2` の回（`server-max2.log`）

`/health` の `pool.max` が 2 になり、環境変数の口が効く事を確認した。

| 負荷 | 結果 | 最大 `db.pool.waiting` | `error.kind` |
| --- | --- | --- | --- |
| 正常時 同時 100 | 全部 200、最遅 0.92 秒 | 98 | 失敗 0 |
| 正常時 同時 250 | 全部 200、最遅 1.89 秒 | — | 失敗 0 |
| 正常時 同時 400 | 200 が 319 本、**503 が 81 本**（0.001 秒で即断） | — | 失敗 0 |
| pause 中 同時 50 | 全部 `INTERNAL`、6.08〜6.54 秒 | 38（`/health` の `pool.waiting`） | **50 本とも `connectionLost`** |

**`error.kind` が `timeout` になる回は 1 度も作れなかった。** 理由が 2 つある。

1. **DB が落ちている / 止まっている間は、プールが空になるので必ず `connectionLost`**。
   「プールが満杯で借り待ち」は起きようがない
2. **DB が健在なら、HTTP の接続数の上限（256）が先に効く**。同時 400 のうち 81 本は
   `503:0.001` で即断られ、DB まで届く同時数が 256 で頭打ちになる。
   max 2 のプールに 256 本を当てても最遅 1.89 秒で、借り待ちの上限 2 秒に届かなかった

つまり **`timeout` が出るのは「遅い SQL で接続が長く占有されている」か「接続が漏れている」時だけ**で、
今の台本（軽い query）では作れない。`pg_sleep` を打てる口か、`CMS_DB_BORROW_TIMEOUT_SECONDS=1` まで下げる必要がある。

---

## S5 OOM と自己回復

`-Xmx64m` / `CMS_SELF_HEAL=on` / `CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS=20` / `CMS_SELF_HEAL_WARMUP_SECONDS=10`。
warmup が環境変数で動くようになったので、2 回目のように 5 分待つ必要はなくなった。900 KB の `createEntry` を同時 50 本。

**目標は「`self-heal: exiting` まで 20〜25 秒」（2 回目は 79.7 秒）。結果は 2 回とも `self-heal: exiting` が 0 行で、
プロセスは終わらなかった。** 2 回目より悪化している。

### 1 回目（`server-oom-run1.log`）15:31:18 に負荷

応答は 200 が 10 本、500 が 24 本、接続断が 16 本。最初の OOM（254 行）:

```json
{"time":"2026-09-08T06:31:20.308Z","severity":"error","message":"request","duration_ms":646,"exception.message":"Java heap space","exception.type":"java.lang.OutOfMemoryError","http.request.body.size":900117,"http.response.status_code":500,…}
```

その後、通常のリクエストは 200 で返り続けたが、`/health` の `jobs.lastTickAt` が
**`2026-09-08T06:31:17.961Z`（OOM の 2 秒前）で止まったまま 3 分以上動かなかった**。

```
06:32:26 → lastTickAt=2026-09-08T06:31:17.961Z status=ok pool={'active':10,'idle':0,'max':10,'total':10,'waiting':0}
06:34:21 → lastTickAt=2026-09-08T06:31:17.961Z status=ok pool={'active':9,'idle':1,'max':10,'total':10,'waiting':0}
```

**仕事のスレッド（`BackgroundJobs.runForever`）が OOM で死んで、二度と戻らない。**
それでも `/health` は `status: ok` を返す。予約公開も webhook の配信も止まったままなのに、
外からは健康に見える。

### 2 回目（`server-oom-noexit.log`）15:34:59 に負荷

こちらは 2 回目の実験と同じ壊れ方をした。プールは壊れ、仕事のスレッドは生き残った。

```
06:36:04 → lastTickAt=2026-09-08T06:36:04.499Z status=error pool={'active':10,'idle':0,'max':10,'total':10,'waiting':1}
06:41:19 → lastTickAt=2026-09-08T06:41:19.137Z status=error pool={'active':10,'idle':0,'max':10,'total':10,'waiting':2}
```

`status: error` かつ `active = max = 10`（接続の漏れ）が **5 分以上**続いたのに、
`self-heal` の行は **1 行も出ず**、プロセスは生き続けた（`grep -c "self-heal" = 0`）。
`minUnhealthyMs`（20 秒）+ jitter（上限 30 秒）を足しても 50 秒なので、5 分は明らかに超えている。

### バグ 1: OOM の後、自己回復の見張りが二度と動かない（再現あり）

**仕様**: `SelfHeal.decide` の 4 条件（warmup を過ぎ・`minUnhealthyMs` 続けて ping が失敗し・
プールを通さない接続では届き・jitter も過ぎた）が揃えば `self-heal: exiting` + 終了コード 3。

**実際**: 2 回とも条件は揃っているのに 1 行も出ない。`c334dd6` が見張りを
`spawn BackgroundJobs.watchForever(...)`（`src/Main.flix:108`）の**別スレッド**に移したので、
**そのスレッドが OOM で死ぬと、誰も気付かず自己回復が永久に無効になる**。
2 回目の実験で効いたのは、見張りが仕事の周（`runForever`）に相乗りしていて、
そちらは生き残ったからだった。粒度（17 秒 → 2 秒）と引き換えに、効く場面そのものを失っている。

**再現の行**:

- `server-oom-run1.log` 254 行の `"exception.type":"java.lang.OutOfMemoryError"` の後、
  `/health` の `jobs.lastTickAt` が `2026-09-08T06:31:17.961Z` で固定（3 分観測）
- `server-oom-noexit.log` は `status: error` / `active=10` が 5 分続いても `self-heal` が 0 行

**直す所**: `BackgroundJobs.watchForever` / `runForever` を spawn しっぱなしにせず、
死んだら作り直す（Java の `UncaughtExceptionHandler` か、`Main` が生存を見張る）。
`spawn` した木の中で `Throwable` を受けて自分で回り直すのでも良い。

### バグ 2: 仕事のスレッドが死んでいても `/health` が `ok` を返す（再現あり）

`server-oom-run1.log` の状態。`Health` は DB の ping しか見ておらず、`jobs.lastTickAt` の古さを判定に使っていない。
`lastTickAt` は本文に出るので、監視側で「今より 30 秒以上古ければ異常」と読む事はできるが、
`/health` の `status` と Docker の `HEALTHCHECK` は騙される。

**直す所**: `Health.ofPool` の `status` に「`lastTickAt` が `intervalMs` の数倍より古くないか」を足す。

---

## S6 処理中の SIGTERM

3 通り測った。

### (a) 正常時（`server-sigterm-clean.log`）

15:28:20.493 に `kill -TERM`。

```json
{"time":"2026-09-08T06:28:20.495Z","severity":"info","message":"shutting down","service":"cms","version":"dev"}
{"time":"2026-09-08T06:28:20.497Z","severity":"info","message":"jobs drained","service":"cms","version":"dev"}
```

`jobs drained`、**終了コード 0**、シグナルから 4.26 秒で消えた。

### (b) 処理中のリクエストあり・既定の 20 秒（`server-sigterm.log`）

PG を pause して 12 秒掛かるリクエストを 1 本投げ、その 2 秒後（15:27:34.281）に `kill -TERM`。

```json
{"time":"2026-09-08T06:27:34.283Z","severity":"info","message":"shutting down"}
{"time":"2026-09-08T06:27:44.680Z","severity":"error","message":"field failed","error.kind":"connectionLost","request.id":"01M1ZV6K9RS1JA7X3KTPHSE7QZ"}
{"time":"2026-09-08T06:27:44.692Z","severity":"info","message":"request","db.retries":2,"duration_ms":12412,"http.response.status_code":200,…}
{"time":"2026-09-08T06:27:47.607Z","severity":"warn","message":"request","duration_ms":20518,"http.response.status_code":503,"url.path":"/health"}
{"time":"2026-09-08T06:27:54.350Z","severity":"warn","message":"jobs drain timed out (claimed_at で拾い直す)"}
{"time":"2026-09-08T06:27:54.352Z","severity":"warn","message":"shutdown timed out","shutdown.connections":0,"shutdown.in_tick":true}
```

| 観点 | 結果 |
| --- | --- |
| listen が閉じるか | **閉じた**。`shutting down` の直後の新しい接続は `000:0.000195`（接続拒否）。2 回目からの改善 |
| 処理中のリクエスト | **完走**（12.41 秒、応答は `sigterm-inflight.txt`） |
| HTTP の drain | **できた**（`shutdown.connections: 0`） |
| 出た行 / 終了コード | `shutdown timed out` / **2** |

**終了コード 2 の原因は HTTP ではなく仕事の tick** で、`shutdown.in_tick: true` がそれを名指ししている。
PG が pause のままなので tick が 15 秒級で詰まり、20 秒の上限に間に合わなかった。
つまり **DB が止まっている最中の停止は、HTTP を待ち切れても必ず exit 2 になる**。

### (c) `CMS_SHUTDOWN_TIMEOUT_SECONDS=5`（`server-sigterm-t5.log`）

同じ形で 15:28:48.132 に `kill -TERM`。

```json
{"time":"2026-09-08T06:28:48.134Z","severity":"info","message":"shutting down"}
{"time":"2026-09-08T06:28:53.209Z","severity":"warn","message":"jobs drain timed out (claimed_at で拾い直す)"}
{"time":"2026-09-08T06:28:53.210Z","severity":"warn","message":"shutdown timed out","shutdown.connections":2,"shutdown.in_tick":true}
```

5.08 秒で `shutdown timed out`、**終了コード 2**。今度は `shutdown.connections: 2` で、
**処理中のリクエストが 2 本残ったまま切られた**（`sigterm-t5-inflight.txt` は `000:7.463035` = 接続断）。
`CMS_SHUTDOWN_TIMEOUT_SECONDS` を短くすると処理中のリクエストを捨てる、という代償が数字で出る。

---

## 1 → 2 → 3 回目の比較表

| # | 障害 | 1 回目 | 2 回目 | 3 回目 | 判定 |
| --- | --- | --- | --- | --- | --- |
| 1 | PG の停止 → 再起動 | 1 リクエスト 15.02 秒。`error.kind` 無し。message に内部の文言 | 15.22 秒。`error.kind=timeout` | **6.31 秒**。`error.kind=connectionLost`、`error.message` に stats、`/health` は `503:8.35`（打ち切りでない）。復帰 約 1 秒 | **良くなった** |
| 2 | PG の pause → unpause | 15.02 秒 | 15.16 秒、`timeout`（S1 と同一） | **12.49 秒**、`connectionLost`（S1 と同一）。差は所要時間に出る（6.3 秒 vs 12.5 秒） | 時間は良くなった / kind での読み分けは**成立しない** |
| 3 | 同時 50（正常） | 最遅 0.27 秒 | 0.30 秒 | 0.29 秒 | 変わらない |
| 3b | pause 中に同時 50 | 揃って 15.02 秒、pool の行なし | 15.05〜15.32 秒、`waiting=53` | **6.02〜6.54 秒**、`waiting=52`、全部 `connectionLost` | **良くなった** |
| 3c | `CMS_DB_MAX_CONNECTIONS=2` | 口が無い | 口が無い | **口が効く**（`pool.max=2`、`waiting` 98）。ただし `timeout` は再現できず | 口は良くなった / `timeout` は未確認 |
| 5 | OOM（ExitOnOOM 無し） | 復帰しない | **79.7 秒で exit 3** | **2 回とも exit せず**。1 回目は仕事のスレッドが死んで `/health` は `ok` のまま、2 回目は `status: error` が 5 分続いても `self-heal` が 0 行 | **悪化（回帰）** |
| 6 | 処理中の SIGTERM | 15.49 秒、exit 0、`jobs drain timed out`、HTTP は drain しない | ほぼ同じ | **listen が閉じ、HTTP を drain する**。正常時は `jobs drained` + exit 0。DB が止まっていると `shutdown timed out` + **exit 2**（`shutdown.in_tick: true`）。`=5` にすると `shutdown.connections: 2` で処理中を捨てる | **良くなった** |

## 残る弱点

| # | 弱点 | 根拠 | 直す所 | いつから |
| --- | --- | --- | --- | --- |
| 1 | **OOM の後、自己回復が永久に無効になる**。見張りを別スレッドに移したので、そのスレッドが OOM で死ぬと誰も気付かない。2 回目に効いた対策が効かなくなった | S5 の 2 回とも `self-heal` が 0 行。`status: error` / `active=10` が 5 分続いても終わらない | `Main.flix:108` の `spawn` を死んだら作り直す形にする（`UncaughtExceptionHandler` か生存の見張り） | **3 回目（回帰）** |
| 2 | **仕事のスレッドが死んでも `/health` が `ok`**。予約公開も webhook も止まっているのに外からは健康に見える | S5 の 1 回目。`lastTickAt` が 3 分止まったまま `status: ok` | `Health.ofPool` の `status` に `lastTickAt` の古さを足す | **3 回目（新規）** |
| 3 | **`error.kind` の `timeout` を作れない**。DB が落ちている間はプールが空なので必ず `connectionLost`、DB が健在なら HTTP の 256 接続が先に効いて借り待ちが 2 秒に届かない。`timeout` が出るのは「遅い SQL」か「接続の漏れ」だけ | S3b (c) の 4 通り全部。同時 400 で 81 本が `503:0.001` | 遅い SQL を打てる口か `CMS_DB_BORROW_TIMEOUT_SECONDS=1` で確かめる。仕様の問題ではない | 3 回目（2 回目の #1 は解消） |
| 4 | **停止と pause が `error.kind` で分かれない**。どちらも `connectionLost`。読み分けは `duration_ms`（6 秒 vs 12 秒）でしかできない | S1・S2 | 分けたいなら pgjdbc の `loginTimeout` を短くして cause を残す。今の `deploy/README.md` の説明（借り待ち vs 届かない）自体は正しい | 2 回目から（意味は変わった） |
| 5 | **DB の失敗が HTTP 200 で返る**。`graphql.error_codes` を読まないと落ちている事が分からない | S1・S3b の `http.response.status_code: 200` | 監視で `graphql.error_codes` を見る、または GraphQL 越しの 5xx を決める | 1 回目から |
| 6 | **`/health` が DB の停止中に 6〜8 秒返る**。`503` は返すようになったが、Dockerfile の `HEALTHCHECK --timeout=3s` には今も間に合わない | S1 の probe `health=503:8.351966` | `CMS_DB_BORROW_TIMEOUT_SECONDS=1` にするか、`HEALTHCHECK --timeout` を伸ばす | 1 回目から（軽くなった） |
| 7 | **OOM で HTTP と DB の接続が漏れる**。`active=10 / total=10` が返らないまま、HTTP も `connections.active` が 34 に張り付いた | S5 の両方 | `HttpServer` の接続の閉じ方 | 1 回目から |
| 8 | **DB が止まっている最中の停止は必ず exit 2**。tick が詰まって drain の上限に間に合わない（`shutdown.in_tick: true`） | S6 (b) の 20 秒でも間に合わない | tick に停止用の短い上限を持たせる | 3 回目（新規。HTTP の drain は解決した） |
| 9 | **job の属性が足りない**。`job.attempts` / `job.next_attempt_at` / `job.tick.duration_ms` が今も無い | 1・2 回目の S4 | `JobLog` / `WebhookDispatcher` | 1 回目から |
