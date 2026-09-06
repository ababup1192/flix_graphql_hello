// content_fields.q: フィールドの定義

query listAllFields() -> many {
    SELECT id, type_id, api_id, name, kind, is_many, is_required, is_unique, is_localized, config, position
    FROM content_fields ORDER BY type_id, position, id
}

query listFieldsOfType(typeId: Int64) -> many {
    SELECT id, type_id, api_id, name, kind, is_many, is_required, is_unique, is_localized, config, position
    FROM content_fields WHERE type_id = :typeId ORDER BY position, id
}

query findField(id: Int64) -> one {
    SELECT id, type_id, api_id, name, kind, is_many, is_required, is_unique, is_localized, config, position
    FROM content_fields WHERE id = :id
}

query insertField(typeId: Int64, apiId: String, name: String, kind: String, isMany: Bool, isRequired: Bool, isUnique: Bool, isLocalized: Bool, config: Json, position: Int32) -> one {
    INSERT INTO content_fields (type_id, api_id, name, kind, is_many, is_required, is_unique, is_localized, config, position)
    VALUES (:typeId, :apiId, :name, :kind, :isMany, :isRequired, :isUnique, :isLocalized, :config, :position)
    RETURNING id
}

query updateField(id: Int64) -> exec with changes: Changes[content_fields] {
    UPDATE content_fields SET {changes} WHERE id = :id
}

query setFieldPosition(id: Int64, position: Int32) -> exec {
    UPDATE content_fields SET position = :position WHERE id = :id
}

query deleteField(id: Int64) -> exec {
    DELETE FROM content_fields WHERE id = :id
}

query nextFieldPosition(typeId: Int64) -> one {
    SELECT coalesce(max(position) + 1, 0)::int AS next FROM content_fields WHERE type_id = :typeId
}
