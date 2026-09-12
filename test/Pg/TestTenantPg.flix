///
/// プロジェクトの分離を実 PostgreSQL で見る。別のプロジェクトの型と entry は、id を知っていても見えない・触れない。
///
mod TestTenantPg {

    use Util.Json.Json

    /// 既定のプロジェクトで作った blogs は、別のプロジェクト（shop）からは一覧にも apiId でも id でも見えず、同じ apiId の型を別に作れる。
    /// entry も同じで、id で引けず、他方の型に作ろうとすると notFound。
    ///
    ///   default: blogs(b1)      shop: blogs（別物）
    @Test
    def testPgTenantIsolation(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1"}, () -> {
            let shop = Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店");
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            let entry = ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("hello"))}));
            PgTestSupport.asProject(shop, () -> {
                let own = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "商品記事"));
                (List.length(ContentTypes.list(Session.grant())),
                 ContentTypes.findByApiId(Session.grant(), CmsTestKit.apiId("blogs")) |> Option.map(found -> found#id == own#id),
                 ContentTypes.find(Session.grant(), blogs#id) |> Option.isEmpty,
                 ContentEntries.find(Session.grant(), entry#id) |> Option.isEmpty,
                 CmsTestKit.failureMessage(() -> ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("body", FieldKind.Text, FieldConfig.empty()))),
                 CmsTestKit.failureMessage(() -> ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(Nil))))
            })
        }));
        Assert.assertEq(expected = (1, Some(true), true, true, Err("content type '1' が見つかりません"), Err("content type '1' が見つかりません")), result)

    /// プロジェクト slug の形（境界の parse）・予約・重複。既定プロジェクトは default。
    @Test
    def testPgProjectSlug(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() ->
            (CmsTestKit.failureMessage(() -> Projects.parseSlug("Shop")),
             CmsTestKit.failureMessage(() -> Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("account"), "x")),
             CmsTestKit.failureMessage(() -> Projects.create(OrgId.default(), ProjectSlug.default(), "x")),
             Projects.findBySlug(ProjectSlug.default())));
        Assert.assertEq(expected = (
            Err("slug: 'Shop' は 英小文字・数字・- を 1 〜 64 文字（先頭は英数字） にしてください"),
            Err("slug: 'account' は予約されています"),
            Err("slug: 'default' は既にあります"),
            Some(ProjectId.default())), result)

}
