# 設計: 認証・組織・権限と subdomain ルーティング

状態: 未着手（2026-09-07 に方針だけ決めた）。テナント（projects / `Tenant` effect / `/p/{slug}/`）は
実装済みで、この設計はその上に載せる。今の実装で先にやっておく事は無い。

## 目的

microCMS に対抗するサービスとして出すために、次の 3 つを足す。

1. ユーザーがログインし、自分が属するプロジェクトだけを見て切り替えられる
2. プロジェクトごとに役割（owner / editor / writer / viewer）で操作を絞れる
3. 公開側は `{slug}.example.com/graphql` のように subdomain で見える

## ユーザーから見える形

- 公開 API: `{slug}.example.com/graphql`（読むだけ。CDN でキャッシュしてよい）
- 管理 API: `{slug}.example.com/admin/graphql`（素通し）
- プロジェクトに属さない管理 API: `example.com/admin/graphql`（`me`、プロジェクト一覧、組織の操作）
- 開発・内部: `/p/{slug}/...` も同じ意味で受け続ける（curl や Docker 内では subdomain が効かないため）
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

- **`Actor` effect** を `Tenant` の隣に置く。`Actor.current(): Actor`（ユーザー id と今のプロジェクトでの役割）と `Actor.require(role)`。Runner が JWT を検証して membership を引き、`Tenant.runWith` と一緒に handler を入れる
- ユースケースは `Actor.require(Editor)` のように書く。権限チェックの抜けは「Actor effect を使っていない」でコンパイル時に見つかる（テナントと同じ守り方）
- 公開 API の鍵は `api_keys` を hash で引く。`ContentRunner` に入れるのは `Tenant` だけで、鍵はプロジェクトへの読み取り許可の判定にしか使わない
- `Server.splitProject` の前に Host の先頭ラベルを slug として拾う。パスの `/p/` があればそちらを優先。予約 slug（`www` / `api` / `admin` / `app` など）は `Projects.create` で弾く。slug は作った後は変えない（URL が変わるため。microCMS も同じ）
- JWT の発行元は Cloudflare Access か自前かをこの段で決める。検証は Flix 側で行う（構成メモ: Flix の責務は GraphQL と JWT 検証）

## 管理 API に足す物

- `me { id email projects { slug name role } }`: 切り替え候補。membership が無いプロジェクトは出ない
- `createProject(orgId, slug, name)`: 組織の owner だけ
- `inviteMember(projectId, email, role)` / `removeMember` / `changeRole`: プロジェクトの owner だけ
- `createApiKey(projectId, scope)` / `revokeApiKey`: owner だけ。生の鍵は作った時に 1 回だけ返す

## 見えないは UI ではなく API が守る

切り替え候補に出さないだけでなく、`business.example.com/admin/graphql` を叩いても membership が無ければ 403。
テストは `TestTenantPg` と同じ形で「Consumer の editor が Business の型を読めない・作れない」を書く。

## 見積もり

3〜4 日。内訳: 表と migration（0.5）、JWT 検証と Runner への組み込み（1）、Actor effect と既存ユースケースへの
`require` 追加とテスト（1）、`me` とメンバー・鍵の mutation（1）、Host ルーティングと予約 slug（0.5）。

## 関連

- 他のクラウド型 CMS の形: microCMS / Sanity / Prismic は subdomain、Contentful / Hygraph はパス、Storyblok はトークンだけ。
  どれも読み取り（CDN）と書き込み（管理）はホストを分けている
- 後回しにしてよい物: entry id をプロジェクトごとに重ねる（PK を `(project_id, id)` にする。約 1 日）、RLS
