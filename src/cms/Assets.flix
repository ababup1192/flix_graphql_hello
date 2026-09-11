///
/// asset のユースケース。署名付き URL の発行 → ブラウザが置く → confirm で ready、と、alt の変更・削除・一覧。
/// 中身はストレージ（ObjectStore）にあり、DB は場所と属性だけ。読み書きは今のプロジェクトに閉じる。
/// pub の入口は権限の証明（`Granted[ReadDraft]` / `Granted[ManageAssets]`。`Session.grant()` で作る）を最初の引数で受け、自分では判定しない。
///
mod Assets {

    ///
    /// 申し込みを検査して pending の行を作り、置き先の署名付き URL を返す。
    ///
    pub def createUpload(_proof: Granted[ManageAssets], request: UploadRequest): Upload \ Db + CmsErr + IdGen + Tenant + ObjectStore =
        CmsErr.raiseIfAny(AssetRules.validateUpload(request));
        let id = IdGen.freshAssetId();
        let key = "${Tenant.currentId()}/${AssetId.text(id)}/${AssetRules.safeFileName(request#fileName)}";
        let uploadUrl = ObjectStore.presignPut(key, request#mime, request#size) |> orStorageErr;
        discard AssetsQueries.insertAsset({ id = AssetId.text(id), projectId = Tenant.currentId(), key = key, fileName = AssetRules.safeFileName(request#fileName), mime = request#mime, size = request#size });
        { asset = get(id), uploadUrl = uploadUrl, expiresInSeconds = ObjectStore.uploadExpirySeconds() }

    ///
    /// ブラウザが置いた後。ストレージに実在するかを HEAD で確かめ、その size と渡された寸法・alt で ready にする。
    /// 既に ready なら寸法と alt だけ上書きする（再送しても壊れない）。
    ///
    pub def confirm(_proof: Granted[ManageAssets], id: AssetId, details: AssetConfirm): Asset \ Db + CmsErr + IdGen + Tenant + Session + ObjectStore =
        let asset = get(id);
        let size = ObjectStore.head(asset#key) |> orStorageErr;
        match size {
            case None => CmsErr.invalid(Violation.Violation("id", "'${id}' はまだアップロードが終わっていません") :: Nil)
            case Some(found) =>
                discard AssetsQueries.markAssetReady({
                    id = AssetId.text(id), projectId = Tenant.currentId(), size = found,
                    width = AssetRows.dimensionToDb(details#width), height = AssetRows.dimensionToDb(details#height),
                    alt = details#alt |> Option.getWithDefault(asset#alt)
                });
                let ready = get(id);
                // WhyNot: 既に ready の物の confirm を積まない。confirm は冪等で同じ asset に何度も来るため
                if (asset#status == AssetStatus.Pending) Audit.record(AuditChange.AssetConfirmed(id, AuditSnapshot.ofAsset(ready))) else ();
                ready
        }

    ///
    /// alt を変える。ファイルの差し替えは新しい asset を作る。
    ///
    pub def updateAlt(_proof: Granted[ManageAssets], id: AssetId, alt: String): Asset \ Db + CmsErr + Tenant =
        discard get(id);
        discard AssetsQueries.updateAssetAlt({ id = AssetId.text(id), projectId = Tenant.currentId(), alt = alt });
        get(id)

    ///
    /// 消す。entry（下書き・公開・richText の image を含む）が使っていれば invalid。
    /// ストレージの削除は DB の後で、失敗しても DB は消えたまま（孤児は掃除で拾う）。
    ///
    pub def delete(_proof: Granted[ManageAssets], id: AssetId): Unit \ Db + CmsErr + IdGen + Tenant + Session + ObjectStore =
        let asset = get(id);
        let holders = AssetsQueries.assetHolders({ projectId = Tenant.currentId(), assetId = AssetId.text(id) }) |> List.map(row -> row#id);
        CmsErr.raiseIfAny(if (List.isEmpty(holders)) Nil else Violation.Violation("id", "entry '${List.join("', '", holders)}' が使っています。先に外してください") :: Nil);
        discard AssetsQueries.deleteAsset({ id = AssetId.text(id), projectId = Tenant.currentId() });
        Audit.record(AuditChange.AssetDeleted(id, AuditSnapshot.ofAsset(asset)));
        discard ObjectStore.delete(asset#key)

    ///
    /// この asset を中身（下書き・公開・本文の image）に持つ entry の id。
    ///
    pub def holders(_proof: Granted[ReadDraft], id: AssetId): List[EntryId] \ DbRead + Tenant =
        AssetsQueries.assetHolders({ projectId = Tenant.currentId(), assetId = AssetId.text(id) }) |> List.filterMap(row -> EntryId.parse(row#id))

    ///
    /// id で 1 つ（管理 API）。無ければ None。他のプロジェクトの物も None。
    ///
    pub def find(_proof: Granted[ReadDraft], id: AssetId): Option[Asset] \ DbRead + Tenant =
        lookup(id)

    /// id で 1 つ。権限は見ない（ユースケースの内部で使う）。
    def lookup(id: AssetId): Option[Asset] \ DbRead + Tenant =
        AssetsQueries.findAsset({ id = AssetId.text(id), projectId = Tenant.currentId() }) |> Option.map(AssetRows.toAsset)

    ///
    /// id の並びで引く。無い物は落ちる。順は問わない。コンテンツ API の配信と公開の検査が使う。
    ///
    /// WhyNot: 権限の証明を取らないのは、asset は stage を持たず配信 URL は誰でも開けるので、読める entry の asset は誰でも読めるため。
    ///
    pub def findMany(ids: List[AssetId]): List[Asset] \ DbRead + Tenant = match ids {
        case Nil => Nil
        case _   => AssetsQueries.findAssets({ ids = ids |> List.map(AssetId.text), projectId = Tenant.currentId() }) |> List.map(AssetRows.toAsset)
    }

    ///
    /// 一覧。新しい順。first + 1 件引いて「次があるか」を決め、各 asset の位置（cursor）を付ける。after なら cursor の位置より古い物。
    ///
    pub def list(_proof: Granted[ReadDraft], first: Int32, start: PageStart): AssetPage \ DbRead + CmsErr + Tenant =
        let limit = Int32.toInt64(first + 1);
        let rows = match start {
            case PageStart.Offset(skip)  => AssetsQueries.listAssets({ projectId = Tenant.currentId(), limit = limit, offset = Int32.toInt64(skip) }) |> List.map(AssetRows.toAsset)
            case PageStart.After(cursor) =>
                let (createdAt, id) = Cursor.assetPosition(cursor) |> CmsErr.orInvalid("after", "cursor が壊れています");
                AssetsQueries.listAssetsAfter({ projectId = Tenant.currentId(), createdAt = createdAt, id = AssetId.text(id), limit = limit }) |> List.map(AssetRows.toAsset)
        };
        let (assets, hasNextPage) = EntryPage.trimPage(first, rows);
        {
            assets = assets,
            cursors = assets |> List.map(asset -> Cursor.encode(Cursor.ofAsset(asset))),
            totalCount = AssetsQueries.countAssets(Tenant.currentId()) |> Rows.total,
            hasNextPage = hasNextPage
        }

    /// 1 つ。無ければ notFound。
    def get(id: AssetId): Asset \ DbRead + CmsErr + Tenant =
        lookup(id) |> CmsErr.orNotFound(Entity.Asset, AssetId.text(id))

    /// ストレージの失敗は業務エラーとして返す（DB の失敗ではないので DbErr にしない）。
    def orStorageErr(result: Result[String, a]): a \ CmsErr = match result {
        case Ok(value)     => value
        case Err(message)  => CmsErr.invalid(Violation.Violation("storage", message) :: Nil)
    }

}
