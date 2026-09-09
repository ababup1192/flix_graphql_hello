# 管理画面の実装のフェーズ（2026-09-09）

仕様は [admin-ui-spec.md](admin-ui-spec.md)、モックは https://claude.ai/code/artifact/0bd9dace-75e1-4d99-9cd5-9232f820d3c1 。
最初の目標は **「管理者が組織とプロジェクトを作り、編集者を招待し、招待された人がコンテンツを作って公開できる」までをローカルで通す**（P0 〜 P3）。裏方の画面は仮のまま置く。

各フェーズは「動かして確かめる事」が終わりの条件。実装は仕様の 11 章（Elm の決まり）に従う。

**見積りは日数で置かない。** このリポジトリの実測（2026-09-08 の 1 日で 111 コミット。logfx、MCP サーバ v1、richText の Markdown 往復、差分、自己回復、障害の実験 4 回）に対して、日数の見積りは意味を持たない。代わりに **「区切り」= 人が触って確かめる回数**で書く。実際に時間を食うのは、書く事ではなく次の 3 つ:

1. **決めを待つ所**（人に聞かないと進めない分岐）
2. **確かめる所**（実際に画面を触って、思っていた物と違うと分かる回）
3. **未知の所**（やってみないと分からない技術。今回は elm-graphql と封筒の port の両取り、TipTap の Web Component、devbox での node の用意）

P0 〜 P3 は **1 日で通る見込み**。詰まるとすれば 3 の未知で、そこは批判者に先に潰させている。

---

## P0 骨組み

**目的**: 1 本のリクエストが Elm から CMS まで通り、テストの型ができる。

- `admin-ui/` を作る（package.json / vite / elm.json / elm-tooling / tsconfig / index.html）
- Tailwind v4 + daisyUI のテーマ 2 本（`cms-light` / `cms-dark`）と `@theme` のトークン
- `Effect.elm`（`SendGraphql` / `PushRoute` / `ReplaceRoute` / `ShowToast` / `Autosave` / `Debounce` / `Batch` / `None`）と `perform`
- 封筒の port 2 本（`apiRequest_Api_JS` / `apiResponse_Api_ELM`）と TypeScript 側（URL・ヘッダ・再試行・タイムアウト）
- `Route.elm`（仕様 6.2 の URL。往復のテスト）
- `Session.elm`（認証済みユーザー・permissions・今のプロジェクト・トースト**だけ**）
- `Api/Error.elm`（`extensions.code` → 型、violations の**デコーダ 2 本**、path → フォームの項目）
- `make ui-gen` で `admin.graphql` / `account.graphql` → `generated/`
- dev proxy（cookie `dev_user` → `X-Dev-User`。Elm と封筒の TS は知らない）と、本番ビルドに `x-dev` が残っていないかの CI の grep
- **封筒に `requestId` と `retriable`**（後付けできないので P0 で入れる。ULID を Elm が発番、mutation は再試行しない）
- `admin-ui/devbox.json` に node を固定（この環境に node も npm も PATH に無い）
- 入口の 4 状態（起動中 / メンバーでない / セッション切れ / 開発モードの帯）
- Makefile の `ui-install` / `ui-gen` / `ui-gen-check` / `ui-dev` / `ui-check` / `ui-build`、CI の `admin-ui.yml`、elm-review の設定

**確かめる事**: `make run` と `make ui-dev` を上げ、ブラウザで `me` の結果が出る。身元を切り替えると別の人になる。`make ui-check` が通る。

**区切り**: 1 回

---

## P1 オンボーディング（Account API）

**目的**: 人とプロジェクトが用意できる。

- `/account`（自分・組織の一覧・PAT）
- 組織を作る、プロジェクトを作る（プロジェクト slug の検証は CMS の INVALID をそのまま出す）
- プロジェクト選択（最後に開いた物へ redirect。1 つなら出さない）
- プロジェクト設定 › メンバー（招待・権限の変更・削除・招待の取り消し）
- **サイドバーと設定は `viewer.permissions` で出し分ける**（編集者には「プロジェクト設定」が出ない）

**CMS 側の前提**: 無し（実装済み）

**確かめる事**: 管理者で組織とプロジェクトを作り、編集者を招待する。身元を切り替えて編集者で入り、プロジェクトが見え、設定が見えない。

**区切り**: 1 回

---

## P2 API スキーマ（型の定義）

**目的**: コンテンツを入れる型が作れる。

- API の一覧（サイドバー）、API を作る、API 設定（名前 / エンドポイント / 削除 / `previewUrl`）
- フィールドの追加・編集・並び替え・削除。13 種類すべての config フォーム
- セレクトの選択肢の管理
- **種類は後から変えられない**事を作成時に伝える。`removeField` と選択肢の削除は影響を検査しないので、確認のモーダルで言葉で断る

**CMS 側の前提**: 無し（`titleField` と `description` は P3 までに欲しいが、無くても作れる）

**確かめる事**: ブログの型を作り、13 種類のフィールドを一通り置いて保存できる。

**区切り**: 1 回

---

## P3 コンテンツの編集

**目的**: 書いて保存できる。**ここまでで最初の目標が終わる。**

- 一覧から「追加」→ 即エディタ（`/new` → 保存で id に置き換え）
- 全フィールドの入力部品（モックの「全フィールドの入力部品」）。richText は**段階 1**（段落・見出し・リスト・チェックリスト・引用・コード・画像・リンク・太字・斜体）。未対応の node は消さずに保持
- 下書き保存（人が押す。`updateEntry` の `expectedVersion` を持ち回る）と「未保存 / 保存しています… / 保存済み / 競合」の表示
- `CONFLICT` の扱い（相手の変更を diff で見せ、乗せるか捨てるかを選ばせる）
- violations をフォームの項目に写す
- TipTap を Web Component に包む（`web/tiptap-editor.ts`）

**CMS 側の前提**: `FieldConfig.description`（欄の下の説明）があると良い。無ければ出さない

**確かめる事**: 編集者の身元でコンテンツを作り、閉じて開き直しても残っている。2 つのタブで開いて片方を保存すると、もう片方が競合を出す。

**区切り**: 1〜2 回（入力部品が 13 種類あるので、ここだけ厚い）

---

## ここで一度止めて確認する

P0 〜 P3 が終わった時点で、目標の流れがローカルで通る。ここで実際に触って、以降の順を見直す。

---

## P3.5 API キーと Webhook（前倒し）

**目的**: 本番で人が繰り返す操作を画面から出来るようにする。これが無いと、公開サイトがコンテンツ API を読めず、公開してもサイトが再ビルドされない。

- API キーの発行と失効（生の値は 1 回だけ。`curl` で叩いて端末の履歴に残す運用を避ける）
- Webhook の作成・編集・削除、配信履歴、再送

**区切り**: 1 回

---

## P3.9 運用の配線

**目的**: 本番に出せる状態にする。ローカルが通った直後にやる（ここで初めて本番に出す価値が生まれる）。

- `deploy/` の Caddy を 2 ホストに分ける（`admin.` に Access、`cms.` は Access 無し）
- admin-ui のイメージ化と compose、**CMS と同じ sha で出す**（別々だと SDL の変更で片方だけ古くなる）。起動時に `/health` の version と自分の sha を比べ、不一致なら帯を出す
- `index.html` は `no-store`、`/assets/*` は `immutable`、Cloudflare の Bypass ルール、chunk の読み込み失敗で 1 回だけリロード、旧 chunk を 1 世代残す
- Caddy の access log を JSON で出して Loki へ（chunk の 404 と 4xx/5xx が見える）
- `admin-ui.yml`（elm-review / elm-format --validate / elm-test / build / `ui-gen-check` / `x-dev` の grep）。paths で絞り、`~/.elm` と flix.jar をキャッシュ
- ロールバックの手順を 1 本書く（両方を同じ 1 つ前の sha に固定 → 管理画面のキャッシュを purge）
- **CMS 側の必須**: ログインの email を小文字・trim に揃える。compose の `CMS_SIGNUP` の既定を `closed` に

**区切り**: 1 回

---

## P4 コンテンツの一覧

- テーブル（検索 / 絞り込み / 並び替え / cursor のページ / 表示する列）
- 絞り込みと列と並びを **URL に持つ**。保存したビュー（最初は localStorage）
- 参照ピッカーと「内容を見る」の右パネル
- ⌘K（型・コンテンツ・メディア・設定へ。型を跨いだ検索は CMS 側が入るまで型ごとに引く）

**CMS 側の前提**: `ContentType.titleField`（代表列。無いと一覧の 1 列目が決まらない）。`searchEntries`（⌘K）

**区切り**: 1 回

---

## P5 公開まわり

- 右のレール（公開前の確認 → 公開、一緒に公開される物、公開終了、予約、画面プレビュー）
- 変更履歴と差分（版の一覧、公開中との差分、この版に戻す、版として残す）
- 予約の一覧（失敗の理由）
- まとめて公開（`publishPlan` → `publishMany`）

**CMS 側の前提**: 違反にフィールドを紐づける改善（`references` / `assets` の violation）があるとフォームに写せる範囲が広がる

**区切り**: 1 回

---

## P5.5 スマホの承認（前倒し）

**目的**: 外出先で承認だけしたい、という最初に来る要望に応える。

- 自分に割り当てられた一覧 → 中身の確認 → 公開前の確認と公開（モックのスマホ 3 枚）
- ステータスの変更は P7 が入るまで出さない（公開と公開終了だけ）

**区切り**: 1 回

---

## P6 メディア

- グリッド、ドラッグ & ドロップ、`createUploadUrl` → PUT → `confirmAsset`、PENDING の表示
- 右パネル（alt・使われている場所・URL のコピー）
- 画像のフィールドと richText の image のピッカー

**CMS 側の前提**: メディアの絞り込みと `AssetUse.via` と容量の集計。画像の変換 URL（無い間はプリセットを出さない）

**区切り**: 1 回

---

## P7 ワークフロー

- ステータスと担当者、ボード、一覧の絞り込みへの追加、設定 › ワークフロー

**CMS 側の前提**: 仕様 10.2 の 1 番（ワークフローの実装）。**これが入るまで着手しない**

**区切り**: 1 回

---

## P8 裏方（仮のモックを本物にする）

- API キー、Webhook（配信履歴・再送）、MCP をつなぐ、プロジェクトの公開範囲
- 今開いている人（presence）
- 逆参照（この執筆者のコンテンツ）

**区切り**: 1 回

---

## P9 仕上げ

- ダークテーマの詰め、タブレットの並び
- richText の段階 2（表・注意書き・折りたたみ・埋め込み・リンクカード）→ 段階 3
- API プレビュー（GraphiQL の埋め込み）

**区切り**: 1〜2 回

---

## 実際のリスク（日数ではなくここを見る）

各フェーズの終わりに「ここで止めた時に本番に出せるか」を確かめる。**P7 は CMS 側と画面を同じ PR 群で入れる**（片方だけ出すと、使われない列が DB に残る）。

| リスク | どこで分かるか | 詰まった時 |
|---|---|---|
| elm-graphql から query 文字列と decoder を取り出して封筒に載せられるか | P0 の最初 | `Graphql.Http` をそのまま使い、封筒は非 GraphQL の物だけにする |
| `JSON` scalar の生成（`--scalar-codecs`） | P0 の生成 | 手書きの codec を 1 つ足す |
| devbox での node の用意（この環境に node も npm も PATH に無い） | P0 の最初 | `admin-ui/devbox.json` に nodejs を入れる（flix_ge_studio と同じ形） |
| TipTap を Web Component に包む | P3 | 段階 1 を素の contenteditable でなく textarea + Markdown で凌ぎ、後で差し替える |
| 入力部品 13 種類の量 | P3 | kind ごとに切って区切りを増やす |

## 並走する CMS 側の作業（仕様 10.2 の優先順）

| いつ | 何を |
|---|---|
| **P0 と同時** | **graphql-java の `ParserOptions` のトークン上限を上げる**（既定 15,000。本文が document に埋め込まれるので長い記事で当たる。1 MiB の本文の上限より先に当たらない値にする。MCP と CLI にも効く） |
| P2 の間 | `ContentType.titleField`、`FieldConfig.description` / `defaultValue` |
| P4 の間 | `searchEntries`、違反にフィールドを紐づける |
| P5 の間 | メディアの絞り込みと `AssetUse.via` と容量 |
| P6 の間 | ワークフロー（P7 の前提） |
| いつでも | presence、逆参照、画像の変換 |

---

## ローカルで通す手順（調査で確かめた事。2026-09-09）

**必須の CMS 側の変更は無い。** 現状のコードで管理者 → 組織 → プロジェクト → 招待 → 編集者がコンテンツを作る、まで通る。

手順:

1. `make db-up` → `make migrate` → `make run`（**この順。`make run` は migration を当てず、未適用なら起動に失敗する**）
2. migrate 直後の DB には組織 1 行（id 1 / `default`）とプロジェクト 1 行（slug `default`）だけがあり、users も memberships も 0 行
3. `CMS_BOOTSTRAP_OWNER`（Makefile の既定は `dev@localhost`）の**初回ログインで、その人が組織 1 の owner**になる。組織 owner はそのプロジェクトの owner にもなる
4. 招待は project 単位。**組織のメンバーでない人をそのまま招待できる**（`addOrganizationMember` は不要）
5. 招待された人が X-Dev-User でログインすると、**ログインのたびに走る処理が招待を membership に変える**。承認の操作は要らない。users 行も自動で作られる

### 気をつける事（4 つ）

- **管理 API の URL は `/p/{slug}/admin/graphql`**。`/p/{slug}/graphql` はコンテンツ API。Account API は `/account/graphql` だけ
- **email は完全一致で突き合わせる。** 招待側は小文字化されるが、ログイン側（X-Dev-User の値）は生のまま。`Editor@Example.com` でログインすると招待が当たらない。**小文字で統一する**
- **招待は PAT のログインでは適用されない。** 最初は必ず X-Dev-User（本番は JWT）で入る
- **既定（`CMS_SIGNUP=open`）では編集者も組織とプロジェクトを作れる。** 「編集者にできない事」を確かめる時は `CMS_SIGNUP=closed` を付ける。管理画面は編集者に「組織を作る」導線を出さない

### 身元の切り替え（P0 で作る）

CMS 側に切り替えの仕組みは無く、ヘッダしか見ない。**dev proxy に閉じ込める**:

- **proxy が cookie（`dev_user`）を読んで `X-Dev-User` に写す。** cookie を書くのは開発モードの帯の中の小さな JavaScript だけ
- **Elm も封筒の TypeScript も dev のヘッダを知らない**（本番のビルドに混ざる事故を構造で防ぐ）。CI が `dist/*.js` を `grep -i 'x-dev'` して当たれば落とす
- 2 人を同時に見たい時はブラウザのプロフィールを分ける
- 本番は proxy を外すだけ。Elm は何も変えない

### CMS 側に入れると楽になる物（必須ではない。小さい）

- ログインの email を小文字・trim に揃える（招待の当たり外れが消える）
- `Members.invite` を doc に合わせる（既にログイン済みの人を招待したらその場でメンバーにする。今は相手の再ログインまで「招待中」のまま）
- Makefile に `CMS_SIGNUP=closed` を足すか、確認の時だけ付ける

### asset（MinIO）

- **`ASSET_ENDPOINT` が未設定なら、アップロード系の 3 つだけが `INVALID` になり、それ以外は全部動く。** P0 〜 P5 は asset 無しで進められる
- ただし **`ASSET_ENDPOINT` があるのに他の ASSET_* が欠けていると起動時に落ちる**。全部渡すか全部消すかのどちらか
- `make db-up` は postgres と MinIO を両方立てる。MinIO の置き換えを決めるなら P6 の前まで（→ 下の「MinIO の扱い」）

---

## MinIO の扱い（2026-09-09）

MinIO はローカルの開発でだけ使う S3 の代役で、**本番は Cloudflare R2**。CMS 側は `SigV4` の署名と `ObjectStore` の handler だけを持ち、MinIO と R2 を同じ handler で扱う（AGENTS.md）。

**状況**: 2025 年に MinIO は Community Edition の Web UI から管理機能を外し、有償の AIStor に寄せた。その後 Community Edition は「新機能なし、issue と PR の対応なし、重大な脆弱性の修正だけを個別に判断」という保守のみの状態になっている。

**うちへの影響**: 本番には無い。ローカルの開発だけ。ただし**脆弱性の修正が個別判断になった物を開発機で動かし続けるのは避けたい**ので、置き換える。

**置き換え先の候補**: SeaweedFS（Apache 2.0、S3 API、活発）、Garage（AGPLv3、軽い）、RustFS（Apache 2.0）。**署名付き URL の PUT と HEAD と DELETE が動けば良い**ので、どれでも足りる（要検証）。

**やる事**: `docker-compose.yml` の minio を差し替え、`Makefile` の `ASSET_*` を合わせ、`make test-pg` の asset のテストが通る事を確かめる。**P6（メディア）の前まで**にやる。それまでは asset 無しで進められる。

**やらない事**: CMS のコードは変えない（S3 互換なので `ObjectStore` も `SigV4` もそのまま）。
