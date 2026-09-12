// entry_autosaves.q: 編集中の中身の、利用者ごとの置き場。
//
// **誰の行かを呼ぶ側に選ばせない。** userId は必ず今の主体（Session.currentUser / currentUserForRead）から来る。
// RLS（030_entry_autosaves.sql）も自分の行しか見せないので、二重に守る。

// 自分の行を置き直す。3 秒ごとに来るので更新だけで、version は動かさない（下書きを触らない）
query upsertAutosave(entryId: String, userId: Int64, projectId: Int64, data: Json, baseVersion: Int32) -> exec {
    INSERT INTO entry_autosaves (entry_id, user_id, project_id, data, base_version)
    VALUES (:entryId, :userId, :projectId, :data, :baseVersion)
    ON CONFLICT (entry_id, user_id) DO UPDATE SET data = EXCLUDED.data, base_version = EXCLUDED.base_version, updated_at = now()
}

query findAutosave(entryId: String, userId: Int64, projectId: Int64) -> one {
    SELECT entry_id, user_id, data, base_version, updated_at
    FROM entry_autosaves
    WHERE entry_id = :entryId AND user_id = :userId AND project_id = :projectId
}

// 一覧の行ごとに引かずに、ページの分を 1 本で（管理 API の先読み）
query findAutosavesOf(entryIds: List[String], userId: Int64, projectId: Int64) -> many {
    SELECT entry_id, user_id, data, base_version, updated_at
    FROM entry_autosaves
    WHERE entry_id = ANY(:entryIds) AND user_id = :userId AND project_id = :projectId
}

// 自分の行を捨てる（明示的な保存の後、下書きと同じ中身になった時）
query deleteAutosave(entryId: String, userId: Int64, projectId: Int64) -> exec {
    DELETE FROM entry_autosaves WHERE entry_id = :entryId AND user_id = :userId AND project_id = :projectId
}

// その entry の全員分を捨てる（ゴミ箱に入れた時）。DELETE の policy だけプロジェクト全体なので、
// 他人の行を読めないまま消せる
query deleteAutosavesOfEntry(entryId: String, projectId: Int64) -> exec {
    DELETE FROM entry_autosaves WHERE entry_id = :entryId AND project_id = :projectId
}
