// entries.q: entry の身元と中身

// 列を足す時は listEntries / findEntryByStage / listEntriesByStage / findEntriesByStage の 4 か所（EntryRows.toEntry が受ける形）
// ゴミ箱の物も含めて id があるか。createEntry の重複検査用（PK はゴミ箱の行とも衝突する）
query entryExists(id: String, projectId: Int64) -> one {
    SELECT id FROM entries WHERE id = :id AND project_id = :projectId
}

query countEntriesOfType(typeId: Int64, projectId: Int64) -> one {
    SELECT count(*)::bigint AS total FROM entries WHERE type_id = :typeId AND project_id = :projectId AND deleted_at IS NULL
}

query insertEntry(id: String, typeId: Int64, projectId: Int64) -> exec {
    INSERT INTO entries (id, type_id, project_id) VALUES (:id, :typeId, :projectId)
}

// 楽観ロック。version が合う時だけ進める。影響行数 0 なら誰かが先に進めた
query bumpEntryVersion(id: String, expected: Int32, projectId: Int64) -> exec {
    UPDATE entries SET version = version + 1, updated_at = now()
    WHERE id = :id AND project_id = :projectId AND version = :expected AND deleted_at IS NULL
}

query softDeleteEntry(id: String, projectId: Int64) -> exec {
    UPDATE entries SET deleted_at = now() WHERE id = :id AND project_id = :projectId AND deleted_at IS NULL
}

query purgeDeletedEntries(typeId: Int64, projectId: Int64) -> exec {
    DELETE FROM entries WHERE type_id = :typeId AND project_id = :projectId AND deleted_at IS NOT NULL
}

query upsertContent(entryId: String, stage: String, data: Json, projectId: Int64) -> exec {
    INSERT INTO entry_contents (entry_id, stage, data, project_id) VALUES (:entryId, :stage, :data, :projectId)
    ON CONFLICT (entry_id, stage) DO UPDATE SET data = EXCLUDED.data, updated_at = now()
}

// ---- コンテンツ API ----
// stage の行を読む。where は断片 DSL のスロットで、JSONB の式（c.data->>'title'）を EntryFilterSql が組む

query findEntryByStage(id: String, stage: String, projectId: Int64) -> one {
    SELECT e.id, e.type_id, e.version, e.stage, e.published_at, e.created_at, e.updated_at, c.data, p.data AS published_data
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = :stage
    LEFT JOIN entry_contents AS p ON p.entry_id = e.id AND p.stage = 'published'
    WHERE e.id = :id AND e.project_id = :projectId AND e.deleted_at IS NULL
}

query listEntriesByStage(typeId: Int64, stage: String, limit: Int64, offset: Int64, projectId: Int64) -> many
    with filter: Pred[entry_contents], order: Order[entry_contents]
{
    SELECT e.id, e.type_id, e.version, e.stage, e.published_at, e.created_at, e.updated_at, c.data, p.data AS published_data
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = :stage
    LEFT JOIN entry_contents AS p ON p.entry_id = e.id AND p.stage = 'published'
    WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL AND {filter}
    {order}
    LIMIT :limit OFFSET :offset
}

query countEntriesByStage(typeId: Int64, stage: String, projectId: Int64) -> one with filter: Pred[entry_contents] {
    SELECT count(*)::bigint AS total
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = :stage
    WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL AND {filter}
}

// ---- 公開 ----

query markPublished(id: String, projectId: Int64) -> exec {
    UPDATE entries SET stage = 'published', published_at = now(), updated_at = now() WHERE id = :id AND project_id = :projectId AND deleted_at IS NULL
}

// 公開中の行だけ触る（未公開の entry に取り下げを送っても updated_at を動かさない）
query markUnpublished(id: String, projectId: Int64) -> exec {
    UPDATE entries SET stage = 'draft', published_at = NULL, updated_at = now() WHERE id = :id AND project_id = :projectId AND stage = 'published' AND deleted_at IS NULL
}

query deleteContent(entryId: String, stage: String, projectId: Int64) -> exec {
    DELETE FROM entry_contents WHERE entry_id = :entryId AND stage = :stage AND project_id = :projectId
}

// ---- 一意 ----
// 一意は写しの表を持たず、公開中の中身（JSONB）を直接引く。jsonb の = は数値を数値として比べる（1 と 1.0 は同じ）

// 同じ（型, フィールド, 値）を公開する Tx を直列にする。値ごとの悲観ロックで、commit / rollback で外れる。
// 検査の前に取るので、先に取った方の公開を後の方が見て invalid になる
query lockUniqueValue(typeId: Int64, fieldId: Int64, value: Json) -> one {
    SELECT (pg_advisory_xact_lock(hashtext(concat_ws(':', :typeId, :fieldId, :value))) IS NULL)::boolean AS locked
}

// 公開中でその値を持つ entry（1 つ）。
// 含む（@>）で書くのは entry_contents_published_data_gin（GIN jsonb_path_ops、stage = 'published' の部分索引）が効く形だから。
// `data -> :apiId = :value` は索引が効かず、公開のたびに entry_contents を全部読む（11 万件で 43ms → 0.1ms）。
// 一意は配列・OBJECT・BLOCKS に付けられない（Naming.validateFlags）ので、@> の「配列は含む」の意味は出てこず、スカラーの等価と同じになる。
// 型の照合は jsonb の等価そのものなので、1 と 1.0 は同じ値、"1" とは別の値（-> = と同じ）。
// :apiId::text と :value::jsonb の cast を書くのは、jsonb_build_object が variadic "any" で、
// 素のプレースホルダだと PG が型を決められず prepare で落ちるため
query findUniqueHolder(typeId: Int64, apiId: String, value: Json, projectId: Int64) -> one {
    SELECT e.id
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = 'published'
    WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL AND c.data @> jsonb_build_object(:apiId::text, :value::jsonb)
    ORDER BY e.id LIMIT 1
}

// ---- 版 ----

query insertVersion(projectId: Int64, entryId: String, version: Int32, data: Json, author: String, reason: String) -> one {
    INSERT INTO entry_versions (project_id, entry_id, version, data, author, reason) VALUES (:projectId, :entryId, :version, :data, :author, :reason)
    RETURNING id
}

query listVersions(entryId: String, projectId: Int64) -> many {
    SELECT id, entry_id, version, data, author, reason, created_at FROM entry_versions WHERE entry_id = :entryId AND project_id = :projectId ORDER BY id DESC
}

// 複数の entry の版をまとめて 1 本で（一覧の先読み用）。entry ごとに新しい順
query listVersionsOf(entryIds: List[String], projectId: Int64) -> many {
    SELECT id, entry_id, version, data, author, reason, created_at FROM entry_versions WHERE entry_id = ANY(:entryIds) AND project_id = :projectId ORDER BY entry_id, id DESC
}

query findVersion(id: Int64, projectId: Int64) -> one {
    SELECT id, entry_id, version, data, author, reason, created_at
    FROM entry_versions
    WHERE id = :id AND project_id = :projectId
}

// ---- 参照 ----

query findEntriesByStage(ids: List[String], stage: String, projectId: Int64) -> many {
    SELECT e.id, e.type_id, e.version, e.stage, e.published_at, e.created_at, e.updated_at, c.data, p.data AS published_data
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = :stage
    LEFT JOIN entry_contents AS p ON p.entry_id = e.id AND p.stage = 'published'
    WHERE e.id = ANY(:ids) AND e.project_id = :projectId AND e.deleted_at IS NULL
}

query deleteLinks(fromEntryId: String, stage: String, projectId: Int64) -> exec {
    DELETE FROM entry_links WHERE from_entry_id = :fromEntryId AND stage = :stage AND project_id = :projectId
}

query insertLink(projectId: Int64, fromEntryId: String, stage: String, fieldApiId: String, toEntryId: String, position: Int32) -> exec {
    INSERT INTO entry_links (project_id, from_entry_id, stage, field_api_id, to_entry_id, position) VALUES (:projectId, :fromEntryId, :stage, :fieldApiId, :toEntryId, :position)
}

// 下書きが参照している entry のうち、公開されていない物（ゴミ箱の物と無い物を含む）
query unpublishedTargets(fromEntryId: String, projectId: Int64) -> many {
    SELECT DISTINCT l.to_entry_id
    FROM entry_links AS l
    JOIN entries AS src ON src.id = l.from_entry_id AND src.project_id = l.project_id
    JOIN content_fields AS f ON f.type_id = src.type_id AND f.api_id = l.field_api_id AND f.project_id = l.project_id
    LEFT JOIN entries AS e ON e.id = l.to_entry_id AND e.deleted_at IS NULL AND e.stage = 'published'
    WHERE l.from_entry_id = :fromEntryId AND l.project_id = :projectId AND l.stage = 'draft' AND e.id IS NULL
}

// 下書きが参照している entry のうち、無い物（ゴミ箱の物と、消えた物）
query missingTargets(fromEntryId: String, projectId: Int64) -> many {
    SELECT DISTINCT l.to_entry_id
    FROM entry_links AS l
    JOIN entries AS src ON src.id = l.from_entry_id AND src.project_id = l.project_id
    JOIN content_fields AS f ON f.type_id = src.type_id AND f.api_id = l.field_api_id AND f.project_id = l.project_id
    LEFT JOIN entries AS e ON e.id = l.to_entry_id AND e.deleted_at IS NULL
    WHERE l.from_entry_id = :fromEntryId AND l.project_id = :projectId AND l.stage = 'draft' AND e.id IS NULL
}

// この entry を stage の中身で参照している entry と、どのフィールドで参照しているか（影響の見える化用）
query referrerLinks(toEntryId: String, stage: String, projectId: Int64) -> many {
    SELECT DISTINCT l.from_entry_id, l.field_api_id
    FROM entry_links AS l
    JOIN entries AS e ON e.id = l.from_entry_id AND e.deleted_at IS NULL AND e.project_id = l.project_id
    JOIN content_fields AS f ON f.type_id = e.type_id AND f.api_id = l.field_api_id AND f.project_id = l.project_id
    WHERE l.to_entry_id = :toEntryId AND l.project_id = :projectId AND l.stage = :stage
    ORDER BY l.from_entry_id, l.field_api_id
}

// この entry を公開側で参照している entry（取り下げ・削除の防止用）
query publishedReferrers(toEntryId: String, projectId: Int64) -> many {
    SELECT DISTINCT l.from_entry_id
    FROM entry_links AS l
    JOIN entries AS e ON e.id = l.from_entry_id AND e.deleted_at IS NULL AND e.project_id = l.project_id
    JOIN content_fields AS f ON f.type_id = e.type_id AND f.api_id = l.field_api_id AND f.project_id = l.project_id
    WHERE l.to_entry_id = :toEntryId AND l.project_id = :projectId AND l.stage = 'published'
}
