///
/// 取り込む API の apiId から、管理画面のサイドバーに出すアイコンの名前を決める。純粋。
/// 名前は admin-ui の `Ui/Icon.elm` の `byName` が絵を持つ物に限る（無い名前は既定の一覧のアイコンに落ちる）。
///
/// WhyNot: `src/cms/rules/` に置かない。これは microCMS の見本と作例ブログのエンドポイント名を覚えた表で、
/// CMS のドメインの規則ではない。ドメインに置くと、取り込み以外の型にもこの表が当たるように読める。
///
mod MicrocmsIcons {

    ///
    /// apiId → アイコンの名前。表に無い apiId は None で、型の kind の既定（Naming.deriveIcon）に落ちる。
    ///
    pub def iconOf(apiId: ApiId): Option[String] =
        icons() |> List.findMap(match (name, icon) -> if (name == ApiId.text(apiId)) Some(icon) else None)

    ///
    /// 振り分けの表。左が apiId、右がアイコンの名前。
    ///
    pub def icons(): List[(String, String)] =
        List#{
            ("blogs", "news"),
            ("authors", "user"),
            ("profiles", "user"),
            ("tags", "tag"),
            ("insidesalesCategoryKeywords", "tag"),
            ("categories", "box"),
            ("insidesalesCategory", "box"),
            ("insidesaleServices", "cart"),
            ("insidesalesFeature", "star"),
            ("insidesalesIssue", "question")
        }

}
