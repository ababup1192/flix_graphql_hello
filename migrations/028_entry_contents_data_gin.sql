-- 一意の確認（findUniqueHolder）が公開のたびに entry_contents を全部読んでいたのを索引で引く。
-- 部分索引にするのは、一意が見るのが公開中の中身だけで、下書きの自動保存（一番多い書き込み）に索引の保守を掛けないため。
-- jsonb_path_ops はキーが動的（apiId が実行時に決まる）でも 1 本で効く。式の索引だとフィールドごとに実行時の DDL が要る（007 の決め）。
CREATE INDEX entry_contents_published_data_gin ON entry_contents USING gin (data jsonb_path_ops) WHERE stage = 'published';
