///
/// 業務エラーが GraphQL の errors[].extensions に出す機械向けの情報を、管理 API と実 PostgreSQL で見る。
/// クライアント（自作クライアント・CLI・MCP）は message の日本語ではなく、この code で分岐する。
///
mod TestErrorCodesPg {

    /// errors[0].extensions.code。
    def code(extensions: Value): Value = Value.field("code", extensions)

    /// errors[0].extensions.violations の field だけ。
    def violationFields(extensions: Value): List[Value] = match Value.field("violations", extensions) {
        case Value.List(items) => items |> List.map(Value.field("field"))
        case other             => bug!("violations が配列ではありません: ${other}")
    }

    /// 1 回問い合わせて errors[0].extensions を返す。エラーが無ければ Null。認証で断られた物は Runner の手前の形（code だけ）。
    def extensionsOf(api: PgTestSupport.Api, engine: Graphql.Engine, credential: Credential, queryText: String): Value \ IO =
        match PgTestSupport.authenticate(api#pool, api#engine, credential) {
            case Err(rejection) => Value.Obj(Map#{ "code" => Value.Str(ErrorCode.text(Rejection.code(rejection))) })
            case Ok(found)      => GraphqlTestKit.firstErrorField("extensions", Graphql.executeWith(engine, GraphqlTestKit.queryOnly(queryText), Context.withActor(found#actor)))
        }

    ///
    /// 管理 API のそれぞれの失敗に、分類（code）と手掛かりが付く。
    ///
    ///   同じ apiId で 2 回目の型          → INVALID + violations[].field
    ///   無い entry id を消す              → NOT_FOUND + entity / id
    ///   身元無しで型を作る                → FORBIDDEN
    ///   古い expectedVersion で更新       → CONFLICT + id / expectedVersion / actualVersion
    ///   死んだ PAT・壊れたログインの JWT  → UNAUTHENTICATED
    ///
    @Test
    def testPgErrorCodesInAdminApi(): Unit \ {IO, Assert} =
        let (entryId, invalid, notFound, forbidden, conflict, deadToken, brokenJwt) = PgTestSupport.withAdminApi(() -> (), (api, _) -> {
            let engine = GraphqlTestKit.engineOrBug(api#schema);
            let owner = PgTestSupport.ownerCredential();
            let ask = PgTestSupport.askEngineAs(api#pool, api#engine, engine, owner);
            let extensions = (credential, queryText) -> extensionsOf(api, engine, credential, queryText);
            let createType = "mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id } }";
            let typeId = GraphqlTestKit.stringAt(List#{"createContentType", "id"}, ask(createType));
            let entryId = GraphqlTestKit.stringAt(List#{"createEntry", "id"},
                ask("mutation { createEntry(typeId: \"${typeId}\", fields: {}) { id } }"));
            let staleUpdate = "mutation { updateEntry(id: \"${entryId}\", fields: {}, expectedVersion: 1) { version } }";
            discard ask(staleUpdate);
            (entryId,
             extensions(owner, createType),
             extensions(owner, "mutation { deleteEntry(id: \"nope\") }"),
             extensions(Credential.Missing, "mutation { createContentType(input: { apiId: \"tags\", name: \"x\" }) { id } }"),
             extensions(owner, staleUpdate),
             extensions(Credential.PersonalToken("cmspat_nope"), "{ contentTypes { id } }"),
             extensions(Credential.Invalid("JWT は無し"), "{ contentTypes { id } }"))
        });
        Assert.assertEq(
            expected = (
                (Value.Str("INVALID"), List#{ Value.Str("apiId") }),
                (Value.Str("NOT_FOUND"), Value.Str("Entry"), Value.Str("nope")),
                Value.Str("FORBIDDEN"),
                (Value.Str("CONFLICT"), Value.Str(entryId), Value.Int(1), Value.Int(2)),
                Value.Str("UNAUTHENTICATED"),
                Value.Str("UNAUTHENTICATED")),
            ((code(invalid), violationFields(invalid)),
             (code(notFound), Value.field("entity", notFound), Value.field("id", notFound)),
             code(forbidden),
             (code(conflict), Value.field("id", conflict), Value.field("expectedVersion", conflict), Value.field("actualVersion", conflict)),
             code(deadToken),
             code(brokenJwt)))

}
