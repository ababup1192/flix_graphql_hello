// content_types.q: content type の定義

query listContentTypes() -> many {
    SELECT id, api_id, kind, name, singular, plural, preview_url, created_at, updated_at
    FROM content_types ORDER BY api_id
}

query findContentType(id: Int64) -> one {
    SELECT id, api_id, kind, name, singular, plural, preview_url, created_at, updated_at
    FROM content_types WHERE id = :id
}

query findContentTypeByApiId(apiId: String) -> one {
    SELECT id, api_id, kind, name, singular, plural, preview_url, created_at, updated_at
    FROM content_types WHERE api_id = :apiId
}

query insertContentType(apiId: String, kind: String, name: String, singular: String, plural: String, previewUrl: String) -> one {
    INSERT INTO content_types (api_id, kind, name, singular, plural, preview_url)
    VALUES (:apiId, :kind, :name, :singular, :plural, :previewUrl)
    RETURNING id
}

query updateContentType(id: Int64) -> exec with changes: Changes[content_types] {
    UPDATE content_types SET updated_at = now(), {changes} WHERE id = :id
}

query touchContentType(id: Int64) -> exec {
    UPDATE content_types SET updated_at = now() WHERE id = :id
}

query deleteContentType(id: Int64) -> exec {
    DELETE FROM content_types WHERE id = :id
}
