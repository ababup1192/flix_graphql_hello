-- 型ごとの「パスの形」。本文のコンテンツへのリンクが、サイト上でどの path になるかの型紙。
-- `/blog/{slug}` のように書き、`{id}` と `{slug}` を差し替える（`src/cms/rules/LinkPath.flix`）。
-- 空なら型紙なしで、本文の HTML は今まで通り `#entry:{id}` を出す（サイトが data-entry-id を見て置き換える）。
ALTER TABLE content_types ADD COLUMN link_path TEXT NOT NULL DEFAULT '';
