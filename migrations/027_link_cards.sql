-- richText の linkCard の OGP。編集画面が URL を貼った瞬間に管理 API（fetchLinkCard）が取り、公開の HTML はここから組む。
-- doc には持たない（OGP は変わる物で、doc に写すと古くなる。docs/design/richtext-note-style.md §3.3）。
-- url はプロジェクトの中で 1 つ。失敗も行にして error に理由を残す（次に貼った人がすぐ取り直しに行かず、編集画面が理由を見せる）。
-- 取り直し（fetched_at が 7 日より前・error のある行）は BackgroundJobs が拾う。
CREATE TABLE link_cards (
    project_id BIGINT NOT NULL,
    url TEXT NOT NULL,
    title TEXT,
    description TEXT,
    image_url TEXT,
    site_name TEXT,
    error TEXT,
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT link_cards_pkey PRIMARY KEY (project_id, url)
);
ALTER TABLE link_cards ADD CONSTRAINT link_cards_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
CREATE INDEX link_cards_fetched_idx ON link_cards (fetched_at);

-- RLS は付けない（webhook_deliveries / scheduled_actions / cdn_purges と同じ）。取り直しの仕事が印（app.project_id）無しの Tx で
-- プロジェクトを跨いで古い行を拾うため。読む・書く query は全部 project_id を条件に持つ（make gen --scope project_id が見張る）
