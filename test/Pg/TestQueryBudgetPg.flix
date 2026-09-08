///
/// 1 リクエストで出る SQL の数（db.statements）と張った Tx の数（db.transactions）を、代表的な query で数える。
/// Runner が Context の observe に戻す値を LogFields.mergeCounts で足し合わせる（Main の runObserved と同じ受け方）。
/// 数は標準出力にも出す（実測値をコミットログに残すため）。
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

    /// この身元で問い合わせ、Runner が observe に戻した属性（合算）と先頭の errors[].message を返す。
    def measure(engine: Graphql.Engine, credential: Credential, queryText: String): (Log.Fields, Option[String]) \ IO =
        let observed = Ref.fresh(Static, Log.Fields.empty());
        let context = { observe = fields -> Ref.put(LogFields.mergeCounts(fields, Ref.get(observed)), observed) | Context.withCredential(credential) };
        let response = Graphql.executeWith(engine, GraphqlTestKit.queryOnly(queryText), context);
        (Ref.get(observed), GraphqlTestKit.firstMessage(response))

    /// (名前, db.statements, db.transactions, エラー)。数が無ければ -1。
    def budget(name: String, measured: (Log.Fields, Option[String])): (String, Int32, Int32, Option[String]) =
        let (fields, message) = measured;
        let count = key -> Map.get(key, fields) |> Option.flatMap(Value.asInt) |> Option.getWithDefault(-1);
        (name, count("db.statements"), count("db.transactions"), message)

    ///
    /// 3 つの query の SQL の数と Tx の数。
    ///   (a) JWT で entries 50 件 × 10 フィールド
    ///   (b) JWT で contentTypes { name }
    ///   (c) API キー（EDITOR の WRITE）で (a) と同じ一覧
    /// どれも 1 以上（数えられている）で、エラーは無い。数そのものは出力を読む。
    ///
    @Test
    def testPgQueryBudget(): Unit \ {IO, Assert} =
        let budgets = PgTestSupport.withAdminApi(seed, (schema, _) -> {
            let engine = GraphqlTestKit.engineOrBug(schema);
            let owner = PgTestSupport.ownerCredential();
            let ask = PgTestSupport.askOwner(schema);
            let typeId = GraphqlTestKit.stringAt(List#{"contentType", "id"}, ask("{ contentType(apiId: \"blogs\") { id } }"));
            let key = GraphqlTestKit.stringAt(List#{"createApiKey", "key"}, ask("mutation { createApiKey(name: \"ci\", scope: WRITE, role: EDITOR) { key } }"));
            List#{
                budget("jwt entries 50x10", measure(engine, owner, listQuery(typeId))),
                budget("jwt contentTypes name", measure(engine, owner, "{ contentTypes { name } }")),
                budget("api-key entries 50x10", measure(engine, Credential.ApiKey(key), listQuery(typeId)))
            }
        });
        List.forEach(match (name, statements, transactions, _) -> println("query budget: ${name}: db.statements=${statements} db.transactions=${transactions}"), budgets);
        Assert.assertEq(
            expected = budgets |> List.map(match (name, _, _, _) -> (name, true, true, None)),
            budgets |> List.map(match (name, statements, transactions, message) -> (name, statements > 0, transactions > 0, message)))

}
