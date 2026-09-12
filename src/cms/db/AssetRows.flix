///
/// assets の行とドメインの Asset のあいだの変換。status の文字列と、0 = 不明の寸法。
///
mod AssetRows {

    ///
    /// assets.status の値。CHECK 制約の文字列と揃える。
    ///
    pub def statusToDb(status: AssetStatus): String = match status {
        case AssetStatus.Pending => "pending"
        case AssetStatus.Ready   => "ready"
    }

    ///
    /// assets.status の値から。知らない文字列は None（CHECK が守るので起きない）。
    ///
    pub def statusFromDb(text: String): Option[AssetStatus] = match text {
        case "pending" => Some(AssetStatus.Pending)
        case "ready"   => Some(AssetStatus.Ready)
        case _         => None
    }

    ///
    /// 行から Asset へ。寸法の 0 は不明として None。
    ///
    pub def toAsset(row: { id = String, key = String, fileName = String, mime = String, size = Int64, width = Int32, height = Int32, alt = String, status = String, createdAt = Timestamp.Timestamp, presentation = Option[Util.Json.Json] | r }): Asset \ DbErr =
        {
            id           = AssetId.parse(row#id) |> Rows.orRaise("assets.id", row#id),
            key          = row#key,
            fileName     = row#fileName,
            mime         = row#mime,
            size         = row#size,
            width        = dimension(row#width),
            height       = dimension(row#height),
            alt          = row#alt,
            status       = statusFromDb(row#status) |> Rows.orRaise("assets.status", row#status),
            createdAt    = row#createdAt,
            presentation = presentationFromDb(row#presentation)
        }

    ///
    /// ドメインの寸法を列の値へ。None は 0。
    ///
    pub def dimensionToDb(value: Option[Int32]): Int32 = value |> Option.getWithDefault(0)

    ///
    /// 見せ方を列（JSONB、NULL 可）へ。何も無ければ NULL。
    ///
    pub def presentationToDb(presentation: AssetPresentation): Option[Util.Json.Json] =
        if (AssetPresentation.isEmpty(presentation)) None else Some(AssetPresentation.toJson(presentation))

    /// 列から。NULL は何も無し。形が違えば DbErr（書くのは presentationToDb だけなので起きない）。
    def presentationFromDb(json: Option[Util.Json.Json]): AssetPresentation \ DbErr = match json {
        case None        => AssetPresentation.empty()
        case Some(found) => AssetPresentation.fromJson(found) |> Rows.orRaise("assets.presentation", Util.Json.toCompactString(found))
    }

    def dimension(value: Int32): Option[Int32] = if (value > 0) Some(value) else None

}
