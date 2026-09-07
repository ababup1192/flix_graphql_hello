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
    /// entries と entry_contents（stage の行）を JOIN した行から Entry を組む。
    ///
    /// changedSincePublish は「読んだ stage の行の updated_at（content_updated_at）」と「published の行の updated_at」の比較。
    /// 管理 API は draft の行を読むので下書きが進んだかが分かり、コンテンツ API が published の行を読めば常に false。
    ///
    pub def toEntry(contentStage: Stage, row: { id = String, typeId = Int64, version = Int32, stage = String, publishedAt = Option[Timestamp.Timestamp], createdAt = Timestamp.Timestamp, updatedAt = Timestamp.Timestamp, data = Json, contentUpdatedAt = Timestamp.Timestamp, publishedUpdatedAt = Option[Timestamp.Timestamp] | r }): Entry \ DbErr =
        let stage = stageFromDb(row#stage) |> Rows.orRaise("entries.stage", row#stage);
        {
            id          = EntryId.parse(row#id) |> Rows.orRaise("entries.id", row#id),
            typeId      = TypeId.TypeId(row#typeId),
            version     = row#version,
            stage       = stage,
            data        = dataFromJson(row#data),
            publishedAt = row#publishedAt,
            changedSincePublish = stage == Stage.Published and (row#publishedUpdatedAt |> Option.map(published -> Timestamp.toEpochMicros(row#contentUpdatedAt) > Timestamp.toEpochMicros(published)) |> Option.getWithDefault(false)),
            contentStage = contentStage,
            linked      = Linked.empty(),
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
    /// insertVersion の引数。今の下書きをそのまま積む。
    ///
    pub def versionInsert(entry: Entry, author: String, reason: VersionReason): { entryId = String, version = Int32, data = Json, author = String, reason = String } =
        { entryId = EntryId.text(entry#id), version = entry#version, data = dataToJson(entry#data), author = author, reason = reasonToDb(reason) }

    ///
    /// entry_versions の行から EntryVersion を組む。
    ///
    pub def toVersion(row: { id = Int64, entryId = String, version = Int32, data = Json, author = String, reason = String, createdAt = Timestamp.Timestamp | r }): EntryVersion \ DbErr =
        {
            id        = VersionId.VersionId(row#id),
            entryId   = EntryId.parse(row#entryId) |> Rows.orRaise("entry_versions.entry_id", row#entryId),
            version   = row#version,
            data      = dataFromJson(row#data),
            author    = row#author,
            reason    = reasonFromDb(row#reason) |> Rows.orRaise("entry_versions.reason", row#reason),
            createdAt = row#createdAt
        }

    ///
    /// entry_links の参照先（to_entry_id）。規則外の id は無い物にする。
    ///
    pub def toTargetId(row: { toEntryId = String | r }): Option[EntryId] = EntryId.parse(row#toEntryId)

    ///
    /// entry_links の参照元（from_entry_id）の文字列。
    ///
    pub def referrerText(row: { fromEntryId = String | r }): String = row#fromEntryId

}
