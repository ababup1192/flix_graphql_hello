// schema_impact.q: スキーマを変える前に「何件に当たるか」を数える。
//
// **判定はしない。** 「値がある」の定義は EntryValidation.hasValue が持つ。ここは同じ述語を
// jsonpath で書いた写しで、SQL と規則がずれていないかは TestSchemaImpactPg が突き合わせる。
//
// path は Flix が組んだ jsonpath（`$.**."apiId" ? (...)`）。apiId は lowerCamel に限る
// （Naming.validateFieldApiId）ので、そのまま埋め込んでも壊れない。入れ子（object / blocks）の
// 子も拾うために `$.**` を使う。GIN には乗らないので、影響が空でない時だけ呼ぶ。

// 返すのは「当たった entry の見本 + 全体の件数」。total は window で全件、行は updated_at の新しい順に
// max 件まで。件数を正確に持ちながら、画面に並べる分だけ id を返す。

// その型の entry のうち、その path に値を持つ物。stage ごとに max 件、total は stage ごとの全件
query listFieldValues(typeId: Int64, path: String, max: Int32, projectId: Int64) -> many {
    SELECT hits.id::text AS id, hits.stage::text AS stage, hits.total::bigint AS total
    FROM (
        SELECT e.id, c.stage,
               count(*) OVER (PARTITION BY c.stage)::bigint AS total,
               row_number() OVER (PARTITION BY c.stage ORDER BY e.updated_at DESC, e.id) AS n
        FROM entries AS e
        JOIN entry_contents AS c ON c.entry_id = e.id AND c.project_id = e.project_id
        WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
          AND jsonb_path_exists(c.data, :path::jsonpath)
    ) AS hits
    WHERE n <= :max
}

// 公開中だが、その path に値が無い物（required を立てると再公開できなくなる）
query listMissingPublished(typeId: Int64, path: String, max: Int32, projectId: Int64) -> many {
    SELECT hits.id::text AS id, hits.total::bigint AS total
    FROM (
        SELECT e.id, count(*) OVER ()::bigint AS total, row_number() OVER (ORDER BY e.updated_at DESC, e.id) AS n
        FROM entries AS e
        JOIN entry_contents AS c ON c.entry_id = e.id AND c.project_id = e.project_id AND c.stage = 'published'
        WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
          AND NOT jsonb_path_exists(c.data, :path::jsonpath)
    ) AS hits
    WHERE n <= :max
}

// 公開中で値が重なっている物（unique を立てると再公開できなくなる）。
// unique は最上位のスカラーにしか付かない（Naming.validateFlags）ので ->> で足りる
query listDuplicatePublished(typeId: Int64, apiId: String, max: Int32, projectId: Int64) -> many {
    SELECT hits.id::text AS id, hits.total::bigint AS total
    FROM (
        SELECT e.id, count(*) OVER ()::bigint AS total, row_number() OVER (ORDER BY e.updated_at DESC, e.id) AS n
        FROM entries AS e
        JOIN entry_contents AS c ON c.entry_id = e.id AND c.project_id = e.project_id AND c.stage = 'published'
        WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
          AND c.data ->> :apiId IS NOT NULL
          AND (c.data ->> :apiId) IN (
              SELECT c2.data ->> :apiId
              FROM entries AS e2
              JOIN entry_contents AS c2 ON c2.entry_id = e2.id AND c2.project_id = e2.project_id AND c2.stage = 'published'
              WHERE e2.type_id = :typeId AND e2.project_id = :projectId AND e2.deleted_at IS NULL
                AND c2.data ->> :apiId IS NOT NULL
              GROUP BY 1
              HAVING count(*) > 1
          )
    ) AS hits
    WHERE n <= :max
}

// 下書きに、新しい選択肢から外れた値を持つ物（SELECT の選択肢を消すと保存が通らなくなる）
query listOutsideOptions(typeId: Int64, apiId: String, options: List[String], max: Int32, projectId: Int64) -> many {
    SELECT hits.id::text AS id, hits.total::bigint AS total
    FROM (
        SELECT e.id, count(*) OVER ()::bigint AS total, row_number() OVER (ORDER BY e.updated_at DESC, e.id) AS n
        FROM entries AS e
        JOIN entry_contents AS c ON c.entry_id = e.id AND c.project_id = e.project_id AND c.stage = 'draft'
        WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
          AND c.data ->> :apiId IS NOT NULL AND NOT (c.data ->> :apiId = ANY(:options))
    ) AS hits
    WHERE n <= :max
}

// 下書きに、新しい上限より長い文字列を持つ物（maxLength を縮めると保存が通らなくなる）。
// length() はコードポイントで数え、EntryValidation.codePointCount と同じ（UTF-16 の単位ではない）
query listOverLength(typeId: Int64, path: String, limit: Int32, max: Int32, projectId: Int64) -> many {
    SELECT hits.id::text AS id, hits.total::bigint AS total
    FROM (
        SELECT e.id, count(*) OVER ()::bigint AS total, row_number() OVER (ORDER BY e.updated_at DESC, e.id) AS n
        FROM entries AS e
        JOIN entry_contents AS c ON c.entry_id = e.id AND c.project_id = e.project_id AND c.stage = 'draft'
        WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
          AND EXISTS (
              SELECT 1 FROM jsonb_path_query(c.data, :path::jsonpath) AS v
              WHERE jsonb_typeof(v) = 'string' AND length(v #>> '{}') > :limit
          )
    ) AS hits
    WHERE n <= :max
}

// 下書きに、新しい範囲から外れた数値を持つ物（min を上げる・max を下げる・整数に限る）。
// 渡さなかった側（NULL）は見ない。前から外れていた値は今回の影響ではない
query listOutsideRange(typeId: Int64, path: String, low: Option[Float64], high: Option[Float64], integer: Bool, max: Int32, projectId: Int64) -> many {
    SELECT hits.id::text AS id, hits.total::bigint AS total
    FROM (
        SELECT e.id, count(*) OVER ()::bigint AS total, row_number() OVER (ORDER BY e.updated_at DESC, e.id) AS n
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
    ) AS hits
    WHERE n <= :max
}

// その型の entry（ゴミ箱を除く）。型を消す時に一緒に消える物
query listEntriesOfType(typeId: Int64, max: Int32, projectId: Int64) -> many {
    SELECT hits.id::text AS id, hits.total::bigint AS total
    FROM (
        SELECT e.id, count(*) OVER ()::bigint AS total, row_number() OVER (ORDER BY e.updated_at DESC, e.id) AS n
        FROM entries AS e
        WHERE e.type_id = :typeId AND e.project_id = :projectId AND e.deleted_at IS NULL
    ) AS hits
    WHERE n <= :max
}
