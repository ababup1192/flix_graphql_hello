///
/// 公開の検査結果。書き込まずに「公開できるか」を全部一度に答える（dry-run）。
///
/// - violations: required / unique / 参照の消失 / asset の pending。空なら publish は通る（unique は押した瞬間の競合を除く）
/// - unpublishedDependencies: 未公開の参照先。withDependencies: true で一緒に公開できる
///
pub type alias PublishReport = { violations = List[Violation], unpublishedDependencies = List[Entry] }

///
/// 影響を見たい操作。
///
pub enum ImpactAction with Eq, Order, ToString {
    /// 公開する。一緒に公開される未公開の参照先が cascades に出る
    case Publish
    /// 取り下げる。公開中の中身がこの entry を参照している物が breaks に出る
    case Unpublish
    /// 消す。公開中に加えて下書きで参照している物も breaks に出る
    case Delete
}

///
/// この entry を参照している 1 つ。
///
/// - entry: 参照している側（下書きの中身）
/// - via: どのフィールドで参照しているか。本文内のリンクなら RICH_TEXT のフィールド
/// - stage: 参照している側のどの中身が参照しているか
///
pub type alias Referrer = { entry = Entry, via = ApiId, stage = Stage }

///
/// 操作の影響。
///
/// - breaks: 壊れる（参照先を失う）entry。取り下げ・削除の前に見せる
/// - cascades: 一緒に動く entry。公開なら先に公開される未公開の参照先（再帰的に集めた物）
///
pub type alias Impact = { breaks = List[Referrer], cascades = List[Entry] }
