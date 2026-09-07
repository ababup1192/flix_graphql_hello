///
/// RLS を実 PostgreSQL で見る。条件を書かない生 SQL でも他のプロジェクトの行は出ず、印の無い接続は 0 行で、
/// 他のプロジェクトの project_id では INSERT できない。
///
mod TestRlsPg {

    use Util.Json.Json

    def countEntries(): Int64 \ DbRead + RawSql + DbErr =
        Sql.fetchOneAs(Decoder.int64("total"), "SELECT count(*)::bigint AS total FROM entries", Nil) |> Option.getWithDefault(-1i64)

    def stampSession(text: String): Unit \ DbRead + RawSql =
        discard Sql.fetch("SELECT set_config('app.project_id', $1, false)", SqlValue.Str(text) :: Nil)

    ///
    /// default に entry を 1 つ置き（所有者 = superuser なので RLS は素通り）、アプリ用のロール cms_app で繋ぎ直して見る。
    ///
    ///   印 = default : count(*) FROM entries → 1
    ///   印 = shop    : → 0（条件を書いていないのに）
    ///   印 無し      : → 0
    ///   印 = default のまま project_id = shop で INSERT → policy（WITH CHECK）で落ちる
    ///
    @Test
    def testPgRlsHidesOtherProjects(): Unit \ {IO, Assert} =
        let shop = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"e1"}, () -> {
            let shop = Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店");
            let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            discard ContentEntries.create(blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("hello"))}));
            shop
        })) |> PgTestSupport.seededOrBug;
        let owner = PgTestSupport.config();
        let app = { url = owner#url, user = "cms_app", password = "cms_app" };
        let prepared = AppRole.ensure(owner, app#user, app#password);
        let seen = DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(app, _ -> {
            stampSession("${ProjectId.default()}");
            let mine = countEntries();
            stampSession("${shop}");
            let theirs = countEntries();
            stampSession("");
            let unstamped = countEntries();
            stampSession("${ProjectId.default()}");
            let crossInsert = DbError.runWithFailure(() ->
                Sql.execute("INSERT INTO content_types (project_id, api_id, kind, name, singular, plural) VALUES ($1, 'x', 'collection', 'x', 'X', 'Xs')", SqlValue.Int64(ProjectId.toInt64(shop)) :: Nil))
                |> Result.mapErr(failure -> String.contains(substr = "row-level security", "${failure}"));
            (mine, theirs, unstamped, crossInsert)
        })));
        Assert.assertEq(expected = (Ok(()), Ok((1i64, 0i64, 0i64, Err(true)))), (prepared, seen))

}
