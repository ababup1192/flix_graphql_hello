// content_fields.q: フィールドの定義

// プロジェクトの全フィールド（型ごとに配るのは FieldTree.byType）
query listAllFields(projectId: Int64) -> many {
    SELECT f.id, f.type_id, f.parent_field_id, f.api_id, f.name, f.kind, f.is_many, f.is_required, f.is_unique, f.is_localized, f.target_type_id, f.config, f.position
    FROM content_fields AS f
    JOIN content_types AS t ON t.id = f.type_id
    WHERE t.project_id = :projectId ORDER BY f.type_id, f.position, f.id
}

query listFieldsOfType(typeId: Int64) -> many {
    SELECT id, type_id, parent_field_id, api_id, name, kind, is_many, is_required, is_unique, is_localized, target_type_id, config, position
    FROM content_fields WHERE type_id = :typeId ORDER BY position, id
}

query findField(id: Int64, projectId: Int64) -> one {
    SELECT f.id, f.type_id, f.parent_field_id, f.api_id, f.name, f.kind, f.is_many, f.is_required, f.is_unique, f.is_localized, f.target_type_id, f.config, f.position
    FROM content_fields AS f
    JOIN content_types AS t ON t.id = f.type_id
    WHERE f.id = :id AND t.project_id = :projectId
}

query insertField(typeId: Int64, apiId: String, name: String, kind: String, isMany: Bool, isRequired: Bool, isUnique: Bool, isLocalized: Bool, config: Json, position: Int32) -> one {
    INSERT INTO content_fields (type_id, api_id, name, kind, is_many, is_required, is_unique, is_localized, config, position)
    VALUES (:typeId, :apiId, :name, :kind, :isMany, :isRequired, :isUnique, :isLocalized, :config, :position)
    RETURNING id
}

query setFieldTarget(id: Int64, targetTypeId: Int64) -> exec {
    UPDATE content_fields SET target_type_id = :targetTypeId WHERE id = :id
}

query setFieldParent(id: Int64, parentFieldId: Int64) -> exec {
    UPDATE content_fields SET parent_field_id = :parentFieldId WHERE id = :id
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
    SELECT coalesce(max(position) + 1, 0)::int AS next FROM content_fields WHERE type_id = :typeId AND parent_field_id IS NULL
}

query nextChildPosition(parentFieldId: Int64) -> one {
    SELECT coalesce(max(position) + 1, 0)::int AS next FROM content_fields WHERE parent_field_id = :parentFieldId
}

// この型を参照先にしている REFERENCE のフィールドの数（型を消せるかの判断用。FK に ON DELETE が無いので先に見る）
query countFieldsTargeting(typeId: Int64) -> one {
    SELECT count(*)::bigint AS total FROM content_fields WHERE target_type_id = :typeId
}
