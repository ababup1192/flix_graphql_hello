-- フィールド種別に date を足す
ALTER TABLE content_fields DROP CONSTRAINT content_fields_kind_check;
ALTER TABLE content_fields ADD CONSTRAINT content_fields_kind_check
    CHECK (kind IN ('text','textArea','slug','number','boolean','select','reference','object','blocks','asset','richText','date'));
