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

## 読む

管理 API の `auditEvents(first, after)`（owner だけ）。新しい順、`after` は前のページの最後の id（id は ULID）。

## 残っている物

- **読み取りの記録が無い**（誰がどの entry を見たか）。要求されてから
- **変更前の値が無い**。`detail` に入るのは役割と鍵の名前だけ。中身の差分が要るなら、版のある entry と同じ形を別に足す
- 組織（`organizations` / `org_members`）の変更は、プロジェクトを跨ぐので入っていない
