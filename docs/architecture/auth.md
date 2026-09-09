# 認証と権限（現状の仕様）

読むタイミング: 認証の道・権限の判定・API キー / PAT / プレビュートークンを触る時。
設計の由来と決めた事は [../design/auth-and-organizations.md](../design/auth-and-organizations.md)。

言葉: Credential → Actor の解決を**認証**、Actor を**認証済みユーザー**と呼ぶ。

## 認証の道

ヘッダから読んだ `Credential`（Bearer / ApiKey / PersonalToken / Preview / Missing / Invalid）は `Credentials.wrap`（src/app）が RouteRequest に入れる。**認証はリクエストに 1 回**、`Main.runRoute` がプロジェクトの解決と同じ Tx（`DbRunner.withTx`）で `Authentication.resolve` を呼ぶ。middleware に置けないのは、API キーの解決と membership の検索がプロジェクトの RLS の印の下で行を見るため。

- **Credentials** — ヘッダ → Credential。PAT / JWT / X-Api-Key / X-Preview-Token の順
- **Authentication** — Credential → 認証済みユーザー `Authenticated = { actor, log }`。`resolve(deps, engine, scope, credential)` は Tx の中で呼ぶ物。API キーと PAT の hash 解決、`last_used_at`（Admin / Account だけ）、private なプロジェクトの断り（Content）、Account に鍵とプレビューが来た断り。断る理由は `Rejection`（Invalid / DeadToken / NotForAccount / PrivateProject / NotMember。`code` と `message`）で、RouteRequest の `auth` に載り、形は handler が決める

graphql 層の Context は認証済みユーザー（`actor`）を持ち、Runner は認証をしない。認証に落ちた物は /graphql は 200 と path 無しの errors[] 1 件、/mcp は 401 で断る。

鍵と PAT の使用時刻（last_used_at）は認証の Tx で COMMIT される（業務が失敗しても残る。コンテンツ API では書かない）。

## 主体

- **人** — `Actor.User(id, email, roles, Login)`。`Login` がログインの JWT（Interactive）か PAT（scope 付き）かを持つ
- **API キー** — `scope: WRITE` + `role` で管理 API の mutation を役割の範囲で叩ける（メンバー・鍵・プロジェクトの管理は鍵では不可。`expiresAt` で期限、`lastUsedAt` は管理 API の使用だけ 1 分粒度で記録）
- **PAT**（Personal Access Token）— `Authorization: Bearer cmspat_...`、Account API の `createPersonalAccessToken`。本人の役割で動く。READ の PAT は `Authz` が viewer に落とし、書く入口 `Session.currentUser()` は拒む（自分を読む物は `currentUserForRead()`）。死んだ PAT は `Rejection.DeadToken(PatRejection)`。表 personal_access_tokens の RLS は本人の印と `app.token_hash` の印（解決の時だけその 1 行。置くのは `PersonalTokens.resolve` だけ）
- **プレビュートークン** — `X-Preview-Token`、`Actor.Preview(entryId)`。その entry と参照先の下書きだけ読める。判定は `Authz.can` の resource（entryId）
- **仕組み** — `Actor.System`

API キーと PAT の発行は `Granted[Interactive]`（`Session.grantInteractive()` がログインの JWT にだけ作る。PAT や鍵からは作れない）を引数で受ける。

## 権限の証明（Granted）

ユースケースは権限の証明（`Granted[p]`。`src/cms/model/Granted.flix`）で守り、判定は `Authz.can`（Datalog）。

- DB に触る pub のユースケースは最初の引数で `Granted[ManageTypes]` のような証明を受け、自分では判定しない
- 証明は `Session.grant()`（対象付きは `grantOn(resource)`、できなければ None の `tryGrant()`）だけが作り（中身の `Session.Seal` は非 pub）、印の型 → Permission は trait `Perm` の instance
- 呼ぶ側（リゾルバ・ContentEngine・Scheduler・MicrocmsImport・テスト）が `ContentTypes.create(Session.grant(), draft)` の形で渡し、作り忘れは引数不足でコンパイルが落ちる
- 証明を取らない pub は意図的に権限を見ない物（認証と起動が呼ぶ物、outbox、id の写し、公開の読み）で、理由を各関数の doc に WhyNot で書く
- 書く証明から読む証明は `Session.readDraftOfWriter` / `readDraftOfPublisher`（判定し直さない。Authz の Implies で常に通る事を TestGranted が見張る）
- 公開中の entry の削除に要る取り下げの証明は、呼ぶ側が `Session.tryGrant()` で持てるだけ渡す
- コンテンツ API の stage は `ContentEntries.StageAccess`（Published は証明なし、Draft は `Granted[ReadDraft]` 付き）
- ユースケースが Session を持つのは主体そのものを読む時（`currentUser()` / `displayName()`）だけ

役割は owner ⊃ editor ⊃ writer ⊃ viewer、組織 owner はプロジェクト owner。

## 公開 API の見え方

public なら鍵無しで公開中を読め、`stage: DRAFT` は readDraft、private は API キー（`X-Api-Key`）か役割が要る（匿名は UNAUTHENTICATED、メンバーでない人は FORBIDDEN。認証で断るのでリゾルバは走らない）。

## 起動と dev

最初の owner は `CMS_BOOTSTRAP_OWNER` の初回ログイン。dev 認証（`X-Dev-User`）は `CMS_VERSION=dev` の時だけで、その時は 127.0.0.1 にしか bind しない。
