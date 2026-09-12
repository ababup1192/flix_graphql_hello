# 監査の記録

状態: 入った（2026-09-10）。主体の列・Webhook / asset / 公開範囲 / entry の取り下げ・削除・予約公開・絞り込みは 2026-09-11。roadmap #18。

## 何を残すか

**版の残らない変更だけ**を `audit_events` に積む。

| 対象 | 積む操作 | detail |
|---|---|---|
| メンバー | `member.invited` / `member.role_changed` / `member.removed` / `invitation.cancelled` | 役割。役割の変更は `{role, before}` |
| 鍵 | `api_key.created` / `api_key.revoked` | 名前 |
| 型 | `type.created` / `type.updated` / `type.deleted` | 変更前の姿（`SchemaSnapshot`）。消した物は物理削除した entry の件数 `purgedEntries` も |
| フィールド | `field.added` / `field.updated` / `field.removed` / `fields.reordered` | 変更前の姿 |
| プロジェクト | `project.visibility_changed` | `{before, after}` |
| Webhook | `webhook.created` / `webhook.updated` / `webhook.deleted` / `webhook.redelivered` | 姿（`AuditSnapshot.ofWebhook`。url はマスク）。直した・消した物は `before` |
| asset | `asset.confirmed` / `asset.deleted` | `{mime, size, width, height}`。消した物は `before` |
| entry | `entry.unpublished` / `entry.deleted` / `entry.published`（予約の実行だけ） | `{typeApiId, version}`。予約は `scheduledFor` も |
| 監査 | `audit.exported`（CSV / JSON Lines の書き出し。targetId は形式） | `{format, actorKind, action, since, until, count}`（絞り込みは渡した物だけ） |

**WhyNot: entry の編集と手での公開を積まない。** `entry_versions` が誰が・いつ・どんな中身にしたかを**版として全部**持っていて、
監査としてはそちらの方が強い。二重に持つと片方だけ残る形が作れてしまう。
取り下げと論理削除は版を作らないので積む。予約公開の実行は版の author が "scheduler" になり誰の予約かが版から読めないので積む（主体は system）。

**この判断が成り立つのは、版が `audit_events` と同じ append-only だから**（`029_entry_versions_append_only.sql`）。
それまでは版は書き換え・削除ができ、content type を消すと外部キーの CASCADE で道連れに消えていたので、
「手での公開の記録は版が持っている」は保証になっていなかった。今は RLS の policy を SELECT と INSERT の 2 本に分け
UPDATE / DELETE がどの policy にも当たらないようにし、entry への外部キーも外して content type を消しても版が残るようにしてある。

**WhyNot: `asset.confirmed` を再送で積まない。** confirm は冪等で同じ asset に何度も来る。積むのは pending → ready に変わった 1 回だけ。

### 積まない物

| 物 | 理由 |
|---|---|
| preview token の発行 | 1 時間で切れる無状態の物で、量が桁違い（編集者 10 人 × 30 回/日 = 年 11 万行）。「使われた」はコンテンツ API の構造化ログに出る |
| pending の upload（署名付き URL の発行） | まだ置かれていない。置かれて ready になった時に `asset.confirmed` |
| asset の alt の変更 | 本文に準ずる。版が要るなら asset 側で持つ |
| 読み取り（誰がどの entry を見たか） | 要求されてから |
| ログイン・認証の失敗・forbidden | 構造化ログの層（Loki）。**セキュリティイベントはログ基盤、業務の変更は audit_events** の二層 |
| PAT（`personal_access_tokens`） | 本人に付いてプロジェクトを跨ぐので、プロジェクト単位の `audit_events`（RLS が project_id で切る）に入れると、どのプロジェクトの記録にするかが決まらない。組織の監査（別の置き場）で扱う |

## 主体

`actor_kind` / `actor_id` / `actor` の 3 列。`Session.actorRef()` が今の主体から作る。

| kind | id | actor（表示名） |
|---|---|---|
| `user`（ログインの JWT） | users.public_id | email |
| `pat`（PAT で来た人） | users.public_id | email |
| `api_key` | 鍵の名前 | `api-key:<鍵の名前>` |
| `system`（予約公開の実行） | 空 | `system` |

表示名は**版の `author` と同じ形**。

**WhyNot: 表示名だけにしない。** 鍵の同名再発行や email の変更で「誰」を機械で引けなくなる。

**WhyNot: 人の id に users.id（内部の連番）を積まない。** 管理 API の `actorId` に出るので、外向きの id の決まりどおり public_id。
`Actor.User` は内部の id しか持たないので、`Session.actorRef` が積む時に users を 1 回引く（`Audit.record` の effect は `Db`）。
`Actor.User` に public id を足さないのは、組む・分ける場所が 31 か所あり、監査の書き込みは稀なため。

**WhyNot: 鍵の actor_id を public id にしない（今は名前）。** `Actor.ApiKey` が名前と scope しか持たず、public id を足すと Actor を組む全ての場所（テストを含めて 27 か所）が変わる。
同名で再発行した鍵は `api_key.created` の行の時刻で見分ける。public id に替える時は Actor に足して `Session.actorRef` を 1 行変える。

**`025_audit_actor.sql` より前の行は actor_id が空**（DEFAULT で埋めた。表示名しか残していない）。

## secret と個人情報を入れない

append-only なので、入れてしまった物は二度と消せない。積む前に `src/cms/rules/` の純粋な関数で落とす。

- **Webhook の URL はマスク**（`AuditRedact.webhookUrl`）: `{host, pathHint, urlHash}`。pathHint は path の最後のセグメントを `…` に、urlHash は SHA-256 の先頭 12 桁。
  deploy hook（Cloudflare / Vercel / Netlify）と Slack の URL は最後のセグメントがそのまま認証情報。
  **WhyNot: ホスト名で判定しない。** 提供元は増えるので全 URL で一律に落とす。同じ URL に戻したかは urlHash で照合できる
- **asset の fileName / key / alt は入れない**（`AuditSnapshot.ofAsset`）。fileName は個人名・取引先名が入る運用があり、消去請求に応えられなくなる
- Webhook の secret は `Webhook` の値に無い（`IssuedWebhook` だけが持つ）ので、`ofWebhook` の引数型で渡せない

## どこで積むか

ユースケースが `Audit.record(change)` を**業務の書き込みと同じ Tx で 1 回**呼ぶ（`Publishing.notify` と同じ形）。

**WhyNot: `DbRunner.transact` で全 mutation をまとめて 1 か所で積まない。** そこに揃っているのは主体とプロジェクトだけで、
何をどの対象にしたかが無い。**操作名だけの記録は監査に使えない。**

同じ Tx なので「変えたのに記録が無い」も「記録があるのに変わっていない」も起きない。
失敗した操作は記録も一緒に ROLLBACK される（`test/Pg/TestAuditPg.flix` が実 PG で確かめている）。

予約公開は `Scheduler` が `ContentEntries.publishScheduled` を呼ぶ（手での公開は `publish` で、積まない）。

## 書き換えられない・保持は無期限

`audit_events` には **SELECT と INSERT の policy しか作っていない**。UPDATE と DELETE はどの policy にも当たらないので、
FORCE RLS の下ではアプリも表の所有者も書き換えられない（実 PG のテストが 0 行を確かめている）。

**保持は無期限。** 消す仕組みは置かない。保持の都合で古い行を消す時は、**DELETE の policy を足す migration を書く**（消せるようにした事自体が記録に残る）。

**WhyNot: 掃除の仕事を置かない。** 積むのは管理の操作と、版に残らない entry の 3 つだけで、entry の編集では増えない。
1 日 10 回の型・メンバー・Webhook の変更 + 1 日 20 回の取り下げ・削除・予約でも年 1 万行。消す仕組みより消せない事の方が価値がある。

## 変更前の姿が残る

型・フィールドを**直した／消した**記録は、`detail` に `{ "before": ... }` で変更前の姿を持つ（`SchemaSnapshot`）。
入るのは apiId・名前・kind・性質・config で、消したフィールドは**子ごと**、消した型は**フィールド全部**。
参照先は内部の連番ではなく apiId で持つので、足し直した後も同じ型を指す。

これが「押した後に戻せるか」の答え。entry と違って型には版が無いので、消した定義はここからしか組み直せない。
`SchemaSnapshot.toDraft` が逆向きで、`addField` にそのまま渡せる。

- 純粋な往復: `test/cms/rules/TestSchemaSnapshot.flix`
- DB を通した組み直し: `test/Pg/TestSchemaRestorePg.flix`

Webhook と asset も同じ形で `before` を持つ（`AuditSnapshot`）。Webhook の url はマスク済みなので、そのままでは戻せない（host と pathHint で当たりを付け、urlHash で照合する）。

作った・足した記録は `before` を持たない（元に戻すのは消す事なので、要る物が無い）。
鍵も持たない（値を二度と出せない）。役割の変更（`member.role_changed`）は `{role, before}` で、`role` が変更後、`before` が変更前。

**まだ戻せないのは entry の中身**。フィールドを消すと `entry_contents` の値は残るが、監査に残るのは定義だけで、
値そのものは版（`entry_versions`）から辿る。取り下げ・削除の行も `{typeApiId, version}` だけで、中身は版から辿る。

## 読む

管理 API の `auditEvents(first, after, actorKind, action, since, until)`（owner だけ）。新しい順、`after` は前のページの最後の id（id は ULID）。

絞り込みは全部サーバ側で、全部任意:

- `actorKind`: `USER` / `API_KEY` / `PAT` / `SYSTEM`
- `action`: 前方一致（`"webhook."` で Webhook の全部）。`audit_events_action_idx`（`text_pattern_ops`）が効く
- `since` / `until`: ISO 8601。**id が ULID なので、その時刻の最小の ULID（`Ulid.lowerBoundAt`）に変えて id の範囲で引く**（`created_at` の index は要らない）

query は `listAuditEvents` の 1 本で、無い引数は NULL（`(:x IS NULL OR col = :x)`）。件数は同じ WHERE の `countAuditEvents`（管理 API の `auditEventsCount`）。

## 書き出す

`GET /p/{slug}/admin/audit.csv` と `audit.jsonl`（引数は `auditEvents` と同じ）。owner だけ、上限 100,000 件（超えたら 413 で期間を分けてもらう）。
中身と裏側は [../architecture/runtime.md](../architecture/runtime.md) の AuditExport。

**書き出し自体が監査に残る**（Strapi と同じ）: `audit.exported`、targetKind `audit`、targetId は形式（`csv` / `json`）、detail は `{format, actorKind, action, since, until, count}`（渡した絞り込みだけ）。
管理 API の `recordAuditExport(input)` が積み、書き出しのルートが読みの後に 1 回呼ぶ。

**WhyNot: 読みと同じ Tx で積まない。** 読みは 1 リクエスト 1 Tx の READ ONLY で、ページごとに管理 API を叩く形（MCP と同じ道）なので、書きの Tx は別に 1 つ。
記録が無く書き出しだけ通る形は、記録の mutation が失敗した時に応答も断る事で塞ぐ。

## 残っている物

- **戻す操作が API に無い**。変更前の姿は残るが、押して戻す口はまだ無く、`detail` を読んで手で足し直す
- 組織（`organizations` / `org_members`）の変更と PAT は、プロジェクトを跨ぐので入っていない（組織の監査で）
- MCP 経由の操作を人と分ける（`actor_kind` に `mcp`）
- 予約公開の `scheduledBy`（誰の予約か）。`scheduled_actions.requested_by` にはあるが、行には載せていない
