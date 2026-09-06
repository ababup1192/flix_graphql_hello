///
/// entries / entry_contents の行と、ドメインの値のあいだの変換。stage の文字列と data の JSONB。
///
mod EntryRows {

    use Util.Json.Json

    ///
    /// entries.stage の値。CHECK 制約の文字列と揃える。
    ///
    pub def stageToDb(stage: Stage): String = match stage {
        case Stage.Draft     => "draft"
        case Stage.Published => "published"
    }

    ///
    /// entries.stage の値から。知らない文字列は None（DDL の CHECK が守るので起きない）。
    ///
    pub def stageFromDb(text: String): Option[Stage] = match text {
        case "draft"     => Some(Stage.Draft)
        case "published" => Some(Stage.Published)
        case _           => None
    }

    ///
    /// entry_contents.data の JSON からドメインの中身へ。オブジェクトでない・キーが apiId の規則に合わない行は DbErr。
    ///
    pub def dataFromJson(json: Json): EntryData \ DbErr = match json {
        case Json.JObject(fields) =>
            Map.foldLeftWithKey((acc, key, value) -> match ApiId.parse(key) {
                case Some(apiId) => Map.insert(apiId, value, acc)
                case None        => DbErr.other("entry_contents.data のキーが apiId の規則に合いません: ${key}")
            }, Map.empty(), fields)
        case _ => DbErr.other("entry_contents.data がオブジェクトではありません")
    }

    ///
    /// ドメインの中身を entry_contents.data の JSON へ。
    ///
    pub def dataToJson(data: EntryData): Json =
        Json.JObject(data |> Map.toList |> List.map(match (apiId, value) -> (ApiId.text(apiId), value)) |> List.toMap)

    ///
    /// entries と entry_contents（draft）を JOIN した行から Entry を組む。
    ///
    pub def toEntry(row: { id = String, typeId = Int64, version = Int32, stage = String, publishedAt = Option[Timestamp.Timestamp], createdAt = Timestamp.Timestamp, updatedAt = Timestamp.Timestamp, data = Json | r }): Entry \ DbErr =
        {
            id          = EntryId.parse(row#id) |> orRaise("entries.id", row#id),
            typeId      = TypeId.TypeId(row#typeId),
            version     = row#version,
            stage       = stageFromDb(row#stage) |> orRaise("entries.stage", row#stage),
            data        = dataFromJson(row#data),
            publishedAt = row#publishedAt,
            createdAt   = row#createdAt,
            updatedAt   = row#updatedAt
        }

    def orRaise(column: String, text: String, value: Option[a]): a \ DbErr = match value {
        case Some(found) => found
        case None        => DbErr.other("${column} の値が読めません: ${text}")
    }

}
