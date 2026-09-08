///
/// 1 リクエストで出る SQL の数（db.statements）と張った Tx の数（db.transactions）を、代表的な query で数えて上限と比べる。
/// 認証の Tx と Runner が observe に戻す値を LogFields.mergeCounts で足し合わせる（Main の runRoute / runObserved と同じ受け方）。
/// 数は標準出力にも出す（実測値をコミットログに残すため）。
///
/// 上限は実測（2026-09-08）+ 少しの余裕。一覧の行ごとに版・型・参照先を引く形（N+1）に戻れば (a) (c) (d) が落ち、
/// 認証の SQL（JWT で 7 本）がフィールドごとに繰り返されると (b) が 2 倍を超えて落ちる。
///
mod TestQueryBudgetPg {

    use Util.Json.Json

    /// 一覧の件数と、1 件で選ぶフィールドの数（id typeId version stage fields publishedAt createdAt updatedAt versions diff）。
    def entryCount(): Int32 = 50

    /// 書き手の数。blogs は書き手ごとに entryCount / 5 件で、全部が profile を参照する。
    def authorCount(): Int32 = 5

    /// profiles 型（name）に書き手 5 人、blogs 型（title / profile: profiles への参照）に entry 50 件。
    def seed(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let profiles = ContentTypes.create(CmsTestKit.typeDraft("profiles", "書き手"));
        discard ContentTypes.addField(profiles#id, CmsTestKit.fieldDraft("name", FieldKind.Text, FieldConfig.empty()));
        let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        discard ContentTypes.addField(blogs#id, { target = Some(profiles#id) | CmsTestKit.fieldDraft("profile", FieldKind.Reference, FieldConfig.empty()) });
        List.range(0, authorCount()) |> List.forEach(a -> {
            let author = ContentEntries.create(profiles#id, None, CmsTestKit.entryData(List#{("name", Json.JString("a${a}"))}));
            List.range(0, entryCount() / authorCount()) |> List.forEach(n ->
                discard ContentEntries.create(blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("t${a}-${n}")), ("profile", Json.JString(EntryId.text(author#id)))})))
        })

    /// 管理 API: entries 50 件 × 10 フィールド。
    def listQuery(typeId: String): String =
        "{ entries(typeId: \"${typeId}\", first: ${entryCount()}) { totalCount nodes { id typeId version stage fields publishedAt createdAt updatedAt versions { id } diff(from: { stage: DRAFT }, to: { stage: DRAFT }) { path } } } }"

    /// コンテンツ API: blogs 50 件と参照先の profile。
    def contentListQuery(): String =
        "{ blogs(stage: DRAFT, first: ${entryCount()}) { totalCount nodes { id title profile { id name } } } }"

    /// この Credential で認証してから問い合わせ、認証の Tx と Runner が observe に戻した属性（合算）と先頭の errors[].message を返す。
    /// Context は Main と同じ形（読むだけの文書には先読みの写し）。
    def measure(pool: Pool, kind: Engine, engine: Graphql.Engine, credential: Credential, queryText: String): (Log.Fields, Option[String]) \ IO =
        let observed = Ref.fresh(Static, Log.Fields.empty());
        let observe = fields -> Ref.put(LogFields.mergeCounts(fields, Ref.get(observed)), observed);
        match PgTestSupport.authenticateObserved(pool, kind, Some(ProjectId.default()), observe, credential) {
            case Err(rejection) => (Ref.get(observed), Some(Rejection.message(rejection)))
            case Ok(found)      =>
                let response = Graphql.executeWith(engine, GraphqlTestKit.queryOnly(queryText), { observe = observe | PgTestSupport.contextFor(found#actor, queryText) });
                (Ref.get(observed), GraphqlTestKit.firstMessage(response))
        }

    /// (名前, db.statements, db.transactions, エラー)。数が無ければ -1。
    def budget(name: String, measured: (Log.Fields, Option[String])): (String, Int32, Int32, Option[String]) =
        let (fields, message) = measured;
        let count = key -> Map.get(key, fields) |> Option.flatMap(Value.asInt) |> Option.getWithDefault(-1);
        (name, count("db.statements"), count("db.transactions"), message)

    ///
    /// 4 つの query の SQL の数と Tx の数が上限の中に収まり、エラーは無い。
    ///   (a) JWT で entries 50 件 × 10 フィールド            実測 12 / 504（認証 7 + 一覧 2 + 版 1 + 型 2。Tx は認証 1 + フィールド 503）
    ///   (b) JWT で contentTypes { name }                     実測 9 / 4（認証 7 本 + 印 + 一覧 1 本。Tx は認証 1 + 一覧 1 + name 2）
    ///   (c) API キー（EDITOR の WRITE）で (a) の一覧          実測 7 / 504
    ///   (d) API キーでコンテンツ API の blogs 50 件と参照先   実測 5 / 254（認証 2 + 一覧 2 + 参照先 1。参照先は Linked から）
    ///
    @Test
    def testPgQueryBudget(): Unit \ {IO, Assert} =
        let budgets = PgTestSupport.withAdminApi(seed, (api, _) -> {
            let admin = GraphqlTestKit.engineOrBug(api#schema);
            let content = PgTestSupport.contentEngine(api#pool);
            let owner = PgTestSupport.ownerCredential();
            let ask = PgTestSupport.askOwner(api);
            let typeId = GraphqlTestKit.stringAt(List#{"contentType", "id"}, ask("{ contentType(apiId: \"blogs\") { id } }"));
            let key = Credential.ApiKey(GraphqlTestKit.stringAt(List#{"createApiKey", "key"}, ask("mutation { createApiKey(name: \"ci\", scope: WRITE, role: EDITOR) { key } }")));
            List#{
                (budget("jwt entries 50x10", measure(api#pool, Engine.Admin, admin, owner, listQuery(typeId))), (16, 510)),
                (budget("jwt contentTypes name", measure(api#pool, Engine.Admin, admin, owner, "{ contentTypes { name } }")), (12, 5)),
                (budget("api-key entries 50x10", measure(api#pool, Engine.Admin, admin, key, listQuery(typeId))), (12, 510)),
                (budget("api-key content blogs 50 + profile", measure(api#pool, Engine.Content, content, key, contentListQuery())), (8, 260))
            }
        });
        List.forEach(match ((name, statements, transactions, _), _) -> println("query budget: ${name}: db.statements=${statements} db.transactions=${transactions}"), budgets);
        Assert.assertEq(
            expected = budgets |> List.map(match ((name, _, _, _), _) -> (name, true, true, None)),
            budgets |> List.map(match ((name, statements, transactions, message), (maxStatements, maxTransactions)) ->
                (name, statements > 0 and statements <= maxStatements, transactions > 0 and transactions <= maxTransactions, message)))

}
