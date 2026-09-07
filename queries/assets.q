// assets.q: 画像やファイルのメタデータ。中身はストレージにあり、ここは場所と属性だけ

query insertAsset(id: String, projectId: Int64, key: String, fileName: String, mime: String, size: Int64) -> exec {
    INSERT INTO assets (id, project_id, key, file_name, mime, size, status)
    VALUES (:id, :projectId, :key, :fileName, :mime, :size, 'pending')
}

query findAsset(id: String, projectId: Int64) -> one {
    SELECT id, key, file_name, mime, size, width, height, alt, status, created_at
    FROM assets WHERE id = :id AND project_id = :projectId
}

query findAssets(ids: List[String], projectId: Int64) -> many {
    SELECT id, key, file_name, mime, size, width, height, alt, status, created_at
    FROM assets WHERE id = ANY(:ids) AND project_id = :projectId
}

// 一覧。新しい順。pending も出す（アップロード途中の物を管理画面で見せる）
query listAssets(projectId: Int64, limit: Int64, offset: Int64) -> many {
    SELECT id, key, file_name, mime, size, width, height, alt, status, created_at
    FROM assets WHERE project_id = :projectId
    ORDER BY created_at DESC, id DESC
    LIMIT :limit OFFSET :offset
}

query countAssets(projectId: Int64) -> one {
    SELECT count(*)::bigint AS total FROM assets WHERE project_id = :projectId
}

// ブラウザが置いた後。ストレージで確かめた size で上書きし、寸法と alt を入れて ready にする
query markAssetReady(id: String, projectId: Int64, size: Int64, width: Int32, height: Int32, alt: String) -> exec {
    UPDATE assets SET status = 'ready', size = :size, width = :width, height = :height, alt = :alt
    WHERE id = :id AND project_id = :projectId
}

query updateAssetAlt(id: String, projectId: Int64, alt: String) -> exec {
    UPDATE assets SET alt = :alt WHERE id = :id AND project_id = :projectId
}

query deleteAsset(id: String, projectId: Int64) -> exec {
    DELETE FROM assets WHERE id = :id AND project_id = :projectId
}

// この asset の id を中身のどこかに持つ entry（下書き・公開の両方。richText の image も含めて、値として現れる所を全部）
query assetHolders(projectId: Int64, assetId: String) -> many {
    SELECT DISTINCT e.id
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id
    WHERE e.project_id = :projectId AND e.deleted_at IS NULL
      AND jsonb_path_exists(c.data, '$.** ? (@ == $id)', jsonb_build_object('id', :assetId))
    ORDER BY e.id
}
