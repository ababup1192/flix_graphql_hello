// projects.q: プロジェクト

query findProjectBySlug(slug: String) -> one {
    SELECT id, slug, name, org_id, visibility FROM projects WHERE slug = :slug
}

query listProjects() -> many {
    SELECT id, slug, name, org_id, visibility FROM projects ORDER BY id
}

query insertProject(orgId: Int64, slug: String, name: String) -> one {
    INSERT INTO projects (org_id, slug, name) VALUES (:orgId, :slug, :name) RETURNING id
}
