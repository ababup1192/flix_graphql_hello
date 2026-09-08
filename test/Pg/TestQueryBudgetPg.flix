///
/// 1 リクエストで出る SQL の数（db.statements）と張った Tx の数（db.transactions）を、代表的な query で数えて上限と比べる。
/// 認証の Tx と Runner が observe に戻す値を LogFields.mergeCounts で足し合わせる（Main の runRoute / runObserved と同じ受け方）。
/// 数は標準出力にも出す（実測値をコミットログに残すため）。
///
/// 上限は実測（2026-09-08）+ 少しの余裕。認証の SQL（JWT で 7 本）がフィールドごとに繰り返されると (b) が 2 倍を超えて落ちる。
///
mod TestQueryBudgetPg {

    use Util.Json.Json

    /// 一覧の件数と、1 件で選ぶフィールドの数（id typeId version stage fields publishedAt createdAt updatedAt versions diff）。
    def entryCount(): Int32 = 50

    /// blogs 型（title）と entry 50 件。
    def seed(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        List.range(0, entryCount()) |> List.forEach(n ->
            discard ContentEntries.create(blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("t${n}"))})))

    /// entries 50 件 × 10 フィールド。
    def listQuery(typeId: String): String =
        "{ entries(typeId: \"${typeId}\", first: ${entryCount()}) { totalCount nodes { id typeId version stage fields publishedAt createdAt updatedAt versions { id } diff(from: { stage: DRAFT }, to: { stage: DRAFT }) { path } } } }"

    /// この Credential で認証してから問い合わせ、認証の Tx と Runner が observe に戻した属性（合算）と先頭の errors[].message を返す。
    def measure(api: PgTestSupport.Api, engine: Graphql.Engine, credential: Credential, queryText: String): (Log.Fields, Option[String]) \ IO =
        let observed = Ref.fresh(Static, Log.Fields.empty());
        let observe = fields -> Ref.put(LogFields.mergeCounts(fields, Ref.get(observed)), observed);
        match PgTestSupport.authenticateObserved(api#pool, api#engine, api#scope, observe, credential) {
            case Err(rejection) => (Ref.get(observed), Some(Rejection.message(rejection)))
            case Ok(found)      =>
                let response = Graphql.executeWith(engine, GraphqlTestKit.queryOnly(queryText), { observe = observe | Context.withActor(found#actor) });
                (Ref.get(observed), GraphqlTestKit.firstMessage(response))
        }

    /// (名前, db.statements, db.transactions, エラー)。数が無ければ -1。
    def budget(name: String, measured: (Log.Fields, Option[String])): (String, Int32, Int32, Option[String]) =
        let (fields, message) = measured;
        let count = key -> Map.get(key, fields) |> Option.flatMap(Value.asInt) |> Option.getWithDefault(-1);
        (name, count("db.statements"), count("db.transactions"), message)

    ///
    /// 3 つの query の SQL の数と Tx の数が上限の中に収まり、エラーは無い。
    ///   (a) JWT で entries 50 件 × 10 フィールド   実測 209 / 504（認証 1 Tx + フィールド 503 Tx）
    ///   (b) JWT で contentTypes { name }            実測 9 / 3（認証 7 本 + 印 + 一覧 1 本。認証が 1 回分）
    ///   (c) API キー（EDITOR の WRITE）で (a) の一覧 実測 204 / 504
    ///
    @Test
    def testPgQueryBudget(): Unit \ {IO, Assert} =
        let budgets = PgTestSupport.withAdminApi(seed, (api, _) -> {
            let engine = GraphqlTestKit.engineOrBug(api#schema);
            let owner = PgTestSupport.ownerCredential();
            let ask = PgTestSupport.askOwner(api);
            let typeId = GraphqlTestKit.stringAt(List#{"contentType", "id"}, ask("{ contentType(apiId: \"blogs\") { id } }"));
            let key = GraphqlTestKit.stringAt(List#{"createApiKey", "key"}, ask("mutation { createApiKey(name: \"ci\", scope: WRITE, role: EDITOR) { key } }"));
            List#{
                (budget("jwt entries 50x10", measure(api, engine, owner, listQuery(typeId))), (230, 510)),
                (budget("jwt contentTypes name", measure(api, engine, owner, "{ contentTypes { name } }")), (12, 4)),
                (budget("api-key entries 50x10", measure(api, engine, Credential.ApiKey(key), listQuery(typeId))), (230, 510))
            }
        });
        List.forEach(match ((name, statements, transactions, _), _) -> println("query budget: ${name}: db.statements=${statements} db.transactions=${transactions}"), budgets);
        Assert.assertEq(
            expected = budgets |> List.map(match ((name, _, _, _), _) -> (name, true, true, None)),
            budgets |> List.map(match ((name, statements, transactions, message), (maxStatements, maxTransactions)) ->
                (name, statements > 0 and statements <= maxStatements, transactions > 0 and transactions <= maxTransactions, message)))

}
