// entries.q: entry の身元と中身

query findEntry(id: String) -> one {
    SELECT e.id, e.type_id, e.version, e.stage, e.published_at, e.created_at, e.updated_at, c.data
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = 'draft'
    WHERE e.id = :id AND e.deleted_at IS NULL
}

// 一覧。search が空なら全件、そうでなければ下書きの中身の文字列に含む物
query listEntries(typeId: Int64, search: String, limit: Int64, offset: Int64) -> many {
    SELECT e.id, e.type_id, e.version, e.stage, e.published_at, e.created_at, e.updated_at, c.data
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = 'draft'
    WHERE e.type_id = :typeId AND e.deleted_at IS NULL
      AND (:search = '' OR c.data::text ILIKE '%' || :search || '%')
    ORDER BY e.updated_at DESC, e.id
    LIMIT :limit OFFSET :offset
}

query countEntries(typeId: Int64, search: String) -> one {
    SELECT count(*)::bigint AS total
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.stage = 'draft'
    WHERE e.type_id = :typeId AND e.deleted_at IS NULL
      AND (:search = '' OR c.data::text ILIKE '%' || :search || '%')
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

query upsertContent(entryId: String, stage: String, data: Json) -> exec {
    INSERT INTO entry_contents (entry_id, stage, data) VALUES (:entryId, :stage, :data)
    ON CONFLICT (entry_id, stage) DO UPDATE SET data = EXCLUDED.data, updated_at = now()
}
