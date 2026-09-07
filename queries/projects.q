// projects.q: プロジェクト

query findProjectBySlug(slug: String) -> one {
    SELECT id, slug, name FROM projects WHERE slug = :slug
}

query listProjects() -> many {
    SELECT id, slug, name FROM projects ORDER BY id
}

query insertProject(slug: String, name: String) -> one {
    INSERT INTO projects (slug, name) VALUES (:slug, :name) RETURNING id
}
