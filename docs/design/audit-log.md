# 監査の記録

状態: 入った（2026-09-10）。roadmap #18。

## 何を残すか

**版の残らない変更だけ**を `audit_events` に積む。

| 対象 | 積む操作 |
|---|---|
| メンバー | `member.invited` / `member.role_changed` / `member.removed` / `invitation.cancelled` |
| 鍵 | `api_key.created` / `api_key.revoked` |
| 型 | `type.created` / `type.updated` / `type.deleted` |
| フィールド | `field.added` / `field.updated` / `field.removed` / `fields.reordered` |

**WhyNot: entry の変更を積まない。** `entry_versions` が誰が・いつ・どんな中身にしたかを**版として全部**持っていて、
監査としてはそちらの方が強い。二重に持つと片方だけ残る形が作れてしまう。

**WhyNot: PAT（`personal_access_tokens`）を積まない。** PAT は本人に付いてプロジェクトを跨ぐので、
プロジェクト単位の `audit_events`（RLS が project_id で切る）に入れると、どのプロジェクトの記録にするかが決まらない。
組織の監査を作る時に、別の置き場で扱う。

## どこで積むか

ユースケースが `Audit.record(change)` を**業務の書き込みと同じ Tx で 1 回**呼ぶ（`Publishing.notify` と同じ形）。

**WhyNot: `DbRunner.transact` で全 mutation をまとめて 1 か所で積まない。** そこに揃っているのは主体とプロジェクトだけで、
何をどの対象にしたかが無い。**操作名だけの記録は監査に使えない。**

同じ Tx なので「変えたのに記録が無い」も「記録があるのに変わっていない」も起きない。
失敗した操作は記録も一緒に ROLLBACK される（`test/Pg/TestAuditPg.flix` が実 PG で確かめている）。

主体は `Session.displayName()`。人は email、鍵は `api-key:<鍵の名前>` で、**版の `author` と同じ形**。

## 書き換えられない

`audit_events` には **SELECT と INSERT の policy しか作っていない**。UPDATE と DELETE はどの policy にも当たらないので、
FORCE RLS の下ではアプリも表の所有者も書き換えられない（実 PG のテストが 0 行を確かめている）。

保持の都合で古い行を消す時は、**DELETE の policy を足す migration を書く**（消せるようにした事自体が記録に残る）。

**WhyNot: 掃除の仕事を置かない。** 積むのは管理の操作だけで、entry の編集では増えない。
1 日 10 回の型・メンバーの変更でも年 3,650 行なので、消す仕組みより消せない事の方が価値がある。

## 変更前のスキーマが残る

型・フィールドを**直した／消した**記録は、`detail` に `{ "before": ... }` で変更前の姿を持つ（`SchemaSnapshot`）。
入るのは apiId・名前・kind・性質・config で、消したフィールドは**子ごと**、消した型は**フィールド全部**。
参照先は内部の連番ではなく apiId で持つので、足し直した後も同じ型を指す。

これが「押した後に戻せるか」の答え。entry と違って型には版が無いので、消した定義はここからしか組み直せない。
`SchemaSnapshot.toDraft` が逆向きで、`addField` にそのまま渡せる。

- 純粋な往復: `test/cms/rules/TestSchemaSnapshot.flix`
- DB を通した組み直し: `test/Pg/TestSchemaRestorePg.flix`

作った・足した記録は `before` を持たない（元に戻すのは消す事なので、要る物が無い）。
メンバーと鍵も持たない。役割は 3 通りしか無く action と targetId から読めて、鍵は値を二度と出せない。

**まだ戻せないのは entry の中身**。フィールドを消すと `entry_contents` の値は残るが、監査に残るのは定義だけで、
値そのものは版（`entry_versions`）から辿る。

## 読む

管理 API の `auditEvents(first, after)`（owner だけ）。新しい順、`after` は前のページの最後の id（id は ULID）。

## 残っている物

- **読み取りの記録が無い**（誰がどの entry を見たか）。要求されてから
- **戻す操作が API に無い**。変更前の姿は残るが、押して戻す口はまだ無く、`detail` を読んで手で足し直す
- 組織（`organizations` / `org_members`）の変更は、プロジェクトを跨ぐので入っていない
