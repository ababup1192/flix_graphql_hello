///
/// RLS を実 PostgreSQL で見る。所有者（superuser）で種を置き、アプリ用のロール cms_app で繋ぎ直して、
/// 条件を書かない生 SQL でも他のプロジェクトの行が読めず・書けず・消せず、印の無い Tx は 0 行で、
/// 他のプロジェクトの project_id では INSERT できない事を、中身の 6 表すべてで確かめる。
///
mod TestRlsPg {

    use Util.Json.Json

    /// RLS を掛けた表。
    def guardedTables(): List[String] =
        List#{"content_types", "content_fields", "entries", "entry_versions", "entry_links", "assets"}

    def countRows(table: String): Int64 \ DbRead + RawSql + DbErr =
        Sql.fetchOneAs(Decoder.int64("total"), "SELECT count(*)::bigint AS total FROM ${table}", Nil) |> Option.getWithDefault(-1i64)

    /// 条件無しの UPDATE（何も変えない）と DELETE の影響行数。policy の USING が効けば他のプロジェクトでは 0。
    def touchRows(table: String): (Int32, Int32) \ DbWrite + RawSql =
        (Sql.execute("UPDATE ${table} SET project_id = project_id", Nil), Sql.execute("DELETE FROM ${table}", Nil))

    def stampSession(text: String): Unit \ DbRead + RawSql =
        discard Sql.fetch("SELECT set_config('app.project_id', $1, false)", SqlValue.Str(text) :: Nil)

    ///
    /// default に 6 表とも 1 行以上置く（型・フィールド・entry・版・参照・asset）。shop のプロジェクト id を返す。
    ///
    def seedAllTables(): ProjectId \ Db + CmsErr + IdGen + Tenant + Session + ObjectStore =
        let shop = Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店");
        let tags = ContentTypes.create(CmsTestKit.typeDraft("tags", "タグ"));
        discard ContentTypes.addField(tags#id, CmsTestKit.fieldDraft("label", FieldKind.Text, FieldConfig.empty()));
        let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        discard ContentTypes.addField(blogs#id, { target = Some(tags#id) | CmsTestKit.fieldDraft("tag", FieldKind.Reference, FieldConfig.empty()) });
        let tag = ContentEntries.create(tags#id, None, CmsTestKit.entryData(List#{("label", Json.JString("news"))}));
        let entry = ContentEntries.create(blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("hello")), ("tag", Json.JString(EntryId.text(tag#id)))}));
        discard ContentEntries.saveVersion(entry#id, "tester");
        discard Assets.createUpload({ fileName = "photo.png", mime = "image/png", size = 5i64 });
        shop

    ///
    /// 6 表それぞれで:
    ///   印 = default : count ≥ 1
    ///   印 = shop    : count 0、UPDATE 0 行、DELETE 0 行（条件を書いていないのに）
    ///   印 無し      : count 0
    /// その後 default の印で数え直しても減っていない（shop の印の DELETE が何も消していない）。
    ///
    @Test
    def testPgRlsGuardsEveryTable(): Unit \ {IO, Assert} =
        let shop = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"t1", "e1", "a1"}, seedAllTables)) |> PgTestSupport.seededOrBug;
        let outcome = DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(PgTestSupport.appConfig(), _ ->
            guardedTables() |> List.map(table -> {
                stampSession("${ProjectId.default()}");
                let before = countRows(table);
                stampSession("${shop}");
                let theirs = countRows(table);
                let (updated, deleted) = touchRows(table);
                stampSession("");
                let unstamped = countRows(table);
                stampSession("${ProjectId.default()}");
                let after = countRows(table);
                (table, before >= 1i64 and after == before, theirs, updated, deleted, unstamped)
            }))));
        Assert.assertEq(
            expected = Ok(guardedTables() |> List.map(table -> (table, true, 0i64, 0, 0, 0i64))),
            outcome)

    ///
    /// 他のプロジェクトの project_id を持つ行は、default の印では入れられない（WITH CHECK）。
    /// 印の無い Tx（Account API と同じ）は、生成された query に project_id を明示しても 0 行。
    ///
    @Test
    def testPgRlsBlocksCrossProjectWrites(): Unit \ {IO, Assert} =
        let shop = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"t1", "e1", "a1"}, seedAllTables)) |> PgTestSupport.seededOrBug;
        let crossInsert = DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(PgTestSupport.appConfig(), _ -> {
            stampSession("${ProjectId.default()}");
            Sql.execute("INSERT INTO content_types (project_id, api_id, kind, name, singular, plural) VALUES ($1, 'x', 'collection', 'x', 'X', 'Xs')", SqlValue.Int64(ProjectId.toInt64(shop)) :: Nil)
        }))) |> Result.mapErr(failure -> String.contains(substr = "row-level security", "${failure}"));
        let unstampedTx = PgTestSupport.withPool(pool ->
            DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> List.length(ContentTypesQueries.listContentTypes(ProjectId.toInt64(ProjectId.default()))))));
        let stampedTx = PgTestSupport.withPool(pool ->
            DbError.runWithFailure(() -> TenantTx.withLazyTx(pool, ProjectId.default(), () -> List.length(ContentTypesQueries.listContentTypes(ProjectId.toInt64(ProjectId.default()))))));
        Assert.assertEq(expected = (Err(true), Ok(0), Ok(2)), (crossInsert, unstampedTx, stampedTx))

}
