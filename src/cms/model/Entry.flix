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
    createdAt = Timestamp.Timestamp,
    updatedAt = Timestamp.Timestamp
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
/// - entries: 更新が新しい順
/// - totalCount: 条件に合う全件数
///
pub type alias EntryPage = { entries = List[Entry], totalCount = Int64 }

///
/// 一覧の条件。
///
/// - search: 下書きの中身に含む文字列。空なら全件
/// - first: 最大件数
/// - skip: 読み飛ばす件数
///
pub type alias EntryQuery = { search = String, first = Int32, skip = Int32 }

///
/// entry の id を振る。本番はランダム、テストは決めた値。
///
pub eff IdGen {
    ///
    /// 新しい entry の id。
    ///
    def freshEntryId(): EntryId
}

mod IdGen {

    import java.util.UUID

    ///
    /// UUID から作った 12 文字の id を振るハンドラ。
    ///
    /// WhyNot: UUID をそのまま使わないのは、URL に出る id なので短い方がよく、16^12 通りあれば衝突を心配する規模ではないため。
    /// WhyNot: sqlfx の Uuid.random を使わないのは、それが NonDet で、Runner の IO の中では扱えないため。
    ///
    pub def runWithRandom(f: Unit -> a \ ef): a \ (ef - IdGen) + IO =
        run f() with handler IdGen {
            def freshEntryId(resume) = resume(EntryId.EntryId(UUID.randomUUID().toString() |> String.replace(src = "-", dst = "") |> String.takeLeft(12)))
        }

    ///
    /// 決めた id を順に返すハンドラ。尽きたら最後の物を繰り返す。
    ///
    pub def runWithFixed(ids: List[EntryId], f: Unit -> a \ ef): a \ ef - IdGen = region rc {
        let remaining = Ref.fresh(rc, ids);
        run f() with handler IdGen {
            def freshEntryId(resume) = {
                let next = match Ref.get(remaining) {
                    case head :: tail => { Ref.put(if (List.isEmpty(tail)) head :: Nil else tail, remaining); head }
                    case Nil          => EntryId.EntryId("fixed")
                };
                resume(next)
            }
        }
    }

}
