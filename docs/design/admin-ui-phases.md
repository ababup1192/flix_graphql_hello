# 管理画面の実装のフェーズ（2026-09-11 更新）

仕様は [admin-ui-spec.md](admin-ui-spec.md)、モックは https://claude.ai/code/artifact/0bd9dace-75e1-4d99-9cd5-9232f820d3c1 。
実装は仕様の 11 章（Elm の決まり）に従う。

最初の目標（管理者が組織とプロジェクトを作り、編集者を招待し、招待された人がコンテンツを作って公開できる）は 2026-09-09 にローカルで通った。
その後に、型の編集（消す前・締める前の影響と見本）、一覧とボード、⌘K、バージョン履歴と差分、メディア、API キーと PAT、Webhook、監査ログ、API プレビューが入った（2026-09-11）。
済んだフェーズはここから消してある。**残りの正はロードマップの #9**（[roadmap.md](roadmap.md)）。

**見積りは日数で置かない。** 「区切り」= 人が触って確かめる回数で書く。実際に時間を食うのは、書く事ではなく **決めを待つ所・確かめる所・未知の所** の 3 つ。

各フェーズは「動かして確かめる事」が終わりの条件。

---

## P3.9 運用の配線

**目的**: 本番に出せる状態にする（ここで初めて本番に出す価値が生まれる）。

- `deploy/` の Caddy を 2 ホストに分ける（`admin.` に Access、`cms.` は Access 無し）
- admin-ui のイメージ化と compose、**CMS と同じ sha で出す**（別々だと SDL の変更で片方だけ古くなる）。起動時に `/health` の version と自分の sha を比べ、不一致なら帯を出す
- `index.html` は `no-store`、`/assets/*` は `immutable`、Cloudflare の Bypass ルール、chunk の読み込み失敗で 1 回だけリロード、旧 chunk を 1 世代残す
- Caddy の access log を JSON で出して Loki へ（chunk の 404 と 4xx/5xx が見える）
- ロールバックの手順を 1 本書く（両方を同じ 1 つ前の sha に固定 → 管理画面のキャッシュを purge）
- compose の `CMS_SIGNUP` の既定を `closed` に

`admin-ui.yml`（elm-review / elm-format --validate / elm-test / build / `ui-gen-check` / `x-dev` の grep）とログインの email の正規化は済み。

**区切り**: 1 回

---

## P5 公開まわりの残り

- まとめて公開（`publishPlan` → `publishMany`）と、公開時に一緒に公開される物（`impact(action: PUBLISH)` の cascades）
- `createPreviewToken` / `deleteEntry` の導線
- 予約の一覧（失敗の理由。`Schedule.status` と `lastError` の置き場が今どこにも無い）

右のレール（公開前の確認 → 公開、公開終了、予約、画面プレビュー）、バージョン履歴と差分、この版に戻す、版として残す、は済み。

**CMS 側の前提**: 違反にフィールドを紐づける改善（`references` / `assets` の violation）があるとフォームに写せる範囲が広がる

**区切り**: 1 回

---

## P5.5 スマホの承認

**目的**: 外出先で承認だけしたい、という最初に来る要望に応える。

- 自分に割り当てられた一覧 → 中身の確認 → 公開前の確認と公開（モックのスマホ 3 枚）
- ステータスの変更は P7 が入るまで出さない（公開と公開終了だけ）

**区切り**: 1 回

---

## P7 ワークフロー

- ステータスと担当者、ボードの列を status に、一覧の絞り込みへの追加、設定 › ワークフロー

**CMS 側の前提**: 仕様 10.2 の 1 番（ワークフローの実装）。**これが入るまで着手しない。CMS 側と画面を同じ PR 群で入れる**（片方だけ出すと、使われない列が DB に残る）

**区切り**: 1 回

---

## P8 裏方の残り

- MCP をつなぐ画面（鍵の発行と URL の案内）
- 今開いている人（presence）
- 逆参照（この執筆者のコンテンツ）

API キー、Webhook（配信履歴・再送）、プロジェクトの公開範囲、監査ログは済み。

**区切り**: 1 回

---

## P9 仕上げ

- ダークテーマの詰め、タブレットの並び
- richText の段階 2 の穴（linkCard / 動画 / callout / details / embed は素通しで保持するだけ）→ 段階 3。note 風の書き心地は [richtext-note-style.md](richtext-note-style.md)
- API プレビューに GraphiQL を埋め込む

**区切り**: 1〜2 回

---

## 並走する CMS 側の作業（仕様 10.2 の優先順）

| いつ | 何を |
|---|---|
| P5 の前 | `ContentType.titleField`、`FieldConfig.description` / `defaultValue`、`searchEntries`、違反にフィールドを紐づける |
| P5 の間 | メディアの絞り込みと `AssetUse.via` と容量 |
| P7 の前 | ワークフロー（P7 の前提） |
| いつでも | presence、逆参照、画像の変換 |

graphql-java の `ParserOptions` のトークン上限は上げた（`Graphql.flix`）。

---

## ローカルで通す手順（2026-09-09 に確かめた事）

**必須の CMS 側の変更は無い。** 現状のコードで管理者 → 組織 → プロジェクト → 招待 → 編集者がコンテンツを作る、まで通る。

手順:

1. `make db-up` → `make migrate` → `make run`（**この順。`make run` は migration を当てず、未適用なら起動に失敗する**）
2. migrate 直後の DB には組織 1 行（id 1 / `default`）とプロジェクト 1 行（slug `default`）だけがあり、users も memberships も 0 行
3. `CMS_BOOTSTRAP_OWNER`（Makefile の既定は `dev@localhost`）の**初回ログインで、その人が組織 1 の owner**になる。組織 owner はそのプロジェクトの owner にもなる
4. 招待は project 単位。**組織のメンバーでない人をそのまま招待できる**（`addOrganizationMember` は不要）
5. 招待された人が X-Dev-User でログインすると、**ログインのたびに走る処理が招待を membership に変える**。承認の操作は要らない。users 行も自動で作られる

### 気をつける事

- **管理 API の URL は `/p/{slug}/admin/graphql`**。`/p/{slug}/graphql` はコンテンツ API。Account API は `/account/graphql` だけ
- **招待は PAT のログインでは適用されない。** 最初は必ず X-Dev-User（本番は JWT）で入る
- **既定（`CMS_SIGNUP=open`）では編集者も組織とプロジェクトを作れる。** 「編集者にできない事」を確かめる時は `CMS_SIGNUP=closed` を付ける。管理画面は編集者に「組織を作る」導線を出さない
- email は `Email.normalize` で小文字・trim に揃うので、大文字で入っても招待は当たる

### 身元の切り替え

CMS 側に切り替えの仕組みは無く、ヘッダしか見ない。**dev proxy に閉じ込める**:

- **proxy が cookie（`dev_user`）を読んで `X-Dev-User` に写す。** cookie を書くのは開発モードの帯の中の小さな JavaScript だけ
- **Elm も封筒の TypeScript も dev のヘッダを知らない**（本番のビルドに混ざる事故を構造で防ぐ）。CI が `dist/*.js` を `grep -i 'x-dev'` して当たれば落とす
- 2 人を同時に見たい時はブラウザのプロフィールを分ける
- 本番は proxy を外すだけ。Elm は何も変えない

### asset（MinIO）

- **`ASSET_ENDPOINT` が未設定なら、アップロード系の 3 つだけが `INVALID` になり、それ以外は全部動く**
- ただし **`ASSET_ENDPOINT` があるのに他の ASSET_* が欠けていると起動時に落ちる**。全部渡すか全部消すかのどちらか
- `make db-up` は postgres と MinIO を両方立てる

---

## MinIO の扱い（2026-09-09）

MinIO はローカルの開発でだけ使う S3 の代役で、**本番は Cloudflare R2**。CMS 側は `SigV4` の署名と `ObjectStore` の handler だけを持ち、MinIO と R2 を同じ handler で扱う（AGENTS.md）。

**状況**: 2025 年に MinIO は Community Edition の Web UI から管理機能を外し、有償の AIStor に寄せた。その後 Community Edition は「新機能なし、issue と PR の対応なし、重大な脆弱性の修正だけを個別に判断」という保守のみの状態になっている。

**うちへの影響**: 本番には無い。ローカルの開発だけ。ただし**脆弱性の修正が個別判断になった物を開発機で動かし続けるのは避けたい**ので、置き換える。

**置き換え先の候補**: SeaweedFS（Apache 2.0、S3 API、活発）、Garage（AGPLv3、軽い）、RustFS（Apache 2.0）。**署名付き URL の PUT と HEAD と DELETE が動けば良い**ので、どれでも足りる（要検証）。

**やる事**: `docker-compose.yml` の minio を差し替え、`Makefile` の `ASSET_*` を合わせ、`make test-pg` の asset のテストが通る事を確かめる。まだやっていない。

**やらない事**: CMS のコードは変えない（S3 互換なので `ObjectStore` も `SigV4` もそのまま）。
