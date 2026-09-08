///
/// 管理 API を GraphQL 越しに 1 本のシナリオで通す。ミューテーション全部と、SDL・AdminMapping・リゾルバの写しをまとめて確かめる。
///
mod TestAdminScenarioPg {

    /// 型を作る → フィールドを足して直す → entry を作って公開 → 直して CHANGED → 取り下げ → 消す → 型ごと消す。
    ///
    ///   createContentType ─ addField ×2 ─ updateContentType ─ updateField
    ///     └ createEntry ─ publishEntry ─ updateEntry ─ unpublishEntry ─ deleteEntry ─ deleteContentType
    @Test
    def testPgAdminScenario(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> (), (schema, _) -> {
            let ask = PgTestSupport.askOwner(schema);
            let typeId = ask("mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id } }") |> fst |> Value.path(List#{"createContentType", "id"}) |> Value.asStr |> Option.getWithDefault("?");
            let titleId = ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"title\", name: \"題名\", kind: TEXT, required: true }) { id } }") |> fst |> Value.path(List#{"addField", "id"}) |> Value.asStr |> Option.getWithDefault("?");
            discard ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"body\", name: \"本文\", kind: TEXT_AREA }) { id } }");
            let renamed = ask("mutation { updateContentType(id: \"${typeId}\", input: { name: \"ブログ\", previewUrl: \"https://example.com/{id}\" }) { name previewUrl fields { apiId } } }");
            let patched = ask("mutation { updateField(id: \"${titleId}\", input: { required: false, config: { maxLength: 50 } }) { required config { maxLength } } }");
            let created = ask("mutation { createEntry(typeId: \"${typeId}\", id: \"e1\", fields: { title: \"a\" }) { id version stage publishedAt } }");
            let published = ask("mutation { publishEntry(id: \"e1\") { version stage versions { reason } } }");
            let versionAfterPublish = GraphqlTestKit.intAt(List#{"publishEntry", "version"}, published);
            let changed = ask("mutation { updateEntry(id: \"e1\", fields: { title: \"b\" }, expectedVersion: ${versionAfterPublish}) { stage fields } }");
            let stale = ask("mutation { updateEntry(id: \"e1\", fields: { title: \"c\" }, expectedVersion: ${versionAfterPublish}) { stage } }") |> snd;
            let unpublished = ask("mutation { unpublishEntry(id: \"e1\") { stage publishedAt } }");
            let deleted = ask("mutation { deleteEntry(id: \"e1\") }");
            let gone = ask("{ entry(id: \"e1\") { id } entries(typeId: \"${typeId}\") { totalCount } }");
            let typeDeleted = ask("mutation { deleteContentType(id: \"${typeId}\") }");
            let noTypes = ask("{ contentTypes { id } }");
            (typeId, versionAfterPublish,
             List#{ ("renamed", renamed), ("patched", patched), ("created", created), ("published", published), ("changed", changed),
                    ("unpublished", unpublished), ("deleted", deleted), ("gone", gone), ("typeDeleted", typeDeleted), ("noTypes", noTypes) },
             stale)
        });
        let (typeId, versionAfterPublish, responses, stale) = outcome;
        Assert.assertEq(
            expected = (
                List#{
                    ("renamed", (Value.Obj(Map#{ "updateContentType" => Value.Obj(Map#{ "name" => Value.Str("ブログ"), "previewUrl" => Value.Str("https://example.com/{id}"), "fields" => Value.List(Value.Obj(Map#{ "apiId" => Value.Str("title") }) :: Value.Obj(Map#{ "apiId" => Value.Str("body") }) :: Nil) }) }), None)),
                    ("patched", (Value.Obj(Map#{ "updateField" => Value.Obj(Map#{ "required" => Value.Bool(false), "config" => Value.Obj(Map#{ "maxLength" => Value.Int(50) }) }) }), None)),
                    ("created", (Value.Obj(Map#{ "createEntry" => Value.Obj(Map#{ "id" => Value.Str("e1"), "version" => Value.Int(1), "stage" => Value.Str("DRAFT"), "publishedAt" => Value.Null }) }), None)),
                    ("published", (Value.Obj(Map#{ "publishEntry" => Value.Obj(Map#{ "version" => Value.Int(versionAfterPublish), "stage" => Value.Str("PUBLISHED"), "versions" => Value.List(Value.Obj(Map#{ "reason" => Value.Str("PUBLISH") }) :: Nil) }) }), None)),
                    ("changed", (Value.Obj(Map#{ "updateEntry" => Value.Obj(Map#{ "stage" => Value.Str("CHANGED"), "fields" => Value.Obj(Map#{ "title" => Value.Str("b") }) }) }), None)),
                    ("unpublished", (Value.Obj(Map#{ "unpublishEntry" => Value.Obj(Map#{ "stage" => Value.Str("DRAFT"), "publishedAt" => Value.Null }) }), None)),
                    ("deleted", (Value.Obj(Map#{ "deleteEntry" => Value.Str("e1") }), None)),
                    ("gone", (Value.Obj(Map#{ "entry" => Value.Null, "entries" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) }), None)),
                    ("typeDeleted", (Value.Obj(Map#{ "deleteContentType" => Value.Str(typeId) }), None)),
                    ("noTypes", (Value.Obj(Map#{ "contentTypes" => Value.List(Nil) }), None)) },
                Some("entry 'e1' の version が一致しません（渡した ${versionAfterPublish}、今の ${versionAfterPublish + 1}）。読み直してから保存してください")),
            (responses, stale))

}
