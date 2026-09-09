# ステータスページの材料

microCMS の [status.microcms.io](https://status.microcms.io/)（Atlassian Statuspage）に並ぶ物を出すための設計。

## 目的と非目標

**目的**: コンポーネントごとの生死と、過去 90 日の稼働率を出せる材料をこのリポジトリの中に用意する。

**非目標**: ページそのものをここで動かす事。**ステータスページを CMS と同じ compose・同じホストに置くと、障害のときに一緒に落ちて何も出せない。**
置き場は外（Statuspage か、別系統の静的ホスティング）で、ここで作るのはそこへ流し込む値と規則だけ。置き場の決めは Step 5 まで遅らせる。

## コンポーネントの割り

microCMS の 6 行に対応させると、この実装ではこうなる。**内側（`/health`）で分かる行と、外形でしか分からない行がある。**

| ページの行 | 外形で叩く物 | 内側（`/health`）で見る物 |
|---|---|---|
| コンテンツ API | `GET/POST /graphql` | （API 共通の `api` 行） |
| 管理 API | `POST /admin/graphql` | 同上 |
| Account API | `POST /account/graphql` | 同上 |
| メディア配信 | 配信 URL の GET | **見ない**（後述） |
| Webhook | — | `webhook` 行 |
| 予約投稿 | — | `schedule` 行 |

**WhyNot: コンテンツ API / 管理 API / Account API を `/health` で 3 行に割らない。** 3 つとも同じプロセスの同じ DB の上に載っていて、内側から見える壊れ方（DB に届かない・プールが張り付く）は 3 つに同時に効く。
割った所で 3 行が必ず同じ色になり、精度が上がったように見えて実は何も増えない。**3 行の差は外形（実際にその経路を叩く）でしか出ない。**
`/health` は API をまとめて `api` の 1 行として出し、ページの 3 行は外形の結果で塗る。

**WhyNot: メディア配信を `/health` で見ない。** 本番の配信経路は CDN + R2 でプロセスの外を通るので、内側から `ObjectStore.head` を打っても「配信できるか」は分からない（imgix 由来で落ちた microCMS の 9/2 の障害と同じ形）。
加えて `/health` は外形監視が定期的に叩く先で、ここに外向きの HTTP を 1 本足すと、R2 が遅いときに `/health` 自身が遅くなる。**メディア配信は外形だけで見る。**

## ステータスの段

Statuspage は 4 段。`/health` は今 3 段（`ok` / `degraded` / 503 の `error`）で、これは外形監視と Docker の HEALTHCHECK が既に依っているので**意味を変えない**。行ごとの段は追加で出す。

| ページの段 | この実装での判定 |
|---|---|
| Operational | その行に異常なし |
| Degraded Performance | 動いてはいるが余裕が無い（プール 9 割以上の張り付き = 今の `degraded`） |
| Partial Outage | その行だけ止まっている（Webhook の tick だけ止まった、など） |
| Major Outage | DB に届かない・プロセスが応答しない（全行に効く） |

## Step 1: 部分ごとの最終成功時刻

**問題**: `BackgroundJobs.State#lastTick` は tick 1 周（回復 → 予約公開 → Webhook → CDN purge）で 1 本しかない。
`guardedPart` が部分ごとに失敗を捕まえてはいるが、その結果はログに流すだけで残らないので、「Webhook だけ止まっている」を行として出せない。

**やる事**: `State` に部分ごとの最終成功時刻を 3 本足す。

```
lastSchedule = Ref[Option[Int64], Static]
lastWebhook  = Ref[Option[Int64], Static]
lastPurge    = Ref[Option[Int64], Static]
```

`tick` の中で、その部分が `Ok` を返したときだけ更新する。`Err`（失敗・例外）なら据え置き、つまり時刻が古いままになる = 止まっている。
CDN purge は送り先が無ければ何もしない（`Ok(0)`）ので、送り先が `None` のときは行そのものを出さない。

**判定は既存の `Health.stallLimitMs` を使い回す**（間隔の 3 倍、下限 30 秒）。新しい閾値を作らない。

## Step 2: 予約投稿の「遅れ」を数える

**問題**: `countSchedules` の `pending` は `status = 'pending'` の総数で、**まだ公開時刻が来ていない予約も含む**。`countDeliveries` の `pending` も再試行待ちを含む。
どちらも「溜まっている＝異常」ではないので、このままでは行の色を決められない。

**やる事**: 期限を過ぎた物だけを数える query を足す（`make gen`）。

- `countOverdueSchedules` … `status = 'pending' AND scheduled_at < now() - interval`
- `countOverdueDeliveries` … `status = 'pending' AND next_attempt_at < now() - interval`

`interval` は tick の間隔と回復の猶予を足した幅。ここが 0 より大きい状態が続く = ワーカーは回っているのに捌けていない → **Degraded Performance**。
`Summary` には既存の `pending` / `failed` を残したまま `overdue` を足す（`/health` の既存のキーを消さない）。

## Step 3: `/health` に components を足す

`Server.healthBody` に `components` を足す。**既存のキー（`status` / `version` / `jobs` / `connections` / `pool` / `reason` / `db`）と HTTP の status code は据え置き。追加だけ。**

```json
"components": {
  "api":      {"status": "operational"},
  "schedule": {"status": "operational", "lastSuccessAt": "..."},
  "webhook":  {"status": "partial_outage", "lastSuccessAt": "...", "reason": "webhook stalled"}
}
```

判定は `Health` の純粋関数に置く（`Server` には組み立てだけ）。

```
pub enum Level { Operational, Degraded, PartialOutage, MajorOutage }
pub def componentLevels(input: ComponentInput): List[(String, Level, Option[String])]
```

`ComponentInput` は `checkDb` の結果・`stall`・`saturation`・部分ごとの最終成功時刻・`overdue` の件数をまとめた値。
**入力が全部値なので表駆動でテストできる**（`TestHealth` の既存の書き方をそのまま）。実装より先にテストの表を書く。

判定の順（強い物が勝つ）:

1. DB に届かない → 全行 `major_outage`
2. その行の最終成功時刻が `stallLimitMs` を超えている → その行だけ `partial_outage`
3. その行の `overdue` が 0 より大きい → `degraded`
4. プールが 9 割以上 → `api` が `degraded`
5. それ以外 → `operational`

## Step 4: 外形プローブと置き場

ページの 6 行を外から叩く。**Step 3 まで済んでいれば `/health` の 1 発で内側の 3 行が取れる**ので、プローブが叩くのは 4 つ。

| 叩く先 | 見る物 |
|---|---|
| `POST /graphql` | 軽い query が 200 で返るか |
| `POST /admin/graphql` | 同上 |
| `POST /account/graphql` | 同上 |
| 配信 URL | 既知のオブジェクトが 200 で返るか |
| `GET /health` | `components`（schedule / webhook / api） |

**残っていた閾値の決め**（推し値。実測で動かす）:

| 閾値 | 値 | 理由 |
|---|---|---|
| 叩く間隔 | 60 秒 | 90 日で 1 行あたり 13 万点。1 行 1 JSON でも数十 MB に収まる |
| ダウンとみなす | 連続 2 回失敗 | 1 回の取りこぼしで 90 日の稼働率を割らせない。検知は最大 2 分遅れる |
| degraded の扱い | 稼働率に数えず、別に「degraded だった時間」を出す | 稼働率が「落ちていた割合」の意味を保てる |
| 復旧とみなす | 1 回の成功 | 落ちる側は慎重に、戻る側は速く |

**置き場**: プローブの結果は 1 行 1 JSON の追記ファイル。CMS の DB に入れない（**DB が落ちている間こそ書きたい記録なので、DB に置くと肝心なときに書けない**）。

## Step 5: 稼働率とページ

プローブの記録から「過去 90 日の稼働率」と「ダウンだった区間」を出す純粋な規則。ここもテストファースト。

- 連続 n 回の失敗をダウンの区間にまとめる
- 記録が無い時間（プローブ自体が止まっていた）の扱い — **稼働率 100% に数えない。「不明」として区間に出す**
- 期間の端の切り方、分単位の丸め

インシデントは Statuspage の形（id・影響コンポーネント・段階 investigating → identified → monitoring → resolved・更新の列）に合わせた JSON でリポジトリに置く。
自前ページにしても Statuspage を契約しても、そのまま流し込める。メール・Slack の購読は配信基盤が要るので SaaS 側に寄せる。

## 順

Step 1 → 2 → 3 が in-repo で完結し、`make test`（DB 無し）で確かめられる。4 と 5 は置き場の決めが要るので後。
**3 まで済むと、外形と稼働率の閾値を実測で決められる**（今は推し値しか出せない）。
