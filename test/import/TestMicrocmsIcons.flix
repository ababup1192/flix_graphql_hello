///
/// MicrocmsIcons: 取り込む API の apiId から管理画面のアイコンの名前を決める。全部純粋。
///
mod TestMicrocmsIcons {

    /// 管理画面（admin-ui/src/Ui/Icon.elm の byName）が絵を持つ名前。ここに無い名前は既定の一覧のアイコンに落ちる。
    def drawable(): List[String] =
        List#{ "file", "book", "news", "tag", "user", "image", "video", "cart", "star", "pin",
               "calendar", "message", "question", "box", "code", "chart", "flag" }

    def iconOf(apiId: String): Option[String] =
        MicrocmsIcons.iconOf(CmsTestKit.apiId(apiId))

    // ---- 作例ブログ（import/blog-example/schema） ----

    /// blogs は記事、authors は書き手、tags はラベル。
    @Test
    def testMicrocmsIconsBlogExample(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ Some("news"), Some("user"), Some("tag") },
            List#{ iconOf("blogs"), iconOf("authors"), iconOf("tags") })

    // ---- microCMS の見本（import/microcms/schema） ----

    /// 9 つの API それぞれのアイコン。分類の 2 つ（categories / insidesalesCategory）と
    /// ラベルの 2 つ（tags / insidesalesCategoryKeywords）は中身が同じ役割なので同じ名前。
    @Test
    def testMicrocmsIconsMicrocmsSample(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
                ("blogs", Some("news")),
                ("categories", Some("box")),
                ("profiles", Some("user")),
                ("tags", Some("tag")),
                ("insidesaleServices", Some("cart")),
                ("insidesalesCategory", Some("box")),
                ("insidesalesCategoryKeywords", Some("tag")),
                ("insidesalesFeature", Some("star")),
                ("insidesalesIssue", Some("question"))
            },
            List#{ "blogs", "categories", "profiles", "tags", "insidesaleServices",
                   "insidesalesCategory", "insidesalesCategoryKeywords", "insidesalesFeature", "insidesalesIssue" }
                |> List.map(apiId -> (apiId, iconOf(apiId))))

    // ---- 知らない API ----

    /// 表に無い apiId は None（型の kind の既定に落ちる）。
    @Test
    def testMicrocmsIconsUnknown(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ None, None, None },
            List#{ iconOf("products"), iconOf("blog"), iconOf("insidesales") })

    // ---- 返す名前の検査 ----

    /// 表が返す名前は全部、管理画面が絵を持つ名前（byName）の中にある。
    @Test
    def testMicrocmsIconsAreDrawable(): Unit \ Assert =
        Assert.assertEq(
            expected = Nil,
            MicrocmsIcons.icons() |> List.map(match (_, icon) -> icon) |> List.filter(icon -> not List.memberOf(icon, drawable())))

    /// 表が返す名前は全部、アイコンの識別子の規則（英小文字・数字・-、32 文字まで）を満たす。
    @Test
    def testMicrocmsIconsFollowNamingRule(): Unit \ Assert =
        Assert.assertEq(
            expected = Nil,
            MicrocmsIcons.icons() |> List.flatMap(match (_, icon) -> Naming.validateIcon("icon", icon)))

}
