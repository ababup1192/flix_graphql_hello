# 設計: ホスティングと、リスクを外に出す 3 段階

状態: 方針を決めた（2026-09-07）。コードの変更はまだ無い。richText / asset・Docker・認証の各段で、
ここに書いた effect の境界を守りながら実装する。詳しい表は
[レポート](https://claude.ai/code/artifact/39425f5f-21e7-49d0-b5c9-750387e0ff48)。

## 方針

取り返しのつかない部分（データの消失、本人確認、鍵、決済）は専門のサービスに預け、
製品そのもの（Flix の API、GraphQL の組み立て、テナント、認可）は自前で持つ。
判断の軸は「壊れた時に直せるか」。

セルフホスト版は残す。**段階 1 の構成 = セルフホスト版 = 開発環境の compose** と 3 つを同じ物にし、
外部サービスは全部 effect にして handler を環境変数で選ぶ。クラウド版とセルフホスト版で違うのは
`Main` の handler の組み合わせだけ。

## 何を外に出すか

| 部品 | クラウド版 | セルフホスト版 | いつ |
|---|---|---|---|
| 本人確認 | Cloudflare Access → Clerk / Auth0 | Keycloak / Authelia / 自前マジックリンク | 認証の段（Flix は JWKS 検証だけ） |
| 認可（memberships と役割） | 自前 | 自前 | 認証の段 |
| PostgreSQL の耐久性 | Neon 東京 | compose の PG + pg_dump | 有料顧客が付いた時 |
| メディア | Cloudflare R2 | MinIO / ローカルディスク | richText / asset の段 |
| 画像変換 | Cloudflare Images | 無し（原画像）か imgproxy | 変換が要る時 |
| TLS / DDoS / CDN | Cloudflare | Caddy か Cloudflare Tunnel 無料枠 | 最初から |
| シークレット | Doppler | `.env` | Docker の段 |
| メール | Resend / Postmark | SMTP か「ログに出すだけ」 | 認証の段 |
| 決済 | Stripe | 無し（フラグで丸ごと消える） | 課金を始める時 |
| ログ・監視 | Grafana Cloud + 外形監視 | ローカル Grafana + Loki か無し | Docker の段 |

## 3 段階

| 段階 | いつ | 構成 | 月額の目安 |
|---|---|---|---|
| 1. 社内利用 | 今〜認証と管理画面が出るまで | Hetzner CX22 1 台に compose（Flix + PG）、Cloudflare Tunnel / Access / R2、Grafana と外形監視の無料枠、pg_dump → R2 | 約 1,000 円 |
| 2. 有料顧客あり | 最初の他社のデータを預かる時 | Fly.io 東京に Flix 2 台、Neon 東京、Clerk、Resend、Stripe、Doppler、Cloudflare Images | 約 8,000〜12,000 円 |
| 3. 数十顧客 | MRR が数十万円 | Fly の台数と Neon のプランを上げる、読み取りレプリカ、監査ログ | 3〜5 万円 |

- Cloud Run / App Engine は選ばない。JVM 常駐と scale-to-zero が合わず、microCMS と変わらない値段になる
- PG を遠い地域に出すなら Flix も同じ地域へ。ドイツ ↔ 東京は管理 API が目に見えて遅くなる
- 1 → 2 は DSN と issuer の環境変数の差し替えと、`Mailer` と `subscriptions` の追加。1〜2 日
- 2 → 3 は `ContentRunner` の DSN を分ける、entry id を `(project_id, id)` に、RLS。2〜3 日

## 守る設計上の約束

- **状態を Flix に持たない**。ContentEngine / AdminEngine のキャッシュは DB の目印から作り直せる物だけ。セッションも置かない。2 台化に手を入れない
- **外部サービスは effect で境界を切る**。`ObjectStore`（R2 / MinIO）、`Mailer`（Resend / ログ出力）、`TokenVerifier`（Access / Clerk / Keycloak / テスト用）。`Tenant` と同じ形
- **課金と上限はプラグイン扱い**。ドメインは「上限を聞く」effect を呼ぶだけで、答えが Stripe から来るか定数かを知らない。セルフホストは無限を返す handler
- **設定は全部環境変数**。DSN、issuer / JWKS / audience、R2 の endpoint と鍵、公開 URL、メールの API キー
- **migration は前方互換**。列を落とす前に読まなくする。追加は NULL 許容か DEFAULT 付き。起動時に自動で当てる
- **セルフホスト版は Cloudflare 無しで動く**。サポートは「compose が動く事」まで。Helm やクラウドのテンプレートは作らない

## 開発計画に加わる物

| 段 | 追加する物 | 見積もり |
|---|---|---|
| richText / asset | `ObjectStore` effect。S3 互換の handler 1 つで MinIO と R2 の両方に通す | 計画内 |
| Docker と起動時 migration | amd64 / arm64 のイメージ、JSON 1 行のリクエストログ、compose に Caddy / Keycloak / Grafana Alloy の例、シークレットの読み方を差し替え可能に | 1.5 日 |
| 認証・組織 | `TokenVerifier` effect（JWKS 検証。Keycloak でもテスト）、`Mailer` effect（招待メール） | 3〜4 日 |
| 課金（新規） | Stripe Checkout と webhook、`subscriptions` 表、プランごとの上限 | 1〜2 日 |

## 関連

- 認証・組織・subdomain の設計: [auth-and-organizations.md](auth-and-organizations.md)
- richText / asset の計画: https://claude.ai/code/artifact/be6545fa-0d29-4d57-8fb2-e0efc36f3ee3
- 費用の換算は 1 ユーロ 170 円、1 ドル 150 円。無料枠は 2026 年 9 月時点の公開情報
