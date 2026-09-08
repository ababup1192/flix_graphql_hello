///
/// asset（画像やファイル）の id。entry の id と同じ規則で、IdGen が振る。
///
pub enum AssetId with Eq, Order {
    case AssetId(String)
}

instance ToString[AssetId] {
    pub def toString(id: AssetId): String = AssetId.text(id)
}

mod AssetId {

    ///
    /// 文字列から。規則（EntryId と同じ）に合わなければ None。
    ///
    pub def parse(text: String): Option[AssetId] =
        EntryId.parse(text) |> Option.map(id -> AssetId.AssetId(EntryId.text(id)))

    pub def text(id: AssetId): String =
        let AssetId.AssetId(inner) = id;
        inner

}

///
/// asset の状態。
///
pub enum AssetStatus with Eq, Order, ToString {
    /// 署名付き URL を出したが、まだ置かれた事を確かめていない
    case Pending
    /// ブラウザが置き、confirm がストレージで確かめた
    case Ready
}

///
/// asset。中身はストレージに key で置いてあり、ここは場所と属性だけ。
///
/// - key: ストレージの中の場所。`{projectId}/{assetId}/{fileName}`
/// - fileName: 元のファイル名（パスと制御文字を除いた物）
/// - mime / size: 宣言された種類と大きさ。size は confirm でストレージの値に置き換わる
/// - width / height: 画像の寸法。confirm でブラウザが渡す。画像でなければ None
/// - alt: 代替テキスト
///
pub type alias Asset = {
    id = AssetId,
    key = String,
    fileName = String,
    mime = String,
    size = Int64,
    width = Option[Int32],
    height = Option[Int32],
    alt = String,
    status = AssetStatus,
    createdAt = Timestamp.Timestamp
}

///
/// アップロードの申し込み。ブラウザが置く前に宣言する物。
///
pub type alias UploadRequest = { fileName = String, mime = String, size = Int64 }

///
/// 置いた後にブラウザが伝える物。寸法は画像だけ。alt は省ける。
///
pub type alias AssetConfirm = { width = Option[Int32], height = Option[Int32], alt = Option[String] }

///
/// 署名付き URL の発行結果。
///
/// - uploadUrl: ここへ PUT する。Content-Type と Content-Length は申し込みの値と同じにする
/// - expiresInSeconds: URL の有効期限
///
pub type alias Upload = { asset = Asset, uploadUrl = String, expiresInSeconds = Int32 }

///
/// asset の一覧の 1 ページ。cursors は assets と同じ順の各 asset の位置（末尾が endCursor）。
///
pub type alias AssetPage = { assets = List[Asset], cursors = List[String], totalCount = Int64, hasNextPage = Bool }

///
/// 一覧の 1 件と、その位置。
///
pub type alias AssetEdge = { cursor = String, node = Asset }

mod AssetPage {

    pub def endCursor(page: AssetPage): Option[String] = List.last(page#cursors)

    pub def edges(page: AssetPage): List[AssetEdge] = List.zip(page#cursors, page#assets) |> List.map(match (cursor, asset) -> { cursor = cursor, node = asset })

    pub def pageInfo(page: AssetPage): PageInfo = { hasNextPage = page#hasNextPage, endCursor = endCursor(page) }

}
