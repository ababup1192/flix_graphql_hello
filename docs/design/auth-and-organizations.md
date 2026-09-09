# 設計: 認証・組織・権限と subdomain ルーティング

状態: 2026-09-07 に実装（users / organizations / memberships / invitations / api_keys、Authz の Datalog、JWT の検証、`Session` effect、
管理 API の `me` / メンバー / 招待 / 鍵、公開 API の visibility、Host ヘッダでプロジェクト slug、Account API、RLS と生成器の検査（三重化）、外向きの id は乱数の public_id）。
auth の表（memberships / invitations / api_keys）も RLS 済み（migration 013）: `Accounts.resolveUser` が Tx に `app.user_id` / `app.email` の印を置き、
自分の memberships と自分宛の invitations だけプロジェクトを跨いで見える。api_keys はプロジェクトの印だけ。

言葉: **プロジェクト slug** は URL の `/p/{プロジェクト slug}/` と subdomain でプロジェクトを選ぶ人が読める名前（`ProjectSlug` 型。parse 済みしか作れない）。
**プロジェクト id** は DB の主キー。**既定プロジェクト** はプロジェクト slug 無しの時に落ちる先（`CMS_DEFAULT_PROJECT`）。

実装での名前: 認証済みユーザーの effect は `Actor` ではなく `Session`（`Session.current()` / `Session.require(permission)`。`Actor` は認証済みユーザーの enum）。
ユーザーの解決は `Accounts`（`resolveUser` / `actorFor` / `me`）、ヘッダから読んだ物は `Credential`（Bearer / ApiKey / PersonalToken / Preview / Missing / Invalid）で、
認証（Credential → Actor）は `Authentication` がリクエストに 1 回行い、graphql 層の `Context` は `actor` を持つ（下の「認証はリクエストに 1 回」）。API キーの write と PAT は「API キーの write と Personal Access Token」。

**今どうなっているかは [../architecture/auth.md](../architecture/auth.md)。この文書は決めた理由と、決めた時の状態を残す。**

## 目的

microCMS に対抗するサービスとして出すために、次の 3 つを足す。

1. ユーザーがログインし、自分が属するプロジェクトだけを見て切り替えられる
2. プロジェクトごとに役割（owner / editor / writer / viewer）で操作を絞れる
3. 公開側は `{slug}.example.com/graphql` のように subdomain で見える

## ユーザーから見える形

- 公開 API: `{slug}.example.com/graphql`（読むだけ。CDN でキャッシュしてよい）
- 管理 API: `{slug}.example.com/admin/graphql`（素通し）
- Account API（プロジェクトを選ぶ前の操作）: `example.com/account/graphql`（`me`、組織とプロジェクトの作成、組織のメンバー）。`account.graphql` で別のスキーマ、Runner は `Tenant` を入れない（プロジェクトのユースケースは型に `Tenant` が付くので呼べない）。API キーは断る
- 開発・内部: `/p/{プロジェクト slug}/...` も同じ意味で受け続ける（curl や Docker 内では subdomain が効かないため）
- プロジェクト slug 無しの `/graphql` / `/admin/graphql` は既定プロジェクト（`CMS_DEFAULT_PROJECT`。既定 `default`）。空にすると 404 で、クラウド版はこれで運用する
- 認証はどの経路もヘッダで渡す。プロジェクトの選択は Host / slug だけで決め、鍵は「そのプロジェクトを触ってよいか」の判定にしか使わない（2 経路で決めると食い違うため）

## データ

```
users            (id, email, name, created_at)
organizations    (id, name, created_at)                 -- 請求と所有の単位
projects         (id, org_id, slug, name, created_at)   -- 今の projects に org_id を足す
memberships      (user_id, project_id, role)            -- ユーザー × プロジェクト × 役割
api_keys         (id, project_id, key_hash, scope, created_at, revoked_at)  -- アプリ用。人の認証と混ぜない
```

- 役割は enum で 4 つ。細かい権限（この型だけ編集可、など）は後から役割の下に足す

| role | できること |
|---|---|
| owner | メンバー招待、プロジェクト削除、API キー発行 |
| editor | 型の編集、entry の作成・公開 |
| writer | entry の作成・下書き。公開はできない |
| viewer | 読むだけ |

- 既定のプロジェクト（id 1 / `default`）は既定の組織（id 1）に属させる migration を書く
- 組織はこの段で一緒に入れる。後回しにすると projects に org_id を足すだけでは済まず、メンバーの移し替えが要る

## Flix 側の形

- **ユースケース（src/cms）の DB に触る pub は権限の証明 `Granted[p]` を最初の引数で受ける。受けない物は写しか内部**（外向きの id の写し、同じ Tx に積む outbox、Runner が主体を決める前に呼ぶ認証の解決、公開の読み）で、理由を各関数の doc に WhyNot で書く（後述の「権限の証明（Granted）」。以前は Session を持つ約束を `scripts/check-session.sh` が名前の一覧で見張っていた）。仕組みが呼ぶ物（Scheduler / Import / ContentEngine）は `Session.runWith(Actor.System)` で入る
- 公開 API の鍵は `api_keys` を hash で引く。`ContentRunner` に入れるのは `Tenant` だけで、鍵はプロジェクトへの読み取り許可の判定にしか使わない
- `Server.splitProject` の前に Host の先頭ラベルを slug として拾う。パスの `/p/` があればそちらを優先。予約 slug（`www` / `api` / `admin` / `app` など）は `Projects.create` で弾く。slug は作った後は変えない（URL が変わるため。microCMS も同じ）
- JWT は Flix で発行しない。**OIDC の JWKS で検証し `sub` と `email` を取るだけ**に閉じ、発行元は環境変数（issuer URL / JWKS URL / audience）で差し替える。最初は Cloudflare Access（50 人まで無料、社内利用向き。ヘッダ `Cf-Access-Jwt-Assertion`）。顧客が自分で登録する段になったら Clerk / Auth0（1 万 MAU まで無料）、セルフホストは Keycloak か自前のマジックリンクへ。どれも同じ検証コードで通る

## アーキテクチャの決め（2026-09-07 追記）

### 流れ

Host / パスから projectId（既存の Tenant）→ ヘッダ（`Cf-Access-Jwt-Assertion` / `Authorization: Bearer` / `X-Api-Key`）を読む →
`TokenVerifier` effect で JWT を検証して Principal（issuer, sub, email）→ users / memberships から Actor（ユーザー + このプロジェクトの役割）→
`Actor` effect の handler に入れ、ユースケースは `Actor.require(permission)`。

### effect

| effect | 操作 | handler |
|---|---|---|
| `TokenVerifier` | `verify(token): Result[String, Principal]` | 本番: JWKS（`Net.Http`、10 分キャッシュ）と Java 標準の `KeyFactory` / `Signature` で RS256 / ES256。テスト: 固定。開発: `CMS_AUTH=dev` の時だけ `X-Dev-User` を信じる（`CMS_VERSION` が dev 以外なら起動を拒む） |
| `Actor` | `current(): Actor`、`require(permission): Unit \ CmsErr` | Runner がリクエストごとに入れる。テストは `PgTestSupport.withDb` が既定で owner を入れ、権限のテストだけ `Actor.runAs(...)` で上書き |

### Datalog は権限の判定に使う

`Authz`（純粋な mod）の中で、役割が持つ権限・役割の包含（owner ⊃ editor ⊃ writer ⊃ viewer）・組織の owner が全プロジェクトの owner である事を
事実と規則で書き、`Authz.can(roles, permission)` で引く。理由: 包含と継承が再帰で、後から「この型だけ」「この entry の担当」を事実 1 行で足せる。
Fixpoint の導出追跡で「なぜ駄目か」を出す道もある。判定だけに使い、DB や JWT には使わない。

### データ

```
users          (id, issuer, subject, email, name, created_at)   -- 本人の鍵は (issuer, subject)。email は表示と招待の突き合わせ
organizations  (id, name, created_at)
org_members    (user_id, org_id, role: owner | member)
projects       (+ org_id, visibility: public | private)
memberships    (user_id, project_id, role: owner | editor | writer | viewer)
api_keys       (id, project_id, name, key_hash, scope: read | readDraft, created_at, revoked_at)   -- sha256(pepper + key)
```

- 公開 API は既定でキー無し（公開中の中身だけ。CDN のキャッシュキーにヘッダを入れずに済む）。`readDraft` のキーで下書きの一覧を読める。
  プロジェクトの `visibility = private` ならキー必須
- 最初の owner: `CMS_BOOTSTRAP_OWNER=you@example.com`。その email の初回ログインを既定の組織の owner にする
- 招待: email で users に無ければ招待中の行を作り、初回ログインで (issuer, subject) を結ぶ
- Account API（`example.com/account/graphql`）は `Tenant` 無しの別エンジン（`src/account/`）。`me` / 組織 / プロジェクト作成 / 組織のメンバーだけ受ける。`CMS_SIGNUP=closed` なら組織を作れるのは既定の組織の owner だけ

### 環境変数

`CMS_AUTH`（`jwks` | `dev`）、`CMS_AUTH_ISSUER`、`CMS_AUTH_JWKS_URL`、`CMS_AUTH_AUDIENCE`、`CMS_AUTH_HEADER`（既定 `Cf-Access-Jwt-Assertion`）、
`CMS_BOOTSTRAP_OWNER`、`CMS_API_KEY_PEPPER`、`CMS_DEFAULT_PROJECT`、`CMS_SIGNUP`。インフラは増えない（Access は無料、セルフホストは compose の profile `auth` で Keycloak）。

### 懸念と対処

| 懸念 | 対処 |
|---|---|
| JWT 検証の自作（alg 混同、exp / aud / iss の見落とし） | alg を RS256 / ES256 に固定、全項目を検査、自前の鍵で署名したテストで固定 |
| email で人を同定する危うさ（発行元を替えると sub が変わる） | 鍵は (issuer, subject)。発行元の移行は email で 1 回だけ結び直す手順を持つ |
| 既存の PG テスト 46 件 | `withDb` が既定で owner を入れるので変更ゼロ |
| ブラウザの Cookie と CORS | 管理画面を Access の同じアプリの下に置く。`Allow-Credentials` を足す |
| 公開 API をキー無しにする判断 | `visibility` で切り替え。既定は公開 |
| 監査ログ | この段では入れない。Runner で Actor と操作名が揃うので後で 1 か所 |

### セキュリティの決め（規模で緩めない）

**先に直すコードの問題**

- `POST /graphql` は `Content-Type: application/json` 以外を 415 にする（Cookie 認証を入れた時の CSRF。`text/plain` の form POST は preflight 無しで届く）。mutation は `Origin` / `Sec-Fetch-Site` も見る
- JSON ログの `path` からクエリ文字列を落とす（プレビュー トークンや GET のクエリを残さない）

**設計**

- 管理 API の Query（`contentTypes` / `entries` / `entry` / `assets` / `publishCheck` / `impact`）も `readDraft` を要求。既定は拒否
- `CMS_AUTH=dev` は 127.0.0.1 にしか bind せず、`CMS_VERSION=dev` の時だけ起動する。ヘッダで人になれる経路が本番に存在しない事を起動時に保証
- JWT: alg は RS256 / ES256 のみ（`none` / HS256 は拒否）、`kid` で鍵を引き、無ければ JWKS の再取得は 1 回だけ（以後 10 分待つ）、`iss` / `aud` / `exp` / `nbf` を全部検査、時計のずれ 60 秒、`email_verified` があれば true を要求
- API キー: 256 bit の乱数、`cms_` 接頭辞 + 検査和、`sha256(pepper + key)` に pepper の版（`pepper_id`）を持って回せる、比較は `MessageDigest.isEqual`、hash で引いた後に Host のプロジェクトと一致するかを確かめる（キーがプロジェクトを決めない）、失効は行を残す
- プレビュー トークン: project + entry + 期限 + 用途を署名、定数時間の比較、API キーの pepper とは別の秘密、最大 7 日
- `image/svg+xml` は既定の許可リストから外す（スクリプトを含められる）。要る時は設定で明示し `Content-Disposition: attachment`
- `users` は `(issuer, subject)` UNIQUE、`email` は UNIQUE にしない（発行元をまたぐと重なる）。招待は `invitations(org_id, email, role, token_hash, expires_at)` を別表にし、初回ログインで消す
- 他テナントの物は 404 のまま（存在を漏らさない）。権限の失効は membership を毎リクエスト引くので即時
- `api_keys.key_hash` UNIQUE、`(project_id, revoked_at)` に index

**確認済みで問題なし**: richText の HTML（エスケープ、href / embed の許可リスト、noopener）、asset（署名に Content-Type / Length、乱数 id、一覧不可、使用中は消せない）、GraphQL（深さ 15、first 200、1 操作）、HTTP（上限とタイムアウト、制御文字除去）、テナントの型強制、compose の必須値。

### テナント分離の三重化

1. 型: `Tenant` effect の未使用はコンパイルで落ちる（済み）
2. 生成器（済み、sqlfx 0.2.0）: `gen --scope project_id` で、`project_id` 列を持つ表を触る query に列の名前が無ければ生成を失敗させる。
   意図して跨ぐ query は `// unscoped: 理由`。`projectId` は呼ぶ側が渡す（sqlfx が CMS の effect を知らないため。RLS が受け止める）
3. DB（済み、migration 012）: 中身の 6 表に ENABLE / FORCE と policy `project_id = nullif(current_setting('app.project_id', true), '')::bigint`（USING と WITH CHECK）。
   印は Runner が `TenantTx.withLazyTx`（sqlfx の `Pool.withLazyTxAfterBegin`）で BEGIN の直後に `set_config('app.project_id', $1, true)` を流す。
   Account API は印を置かないので中身の表は 0 行。接続は `CMS_DB_APP_PASSWORD` があれば所有者でない `cms_app`（起動時に `AppRole.ensure` が作る）。
   注意: docker の POSTGRES_USER は superuser で RLS を素通りするので、API のテストは `PgTestSupport.withPool` が cms_app で繋ぎ、
   TestRlsPg は 6 表それぞれで SELECT / UPDATE / DELETE / INSERT と印の無い Tx を見る。Runner の印を外すと 4 件が落ちる事を確かめた

### 後から足す属性ベースの権限に備える

- `Authz.can(actor, permission, resource)` は最初から resource（型 id、entry の属性）を受ける。今は使わない
- `Authz.readFilter(actor): List[Condition]` を用意し、管理 API の `entries` とコンテンツ API の一覧に AND で付ける。今は空
- 後で `access_rules(project_id, subject_kind, subject_id, field_api_id, allowed_values)` を足し、Datalog の事実（`Scope`）と readFilter で
  「このタグの記事だけ」を人にも API キーにも付けられる。RLS はテナント境界に限り、属性の絞り込みは SQL の条件で行う

## API キーの write と Personal Access Token（2026-09-07 追記。実装済み）

人の代わりに叩く身元を 2 つに分ける。**プロジェクトの API キー**（CI 用。`X-Api-Key`）と、**本人の PAT**（CLI 用。`Authorization: Bearer cmspat_...`）。

### API キーの write

- `ApiKeyScope` に `Write(Role)` を足した。DB は `scope='write'` + `role` 列（`CHECK ((scope='write') = (role IS NOT NULL))`、役割は writer / editor / owner。viewer の write は readDraft と同じなので作らせない）
- `Authz.can(Actor.ApiKey(Write(role)))` はその役割の表で引く。ただし **manageMembers / manageApiKeys / manageProject は鍵では常に false**（鍵で鍵やメンバーを作る道を作らない）
- 発行者（人）の役割より高い役割の鍵は invalid。発行は owner だけなので今は owner 以下の検査。`expiresAt` は未来だけ（過去は invalid。今は Runner の `Time.Clock`）。
  番兵（role 無し = ''、期限無し = 0）を知るのは `AuthRows.toApiKeyInsert` だけ
- **発行はログインの JWT で来た本人だけ**（`Session.requireInteractive`）。PAT や API キーからは作れない。鍵が書いた版の author は `api-key:<鍵の名前>`（`Actor.ApiKey(name, scope)`）
- `expires_at`（任意）と `last_used_at`。期限切れは `ApiKeys.resolve` が None にする（時計は Runner が `Time.Clock.now()` で渡す）。`last_used_at` は **管理 API と Account API の Runner** が主体を決めた後に書き、前回から 60 秒より古い時だけ UPDATE する。
  コンテンツ API（ContentRunner。GET と POST の読み取り）では書かない: CDN 越しに大量に来る道に UPDATE を足さない。「CI の鍵が生きているか」は管理 API の使用で分かる

### Personal Access Token（PAT）

- 表 `personal_access_tokens`（user_id → users、token_hash UNIQUE、scope read / write、expires_at NOT NULL、last_used_at、revoked_at）。接頭辞 `cmspat_`、ハッシュは API キーと同じ pepper 方式（`SecretHash.hash`。寿命の判定も `SecretHash.isAlive`）。既定 90 日、最長 365 日
- ドメインは `PersonalTokens`（issue / revoke / list / resolve / touch）。プロジェクトを持たない（本人に付く）ので Tenant を取らない
- 主体: `RequestIdentity.resolveForProject` / `resolveForAccount` が hash で引き、`Accounts.resolveUserById`（users を引いて `app.user_id` の印を置く。招待の受け入れと bootstrap はしない）→ 管理 API は `Accounts.actorFor`（本人のそのプロジェクトでの役割）、Account API は `actorWithoutProject`。
  主体は **`Actor.User(id, email, roles, Login)`** で、`Login` が `Interactive`（ログインの JWT）か `PersonalToken(scope)` かを持つ。
  - read の PAT: `Authz.effectiveRoles` が役割を viewer に落とし、書く操作の入口 `Session.currentUser()`（組織の作成、メンバー、PAT の失効）は `requiresLogin`。自分を読む物（me、`organization(id)` / members / projects、自分の PAT の一覧）は `Session.currentUserForRead()` で読める
  - write の PAT: 本人と同じ（メンバー管理まで。CLI の用途）。ただし **PAT と API キーの発行は `Session.requireInteractive()` でログインの JWT だけ**（漏れた PAT を失効すれば、それで作られた物は無い）。失効は PAT からもできる（減らす方向）
  - 期限切れ・失効・知らない物・消えたユーザーは `PatRejection`（Expired / Revoked / Unknown）で Runner が「認証に失敗しました: …」として断る（`Credential.Invalid` と同じ形。黙って匿名にしない）
- ヘッダ: `Credentials.ofHeaders` が `Authorization: Bearer` の値が `cmspat_` で始まれば `Credential.PersonalToken`、そうでなければ今まで通り（`CMS_AUTH_HEADER` の JWT）。JWT のヘッダが別（Cloudflare Access）でも PAT は Authorization から読む
- Account API: `createPersonalAccessToken(name, scope, ttlDays)` / `revokePersonalAccessToken(id)` / `Me.personalAccessTokens`。本人だけ

### PAT の RLS（policy の決め）

一覧と失効は本人の印 `app.user_id`（`Accounts.resolveUser` / `resolveUserById` が置く）で守る。hash での解決は本人が分かる **前** に走るので、
policy 無しの SELECT にすると一覧が RLS で守られなくなる（query の WHERE だけになる）。代わりに **トークンの hash 自体を Tx の印（`app.token_hash`。`TenantQueries.stampTokenHash`）** にし、
policy を `USING (user_id = app.user_id OR token_hash = app.token_hash)`、`WITH CHECK (user_id = app.user_id)` にした。印は秘密から導いた値なので、印を知る者は既にトークンを持っており、他人の行は hash が違うので見えない。
`last_used_at` の UPDATE は `WITH CHECK` が本人の印を見るので、必ず `resolveUserById` の後に流す（`RequestIdentity.touch`）。

pepper の回転: 行の `pepper_id` は解決時に使っていないので、`CMS_API_KEY_PEPPER` を回すと API キーと PAT は全部再発行になる（deploy/README）。

## 見えないは UI ではなく API が守る

切り替え候補に出さないだけでなく、`business.example.com/admin/graphql` を叩いても membership が無ければ 403。
テストは `TestTenantPg` と同じ形で「Consumer の editor が Business の型を読めない・作れない」を書く。

## 関連

- 他のクラウド型 CMS の形: microCMS / Sanity / Prismic は subdomain、Contentful / Hygraph はパス、Storyblok はトークンだけ。
  どれも読み取り（CDN）と書き込み（管理）はホストを分けている
- 後回しにしてよい物: entry id をプロジェクトごとに重ねる（PK を `(project_id, id)` にする。約 1 日）、RLS

## 認証はリクエストに 1 回（2026-09-08 追記。実装済み）

Schema の `Field.erase` が全フィールドを Runner で包むので、Runner の Tx の先頭で認証していた時は、認証（JWT なら users / invitations / memberships / org の SELECT 6〜7 本、鍵と PAT なら hash の検索と last_used_at の UPDATE）がフィールドの数だけ繰り返されていた（entries 50 件 × 10 フィールドで 503 回。`TestQueryBudgetPg` の実測で 3723 本の SQL）。

- 認証は **`Main.runRoute` がリクエストに 1 回**、プロジェクトの解決と同じ Tx（`DbRunner.withTx`）で `Authentication.resolve(deps, engine, scope, credential)` を呼ぶ。middleware（`Credentials.wrap` の隣）に置けないのは、API キーの解決と membership の検索がプロジェクトの RLS の印の下で行を見るので、プロジェクトが決まってからでないと SQL を出せないため。/p/ と Host の経路はプロジェクトの SELECT と同じ Tx、既定プロジェクトの経路は認証の Tx が 1 つ増える
- `Context` は Credential でなく **`actor`（認証済みユーザー）** を持つ。Runner は `AppEnv.runWith` → `DbRunner.transactObserved(pool, scope, observe, context#actor, f)` → `toFieldResult` の 2 段で、認証も `Credential.Invalid` の分岐も持たない
- 断る理由は `Rejection`（`Invalid` / `DeadToken(PatRejection)` / `NotForAccount` / `PrivateProject` / `NotMember`）で `RouteRequest#auth` に載り、形は handler が決める: `/graphql`（POST / GET）は 200 で `data: null` と path 無しの `errors[]` 1 件（`extensions.code`）、`/mcp` は 401 + `WWW-Authenticate`。`Credential.Invalid` の断りも認証の先頭の 1 か所。ただし**コンテンツ API だけは壊れたログインの JWT を匿名に落とす**（public なら公開中が読め、private なら匿名として `UNAUTHENTICATED`。ログには credential.kind = invalid の印）。公開の読み取り API は資格証明の良し悪しを教える場所ではなく、CDN の前に置く API がヘッダを無視するのと同じで、古い JWT がブラウザに残っている公開サイトを壊さないため
- `DbRunner.transact(pool, scope, actor, f)` が BEGIN の直後に RLS の印（プロジェクトと、人なら `app.user_id` / `app.email`）を置き、`Session` の handler と `Db.guard` を入れる。Session の handler はここだけ。仕組みが呼ぶ物（Scheduler / MicrocmsCli / ContentEngine の組み直し / テストの mutate）は `Actor.System` を渡す
- RLS の policy は `app.project_id` / `app.user_id` / `app.email` / `app.token_hash` の 4 つ。`app.token_hash` は `PersonalTokens.resolve`（認証の Tx）だけが置く。業務の Tx で personal_access_tokens を読む一覧・失効は本人の印で通る
- `last_used_at` は認証の Tx で COMMIT される（業務が失敗してもトークンは使われたので残すのが正しい）。コンテンツ API は書かない（CDN の道に UPDATE を足さない）
- private なプロジェクトのコンテンツ API は認証の Content の分岐で断る。匿名は `UNAUTHENTICATED`、メンバーでない人は `FORBIDDEN`（以前はどちらも INVALID）
- 失敗は層ごとに 1 種類: 認証は `Rejection`、ドメインは `CmsFailure`、DB は `DbFailure`。Tx の境界（`DbRunner.transact`）は `ApplicationFailure`（`Infrastructure` / `Domain`）で返し、`toFieldResult` / `GraphqlErrors` / `LogFields` は平らな match で写す。ドメインは UNAUTHENTICATED を出せない
- Unit of Work は**ルートフィールドごとの Tx のまま**（変えない）。1 リクエストに mutation を並べても互いに独立で、2 つ目が業務エラーでも 1 つ目は COMMIT されている。まとめたい操作は 1 つの mutation にする（`TestAdminMutationsPg.testPgRootFieldsAreIndependentTransactions`）
- 数は `db.statements` / `db.transactions`（docs/logging.md）で見え、`TestQueryBudgetPg` が上限で見張る。実測: JWT で entries 50 件 × 10 フィールドが 3723 → 209 本（認証 1 回）→ 12 本（版と型の先読み。`Preloaded`）、`contentTypes { name }` が 16 → 9 本（認証 1 回分）、API キーの一覧が 1208 → 204 → 7 本、コンテンツ API の一覧 50 件 + 参照先が API キーで 5 本

## 権限の証明（Granted）（2026-09-08 追記。第 1 段・第 2 段とも実装済み）

「DB に触る pub のユースケースは中で `Session.require(permission)` を呼ぶ」は約束で、守られているかは `scripts/check-session.sh` が名前の一覧で見張っていた。
権限の証明を値にして引数で渡す形に変え、呼び忘れをコンパイルエラーにした。

### 形

- `Granted[p]`（`src/cms/model/Granted.flix`）は権限の証明。p は印の型（`ReadDraft` / `WriteEntries` / `PublishEntries` / `ManageTypes` / `ManageAssets` / `ManageMembers` / `ManageApiKeys` / `ManageProject`。`Permission` の腕と 1 対 1 の空の enum）で、値は持たない（phantom）
- 作れるのは `Session.grant(): Granted[p] \ Session + CmsErr with Perm[p]`、対象付きの `Session.grantOn(resource)`、できなければ None の `Session.tryGrant(): Option[Granted[p]] \ Session` だけ。中は `Authz.can` で、通らなければ forbidden。p は渡す先の引数の型から決まる（`ContentTypes.create(Session.grant(), draft)`）
- 印の型 → 実行時の `Permission` は trait `Perm[p] { def permission(proof: Granted[p]): Permission }` の instance（権限ごとに関数を増やさない）
- ユースケースの pub の入口は `pub def create(_proof: Granted[ManageTypes], draft: ContentTypeDraft): ContentType \ Db + CmsErr + IdGen + Tenant` のように最初の引数で証明を受け、`Session` を持たず、自分では判定しない。呼ぶ側（src/admin のリゾルバ、`ContentEngine.rebuild`、`Scheduler`、`MicrocmsImport`、テスト）が `Session.grant()` で作って渡す
- ユースケースが Session を持つのは主体そのものを読む時だけ（`Session.currentUser()` / `displayName()` / `currentUserForRead()`。Members.invite、Schedules.schedule、ApiKeys.create の発行者の役割、PersonalTokens）
- 来かたの証明: 鍵と PAT の発行は `Granted[Interactive]`（印 `Interactive`。Perm の instance は無く `Session.grant()` では作れない。`Session.grantInteractive()` がログインの JWT かサーバ自身にだけ作る）を受ける。`ApiKeys.create(Session.grant(), Session.grantInteractive(), pepper, draft, now)` のように 2 つの証明を並べる
- 書く証明から読む証明: `Session.readDraftOfWriter(Granted[WriteEntries]): Granted[ReadDraft]` と `readDraftOfPublisher`。判定し直さない（writeEntries / publishEntries を持つ主体は Authz の Implies で全部 readDraft も持つ）。この含意は `TestGranted.testReadDraftIsImpliedByWriteAndPublish` が主体の一覧で見張る。ContentEntries が型の定義（`ContentTypes.get`）を引く時に使う
- 条件付きの証明: 公開中の entry の削除は取り下げも要る。`ContentEntries.delete(proof: Granted[WriteEntries], unpublishing: Option[Granted[PublishEntries]], id)` で、呼ぶ側が `Session.tryGrant()` で持てるだけ渡し、公開中なのに None なら forbidden(publishEntries)（writer は下書きは消せるが公開中の物は消せない、を型で残す）
- コンテンツ API: `ContentEntries.StageAccess`（`Published` は証明なし、`Draft(Granted[ReadDraft])`）で stage を受ける。公開中は誰でも読める（private なプロジェクトは認証が断る）ので証明が要らず、下書きは content 層（`ContentSchemaBuilder.accessTo`）が 1 件なら `grantOn(entryResource(id))`（プレビュートークンはその entry だけ通る）、一覧なら `grant()` で作る
- リゾルバは「ラムダに effect を使う式を直に書かない」決まりに合わせ、`Session.grant()` を呼ぶ小さな関数（`createType(input)` など）に切り出してラムダからはそれを呼ぶ
- 証明を受けない DB の pub は意図的に権限を見ない物で、理由を各関数の doc に WhyNot で書く: 認証と起動が主体を決める前に呼ぶ物（Accounts.resolveUser / resolveUserById / actorFor、ApiKeys.resolve / touch、PersonalTokens.resolve / touch、Projects.findBySlug / find / visibilityOf / contentVersion）、外向きの id の写し（Accounts.requireByPublicId、Organizations.idOfPublic）、組織側の部品（Accounts.findByEmail、Projects.listOfOrg）、outbox とプロジェクトの版（Webhooks.emitEntry / emitSchema、Projects.bumpContentVersion）、公開の読み（Assets.findMany）
- `scripts/check-session.sh` と `scripts/session-allowlist.txt` は廃止。「DB に触る pub は証明を受ける」が型で守られ、受けない物は署名に `Granted` が無い事と doc の WhyNot で読める

### Flix で書けた所と妥協した所

- phantom の型引数（`pub enum Granted[_p]`）、空の enum を印の型にする事、trait の instance を印の型ごとに付ける事、`Session.grant()` の p を呼び出し先の引数の型から推論する事、enum の payload に証明を載せる事（`StageAccess.Draft`）、はそのまま書けた
- **コンストラクタを mod の外に出せない。** Flix の enum の case は型と同じ可視性で、case だけを隠せない。本体を `mod Session` の中の `pub enum Granted[_p](Seal)` にし、中身の `Seal` を非 pub の enum にして、作れるのを Session の中だけにした。署名で短く書くための alias `pub type alias Granted[p] = Session.Granted[p]` をトップに置く。手元に 1 つ証明があれば `let Granted.Granted(seal) = proof` で中身を取り出して別の印の証明を組めるが、守りたいのは書き忘れであって悪意ではないので、ここまでで止めている
- **`Perm.permission(): Permission` のような証明を受けない trait の署名は書けない。** trait の署名には型変数 p が現れなければならず、p が phantom の Granted は値として渡す以外に p を決める手が無い。`permission(proof: Granted[p])` の形にした
- **含意（p ⇒ q）を型で一般に書かなかった。** Flix の trait は 1 引数で、2 つの印の関係を trait で表すには associated type が要る。要るのは「書く → 読む」の 2 本だけなので、Session の中の具体的な関数（`readDraftOfWriter` / `readDraftOfPublisher`）にし、含意が Authz と合っている事はテストで見張る
- `grantOn(resource)` の Granted は対象（entryId）を値で持たない。今の使い方（コンテンツ API の 1 件の下書き）は判定して通すだけなので、証明にも載せない。載せたくなったら `Granted` を `(Seal, Resource)` にする
- 証明を引数の先頭に置くと、引数の評価順で権限の判定が入力の検査（AdminMapping の parse）より先に走る。以前は入力の invalid が forbidden より先に出ていた（権限の無い人にも入力の誤りが見えていた）ので、今の順の方が正しい

### CmsErr.runWithResult（Tx の境界だけが呼ぶ）

`CmsErr.runWithResult` はユースケースの途中で呼ぶと業務エラーが Tx の中で値に潰れ、ROLLBACK も errors[] への写しも起きない。呼べるファイルを `scripts/cmserr-allowlist.txt` で見張っていたが、
関数そのものを Tx の境界（`DbRunner`）の private にして allowlist と `check-cmserr.sh` を廃止した。CmsErr には失敗の値 `CmsFailure` だけを残し、handler を書く場所は DbRunner（`runCmsErr`）とテストの `CmsTestKit.runWithResult`（テストは自分で境界を作るのが仕事）の 2 つ。
Seal 付きの印（`TxBoundary`）を引数に取る案は、テストが印を作れる pub の入口を要求して結局 allowlist と同じ穴になるので選ばなかった。
