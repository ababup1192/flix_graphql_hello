// projects.q: プロジェクト

query findProjectBySlug(slug: String) -> one {
    SELECT id, public_id, slug, name, org_id, visibility FROM projects WHERE slug = :slug
}

query findProjectById(id: Int64) -> one {
    SELECT id, public_id, slug, name, org_id, visibility FROM projects WHERE id = :id
}

query listProjects() -> many {
    SELECT id, public_id, slug, name, org_id, visibility FROM projects ORDER BY id
}

query insertProject(publicId: String, orgId: Int64, slug: String, name: String) -> one {
    INSERT INTO projects (public_id, org_id, slug, name) VALUES (:publicId, :orgId, :slug, :name) RETURNING id
}

// ---- content_version（コンテンツ API の ETag に入れる版）----

query findContentVersion(id: Int64) -> one {
    SELECT content_version FROM projects WHERE id = :id
}

// 公開・取り下げ・削除・型の変更のユースケースが同じ Tx で呼ぶ
query bumpContentVersion(id: Int64) -> exec {
    UPDATE projects SET content_version = content_version + 1 WHERE id = :id
}
