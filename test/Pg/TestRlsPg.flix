///
/// RLS を実 PostgreSQL で見る。所有者（superuser）で種を置き、アプリ用のロール cms_app で繋ぎ直して、
/// 条件を書かない生 SQL でも他のプロジェクトの行が読めず・書けず・消せず、印の無い Tx は 0 行で、
/// 他のプロジェクトの project_id では INSERT できない事を、中身の 7 表すべてで確かめる。
///
mod TestRlsPg {

    use Util.Json.Json

    /// RLS を掛けた表。
    def guardedTables(): List[String] =
        List#{"content_types", "content_fields", "entries", "entry_versions", "entry_links", "assets", "webhooks"}

    def countRows(table: String): Int64 \ DbRead + RawSql + DbErr =
        Sql.fetchOneAs(Decoder.int64("total"), "SELECT count(*)::bigint AS total FROM ${table}", Nil) |> Option.getWithDefault(-1i64)

    /// 条件無しの UPDATE（何も変えない）と DELETE の影響行数。policy の USING が効けば他のプロジェクトでは 0。
    def touchRows(table: String): (Int32, Int32) \ DbWrite + RawSql =
        (Sql.execute("UPDATE ${table} SET project_id = project_id", Nil), Sql.execute("DELETE FROM ${table}", Nil))

    def stampSession(text: String): Unit \ DbRead + RawSql =
        discard Sql.fetch("SELECT set_config('app.project_id', $1, false)", SqlValue.Str(text) :: Nil)

    ///
    /// default に 7 表とも 1 行以上置く（型・フィールド・entry・版・参照・asset・Webhook）。shop のプロジェクト id を返す。
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
        discard Webhooks.create({ name = "site", url = "https://example.com/hook", events = List#{WebhookEvent.EntryPublished}, active = true });
        shop

    ///
    /// 7 表それぞれで:
    ///   印 = default : count ≥ 1
    ///   印 = shop    : count 0、UPDATE 0 行、DELETE 0 行（条件を書いていないのに）
    ///   印 無し      : count 0
    /// その後 default の印で数え直しても減っていない（shop の印の DELETE が何も消していない）。
    ///
    @Test
    def testPgRlsGuardsEveryTable(): Unit \ {IO, Assert} =
        let shop = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"t1", "e1", "a1", "w1"}, seedAllTables)) |> PgTestSupport.seededOrBug;
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

    def stampUser(userId: String, email: String): Unit \ DbRead + RawSql =
        discard Sql.fetch("SELECT set_config('app.user_id', $1, false), set_config('app.email', $2, false)", SqlValue.Str(userId) :: SqlValue.Str(email) :: Nil)

    /// (memberships, invitations, api_keys, personal_access_tokens) の行数。
    def countAuthRows(): (Int64, Int64, Int64, Int64) \ DbRead + RawSql + DbErr =
        (countRows("memberships"), countRows("invitations"), countRows("api_keys"), countRows("personal_access_tokens"))

    def stampTokenHash(tokenHash: String): Unit \ DbRead + RawSql =
        discard Sql.fetch("SELECT set_config('app.token_hash', $1, false)", SqlValue.Str(tokenHash) :: Nil)

    ///
    /// auth の表。default と shop の両方に招待された a が初回ログインで両方の membership を持ち、b は default に招待だけ、鍵は各 1 つ、
    /// a の PAT が 1 つ。
    ///
    ///   印 = default            : memberships 1（a）、invitations 1（b）、api_keys 1、personal_access_tokens 0
    ///   印 = shop               : 1（a）、0、1、0
    ///   印 無し + user = a      : 2（a の両方）、0（a 宛は受け入れ済み）、0、1（a の PAT）
    ///   印 無し + email = b     : 0、1（b 宛）、0、0
    ///   印 無し                 : 0、0、0、0
    ///   印 無し + token_hash    : 0、0、0、1（その PAT だけ）
    ///
    @Test
    def testPgRlsGuardsAuthTables(): Unit \ {IO, Assert} =
        let pepper = { pepperId = "test", secret = "test-pepper" };
        let (shop, alice, tokenHash) = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"k1", "k2", "p1"}, () -> {
            let bootstrap = { ownerEmail = Some("owner@test") };
            let owner = Accounts.resolveUser(bootstrap, { issuer = "test", subject = "owner", email = "owner@test", name = "owner" });
            let shop = Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店");
            let asOwner = (projectId, thunk) -> PgTestSupport.asProject(projectId, () -> Session.runWith(Accounts.actorFor(owner, projectId, Login.Interactive), thunk));
            asOwner(ProjectId.default(), () -> {
                discard Members.invite("a@test.dev", Role.Editor);
                discard Members.invite("b@test.dev", Role.Viewer);
                discard ApiKeys.create(pepper, { name = "default-key", scope = ApiKeyScope.Read, expiresAt = None }, 0i64)
            });
            asOwner(shop, () -> {
                discard Members.invite("a@test.dev", Role.Writer);
                discard ApiKeys.create(pepper, { name = "shop-key", scope = ApiKeyScope.Read, expiresAt = None }, 0i64)
            });
            let alice = Accounts.resolveUser(bootstrap, { issuer = "test", subject = "a", email = "a@test.dev", name = "a" });
            let pat = Session.runWith(Accounts.actorWithoutProject(alice, Login.Interactive), () -> PersonalTokens.issue(pepper, { name = "cli", scope = PatScope.Read, ttlDays = None }, 0i64));
            (shop, alice, SecretHash.hash(pepper, pat#token))
        })) |> PgTestSupport.seededOrBug;
        let outcome = DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(PgTestSupport.appConfig(), _ -> {
            stampSession("${ProjectId.default()}");
            let byDefault = countAuthRows();
            stampSession("${shop}");
            let byShop = countAuthRows();
            stampSession("");
            stampUser("${alice#id}", alice#email);
            let byAlice = countAuthRows();
            stampUser("", "b@test.dev");
            let byBobEmail = countAuthRows();
            stampUser("", "");
            let unstamped = countAuthRows();
            stampTokenHash(tokenHash);
            let byTokenHash = countAuthRows();
            (byDefault, byShop, byAlice, byBobEmail, unstamped, byTokenHash)
        })));
        Assert.assertEq(
            expected = Ok(((1i64, 1i64, 1i64, 0i64), (1i64, 0i64, 1i64, 0i64), (2i64, 0i64, 0i64, 1i64), (0i64, 1i64, 0i64, 0i64), (0i64, 0i64, 0i64, 0i64), (0i64, 0i64, 0i64, 1i64))),
            outcome)

    ///
    /// 他のプロジェクトの project_id を持つ行は、default の印では入れられない（WITH CHECK）。
    /// 印の無い Tx（Account API と同じ）は、生成された query に project_id を明示しても 0 行。
    ///
    @Test
    def testPgRlsBlocksCrossProjectWrites(): Unit \ {IO, Assert} =
        let shop = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"t1", "e1", "a1", "w1"}, seedAllTables)) |> PgTestSupport.seededOrBug;
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
