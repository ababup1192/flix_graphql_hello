#!/usr/bin/env bash
# テストデータのプロジェクトを空にする（無ければ作る）。make seed-* が取り込みの前に呼ぶ。
#
#   scripts/reset-project.sh <プロジェクト slug> [表示名] [データベース名]
#
# 何度走らせても同じ状態になる: プロジェクトの行は ON CONFLICT で作るか置き換え、
# 中身（型・entry・asset・webhook・予約）は消してから取り込み直す。
#
# WhyNot: プロジェクトの行ごと消さない。api_keys・memberships・招待が一緒に消えると、
# 手元で発行した鍵と管理画面のログインが毎回切れる。消すのは取り込みが作る物だけ。
# WhyNot: audit_events を消さない。監査は後から書き換えない表で、DELETE の policy が無い。
# WhyNot: 管理 API を叩かず psql で消す。取り込み（CMS_MODE=import-microcms）はサーバを立てない一発処理で、
# 作り直しのためだけにサーバを上げる前提を持ち込みたくない。
set -eu
cd "$(dirname "$0")/.."

slug="${1:?プロジェクト slug を渡してください}"
name="${2:-$slug}"
db="${3:-cms}"

docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U cms -d "$db" \
    -v slug="$slug" -v name="$name" <<'SQL'
BEGIN;

INSERT INTO projects (slug, name, org_id, visibility)
VALUES (:'slug', :'name', 1, 'public')
ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name;

SELECT id AS project_id FROM projects WHERE slug = :'slug' \gset
-- RLS（FORCE）が掛かった表を触るので、アプリと同じ印を置く
SELECT set_config('app.project_id', :'project_id', true);

-- entries を消すと entry_contents / entry_versions / entry_links / entry_unique_values / entry_autosaves が続いて消える
DELETE FROM entries WHERE project_id = :project_id;
-- content_types を消すと content_fields が続いて消える
DELETE FROM content_types WHERE project_id = :project_id;
DELETE FROM assets WHERE project_id = :project_id;
DELETE FROM link_cards WHERE project_id = :project_id;
DELETE FROM webhook_deliveries WHERE project_id = :project_id;
DELETE FROM webhooks WHERE project_id = :project_id;
DELETE FROM scheduled_actions WHERE project_id = :project_id;
DELETE FROM cdn_purges WHERE project_id = :project_id;

COMMIT;
SQL

echo "プロジェクト '$slug' を空にしました（$db）"
