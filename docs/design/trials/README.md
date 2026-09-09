# 試用と障害注入の記録（2026-09-08）

生ログ（障害注入 4 回、MCP 2 本、計 116KB）は 2026-09-09 に畳んだ。**残っていた指摘は [../roadmap.md](../roadmap.md) の「実験で見つかって未対応の物」に移した**ので、追うのはそちら。
生ログを読み直したい時は `git log --diff-filter=D -- docs/design/trials/`。

## 何を回したか

**障害注入**（4 回。手元の docker の PG + fat jar）— S1 PG の停止 → 再起動、S2 PG が遅い（docker pause）、S3 pool の枯渇、S4 Webhook の受け手が落ちている / 遅い、S5 OOM、S6 処理中の SIGTERM、S7 リゾルバの VerifyError。1 回目が対策を入れる前の計測で、2〜4 回目が対策の後。

**MCP の試用**（`claude -p` に `scripts/mcp-trial/prompt.txt` の 13 シチュエーション）と、同じ回のログの読み合わせ。手順は `scripts/mcp-trial/README.md`。

## 最終の数字（2 → 3 → 4 回目）

| 見る物 | 2 回目 | 3 回目 | 4 回目 |
| --- | --- | --- | --- |
| OOM の後の `self-heal: exiting` | 79.7 秒で exit 3（1 回） | 2 回とも 0 行。落ちない（回帰） | プールが壊れた 3 回とも出て exit 3。43.7 / 45.4 / 52.7 秒 |
| 見張りが死んだ時 | 仕事の周に相乗り（死なない） | 死ぬと自己回復が永久に無効 | `/health` から `step` が進む |
| 見張りが死んだ事の見え方 | 分からない | `status: ok` のまま（バグ） | `watch stalled` の 503 と `watch.stalled_ms` |
| 仕事の周が死んだ事の見え方 | 分からない | `status: ok` のまま（バグ） | 道は入ったが、7 回とも死ななかったので未確認 |
| OOM で落ちる時の終了コード | 3 | 落ちない | 3（プール破壊）/ 1（main が OOM。7 回中 2 回。その後 exit 3 に寄せた） |
| DB 停止での誤爆 | 無し | 無し | 無し（100 秒） |
| DB 停止中の `/health` | 15 秒 | 6〜8 秒 | 10.3 秒 → その後 `ping` の使い回しで 1 回に |
| 接続の漏れ | あり | あり | あり（`pool.active=9` が 1 分以上）**← 未対応** |

## 実験の台本の直し

**同じ負荷でも壊れ方が 3 通りに分かれる**（どのスレッドが先に OOM を食らうかで決まる）。7 回で 1 / 3 / 3 通りだった。
次に回す時は「1 回やって直った」ではなく、**n 回回して分布を見る**台本にする。

## この 6 本から直した物

自己回復の jitter を 10 秒に、`main` の OOM を exit 3 に寄せる（+ Dockerfile の `-XX:+ExitOnOutOfMemoryError`）、`jobs stalled` の表駆動テスト、`/health` の `ping` を 1 回に、`Net.Http.runWithIO` を廃して `OutboundHttp` の HttpClient 1 個に。
MCP は delete_entry / restore_version / versions / whoami の追加、Markdown の外部 URL 画像と gallery の alt、同じ内容に戻した時の stage、description の書き直し。
ログは認証の失敗を Warn に、主体の印（`user.id` / `api_key.name`）を request の行へ、MCP の 2 行を 1 行に、4xx の理由、ワーカーの行の project / webhook.id、413 の method と path、create_entry の id、webhook の `status_code: 0`。

## 意図的に直さない物

- **DATE が時刻・TZ 付きを受理してそのまま返す** — 書いた人の offset を残すため（`src/cms/rules/DateValues.flix` の WhyNot）
- **reader の鍵でも `preview_url` を発行できる** — プレビュートークンの発行は readDraft を持つ人（SDL に明記）
- **`unable to create native thread` の OOM に `-XX:+ExitOnOutOfMemoryError` が効かない** — 実測として `deploy/README.md` に記載
