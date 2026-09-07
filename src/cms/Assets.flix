///
/// asset のユースケース。署名付き URL の発行 → ブラウザが置く → confirm で ready、と、alt の変更・削除・一覧。
/// 中身はストレージ（ObjectStore）にあり、DB は場所と属性だけ。読み書きは今のプロジェクトに閉じる。
///
mod Assets {

    ///
    /// 申し込みを検査して pending の行を作り、置き先の署名付き URL を返す。
    ///
    pub def createUpload(request: UploadRequest): Upload \ Db + CmsErr + IdGen + Tenant + ObjectStore =
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
    pub def confirm(id: AssetId, details: AssetConfirm): Asset \ Db + CmsErr + Tenant + ObjectStore =
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
                get(id)
        }

    ///
    /// alt を変える。ファイルの差し替えは新しい asset を作る。
    ///
    pub def updateAlt(id: AssetId, alt: String): Asset \ Db + CmsErr + Tenant =
        discard get(id);
        discard AssetsQueries.updateAssetAlt({ id = AssetId.text(id), projectId = Tenant.currentId(), alt = alt });
        get(id)

    ///
    /// 消す。entry（下書き・公開・richText の image を含む）が使っていれば invalid。
    /// ストレージの削除は DB の後で、失敗しても DB は消えたまま（孤児は掃除で拾う）。
    ///
    pub def delete(id: AssetId): Unit \ Db + CmsErr + Tenant + ObjectStore =
        let asset = get(id);
        let holders = AssetsQueries.assetHolders({ projectId = Tenant.currentId(), assetId = AssetId.text(id) }) |> List.map(row -> row#id);
        CmsErr.raiseIfAny(if (List.isEmpty(holders)) Nil else Violation.Violation("id", "entry '${List.join("', '", holders)}' が使っています。先に外してください") :: Nil);
        discard AssetsQueries.deleteAsset({ id = AssetId.text(id), projectId = Tenant.currentId() });
        discard ObjectStore.delete(asset#key)

    ///
    /// この asset を中身（下書き・公開・本文の image）に持つ entry の id。
    ///
    pub def holders(id: AssetId): List[EntryId] \ DbRead + Tenant =
        AssetsQueries.assetHolders({ projectId = Tenant.currentId(), assetId = AssetId.text(id) }) |> List.filterMap(row -> EntryId.parse(row#id))

    ///
    /// id で 1 つ。無ければ None。他のプロジェクトの物も None。
    ///
    pub def find(id: AssetId): Option[Asset] \ DbRead + DbErr + Tenant =
        AssetsQueries.findAsset({ id = AssetId.text(id), projectId = Tenant.currentId() }) |> Option.map(AssetRows.toAsset)

    ///
    /// id の並びで引く。無い物は落ちる。順は問わない。
    ///
    pub def findMany(ids: List[AssetId]): List[Asset] \ DbRead + DbErr + Tenant = match ids {
        case Nil => Nil
        case _   => AssetsQueries.findAssets({ ids = ids |> List.map(AssetId.text), projectId = Tenant.currentId() }) |> List.map(AssetRows.toAsset)
    }

    ///
    /// 一覧。新しい順。
    ///
    pub def list(first: Int32, skip: Int32): AssetPage \ DbRead + DbErr + Tenant =
        {
            assets = AssetsQueries.listAssets({ projectId = Tenant.currentId(), limit = Int32.toInt64(first), offset = Int32.toInt64(skip) }) |> List.map(AssetRows.toAsset),
            totalCount = AssetsQueries.countAssets(Tenant.currentId()) |> Rows.total
        }

    /// 1 つ。無ければ notFound。
    def get(id: AssetId): Asset \ DbRead + DbErr + CmsErr + Tenant =
        find(id) |> CmsErr.orNotFound(Entity.Asset, AssetId.text(id))

    /// ストレージの失敗は業務エラーとして返す（DB の失敗ではないので DbErr にしない）。
    def orStorageErr(result: Result[String, a]): a \ CmsErr = match result {
        case Ok(value)     => value
        case Err(message)  => CmsErr.invalid(Violation.Violation("storage", message) :: Nil)
    }

}
