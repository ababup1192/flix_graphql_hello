///
/// entry の id。microCMS の id をそのまま入れられるように文字列。`parse` を通した物だけを作る。
///
pub enum EntryId with Eq, Order {
    case EntryId(String)
}

instance ToString[EntryId] {
    pub def toString(id: EntryId): String = EntryId.text(id)
}

mod EntryId {

    ///
    /// 規則（[A-Za-z0-9_-] を 1 〜 64 文字）に合えば Some。URL とパスにそのまま使える文字だけ。
    ///
    pub def parse(text: String): Option[EntryId] =
        if (String.isMatch(regex = "^[A-Za-z0-9_-]{1,64}$", text)) Some(EntryId.EntryId(text)) else None

    ///
    /// 中の文字列。
    ///
    pub def text(id: EntryId): String =
        let EntryId.EntryId(raw) = id;
        raw

    ///
    /// 規則の説明。エラーメッセージ用。
    ///
    pub def rule(): String = "英数字と _ - を 1 〜 64 文字"

}

///
/// entry の状態。
///
pub enum Stage with Eq, Order, ToString {
    /// まだ公開していない
    case Draft
    /// 公開中
    case Published
}

///
/// entry の中身。フィールドの apiId → 値。値の形は kind ごとに EntryValidation が守る。
///
pub type alias EntryData = Map[ApiId, Util.Json.Json]

///
/// entry。中身は下書きの物。
///
/// - id: entries.id
/// - typeId: 属する content type
/// - version: 楽観ロックの版。保存のたびに 1 増える
/// - stage: 状態
/// - data: 下書きの中身
/// - publishedAt: 公開した時刻。未公開なら None
/// - changedSincePublish: 公開中で、公開後に下書きが進んでいるか（管理画面の CHANGED バッジ）
/// - contentStage: data がどの stage の行か（コンテンツ API が参照先を同じ stage で引くため）
/// - linked: 参照先の entry を先読みした物。無ければ参照のたびに引く
/// - createdAt / updatedAt: 作成と更新の時刻
///
pub type alias Entry = {
    id = EntryId,
    typeId = TypeId,
    version = Int32,
    stage = Stage,
    data = EntryData,
    publishedAt = Option[Timestamp.Timestamp],
    changedSincePublish = Bool,
    contentStage = Stage,
    linked = Linked,
    createdAt = Timestamp.Timestamp,
    updatedAt = Timestamp.Timestamp
}

///
/// 先読みした参照先。id → entry。
///
/// WhyNot: Entry のレコードに Map[EntryId, Entry] を直に置かないのは、型の別名が自分を参照できないため。enum で切る。
///
pub enum Linked {
    case Linked(Map[EntryId, Entry])
}

mod Linked {
    pub def empty(): Linked = Linked.Linked(Map.empty())

    ///
    /// 先読みした entry から。id で引けるようにする。
    ///
    pub def of(entries: List[Entry]): Linked =
        Linked.Linked(entries |> List.map(entry -> (entry#id, entry)) |> List.toMap)

    pub def get(id: EntryId, linked: Linked): Option[Entry] =
        let Linked.Linked(map) = linked;
        Map.get(id, map)
}

///
/// 版の id。entry_versions.id を包む。
///
pub enum VersionId with Eq, Order {
    case VersionId(Int64)
}

instance ToString[VersionId] {
    pub def toString(id: VersionId): String = Int64.toString(VersionId.toInt64(id))
}

mod VersionId {
    pub def toInt64(id: VersionId): Int64 =
        let VersionId.VersionId(number) = id;
        number
}

///
/// どのバージョンの中身か。差分（ContentEntries.diff）の両端に使う。
///
pub enum VersionRef with Eq, ToString {
    /// 今の下書き
    case Draft
    /// 公開中の中身（未公開なら無い）
    case Published
    /// 積んだバージョン
    case Version(VersionId)
}

///
/// 版を積んだ理由。
///
pub enum VersionReason with Eq, Order, ToString {
    /// 公開した時の中身
    case Publish
    /// 明示的に保存した中身
    case Save
}

///
/// entry の版。公開時と明示的な保存だけ積む。
///
/// - id: entry_versions.id
/// - entryId: どの entry か
/// - version: 積んだ時点の entries.version
/// - data: その時の中身
/// - author: 誰が
/// - reason: 理由
/// - createdAt: 積んだ時刻
///
pub type alias EntryVersion = {
    id = VersionId,
    entryId = EntryId,
    version = Int32,
    data = EntryData,
    author = String,
    reason = VersionReason,
    createdAt = Timestamp.Timestamp
}

///
/// 一覧の 1 ページ。
///
/// - entries: 指定した並び順（既定は更新が新しい順）
/// - cursors: entries と同じ順の、各 entry の位置（不透明な文字列）。末尾が endCursor
/// - totalCount: 条件に合う全件数
/// - hasNextPage: この後にまだ entry があるか
///
pub type alias EntryPage = { entries = List[Entry], cursors = List[String], totalCount = Int64, hasNextPage = Bool }

///
/// ページの続き。hasNextPage なら endCursor を after に渡して次を読む。
///
pub type alias PageInfo = { hasNextPage = Bool, endCursor = Option[String] }

///
/// 一覧の 1 件と、その位置。
///
pub type alias EntryEdge = { cursor = String, node = Entry }

mod EntryPage {

    ///
    /// 1 ページの上限。どちらの API も同じ。
    ///
    def maxFirst(): Int32 = 200

    ///
    /// first + 1 件引いた行から、ページの中身と「次があるか」を決める。first 件を超えた分（末尾）は落とす。
    ///
    pub def trimPage(first: Int32, rows: List[a]): (List[a], Bool) =
        (List.take(first, rows), List.length(rows) > first)

    ///
    /// 最後の entry の位置。空のページなら None。
    ///
    pub def endCursor(page: EntryPage): Option[String] = List.last(page#cursors)

    ///
    /// GraphQL の edges。
    ///
    pub def edges(page: EntryPage): List[EntryEdge] = List.zip(page#cursors, page#entries) |> List.map(match (cursor, entry) -> { cursor = cursor, node = entry })

    ///
    /// GraphQL の pageInfo。
    ///
    pub def pageInfo(page: EntryPage): PageInfo = { hasNextPage = page#hasNextPage, endCursor = endCursor(page) }

    ///
    /// first（省けば default）を 0 〜 maxFirst に、skip（省けば 0）を 0 以上に丸める。0 は「件数だけ欲しい」用。
    ///
    pub def clamp(default: Int32, first: Option[Int32], skip: Option[Int32]): (Int32, Int32) =
        (first |> Option.getWithDefault(default) |> Int32.max(0) |> Int32.min(maxFirst()),
         skip |> Option.getWithDefault(0) |> Int32.max(0))

    ///
    /// Int32 に載る件数（32 bit の Int しか持てない API へ渡す用）。超える分は上限に丸める。
    ///
    pub def totalCountInt32(page: EntryPage): Int32 = countToInt32(page#totalCount)

    ///
    /// 件数や大きさ（Int64）を GraphQL の Int に。負は 0、超えれば上限。
    ///
    pub def countToInt32(value: Int64): Int32 = Int64.clampToInt32(min = 0, max = Int32.maxValue(), value)

}

///
/// 管理 API の一覧の条件。
///
/// - search: 下書きの中身に含む文字列。空なら全件
/// - filter: 絞り込み（コンテンツ API と同じ Condition）
/// - orderBy: 並び順。空なら更新が新しい順
/// - first: 最大件数
/// - start: ページの始まり（skip か after）
///
pub type alias EntryQuery = { search = String, filter = Where, orderBy = OrderBy, first = Int32, start = PageStart }

mod EntryQuery {

    ///
    /// 検索と offset だけの条件（絞り込み無し、更新が新しい順）。
    ///
    pub def of(search: String, first: Int32, skip: Int32): EntryQuery =
        { search = search, filter = Nil, orderBy = Nil, first = first, start = PageStart.Offset(skip) }

}

///
/// entry の id を振る。本番はランダム、テストは決めた値。
///
pub eff IdGen {
    ///
    /// 新しい entry の id。
    ///
    def freshEntryId(): EntryId
    ///
    /// 新しい asset の id。entry と同じ形。
    ///
    def freshAssetId(): AssetId
    ///
    /// 新しい秘密（API キーの本体）。base64url の 43 文字（256 bit）。
    ///
    def freshSecret(): String
    ///
    /// 新しい外向きの id（users / organizations / projects / invitations / api_keys の public_id）。entry と同じ 12 文字。
    ///
    def freshPublicId(): String
    ///
    /// 新しい ULID（配信記録のように時刻順に読む物の id）。
    ///
    def freshUlid(): String
}

mod IdGen {

    import java.util.UUID
    import java.security.SecureRandom
    import java.lang.System

    ///
    /// UUID から作った 12 文字の id を振るハンドラ。
    ///
    /// WhyNot: UUID をそのまま使わないのは、URL に出る id なので短い方がよく、16^12 通りあれば衝突を心配する規模ではないため。
    /// WhyNot: sqlfx の Uuid.random を使わないのは、それが NonDet で、Runner の IO の中では扱えないため。
    ///
    pub def runWithRandom(f: Unit -> a \ ef): a \ (ef - IdGen) + IO =
        run f() with handler IdGen {
            def freshEntryId(resume) = resume(EntryId.EntryId(randomText()))
            def freshAssetId(resume) = resume(AssetId.AssetId(randomText()))
            def freshSecret(resume) = resume(randomSecret())
            def freshPublicId(resume) = resume(randomText())
            def freshUlid(resume) = resume(randomUlid())
        }

    /// 今の時刻と SecureRandom の 10 バイトから ULID。
    def randomUlid(): String \ IO =
        let bytes = Array.empty(Static, 10);
        new SecureRandom().nextBytes(bytes);
        Ulid.encode(System.currentTimeMillis(), Array.toVector(bytes))

    /// SecureRandom の 32 バイトを base64url に。
    def randomSecret(): String \ IO =
        let bytes = Array.empty(Static, 32);
        new SecureRandom().nextBytes(bytes);
        Base64Url.encode(Array.toVector(bytes))

    /// UUID から作った 12 文字。
    def randomText(): String \ IO =
        UUID.randomUUID().toString() |> String.replace(src = "-", dst = "") |> String.takeLeft(12)

    ///
    /// 決めた id を順に返すハンドラ。尽きたら止まる（渡した並びより多く作るのはテストの誤り）。
    ///
    pub def runWithFixed(ids: List[EntryId], f: Unit -> a \ ef): a \ ef - IdGen = region rc {
        let remaining = Ref.fresh(rc, ids);
        let issued = Ref.fresh(rc, unsafe IO { Int64.clampToInt32(min = 0, max = 2147483647, Int64.remainder(System.nanoTime() / 1000i64, 1000000000i64)) });
        run f() with handler IdGen {
            def freshEntryId(resume) = resume(nextFixed(remaining))
            def freshAssetId(resume) = resume(AssetId.AssetId(EntryId.text(nextFixed(remaining))))
            def freshSecret(resume) = resume("secret-${EntryId.text(nextFixed(remaining))}")
            // 外向きの id は決めた列を使わず連番にする。UNIQUE なので「尽きたら最後を繰り返す」では衝突する
            def freshPublicId(resume) = { Ref.put(Ref.get(issued) + 1, issued); resume("pub-${Ref.get(issued)}") }
            // WhyNot: 連番の起点をプロセス内で毎回 0 にしないのは、同じテストの中で runWithFixed を 2 度使うと public_id / ULID が
            // 重なり UNIQUE で落ちるため。起点は時刻から取り、handler の中では発行順に増える（並びは変わらない）
            // ULID も連番。26 文字に揃えて、文字列の並びが時刻順（発行順）になるようにする
            def freshUlid(resume) = { Ref.put(Ref.get(issued) + 1, issued); resume(String.padLeft(26, '0', "${Ref.get(issued)}")) }
        }
    }

    /// 決めた id の次。
    ///
    /// WhyNot: 尽きた時に最後の物を繰り返したり固定の id を返したりしないのは、黙って同じ id が入ると UNIQUE で落ちるか
    /// 別の entry を指してしまい、原因の分からない失敗になるため。足りないのはテストの誤りなので止める
    def nextFixed(remaining: Ref[List[EntryId], r]): EntryId \ r = match Ref.get(remaining) {
        case head :: tail => { Ref.put(tail, remaining); head }
        case Nil          => bug!("決めた id が足りない（withIds に渡した並びより多く id を作っている。テストの誤り）")
    }

}
