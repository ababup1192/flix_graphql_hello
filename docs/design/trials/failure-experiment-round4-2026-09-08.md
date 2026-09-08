# 障害の実験 4 回目（OOM の後も自己回復が効くかの再計測）

2026-09-08。3 回目（[failure-experiment-round3-2026-09-08.md](failure-experiment-round3-2026-09-08.md)）の S5 で
**OOM の後に自己回復が永久に無効になる回帰**（見張りのスレッドが死ぬと誰も気付かない）が出た。
その直しが入ったので、**S5 だけ**を同じ台本で測り直した。コードは触っていない。

| コミット | 中身 |
| --- | --- |
| `b7efa55` | OOM で見張りのスレッドが死んでも自己回復が効くようにする（`SelfHeal.step` を `/health` からも進める。`SelfHeal.Watch#exiting` の印で終わりの道は 1 回だけ） |
| `6360adc` | 仕事の周が死んでいる時に `/health` を 503 にする（`Health.Stall` の `jobs stalled` / `watch stalled`、`stallLimitMs` = 間隔の 3 倍か 30 秒の大きい方） |

3 回目は Docker の `HEALTHCHECK` を模していなかったので、今回は **`/health` を 10 秒ごとに叩き続けた**。
見張りのスレッドが死んでも `/health` から `step` が進む事を見るのが目的。

生ログは `/Users/abab/.claude/jobs/4993073b/tmp/failure-round4/`。

| ファイル | 中身 |
| --- | --- |
| `server-oom-run1.log` 〜 `server-oom-run7.log` | S5 の 7 回ぶんのサーバの JSON ログ |
| `probe-run1.log` 〜 `probe-run7.log` / `probe-control.log` | 10 秒ごとの `/health`（本文と `%{http_code}:%{time_total}`） |
| `server-control.log` / `probe-control.log` | 対照 4（PG 停止）と対照 5（正常時 2 分） |
| `run*-exit.txt` | 各回のプロセスの終了コードと時刻 |
| `load-run*.txt` / `run*-load-at.txt` | 同時 50 本の応答と、負荷を掛けた時刻 |
| `start-oom.sh` / `probe.sh` / `load-oom.sh` / `big900.json` | 使った道具（3 回目からの写し。probe だけ 10 秒間隔に変えた） |

## 環境

| 項目 | 値 |
| --- | --- |
| コミット sha | `6360adc`（3 回目は `3add147`、2 回目は `ecef28d`） |
| sqlfx | `github:ababup1192/sqlfx` 0.3.1 |
| pool の既定 | maxConnections 10 / borrowTimeoutMs 2000 |
| HikariCP | 5.1.0。pgjdbc 42.7.4 |
| Flix | 0.75.3。実行は `make fatjar` の `artifact/flix_graphql_hello.jar`（この計測のために作り直した） |
| JVM | OpenJDK 23.0.1、`-Xss32m -Xmx64m`。**`-XX:+ExitOnOutOfMemoryError` は付けない** |
| Docker | `postgres:16` / `minio`（`make db-up` → `make migrate`） |
| 起動の環境変数 | 3 回目の S5 と同じ。`CMS_SELF_HEAL=on CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS=20 CMS_SELF_HEAL_WARMUP_SECONDS=10 CMS_AUTH=dev CMS_LOG_LEVEL=debug` |
| 負荷 | 900 KB の `createEntry` を同時 50 本（`load-oom.sh`） |
| データ | `Post`（typeId 1、TEXT の `title`）。新しい DB に `createContentType` + `addField` で作った |
| probe | `GET /health` を 10 秒ごと（`--max-time 10`） |

`BackgroundJobs.intervalMs()` も `healIntervalMs()` も 2000 ミリ秒なので、
`stallLimitMs` はどちらも 30 秒（`Int64.max(6000, 30000)`）。

---

## S5 OOM と自己回復

7 回回した。**壊れ方が 3 通りに分かれる**ので、まず表にする。

| 回 | 負荷 | 壊れ方 | 終了コード | 秒数 |
| --- | --- | --- | --- | --- |
| 1 | 16:05:43 | main スレッドが OOM → JVM がそのまま落ちる | **1** | OOM から約 3 秒 |
| 2 | 16:06:29 | プールが壊れて `ping` が失敗 → 見張りのスレッドが判断 | **3** | **43.7 秒** |
| 3 | 16:07:58 | main スレッドが OOM → JVM がそのまま落ちる | **1** | OOM から約 6 秒 |
| 4 | 16:08:33 | 見張りのスレッドだけ死ぬ。プールは生きている（9 本漏れ） | 落ちない（`watch stalled` の 503） | — |
| 5 | 16:10:52 | 両方のスレッドが生き残る。プールは 9 本漏れ | 落ちない（`status: ok`） | — |
| 6 | 16:12:26 | プールが壊れて `ping` が失敗 → **`/health` のリクエストのスレッドが判断** | **3** | **45.4 秒** |
| 7 | 16:18:53 | プールが壊れて `ping` が失敗 → 見張りのスレッドが判断 | **3** | **52.7 秒** |

### 直りの確認 1: `self-heal: exiting` が出て exit 3 になる（3 回目の回帰は解消）

3 回目は 2 回とも `self-heal` が **0 行**でプロセスが生き残った。4 回目は
**プールが壊れた 3 回（2 / 6 / 7）すべてで `self-heal: exiting` が出て、終了コード 3 で終わった**。

```json
{"time":"2026-09-08T07:07:13.860Z","severity":"error","message":"self-heal: exiting","db.pool.active":10,"db.pool.idle":0,"db.pool.max":10,"db.pool.total":10,"db.pool.waiting":0,"reason":"DB の接続プールから 38969 ms 続けて届かず、プールを通さない新しい接続では届いている","service":"cms","version":"dev"}
```

`b7efa55` が効いた事は 6 回目の行がそのまま示している。**`url.path: /health` と `request.id` が付いている
= `/health` のリクエストのスレッドが `step` を進めて Exit を決めた**。見張りのスレッドはこの時点で死んでいる。

```json
{"time":"2026-09-08T07:13:13.650Z","severity":"error","message":"self-heal: exiting","db.pool.active":10,"db.pool.idle":0,"db.pool.max":10,"db.pool.total":10,"db.pool.waiting":3,"http.request.method":"GET","reason":"DB の接続プールから 41611 ms 続けて届かず、プールを通さない新しい接続では届いている","request.id":"01M1ZXT6EDGH6GPXE8RW9B6J8S","service":"cms","url.path":"/health","version":"dev"}
```

7 回目は見張りのスレッド側（`url.path` が無い）で `49420 ms`。

秒数（最初の `OutOfMemoryError` の行 → `self-heal: exiting` の行）:

| 回 | 最初の OOM | `self-heal: exiting` | 差 | 続けて失敗した長さ | プロセスの終了 | drain |
| --- | --- | --- | --- | --- | --- | --- |
| 2 | 07:06:30.127Z | 07:07:13.860Z | **43.7 秒** | 38969 ms | 16:07:14 | 約 0.2 秒 |
| 6 | 07:12:28.288Z | 07:13:13.650Z | **45.4 秒** | 41611 ms | 16:13:29 | 約 15.4 秒 |
| 7 | 07:18:54.926Z | 07:19:47.601Z | **52.7 秒** | 49420 ms | 16:19:59 | 約 11.4 秒 |

**目標の 20〜40 秒には届いていない（43.7 / 45.4 / 52.7 秒）。** 内訳は
「`minUnhealthyMs`（20 秒）+ jitter」+「OOM の直後はまだ `ping` が通っていた助走」で、
続けて失敗した長さ（38.9 / 41.6 / 49.4 秒）が既に 20 秒の倍以上ある。
jitter の上限が 30 秒なので、20 + 30 = 50 秒までは仕様どおりに伸びる。
**目標が 20〜40 秒なら jitter の上限を縮めるしかない。**

### 直りの確認 2: 見張りのスレッドが死ぬと `/health` が `watch stalled` の 503（4 回目）

4 回目は見張りのスレッドだけが OOM で死に、仕事の周（`lastTickAt`）は動き続けた。
負荷が 16:08:33、`lastWatch` が止まってから 30 秒（`stallLimitMs`）で 503 に変わり、そのまま張り付いた。

```
16:09:04 health={... "lastTickAt":"2026-09-08T07:09:02.220Z" ... "status":"ok"} 200:0.006764
16:09:14 health={... "lastTickAt":"2026-09-08T07:09:12.278Z" ... "reason":"watch stalled","status":"error"} 503:0.008918
16:10:14 health={... "lastTickAt":"2026-09-08T07:10:12.754Z" ... "reason":"watch stalled","status":"error"} 503:0.006939
```

リクエストの行にも `watch.stalled_ms` が付く（10 秒ごとに増えていく = 見張りのスレッドは戻っていない）。

```json
{"time":"2026-09-08T07:09:14.195Z","severity":"warn","message":"request","credential.kind":"anonymous","duration_ms":8,"http.request.body.size":0,"http.request.method":"GET","http.response.body.size":291,"http.response.status_code":503,"project":"default","request.id":"01M1ZXJYJBSGBNG4S7GPJABR6Y","service":"cms","url.path":"/health","version":"dev","watch.stalled_ms":36840}
{"time":"2026-09-08T07:09:24.233Z", … "watch.stalled_ms":46882}
```

**この回はプロセスが終わらないのが正しい。** `pool.active=9 / idle=1` で 9 本漏れているが
`ping` は通るので `SelfHeal.decide` の条件 2（`minUnhealthyMs` 続けて失敗）に当たらない。
`/health` は 503 なので、コンテナ側の `HEALTHCHECK` が入れ替えを決める形になる。

### 再現できなかった物: `jobs stalled` の 503

**7 回回して仕事の周（`runForever`）が死んだ回は 1 度も無かった**（3 回目の 1 回目では死んでいた）。
どの回も `lastTickAt` は 2 秒ごとに進んでいた。`jobs stalled` の道は `watch stalled` と同じ
`Health.stalled` / `elapsedOver` を通るので、コードとしては同じ形だが、**この実験では確かめられていない**。

### プールも見張りも壊れない回（5 回目）

5 回目は OOM を食らっても両方のスレッドが生き残り、`/health` は最後まで `status: ok` の 200。
ただし `pool.active=9 / idle=1` が 1 分続いた。**接続は 9 本漏れているのに `ok`。**

```
16:11:53 health={"connections":{"active":31,"max":256},"jobs":{…,"lastTickAt":"2026-09-08T07:11:51.317Z",…},"pool":{"active":9,"idle":1,"max":10,"total":10,"waiting":0},"status":"ok","version":"dev"} 200:0.006341
```

### main スレッドが OOM で死ぬ回（1 / 3 回目）

7 回中 2 回は、負荷の途中で `main` が OOM を食らって JVM が落ちた。

```
Exception in thread "main" java.lang.OutOfMemoryError: Java heap space
```

終了コードは **1**。コンテナは再起動するので運用上は困らないが、
**`drain` も `self-heal` も通らず、終了コードで「壊れて落ちた」（3）と区別が付かない**。

---

## 対照

### 対照 4: DB を止めたまま 100 秒 → 誤爆しない

正常に起動した後に `docker compose stop postgres`（16:16:15）。
**100 秒後もプロセスは生きていて、`self-heal` は 0 行**（`server-control.log`）。
`SelfHeal.decide` の条件 3（プールを通さない新しい接続では届く）が満たされないので正しい。

```json
{"time":"2026-09-08T07:16:57.036Z","severity":"error","message":"jobs tick failed","error.message":"回復と掃除ができません: Permanent(retryExhausted connectionLost HikariPool-1 - Connection is not available, request timed out after 2006ms (total=0, active=0, idle=0, waiting=1) after 3 attempts)","service":"cms","version":"dev"}
```

ただし `/health` の応答は **10.3 秒**まで伸びた（3 回目は 6〜8 秒）。

```
503:10.288622
{"connections":{"active":2,"max":256},"db":"Transient(connectionLost HikariPool-1 - Connection is not available, request timed out after 2004ms (total=0, active=0, idle=0, waiting=3))","jobs":{"failedDeliveries":-1,…},"pool":{"active":0,"idle":0,"max":10,"total":0,"waiting":2},"status":"error","version":"dev"}
```

`healthRoute` が最初に `heal()`（= `SelfHeal.step` の `Health.ping`）を呼ぶようになり、
その後の `checkDb` でもう 1 回 `ping` するので、**DB が落ちている間の `/health` のコストが倍になった**。

### 対照 5: 正常時に 10 秒ごとに 2 分 → 落ちない

16:13:59 から 16:16:07 まで 13 回、全部 `200` の `status: ok`。`self-heal` は 0 行。

```
16:14:34 health={"connections":{"active":1,"max":256},"jobs":{…,"lastTickAt":"2026-09-08T07:14:34.083Z",…},"pool":{"active":0,"idle":10,"max":10,"total":10,"waiting":0},"status":"ok","version":"dev"} 200:0.004415
```

---

## 2 回目 → 3 回目 → 4 回目

| 見る物 | 2 回目 | 3 回目 | 4 回目 |
| --- | --- | --- | --- |
| OOM の後の `self-heal: exiting` | 79.7 秒で exit 3（1 回） | **2 回とも 0 行。落ちない（回帰）** | **プールが壊れた 3 回とも出て exit 3。43.7 / 45.4 / 52.7 秒** |
| 見張りが死んだ時 | 見張りは仕事の周に相乗り（死なない） | **死ぬと自己回復が永久に無効** | **`/health` から `step` が進む。6 回目は `/health` のスレッドが Exit を決めた** |
| 見張りが死んだ事の見え方 | 分からない | **`status: ok` のまま（バグ）** | **`watch stalled` の 503 と `watch.stalled_ms`** |
| 仕事の周が死んだ事の見え方 | 分からない | `status: ok` のまま（バグ） | 道は入ったが、**7 回とも仕事の周が死ななかったので未確認** |
| OOM で落ちる時の終了コード | 3 | 落ちない | 3（プール破壊）/ **1（main が OOM。7 回中 2 回）** |
| DB 停止での誤爆 | 無し | 無し | 無し（100 秒） |
| DB 停止中の `/health` | 15 秒 | 6〜8 秒 | **10.3 秒（`heal()` のぶん伸びた）** |
| 接続の漏れ | あり | あり | **あり（`pool.active=9` が 1 分以上）** |

## 残る弱点

| # | 弱点 | 根拠 | 直す所 | いつから |
| --- | --- | --- | --- | --- |
| 1 | **自己回復が目標の 20〜40 秒に入らない**。43.7 / 45.4 / 52.7 秒。jitter の上限が 30 秒なので `minUnhealthyMs`（20 秒）+ 30 = 50 秒まで仕様どおり伸びる | S5 の 2 / 6 / 7 回目。`reason` の `38969 ms` / `41611 ms` / `49420 ms` | jitter の上限を縮める（`Main` が渡す `jitterMs`）か、目標を「50 秒台まで」に直す | 4 回目（新規） |
| 2 | **`main` スレッドが OOM で死ぬと終了コード 1**。`drain` も `self-heal` も通らず、正常な停止（0）・壊れて落ちた（3）・drain 切れ（2）のどれとも別の番号になる | S5 の 1 / 3 回目。`server-oom-run1.log:77` と `server-oom-run3.log:84` の `Exception in thread "main" java.lang.OutOfMemoryError` | `main` を `Throwable` で受けて exit 3 に寄せるか、`-XX:+ExitOnOutOfMemoryError` を Dockerfile に足す | 4 回目（新規） |
| 3 | **`jobs stalled` の 503 が未確認**。道は入ったが、7 回とも仕事の周が死ななかった | S5 の 7 回とも `lastTickAt` が 2 秒ごとに進んだ | テストで `Health.stalled` を確かめる（`Liveness` は純粋な値なので表駆動で書ける） | 4 回目（新規） |
| 4 | **接続の漏れは自己回復の条件に当たらない**。`pool.active=9 / idle=1` で 9 本漏れていても `ping` は通るので `status: ok` の 200 のまま | S5 の 4 / 5 回目。`probe-run4.log` / `probe-run5.log` の `"pool":{"active":9,"idle":1,…}` | `SelfHeal.decide` か `Health.ofPool` の `status` に「`active` が `max` 近くで張り付いている」を足す | 1 回目から（見え方は 4 回目で悪化） |
| 5 | **`/health` が DB の停止中に 10.3 秒返る**。`heal()` と `checkDb` で `ping` を 2 回打つようになったぶん、3 回目の 6〜8 秒から伸びた。Dockerfile の `HEALTHCHECK --timeout=3s` には全く間に合わない | 対照 4 の `503:10.288622` | `healthRoute` で `ping` の結果を 1 回で使い回す（`heal` に `checkDb` の結果を渡す） | 3 回目からあり、4 回目で悪化 |
| 6 | **OOM で HTTP と DB の接続が漏れる**。`connections.active` が 31〜33 に張り付いたまま戻らない | S5 の 4 / 5 回目 | `HttpServer` の接続の閉じ方 | 1 回目から |
| 7 | **同じ負荷で壊れ方が 3 通りに分かれる**。どのスレッドが先に OOM を食らうかで決まるので、直しの効果は 1 回では測れない | 7 回で 1 / 3 / 3 通り | 実験の台本を「n 回回して分布を見る」に変える | 4 回目（新規） |

なお、3 回目の弱点 3（`error.kind` の `timeout` を作れない）は今回の 7 回目の drain で出た
（`Permanent(retryExhausted timeout 0 after 3 attempts)`）。OOM でプールが壊れた状態なら作れる。
