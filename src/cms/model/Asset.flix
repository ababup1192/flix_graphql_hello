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
/// - presentation: 見せ方（注目点と切り抜き枠）。画像は触らず割合だけ
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
    createdAt = Timestamp.Timestamp,
    presentation = AssetPresentation
}

///
/// 注目点（focal point）。画像の中で主役になる位置。0〜1 の割合で、左上が (0, 0)。
///
pub type alias FocalPoint = { x = Float64, y = Float64 }

///
/// 切り抜き枠（crop）。画像の中で見せる矩形。0〜1 の割合で、左上が (0, 0)。
///
/// - left / top: 枠の左上
/// - width / height: 枠の大きさ。left + width と top + height は 1 以下
///
pub type alias CropRect = { left = Float64, top = Float64, width = Float64, height = Float64 }

///
/// asset の見せ方。どちらも無ければ「そのまま」（注目点は中央、枠は全体として扱う）。
///
pub type alias AssetPresentation = { focalPoint = Option[FocalPoint], crop = Option[CropRect] }

///
/// 直す時の 1 項目の指示。省いた項目は Keep、消す指示は Clear、新しい値は Set。
///
pub enum Patch[a] {
    case Keep
    case Clear
    case Set(a)
}

///
/// 見せ方の直し方。注目点と切り抜き枠を別々に指示する。
///
pub type alias AssetPresentationPatch = { focalPoint = Patch[FocalPoint], crop = Patch[CropRect] }

///
/// asset の属性の直し方。alt は None なら変えない。ファイルの差し替えは新しい asset を作る。
///
pub type alias AssetChanges = { alt = Option[String], presentation = AssetPresentationPatch }

mod AssetPresentation {

    use Util.Json.Json

    /// 何も指定していない見せ方。
    pub def empty(): AssetPresentation = { focalPoint = None, crop = None }

    /// 注目点も枠も無いか。
    pub def isEmpty(presentation: AssetPresentation): Bool =
        Option.isEmpty(presentation#focalPoint) and Option.isEmpty(presentation#crop)

    ///
    /// Json にする。`{ "focalPoint": { "x", "y" }, "crop": { "left", "top", "width", "height" } }`。無い項目はキーごと出ない。
    /// 列（assets.presentation）と監査の detail が同じ形で持つ。
    ///
    pub def toJson(presentation: AssetPresentation): Json =
        Json.JObject(List.toMap(
            (presentation#focalPoint |> Option.map(point -> ("focalPoint", Json.JObject(Map#{ "x" => number(point#x), "y" => number(point#y) }))) |> Option.toList) :::
            (presentation#crop |> Option.map(crop -> ("crop", Json.JObject(Map#{ "left" => number(crop#left), "top" => number(crop#top), "width" => number(crop#width), "height" => number(crop#height) }))) |> Option.toList)))

    ///
    /// Json から。オブジェクトでない・数でない・キーが欠けている物は None。無いキーは「指定なし」。
    ///
    pub def fromJson(json: Json): Option[AssetPresentation] = match json {
        case Json.JObject(fields) =>
            forM (
                focalPoint <- Map.get("focalPoint", fields) |> Option.map(pointFromJson) |> flip;
                crop       <- Map.get("crop", fields) |> Option.map(cropFromJson) |> flip
            ) yield { focalPoint = focalPoint, crop = crop }
        case _ => None
    }

    /// 「キーが無い」は Some(None)、「キーはあるが読めない」は None にする。
    def flip(parsed: Option[Option[a]]): Option[Option[a]] = match parsed {
        case None            => Some(None)
        case Some(None)      => None
        case Some(Some(found)) => Some(Some(found))
    }

    def pointFromJson(json: Json): Option[FocalPoint] = match json {
        case Json.JObject(fields) => forM (x <- coordinate("x", fields); y <- coordinate("y", fields)) yield { x = x, y = y }
        case _                    => None
    }

    def cropFromJson(json: Json): Option[CropRect] = match json {
        case Json.JObject(fields) =>
            forM (left <- coordinate("left", fields); top <- coordinate("top", fields); width <- coordinate("width", fields); height <- coordinate("height", fields))
                yield { left = left, top = top, width = width, height = height }
        case _ => None
    }

    def coordinate(key: String, fields: Map[String, Json]): Option[Float64] =
        Map.get(key, fields) |> Option.flatMap(EntryValue.asFloat64)

    /// 割合を Json の数に。表せない値（NaN / 無限）は入口の検査で落ちているので null にはならない。
    ///
    /// WhyNot: `Float64.tryToBigDecimal` を使わない。0.3 が 2 進の展開そのまま（0.29999…）の 50 桁になり、列と監査に読めない数が残る。
    /// 10 進の文字列を経由すれば書いた桁で収まる。
    def number(value: Float64): Json =
        BigDecimal.fromString(ToString.toString(value)) |> Option.map(Json.JNumber) |> Option.getWithDefault(Json.JNull)

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
