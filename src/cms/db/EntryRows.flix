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
    ///
    /// changedSincePublish は「読んだ stage の行の updated_at」と「published の行の updated_at」の比較。
    /// 管理 API は draft の行を読むので下書きが進んだかが分かり、コンテンツ API が published の行を読めば常に false。
    ///
    pub def toEntry(row: { id = String, typeId = Int64, version = Int32, stage = String, publishedAt = Option[Timestamp.Timestamp], createdAt = Timestamp.Timestamp, updatedAt = Timestamp.Timestamp, data = Json, draftUpdatedAt = Timestamp.Timestamp, publishedUpdatedAt = Option[Timestamp.Timestamp] | r }): Entry \ DbErr =
        let stage = stageFromDb(row#stage) |> orRaise("entries.stage", row#stage);
        {
            id          = EntryId.parse(row#id) |> orRaise("entries.id", row#id),
            typeId      = TypeId.TypeId(row#typeId),
            version     = row#version,
            stage       = stage,
            data        = dataFromJson(row#data),
            publishedAt = row#publishedAt,
            changedSincePublish = stage == Stage.Published and (row#publishedUpdatedAt |> Option.map(published -> Timestamp.toEpochMicros(row#draftUpdatedAt) > Timestamp.toEpochMicros(published)) |> Option.getWithDefault(false)),
            createdAt   = row#createdAt,
            updatedAt   = row#updatedAt
        }

    ///
    /// entry_versions.reason の値。
    ///
    pub def reasonToDb(reason: VersionReason): String = match reason {
        case VersionReason.Publish => "publish"
        case VersionReason.Save    => "save"
    }

    pub def reasonFromDb(text: String): Option[VersionReason] = match text {
        case "publish" => Some(VersionReason.Publish)
        case "save"    => Some(VersionReason.Save)
        case _         => None
    }

    ///
    /// entry_versions の行から EntryVersion を組む。
    ///
    pub def toVersion(row: { id = Int64, entryId = String, version = Int32, data = Json, author = String, reason = String, createdAt = Timestamp.Timestamp | r }): EntryVersion \ DbErr =
        {
            id        = VersionId.VersionId(row#id),
            entryId   = EntryId.parse(row#entryId) |> orRaise("entry_versions.entry_id", row#entryId),
            version   = row#version,
            data      = dataFromJson(row#data),
            author    = row#author,
            reason    = reasonFromDb(row#reason) |> orRaise("entry_versions.reason", row#reason),
            createdAt = row#createdAt
        }

    ///
    /// unique なフィールドの値を entry_unique_values.value の文字列にする。配列や null は None（一意の対象にしない）。
    ///
    pub def uniqueValueText(json: Json): Option[String] = match json {
        case Json.JString(s) => Some(s)
        case Json.JNumber(n) => Some("${n}")
        case Json.JBool(b)   => Some(if (b) "true" else "false")
        case _               => None
    }

    def orRaise(column: String, text: String, value: Option[a]): a \ DbErr = match value {
        case Some(found) => found
        case None        => DbErr.other("${column} の値が読めません: ${text}")
    }

}
