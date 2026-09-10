// schema_impact.q: スキーマを変える前に「何件に当たるか」を数える。
//
// **判定はしない。** 「値がある」の定義は EntryValidation.hasValue が持つ。ここは同じ述語を
// jsonpath で書いた写しで、SQL と規則がずれていないかは TestSchemaImpactPg が突き合わせる。
//
// path は Flix が組んだ jsonpath（`$.**."apiId" ? (...)`）。apiId は lowerCamel に限る
// （Naming.validateFieldApiId）ので、そのまま埋め込んでも壊れない。入れ子（object / blocks）の
// 子も拾うために `$.**` を使う。GIN には乗らないので、影響が空でない時だけ呼ぶ。

// その型の entry のうち、その path に値を持つ数。stage ごと
query countFieldValues(typeId: Int64, path: String, projectId: Int64) -> many {
    SELECT c.stage, count(*)::bigint AS total
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.project_id = e.project_id
    WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
      AND jsonb_path_exists(c.data, :path::jsonpath)
    GROUP BY c.stage
}

// 公開中だが、その path に値が無い数（required を立てると再公開できなくなる）
query countMissingPublished(typeId: Int64, path: String, projectId: Int64) -> one {
    SELECT count(*)::bigint AS total
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.project_id = e.project_id AND c.stage = 'published'
    WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
      AND NOT jsonb_path_exists(c.data, :path::jsonpath)
}

// 公開中で値が重なっている entry の数（unique を立てると再公開できなくなる）。
// unique は最上位のスカラーにしか付かない（Naming.validateFlags）ので ->> で足りる
query countDuplicatePublished(typeId: Int64, apiId: String, projectId: Int64) -> one {
    SELECT coalesce(sum(n), 0)::bigint AS total
    FROM (
        SELECT count(*) AS n
        FROM entries AS e
        JOIN entry_contents AS c ON c.entry_id = e.id AND c.project_id = e.project_id AND c.stage = 'published'
        WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
          AND c.data ->> :apiId IS NOT NULL
        GROUP BY c.data ->> :apiId
        HAVING count(*) > 1
    ) AS duplicated
}

// 下書きに、新しい選択肢から外れた値を持つ数（SELECT の選択肢を減らすと保存が通らなくなる）
query countOutsideOptions(typeId: Int64, apiId: String, options: List[String], projectId: Int64) -> one {
    SELECT count(*)::bigint AS total
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.project_id = e.project_id AND c.stage = 'draft'
    WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
      AND c.data ->> :apiId IS NOT NULL AND NOT (c.data ->> :apiId = ANY(:options))
}

// 下書きに、新しい上限より長い文字列を持つ数（maxLength を縮めると保存が通らなくなる）。
// length() はコードポイントで数え、EntryValidation.codePointCount と同じ（UTF-16 の単位ではない）
query countOverLength(typeId: Int64, path: String, limit: Int32, projectId: Int64) -> one {
    SELECT count(*)::bigint AS total
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.project_id = e.project_id AND c.stage = 'draft'
    WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
      AND EXISTS (
          SELECT 1 FROM jsonb_path_query(c.data, :path::jsonpath) AS v
          WHERE jsonb_typeof(v) = 'string' AND length(v #>> '{}') > :limit
      )
}

// 下書きに、新しい範囲から外れた数値を持つ数（min を上げる・max を下げる・整数に限る）。
// 渡さなかった側（NULL）は見ない。前から外れていた値は今回の影響ではない
query countOutsideRange(typeId: Int64, path: String, low: Option[Float64], high: Option[Float64], integer: Bool, projectId: Int64) -> one {
    SELECT count(*)::bigint AS total
    FROM entries AS e
    JOIN entry_contents AS c ON c.entry_id = e.id AND c.project_id = e.project_id AND c.stage = 'draft'
    WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
      AND EXISTS (
          SELECT 1 FROM jsonb_path_query(c.data, :path::jsonpath) AS v
          WHERE jsonb_typeof(v) = 'number' AND (
                 (:low::float8 IS NOT NULL AND (v #>> '{}')::float8 < :low::float8)
              OR (:high::float8 IS NOT NULL AND (v #>> '{}')::float8 > :high::float8)
              OR (:integer AND (v #>> '{}')::numeric <> trunc((v #>> '{}')::numeric))
          )
      )
}
