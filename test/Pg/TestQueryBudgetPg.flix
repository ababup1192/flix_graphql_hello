///
/// 1 リクエストで出る SQL の数（db.statements）と張った Tx の数（db.transactions）を、代表的な query で数えて上限と比べる。
/// 認証の Tx と Runner が observe に戻す値を LogFields.mergeCounts で足し合わせる（Main の runRoute / runObserved と同じ受け方）。
/// 数は標準出力にも出す（実測値をコミットログに残すため）。
///
/// 上限は実測（2026-09-08）+ 少しの余裕。一覧の行ごとに版・型・参照先を引く形（N+1）に戻れば (a) (c) (d) が落ち、
/// 認証の SQL（JWT で 7 本）がフィールドごとに繰り返されると (b) が 2 倍を超えて落ちる。
/// 読むだけの文書がフィールドごとの Tx に戻れば、Tx の数（上限 2）で全部落ちる。
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

    /// この型の entry を全部、管理 API で公開する（参照先も一緒に）。
    def publishAll(ask: String -> (Value, Option[String]) \ IO, typeId: String): Unit \ IO =
        let ids = ask("{ entries(typeId: \"${typeId}\", first: ${entryCount()}) { nodes { id } } }")
            |> fst |> Value.path(List#{"entries", "nodes"});
        match ids {
            case Value.List(nodes) => nodes |> List.forEach(node -> discard ask("mutation { publishEntry(id: \"${Value.field("id", node) |> Value.asStr |> Option.getWithDefault("")}\", withDependencies: true) { id } }"))
            case _                 => bug!("entries が引けません")
        }

    /// コンテンツ API（匿名。公開中）: blogs 50 件と参照先の profile。
    def publishedListQuery(): String =
        "{ blogs(first: ${entryCount()}) { totalCount nodes { id title profile { id name } } } }"

    ///
    /// 匿名のコンテンツ API の GET を Main.runRoute と同じ形で測る: 認証と版の読み取りの Tx（304 ならここで終わる）と、
    /// 実行する時（200）はそれに問い合わせの分を足した物。(304 の属性, 200 の属性と先頭の errors[].message)。
    ///
    def measureAnonymous(pool: Pool, engine: Graphql.Engine, queryText: String): ((Log.Fields, Option[String]), (Log.Fields, Option[String])) \ IO =
        let observed = Ref.fresh(Static, Log.Fields.empty());
        let observe = fields -> Ref.put(LogFields.mergeCounts(fields, Ref.get(observed)), observed);
        let (auth, _) = PgTestSupport.locateAnonymousObserved(pool, observe);
        let notModified = (Ref.get(observed), None);
        match auth {
            case Err(rejection) => (notModified, (Ref.get(observed), Some(Rejection.message(rejection))))
            case Ok(found)      =>
                let response = PgTestSupport.executeAs(pool, Some(ProjectId.default()), engine, found#actor, observe, GraphqlTestKit.queryOnly(queryText));
                (notModified, (Ref.get(observed), GraphqlTestKit.firstMessage(response)))
        }

    /// この Credential で認証してから問い合わせ、認証の Tx と Runner とリクエストの Tx が observe に戻した属性（合算）と先頭の errors[].message を返す。
    /// 実行は Main と同じ形（読むだけの文書は 1 リクエスト 1 Tx と先読みの写し）。
    def measure(pool: Pool, kind: Engine, engine: Graphql.Engine, credential: Credential, queryText: String): (Log.Fields, Option[String]) \ IO =
        let observed = Ref.fresh(Static, Log.Fields.empty());
        let observe = fields -> Ref.put(LogFields.mergeCounts(fields, Ref.get(observed)), observed);
        match PgTestSupport.authenticateObserved(pool, kind, Some(ProjectId.default()), observe, credential) {
            case Err(rejection) => (Ref.get(observed), Some(Rejection.message(rejection)))
            case Ok(found)      =>
                let response = PgTestSupport.executeAs(pool, Some(ProjectId.default()), engine, found#actor, observe, GraphqlTestKit.queryOnly(queryText));
                (Ref.get(observed), GraphqlTestKit.firstMessage(response))
        }

    /// (名前, db.statements, db.transactions, エラー)。数が無ければ -1。
    def budget(name: String, measured: (Log.Fields, Option[String])): (String, Int32, Int32, Option[String]) =
        let (fields, message) = measured;
        let count = key -> Map.get(key, fields) |> Option.flatMap(Value.asInt) |> Option.getWithDefault(-1);
        (name, count("db.statements"), count("db.transactions"), message)

    ///
    /// 6 つの query の SQL の数と Tx の数が上限の中に収まり、エラーは無い。読むだけの文書は 1 リクエスト 1 Tx なので、Tx は認証 1 + リクエスト 1。
    ///   (a) JWT で entries 50 件 × 10 フィールド            実測 12 / 2（認証 7 + 一覧 2 + 版 1 + 型 2。1 リクエスト 1 Tx の前は 504）
    ///   (b) JWT で contentTypes { name }                     実測 9 / 2（認証 7 本 + 印 + 一覧 1 本。前は 4）
    ///   (c) API キー（EDITOR の WRITE）で (a) の一覧          実測 7 / 2（前は 504）
    ///   (d) API キーでコンテンツ API の blogs 50 件と参照先   実測 5 / 2（認証 2 + 一覧 2 + 参照先 1。参照先は Linked から。前は 254）
    ///   (e) 匿名のコンテンツ API の GET が 304 で終わる道      認証（印 + 公開範囲 1）+ 版 1 の Tx 1 つ。GraphQL は実行しない
    ///   (f) 匿名のコンテンツ API の GET が 200（blogs 50 件）  (e) + 一覧と参照先の Tx 1 つ（前は 254）
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
            // 管理 API の分は下書きのまま測る（公開すると entry ごとに版が 1 つ増え、versions { id } の Tx が 50 増える）
            let jwtEntries = measure(api#pool, Engine.Admin, admin, owner, listQuery(typeId));
            let jwtTypes = measure(api#pool, Engine.Admin, admin, owner, "{ contentTypes { name } }");
            let keyEntries = measure(api#pool, Engine.Admin, admin, key, listQuery(typeId));
            let keyContent = measure(api#pool, Engine.Content, content, key, contentListQuery());
            // 匿名のコンテンツ API は公開中しか読めないので、ここで 50 件を公開してから測る（参照先の profile も一緒に）
            publishAll(ask, typeId);
            let (notModified, executed) = measureAnonymous(api#pool, content, publishedListQuery());
            List#{
                (budget("jwt entries 50x10", jwtEntries), (16, 2)),
                (budget("jwt contentTypes name", jwtTypes), (12, 2)),
                (budget("api-key entries 50x10", keyEntries), (12, 2)),
                (budget("api-key content blogs 50 + profile", keyContent), (8, 2)),
                (budget("anonymous content GET 304", notModified), (4, 1)),
                (budget("anonymous content GET 200 blogs 50 + profile", executed), (8, 2))
            }
        });
        List.forEach(match ((name, statements, transactions, _), _) -> println("query budget: ${name}: db.statements=${statements} db.transactions=${transactions}"), budgets);
        Assert.assertEq(
            expected = budgets |> List.map(match ((name, _, _, _), _) -> (name, true, true, None)),
            budgets |> List.map(match ((name, statements, transactions, message), (maxStatements, maxTransactions)) ->
                (name, statements > 0 and statements <= maxStatements, transactions > 0 and transactions <= maxTransactions, message)))

}
