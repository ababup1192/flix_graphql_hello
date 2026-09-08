-- プロジェクトの版（content_version）。公開・取り下げ・削除・型の変更と同じ Tx で +1 する。
-- コンテンツ API の GET の ETag に入れ、版が進めば CDN のキャッシュが外れる（purge を呼ばずに済む）
ALTER TABLE projects ADD COLUMN content_version BIGINT NOT NULL DEFAULT 0;
