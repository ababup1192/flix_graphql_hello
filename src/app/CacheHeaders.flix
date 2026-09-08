///
/// コンテンツ API の GET に付ける Cache-Control の秒数（CMS_CACHE_S_MAXAGE / CMS_CACHE_MAX_AGE / CMS_CACHE_STALE_WHILE_REVALIDATE）。
///
/// - sMaxAge: 共有キャッシュ（CDN）が持つ秒数
/// - maxAge: ブラウザが持つ秒数
/// - staleWhileRevalidate: 期限が切れた後、裏で取り直しながら古い物を返してよい秒数
///
pub type alias CachePolicy = { sMaxAge = Int32, maxAge = Int32, staleWhileRevalidate = Int32 }

///
/// コンテンツ API の GET の ETag と Cache-Control、If-None-Match の照合。純粋な関数だけで、HTTP と DB は触らない。
///
/// WhyNot: ETag を強い物（応答の本文のハッシュ）にしないのは、本文を作るには GraphQL を実行するしかなく、304 を返すためだけに
/// 200 と同じ SQL を出す事になるため。プロジェクトの版と文書のハッシュなら SQL 1 本で決まる。
///
mod CacheHeaders {

    /// 既定の秒数。CDN は 10 秒、ブラウザは持たない、期限切れから 60 秒は裏で取り直す。
    pub def defaultPolicy(): CachePolicy = { sMaxAge = 10, maxAge = 0, staleWhileRevalidate = 60 }

    ///
    /// 環境変数の生の値から秒数。数字でない物は既定に落とす。s-maxage と max-age が両方 0 以下なら None（no-store）。
    ///
    pub def policyOf(sMaxAge: Option[String], maxAge: Option[String], staleWhileRevalidate: Option[String]): Option[CachePolicy] =
        let base = defaultPolicy();
        let seconds = (raw, fallback) -> raw |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(fallback);
        let policy = { sMaxAge = seconds(sMaxAge, base#sMaxAge), maxAge = seconds(maxAge, base#maxAge), staleWhileRevalidate = seconds(staleWhileRevalidate, base#staleWhileRevalidate) };
        if (policy#sMaxAge <= 0 and policy#maxAge <= 0) None else Some(policy)

    ///
    /// 共有キャッシュに乗せる Cache-Control。
    ///
    pub def cacheControl(policy: CachePolicy): String =
        "public, s-maxage=${policy#sMaxAge}, max-age=${policy#maxAge}, stale-while-revalidate=${policy#staleWhileRevalidate}"

    ///
    /// キャッシュさせない Cache-Control。鍵やトークン付きの応答、errors のある応答。
    ///
    pub def noStore(): String = "private, no-store"

    ///
    /// weak な ETag。`W/"v<版>-<sha256(query + "\n" + variables の JSON + "\n" + operationName) の先頭 16 桁>"`。
    /// 版はプロジェクトの content_version で、公開・取り下げ・削除・型の変更で進む。variables は Map なのでキーの順は決まる。
    ///
    pub def etagOf(version: Int64, request: GraphqlRequest): String =
        let key = "${request#queryText}\n${JsonValue.toJsonString(Value.Obj(request#variables))}\n${request#operationName |> Option.getWithDefault("")}";
        "W/\"v${version}-${String.takeLeft(16, Sha256.hex(key))}\""

    ///
    /// If-None-Match の値がこの ETag に当たるか。`*` は常に当たり、カンマ区切りの複数は 1 つでも合えば当たり、
    /// weak の印（`W/`）は両側とも無視して比べる（RFC 9110 の weak comparison）。
    ///
    pub def matches(ifNoneMatch: Option[String], etag: String): Bool = match ifNoneMatch {
        case None        => false
        case Some(value) =>
            let wanted = opaqueTag(etag);
            value |> String.splitOn(substr = ",") |> List.map(String.trim) |> List.exists(tag -> tag == "*" or (not String.isEmpty(tag) and opaqueTag(tag) == wanted))
    }

    /// `W/"x"` と `"x"` を同じ `"x"` に。
    def opaqueTag(tag: String): String =
        if (String.startsWith(prefix = "W/", tag)) String.dropLeft(2, tag) else tag

}
