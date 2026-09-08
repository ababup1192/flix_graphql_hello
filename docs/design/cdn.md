# 公開側を CDN に乗せる（2026-09-08）

コンテンツ API の匿名の `GET /graphql` を Cloudflare などの共有キャッシュに溜め、公開した瞬間に外す。ロードマップの 16b。

## 決めた事

### プロジェクト単位の版（`projects.content_version`）

- 公開・取り下げ・削除・content type とフィールドの変更で +1。進めるのは Webhook の outbox を積むのと同じ `Publishing.notify(event)`（ユースケースと同じ Tx）。出来事 → 副作用の対応は純粋な表 `Publishing.effectsOf`（`test/cms/TestPublishing`）
- 下書きの保存では進めない。匿名の GET は公開中しか読めず、下書きが変わってもキャッシュの中身は変わらない。進めると下書きの保存のたびに全キャッシュが外れる
- entry 単位・型単位の版にしない。GraphQL の 1 文書が何を読むか（参照の展開、一覧の絞り込み）を追って鍵にするより、プロジェクト全体で 1 つ進める方が確実で安い（microCMS も同じ方式）。1 回の公開で全部外れる代わりに、s-maxage が短いので温め直しは軽い
- 読むのは `Projects.contentVersion()`（Tenant の今のプロジェクト）。`Main.runRoute` が認証と同じ Tx で、コンテンツ API の GET で鍵もトークンも無い時だけ 1 本読む（`Server.wantsContentVersion`）

### 副作用の入口は Facade（`Publishing.notify`）

- 公開・取り下げ・削除・型の変更の副作用（Webhook の outbox、`content_version`）はユースケースが出来事を 1 つ作って `Publishing.notify` に渡し、中が表の順に同じ Tx で積む。今の消費者は Webhook と版の 2 つで、どちらも業務の Tx の中で終わる
- 出来事の表（events）+ consumer の形にはしていない。4 つ目の消費者（監査ログ #18 / 検索索引）が来た時に、events の 1 表に積んで consumer が拾う形へ作り直す
- それまでは Facade。ユースケースから `Webhooks.emit*` / `Projects.bumpContentVersion` を直に呼ばない

### weak な ETag

- `W/"v<版>-<sha256(query + "\n" + variables の JSON + "\n" + operationName) の先頭 16 桁>"`（`CacheHeaders.etagOf`）
- weak にするのは、本文のバイト列でなく「版と文書」で決めているため。強い ETag（本文のハッシュ）にすると 304 を返すためだけに 200 と同じ SQL を出す事になる
- `If-None-Match` の照合は RFC 9110 の weak comparison（`W/` を両側で無視、`*` と複数値に対応。`CacheHeaders.matches`）

### 304 の道は SQL 1 本

- 認証の Tx の中で版を読み、`If-None-Match` が合えば GraphQL を実行せずに 304（本文無し。`ETag` / `Cache-Control` / `Vary` は付ける）
- 1 リクエストの SQL: RLS の印 + プロジェクトの公開範囲 + 版。Tx は 1 つ。上限は `test/Pg/TestQueryBudgetPg`（anonymous content GET 304）
- 200 の時も同じ ETag を付ける（errors があれば付けず no-store）

### Cache-Control の既定

`public, s-maxage=10, max-age=0, stale-while-revalidate=60`（`CMS_CACHE_S_MAXAGE` / `CMS_CACHE_MAX_AGE` / `CMS_CACHE_STALE_WHILE_REVALIDATE`。両方 0 で no-store）。

- CDN は 10 秒持つ。その間の公開は最長 10 秒遅れる（purge を入れれば最長 2 秒）
- ブラウザは持たない（`max-age=0`）。304 で確かめる道があるので、古い物を見せ続ける理由が無い
- 期限切れから 60 秒は裏で取り直しながら古い物を返す（origin が遅くても利用者を待たせない）

### 認証付きは bypass

- 鍵・PAT・プレビュートークン付きの応答は `private, no-store`（今まで通り）。ETag も付けない。`cache.status = bypass`
- `Vary: X-Api-Key, X-Preview-Token, Authorization` は残す。ただし Cloudflare は Vary をキャッシュの鍵に使わない（画像以外）ので、cache rule の式でそれらのヘッダが付いた要求を cache eligible から外す（`deploy/cloudflare-cache-rules.md`）。外さないと匿名の応答が鍵付きの要求に返る
- 認証に落ちた要求（private なプロジェクトの匿名など）は errors[] の 1 件で no-store

### purge は任意（`cdn_purges`）

- `CMS_CDN_PURGE_URL` と `CMS_CDN_PURGE_TOKEN` が両方ある時だけ。Cloudflare の `purge_cache` に `{"purge_everything": true}` と `Authorization: Bearer`
- 積むのは公開のユースケースでなくバックグラウンドの tick。送り先は環境変数（プロセスの設定）で、ユースケースに知らせるには公開・取り下げ・削除・型の変更の署名全部に effect を足す事になる。版は公開と同じ Tx で進んでいるので、tick が `content_version > purged_version` のプロジェクトを拾って積めば「版が進んだのに積まれない」は起きない（遅れは最長 2 秒）。`purged_version` を同じ Tx で進めるので、連続する公開は 1 件にまとまる
- 表は `webhook_deliveries` に相乗りせず `cdn_purges`（同じ形）。`webhook_id` を nullable にする `ALTER COLUMN ... DROP NOT NULL` を sqlfx の生成器が読めず、生成された decoder が NULL の行で落ちるため。拾い方（SKIP LOCKED、同じプロジェクトの古い物が未完なら待つ）、再試行（1 分 → 5 分 → 30 分 → 2 時間、5 回目で failed）、回復（10 分）、掃除（30 日）、仕事の行（`job.kind = cdn_purge`）は Webhook と同じ
- 予約公開が進めた版も同じ tick の後半で拾う（回復 → 予約公開 → Webhook → purge の順）
- `/health` の `jobs` には purge の件数を出していない（失敗は仕事の行の `job.outcome = failed` で見る）

### Unit of Work との関係

- GraphQL の Unit of Work はルートフィールドごとの Tx なので、1 リクエストに mutation を並べると版はフィールドごとに進む。途中で失敗しても、それまでに COMMIT された物の版は進んでいる（キャッシュは正しく外れる）
- 版の +1 は `UPDATE projects` の行ロックを取る。同じプロジェクトの公開が並ぶと直列になるが、公開は元々 unique の advisory lock で直列なので増えない
- 版の読み取り（GET）は認証の Tx で、リクエストの Tx（読むだけの文書の 1 リクエスト 1 Tx。REPEATABLE READ）より前。認証の Tx の COMMIT からリクエストの Tx の最初の SQL（snapshot）までの間に公開が COMMIT されると、古い版の ETag に新しい中身が乗る事がある。次の公開で版がもう 1 つ進むまでその ETag が返り続けるが、中身は新しい側なので古い物を見せる事は無い（逆の「新しい ETag に古い中身」は起きない）。文書の中では snapshot が 1 つなので、一覧と参照先が違う版から来る事は無い
- 窓を消すには 200 の ETag をリクエストの Tx の最初で読み直した版で組めばよい（SQL +1。304 の判定は認証の Tx の版のまま）が、ETag を組むのは `Server.respondQuery`（GraphQL を実行する前に 304 を決め、実行の後に ETag を付ける）で、リクエストの Tx は `Graphql.execute` の handler（`Main.executeDocument`）の中にある。Route の handler に Tx を見せずにこの窓を閉じるには GraphqlResponse に版を載せる形が要るので、後続に回す（窓の向きは上の通り「古い ETag に新しい中身」だけ）

## 測った数（2026-09-08、`TestQueryBudgetPg`）

| 道 | db.statements | db.transactions |
|---|---|---|
| 匿名の GET が 304 で終わる（RLS の印 + 公開範囲 + 版） | 3 | 1 |
| 匿名の GET が 200（blogs 50 件 + 参照先。上の 1 Tx + 一覧 2 + 参照先 1） | 6 | 2（1 リクエスト 1 Tx の前は 254） |
| （比較）API キーのコンテンツ API で同じ一覧 | 5 | 2（前は 254） |

## 関連

- ログのキー `cache.status`（hit / miss / bypass）: [../logging.md](../logging.md)
- deploy: [../../deploy/cloudflare-cache-rules.md](../../deploy/cloudflare-cache-rules.md)、[../../deploy/Caddyfile](../../deploy/Caddyfile)、環境変数は [../../deploy/README.md](../../deploy/README.md)
