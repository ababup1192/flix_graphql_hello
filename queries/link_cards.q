// link_cards.q: richText の linkCard の OGP（url → title / description / image_url / site_name、失敗なら error）

// 取れた物も失敗も同じ upsert。error のある行は他の列を空にする（古い成功の値を失敗の行に残さない）
query upsertLinkCard(projectId: Int64, url: String, title: Option[String], description: Option[String], imageUrl: Option[String], siteName: Option[String], error: Option[String]) -> exec {
    INSERT INTO link_cards (project_id, url, title, description, image_url, site_name, error, fetched_at)
    VALUES (:projectId, :url, :title, :description, :imageUrl, :siteName, :error, now())
    ON CONFLICT (project_id, url) DO UPDATE SET
        title = EXCLUDED.title, description = EXCLUDED.description, image_url = EXCLUDED.image_url,
        site_name = EXCLUDED.site_name, error = EXCLUDED.error, fetched_at = now()
}

query findLinkCard(projectId: Int64, url: String) -> one {
    SELECT url, title, description, image_url, site_name, error, fetched_at
    FROM link_cards WHERE project_id = :projectId AND url = :url
}

query findLinkCards(projectId: Int64, urls: List[String]) -> many {
    SELECT url, title, description, image_url, site_name, error, fetched_at
    FROM link_cards WHERE project_id = :projectId AND url = ANY(:urls)
    ORDER BY url
}

// unscoped: 取り直しの仕事が全プロジェクトを見る。古い行（7 日より前）と、失敗した行（1 時間より前）。古い順に limit 件。
// プロジェクト名は User-Agent に、slug はログの行（project）に出す
query listStaleLinkCards(limit: Int64) -> many {
    SELECT c.project_id, p.slug AS project_slug, p.name AS project_name, c.url
    FROM link_cards AS c JOIN projects AS p ON p.id = c.project_id
    WHERE c.fetched_at < now() - interval '7 days'
       OR (c.error IS NOT NULL AND c.fetched_at < now() - interval '1 hour')
    ORDER BY c.fetched_at LIMIT :limit
}
