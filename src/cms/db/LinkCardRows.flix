///
/// link_cards の行とドメインの値の変換。列名を知るのはここだけ。
///
mod LinkCardRows {

    pub def toLinkCard(row: { url = String, title = Option[String], description = Option[String], imageUrl = Option[String], siteName = Option[String], error = Option[String], fetchedAt = Timestamp.Timestamp | r }): LinkCard =
        { url = row#url, title = row#title, description = row#description, imageUrl = row#imageUrl, siteName = row#siteName, fetchedAt = row#fetchedAt, error = row#error }

}
