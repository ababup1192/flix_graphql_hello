// projects.q: プロジェクト

query findProjectBySlug(slug: String) -> one {
    SELECT id, public_id, slug, name, org_id, visibility FROM projects WHERE slug = :slug
}

query listProjects() -> many {
    SELECT id, public_id, slug, name, org_id, visibility FROM projects ORDER BY id
}

query insertProject(publicId: String, orgId: Int64, slug: String, name: String) -> one {
    INSERT INTO projects (public_id, org_id, slug, name) VALUES (:publicId, :orgId, :slug, :name) RETURNING id
}
