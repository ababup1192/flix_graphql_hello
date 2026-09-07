-- 一意は公開中の中身（JSONB）を直接引き、同時公開は advisory lock で直列にする。写しの表は保守（公開・取り下げ・unique の付け外しで同期）が要るのでやめる
DROP TABLE entry_unique_values;
