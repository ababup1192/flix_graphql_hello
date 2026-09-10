# ステータスページの材料

microCMS の [status.microcms.io](https://status.microcms.io/)（Atlassian Statuspage）に並ぶ物を出すための設計。

## 自作の範囲

**自作するのは内側の材料だけ。** 外形のプローブ・記録・90 日の集計・ページ・購読の配信・障害中のインシデント更新は SaaS（外形監視と Statuspage）に預ける。

**WhyNot: 外形と集計まで自作しない。** 多地点からのプローブ・区間のまとめ・メンテナンスウィンドウ・障害の最中にスマホから更新できる導線は、
1 人で運営する規模（顧客 300 人まで）では作る側も回す側も持たない。[hosting-and-externalized-risk.md](hosting-and-externalized-risk.md) の「取り返しのつかない部分は専門のサービスに預ける」がそのまま当たる。
**逆に SaaS には作れないのが「内側の材料」**（部分ごとの最終成功時刻・期限を過ぎた仕事の件数）で、ここだけが自作の値打ち。ページと無関係に、夜に自分が気付くための値としても効く。

**WhyNot: ステータスページを CMS と同じ compose・同じホストに置かない。** 障害のときに一緒に落ちて何も出せない。
同じ理由で、**外形のプローブも監視対象と別の障害ドメインで走らせる**（同居させると、ホストごと落ちる最悪の全断で記録も止まり、後述の「不明」に化けて**一番重い障害だけが稼働率から抜ける**）。

## `/health` の位置付け

**`/health` は障害の切り分け材料であって、稼働率の根拠にしない。**

**WhyNot: `/health` の自己申告で稼働率を出さない。** `/health` が見ているのは「プロセスと DB が生きている」だけで、
AGENTS.md が名指ししている事故（リゾルバのラムダに effect を直に書くと JVM の VerifyError になり、そのフィールドを選ぶ query でだけ出る）は `/health` を素通りして通ってしまう。
**200 なのに壊れている、という一番よくある形を構造的に拾えない。** 稼働率は外形が実際に叩いた結果（`data` が返り `errors` が無い）だけで塗る。

## コンポーネントの割り

行は**利用者の体感**で割る。microCMS の 6 行の写しにはしない。

| 行 | 外形で叩く物 | `/health` の components |
|---|---|---|
| コンテンツ API | `POST /graphql` | — |
| 管理 API・管理画面 | `POST /admin/graphql` | — |
| メディア | 配信 URL の GET | — |
| Webhook | — | `webhook` |
| 公開反映（予約公開 + CDN purge） | — | `schedule` / `cdnPurge` |

- **Account API は管理 API の行へ畳む。** 利用者が直接叩く経路ではない（管理画面と PAT の発行）ので、単独で赤くしても顧客が何をすればいいか分からない行が増えるだけ。外形では叩くが、ページの行にはしない
- **CDN purge を行にする。** 止まると「公開したのにサイトが古いまま」で、顧客が真っ先に問い合わせてくる形。予約公開と合わせて「公開反映」の 1 行にする
- **メディアは配信とアップロードの両方**。配信経路は CDN + R2 でプロセスの外を通るので、内側からは分からない（imgix 由来で落ちた microCMS の 9/2 の障害と同じ形）。`/health` では見ない

**WhyNot: `/health` で API を行に割らない。** コンテンツ / 管理 / Account は同じプロセスの同じ DB の上で、内側から見える壊れ方は 3 つに同時に効く。割っても必ず同じ色になる。

## 稼働率の定義（コードを書く前に固める）

後から自分に都合よく曲がらないよう、先に決める。

| 決め | 値 | 理由 |
|---|---|---|
| 分母 | 記録がある時間だけ。**「不明」の割合をページに併記する** | 不明を分母から外せば嘘の 100%、含めれば嘘の大障害。どちらにも倒さず、不明のまま出す |
| 表示する期間 | **「記録開始日からの n 日」**。90 日貯まるまで「過去 90 日」と書かない | 記録の無い期間を遡って白く塗らない |
| degraded | **外形が失敗として観測した分は稼働率に数える** | プールが張り付いている間のリクエストは借り待ち 2 秒の後 INTERNAL に落ちている（利用者にとっては失敗）。内側の `pool` の割合は原因の注釈にだけ使う |
| 計画停止 | 宣言したウィンドウは除外し、**除外した時間をページに明示** | 単一ホストの再起動は数十秒。無宣言なら記録する |
| ダウンの区間 | 検知は連続 2 回の失敗、ただし**区間の開始は最初の失敗に戻す** | 1 回の取りこぼしで割らせない。同じ再起動が位相次第で 0 分にも 2 分にもなるのを防ぐ |
| 復旧 | 連続 2 回の成功 | 1 回で戻すと、self-heal の再起動ループ（exit 3 の繰り返し）が毎回「1 回失敗」で消える |
| フラッピング | 24 時間で n 回以上の単発失敗を別に集計して区間に出す | 短周期の断が全部消えるのを防ぐ |

**インシデントは SaaS の UI を正**とし、リポジトリの JSON は事後の記録に限る。障害は深夜・移動中・自分の回線側からも来るので、git push が要る導線を正にすると「Major Outage のまま無言」になる。

## Step 1: 期限を過ぎた仕事を数える

**問題**: `countSchedules` の `pending` は `status = 'pending'` の総数で、**まだ時刻が来ていない予約も含む**（`queries/schedules.q:67`）。`countDeliveries` の `pending` も再試行待ちを含む。
どちらも「溜まっている＝異常」ではないので、行の色を決められない。

**やる事**: 既存の 2 つの query に `overdue` の列を足す。**新しい query を作らない**（`/health` は 10 秒ごとに叩かれる〔`Dockerfile:37`〕ので、往復を増やさない。同じ `SELECT` に `FILTER` を 1 本足すだけなら増えない）。

- `scheduled_actions` … `status = 'pending' AND run_at < now() - interval '60 seconds'`（列は `run_at`。索引 `(status, run_at)` に乗る）
- `webhook_deliveries` … `status = 'pending' AND next_attempt_at < now() - interval '60 seconds'`

60 秒は tick の間隔（既定 2 秒）と 1 tick の伸び（`jobs tick slow` の閾値 15 秒）に対する余裕。ここが 0 より大きい状態が続く = ワーカーは回っているのに捌けていない → **Degraded**。

## Step 2: 部分ごとの最終成功時刻（補助）

`BackgroundJobs.State#lastTick` は tick 1 周（回復 → 予約公開 → Webhook → CDN purge）で 1 本しかないので、`State` に部分ごとの時刻を 3 本足す。`tick` の中でその部分が `Ok` を返したときだけ更新する。

**WhyNot: これを行の色の主軸にしない。** `WebhookDispatcher.tick` も `Scheduler.tickWith` も、**`Err` を返すのは DB の失敗と例外だけ**で、受け手が 500 を返し続けても `Ok` を返す（再試行に積むのが正しい振る舞いなので）。
つまり 3 本の時刻は DB が落ちれば揃って古くなり、差が出るのは片方だけで例外が飛んだときに限られる。**主軸は Step 1 の `overdue`、時刻は「その部分が例外で死んでいる」を拾う補助。**

判定は既存の `Health.stallLimitMs`（間隔の 3 倍、下限 30 秒）を使い回す。新しい閾値を作らない。

## Step 3: `/health` に components を足す

`Server.healthBody` に `components` を足す。**既存のキー（`status` / `version` / `jobs` / `connections` / `pool` / `reason` / `db`）と HTTP の status code は据え置き、追加だけ。**

```json
"components": {
  "webhook":  {"status": "operational"},
  "schedule": {"status": "degraded", "reason": "schedule behind (3)"},
  "cdnPurge": {"status": "partial_outage", "reason": "cdnPurge stalled"}
}
```

判定は `Health` の純粋関数に置き（`Server` は組み立てだけ）、`Health[ef]` の `stall` を `liveness` に差し替えて**生死の入力を 1 本にまとめる**。
`Server` は `Health.stalled(live)` で今までどおりの 3 段を出し、同じ `live` から `componentLevels` を出す。

```
pub enum Level with Eq, ToString { case Operational, Degraded, PartialOutage, MajorOutage }
pub def levelJson(level: Level): String          // "operational" / "degraded" / …
pub def componentLevels(live: Liveness, summary: Summary, dbOk: Bool, saturation: Option[Int32]): List[(String, Level, Option[String])]
```

`Liveness` に `purgeOn` と部分ごとの最終成功時刻 3 本を足す。**`now` / `startedAt` / `jobsOn` は既に `Liveness` にあり**、まだ 1 度も回っていない tick を起動からの経過で見る扱い（`elapsedOver`）もそのまま使える。

判定の順（強い物が勝つ）:

1. `dbOk` が false → 全行 `major_outage`
2. `jobsOn` が false → 仕事の行を**出さない**（このプロセスは回していない）。`cdnPurge` は送り先が無ければ同じく出さない
3. その部分の最終成功時刻が `stallLimitMs` を超えている → その行だけ `partial_outage`
4. その部分の `overdue` が 0 より大きい → `degraded`
5. それ以外 → `operational`

**入力が全部値なので表駆動でテストできる**（`TestHealth` の既存の書き方）。実装より先にテストの表を書く。

**壊れる物**（先に把握しておく）:

- `test/app/TestServer.flix:307` と `:319` は `/health` の本文を**丸ごと**比較しているので、`components` を足した時点で落ちる。期待値に書き足す（出す / 出さないの切替は入れない）
- `deploy/README.md:228` の外形監視の条件は「応答本文に `"status":"ok"` が含まれる事」。`components` の中に `"status": "operational"` が並ぶので、**「トップレベルの `status`」と書き換える**
- `Health[ef]` の `stall` → `liveness` で `ofPool`（`Health.flix:132`）と `HealthFake`（`ok` / `stalled`）が波及

## Step 4 以降（SaaS 側）

1. 外形監視の SaaS を契約し、**別の障害ドメインから** 4 経路（コンテンツ / 管理 / メディアの配信 / `/health`）を叩き始める。記録が貯まらないと閾値は永遠に推し値のまま
2. 上の「稼働率の定義」でメンテナンスウィンドウと除外を設定する
3. ページの公開は記録が 30 日貯まってから。「記録開始日からの n 日」で出す

自前の集計とページは、SaaS で足りないと実際に困ってから。今は着手しない。

## 順

Step 1 → 2 → 3。3 まで済むと外形の閾値を実測で決められる。
Step 1 は `make gen` が要り、Ref の更新規則は `Pool` を握るので `make test`（DB 無し）では回らない（`test/Pg/` 行き）。
**DB 無しで回せるのは `componentLevels` と `summaryOf` と「`Ok` のときだけ更新」を切り出した関数**なので、その 3 つを表駆動で押さえる。
