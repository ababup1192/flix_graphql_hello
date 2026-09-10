// content_types.q: content type の定義

// 読みは全部 project_id で絞る（id は DB 全体で一意だが、他のプロジェクトの物を見せない）

query listContentTypes(projectId: Int64) -> many {
    SELECT id, api_id, kind, name, singular, plural, preview_url, link_path, icon, created_at, updated_at
    FROM content_types WHERE project_id = :projectId ORDER BY api_id
}

query findContentType(id: Int64, projectId: Int64) -> one {
    SELECT id, api_id, kind, name, singular, plural, preview_url, link_path, icon, created_at, updated_at
    FROM content_types WHERE id = :id AND project_id = :projectId
}

query findContentTypeByApiId(projectId: Int64, apiId: String) -> one {
    SELECT id, api_id, kind, name, singular, plural, preview_url, link_path, icon, created_at, updated_at
    FROM content_types WHERE project_id = :projectId AND api_id = :apiId
}

query insertContentType(projectId: Int64, apiId: String, kind: String, name: String, singular: String, plural: String, previewUrl: String, linkPath: String, icon: String) -> one {
    INSERT INTO content_types (project_id, api_id, kind, name, singular, plural, preview_url, link_path, icon)
    VALUES (:projectId, :apiId, :kind, :name, :singular, :plural, :previewUrl, :linkPath, :icon)
    RETURNING id
}

query updateContentType(id: Int64, projectId: Int64) -> exec with changes: Changes[content_types] {
    UPDATE content_types SET updated_at = now(), {changes} WHERE id = :id AND project_id = :projectId
}

query touchContentType(id: Int64, projectId: Int64) -> exec {
    UPDATE content_types SET updated_at = now() WHERE id = :id AND project_id = :projectId
}

query deleteContentType(id: Int64, projectId: Int64) -> exec {
    DELETE FROM content_types WHERE id = :id AND project_id = :projectId
}

// 型の定義が変わったかの目印。コンテンツ API のスキーマを組み直すかの判断に使う
query schemaFingerprint(projectId: Int64) -> one {
    SELECT count(*)::bigint AS types, max(updated_at)::timestamptz AS latest FROM content_types WHERE project_id = :projectId
}
