-- content type のアイコン。管理画面のサイドバーで型を見分けるための短い識別子（"book" / "tag"）。
-- 絵柄そのものは持たず、管理画面が識別子から絵を選ぶ。既定は kind ごと（collection は 'list'、singleton は 'file'）
ALTER TABLE content_types ADD COLUMN icon TEXT NOT NULL DEFAULT 'list';
UPDATE content_types SET icon = 'file' WHERE kind = 'singleton';
ALTER TABLE content_types ADD CONSTRAINT content_types_icon_check
    CHECK (icon ~ '^[a-z][a-z0-9-]*$' AND length(icon) <= 32);
