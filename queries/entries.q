// entries.q: entry の身元と中身

// 列を足す時は listEntries / findEntryByStage / listEntriesByStage / findEntriesByStage の 4 か所（EntryRows.toEntry が受ける形）
// ゴミ箱の物も含めて id があるか。createEntry の重複検査用（PK はゴミ箱の行とも衝突する）
query entryExists(id: String) -> one {
    SELECT id FROM entries WHERE id = :id
}

query countEntriesOfType(typeId: Int64) -> one {
    SELECT count(*)::bigint AS total FROM entries WHERE type_id = :typeId AND deleted_at IS NULL
}

query insertEntry(id: String, typeId: Int64) -> exec {
    INSERT INTO entries (id, type_id) VALUES (:id, :typeId)
}

// 楽観ロック。version が合う時だけ進める。影響行数 0 なら誰かが先に進めた
query bumpEntryVersion(id: String, expected: Int32) -> exec {
    UPDATE entries SET version = version + 1, updated_at = now()
    WHERE id = :id AND version = :expected AND deleted_at IS NULL
}

query softDeleteEntry(id: String) -> exec {
    UPDATE entries SET deleted_at = now() WHERE id = :id AND deleted_at IS NULL
}

query purgeDeletedEntries(typeId: Int64) -> exec {
    DELETE FROM entries WHERE type_id = :typeId AND deleted_at IS NOT NULL
}

query upsertContent(entryId: String, stage: String, data: Json) -> exec {
    INSERT INTO entry_contents (entry_id, stage, data) VALUES (:entryId, :stage, :data)
    ON CONFLICT (entry_id, stage) DO UPDATE SET data = EXCLUDED.data, updated_at = now()
}

// ---- コンテンツ API ----
// stage の行を読む。where は断片 DSL のスロットで、JSONB の式（c.data->>'title'）を EntryFilterSql が組む

query findEntryByStage(id: String, stage: String) -> one {
    SELECT e.id, e.type_id, e.version, e.stage, e.published_at, e.created_at, e.updated_at, c.data, c.updated_at AS content_updated_at, p.updated_at AS published_updated_at
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = :stage
    LEFT JOIN entry_contents AS p ON p.entry_id = e.id AND p.stage = 'published'
    WHERE e.id = :id AND e.deleted_at IS NULL
}

query listEntriesByStage(typeId: Int64, stage: String, limit: Int64, offset: Int64) -> many
    with filter: Pred[entry_contents], order: Order[entry_contents]
{
    SELECT e.id, e.type_id, e.version, e.stage, e.published_at, e.created_at, e.updated_at, c.data, c.updated_at AS content_updated_at, p.updated_at AS published_updated_at
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = :stage
    LEFT JOIN entry_contents AS p ON p.entry_id = e.id AND p.stage = 'published'
    WHERE e.type_id = :typeId AND e.deleted_at IS NULL AND {filter}
    {order}
    LIMIT :limit OFFSET :offset
}

query countEntriesByStage(typeId: Int64, stage: String) -> one with filter: Pred[entry_contents] {
    SELECT count(*)::bigint AS total
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = :stage
    WHERE e.type_id = :typeId AND e.deleted_at IS NULL AND {filter}
}

// ---- 公開 ----

query markPublished(id: String) -> exec {
    UPDATE entries SET stage = 'published', published_at = now(), updated_at = now() WHERE id = :id AND deleted_at IS NULL
}

// 公開中の行だけ触る（未公開の entry に取り下げを送っても updated_at を動かさない）
query markUnpublished(id: String) -> exec {
    UPDATE entries SET stage = 'draft', published_at = NULL, updated_at = now() WHERE id = :id AND stage = 'published' AND deleted_at IS NULL
}

query deleteContent(entryId: String, stage: String) -> exec {
    DELETE FROM entry_contents WHERE entry_id = :entryId AND stage = :stage
}

// ---- 一意 ----

query findUniqueOwner(typeId: Int64, fieldId: Int64, value: String) -> one {
    SELECT entry_id FROM entry_unique_values WHERE type_id = :typeId AND field_id = :fieldId AND value = :value
}

query deleteUniquesOfEntry(entryId: String) -> exec {
    DELETE FROM entry_unique_values WHERE entry_id = :entryId
}

// unique を外した時に写しを消す
query deleteUniquesOfField(fieldId: Int64) -> exec {
    DELETE FROM entry_unique_values WHERE field_id = :fieldId
}

// unique を後から付けた時に公開中の値を写す用。型の公開中の中身
query publishedContentsOfType(typeId: Int64) -> many {
    SELECT e.id AS entry_id, c.data
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = 'published'
    WHERE e.type_id = :typeId AND e.deleted_at IS NULL
}

query insertUnique(typeId: Int64, fieldId: Int64, value: String, entryId: String) -> exec {
    INSERT INTO entry_unique_values (type_id, field_id, value, entry_id) VALUES (:typeId, :fieldId, :value, :entryId)
}

// ---- 版 ----

query insertVersion(entryId: String, version: Int32, data: Json, author: String, reason: String) -> one {
    INSERT INTO entry_versions (entry_id, version, data, author, reason) VALUES (:entryId, :version, :data, :author, :reason)
    RETURNING id
}

query listVersions(entryId: String) -> many {
    SELECT id, entry_id, version, data, author, reason, created_at FROM entry_versions WHERE entry_id = :entryId ORDER BY id DESC
}

query findVersion(id: Int64) -> one {
    SELECT id, entry_id, version, data, author, reason, created_at FROM entry_versions WHERE id = :id
}

// ---- 参照 ----

query findEntriesByStage(ids: List[String], stage: String) -> many {
    SELECT e.id, e.type_id, e.version, e.stage, e.published_at, e.created_at, e.updated_at, c.data, c.updated_at AS content_updated_at, p.updated_at AS published_updated_at
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = :stage
    LEFT JOIN entry_contents AS p ON p.entry_id = e.id AND p.stage = 'published'
    WHERE e.id = ANY(:ids) AND e.deleted_at IS NULL
}

query deleteLinks(fromEntryId: String, stage: String) -> exec {
    DELETE FROM entry_links WHERE from_entry_id = :fromEntryId AND stage = :stage
}

query insertLink(fromEntryId: String, stage: String, fieldId: Int64, toEntryId: String, position: Int32) -> exec {
    INSERT INTO entry_links (from_entry_id, stage, field_id, to_entry_id, position) VALUES (:fromEntryId, :stage, :fieldId, :toEntryId, :position)
}

// 下書きが参照している entry のうち、公開されていない物（ゴミ箱の物と無い物を含む）
query unpublishedTargets(fromEntryId: String) -> many {
    SELECT DISTINCT l.to_entry_id
    FROM entry_links AS l
    LEFT JOIN entries AS e ON e.id = l.to_entry_id AND e.deleted_at IS NULL AND e.stage = 'published'
    WHERE l.from_entry_id = :fromEntryId AND l.stage = 'draft' AND e.id IS NULL
}

// 下書きが参照している entry のうち、無い物（ゴミ箱の物と、消えた物）
query missingTargets(fromEntryId: String) -> many {
    SELECT DISTINCT l.to_entry_id
    FROM entry_links AS l
    LEFT JOIN entries AS e ON e.id = l.to_entry_id AND e.deleted_at IS NULL
    WHERE l.from_entry_id = :fromEntryId AND l.stage = 'draft' AND e.id IS NULL
}

// この entry を公開側で参照している entry（取り下げ・削除の防止用）
query publishedReferrers(toEntryId: String) -> many {
    SELECT DISTINCT l.from_entry_id
    FROM entry_links AS l
    JOIN entries AS e ON e.id = l.from_entry_id AND e.deleted_at IS NULL
    WHERE l.to_entry_id = :toEntryId AND l.stage = 'published'
}
