///
/// richText の linkCard の OGP 1 つ（`link_cards` の行）。url はプロジェクトの中で 1 つ。
///
/// - title / description / imageUrl / siteName: 取れた物。無ければ None（error の行は全部 None）
/// - fetchedAt: 取りに行った時刻。成功も失敗も更新する
/// - error: 取れなかった理由（人が読む文。bot 拒否 / 404 / OGP なし / タイムアウト）。取れていれば None
///
/// WhyNot: 画像を自前の置き先に写した URL を持たないのは、第 1 段では相手の URL をそのまま出すため
/// （docs/design/richtext-note-linkcard-ui.md §6。写す時はこの record に列を足す）。
///
pub type alias LinkCard = { url = String, title = Option[String], description = Option[String], imageUrl = Option[String], siteName = Option[String], fetchedAt = Timestamp.Timestamp, error = Option[String] }
