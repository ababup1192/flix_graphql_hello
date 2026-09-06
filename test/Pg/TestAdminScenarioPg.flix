///
/// 管理 API を GraphQL 越しに 1 本のシナリオで通す。ミューテーション全部と、SDL・AdminMapping・リゾルバの写しをまとめて確かめる。
///

///
/// path を辿って値を取り出す。無ければ Null。
///
def at(path: List[String], data: Value): Value = List.foldLeft((found, name) -> Value.field(name, found), data, path)

///
/// 1 回実行して data と最初のエラー文を返す。GraphQL 自体が動かない（Err）のはテストの前提が壊れている。
///
def ask(schema: Schema, queryText: String): (Value, Option[String]) \ IO = match GraphqlTestKit.executeQuery(schema, queryText) {
    case Ok(found)    => found
    case Err(message) => bug!("graphql: ${message}")
}

/// 型を作る → フィールドを足して直す → entry を作って公開 → 直して CHANGED → 取り下げ → 消す → 型ごと消す。
///
///   createContentType ─ addField ×2 ─ updateContentType ─ updateField
///     └ createEntry ─ publishEntry ─ updateEntry ─ unpublishEntry ─ deleteEntry ─ deleteContentType
@Test
def testPgAdminScenario(): Unit \ {IO, Assert} =
    let pool = Pool.open(Pool.defaultConfig(PgTestSupport.config()));
    discard PgTestSupport.withDb(() -> ());
    let schema = AdminSchema.make(AdminRunner.make(pool));
    let typeId = ask(schema, "mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id } }") |> fst |> at(List#{"createContentType", "id"}) |> Value.asStr |> Option.getWithDefault("?");
    let titleId = ask(schema, "mutation { addField(typeId: \"${typeId}\", input: { apiId: \"title\", name: \"題名\", kind: TEXT, required: true }) { id } }") |> fst |> at(List#{"addField", "id"}) |> Value.asStr |> Option.getWithDefault("?");
    discard ask(schema, "mutation { addField(typeId: \"${typeId}\", input: { apiId: \"body\", name: \"本文\", kind: TEXT_AREA }) { id } }");
    let renamed = ask(schema, "mutation { updateContentType(id: \"${typeId}\", input: { name: \"ブログ\", previewUrl: \"https://example.com/{id}\" }) { name previewUrl fields { apiId } } }");
    let patched = ask(schema, "mutation { updateField(id: \"${titleId}\", input: { required: false, config: { maxLength: 50 } }) { required config { maxLength } } }");
    let created = ask(schema, "mutation { createEntry(typeId: \"${typeId}\", id: \"e1\", fields: { title: \"a\" }) { id version stage publishedAt } }");
    let published = ask(schema, "mutation { publishEntry(id: \"e1\") { version stage versions { reason } } }");
    let versionAfterPublish = published |> fst |> at(List#{"publishEntry", "version"}) |> Value.asInt |> Option.getWithDefault(-1);
    let changed = ask(schema, "mutation { updateEntry(id: \"e1\", fields: { title: \"b\" }, expectedVersion: ${versionAfterPublish}) { stage fields } }");
    let stale = ask(schema, "mutation { updateEntry(id: \"e1\", fields: { title: \"c\" }, expectedVersion: ${versionAfterPublish}) { stage } }");
    let unpublished = ask(schema, "mutation { unpublishEntry(id: \"e1\") { stage publishedAt } }");
    let deleted = ask(schema, "mutation { deleteEntry(id: \"e1\") }");
    let gone = ask(schema, "{ entry(id: \"e1\") { id } entries(typeId: \"${typeId}\") { totalCount } }");
    let typeDeleted = ask(schema, "mutation { deleteContentType(id: \"${typeId}\") }");
    let noTypes = ask(schema, "{ contentTypes { id } }");
    Pool.close(pool);
    Assert.assertEq(
        expected = (
            (Value.Obj(Map#{ "updateContentType" => Value.Obj(Map#{ "name" => Value.Str("ブログ"), "previewUrl" => Value.Str("https://example.com/{id}"), "fields" => Value.List(Value.Obj(Map#{ "apiId" => Value.Str("title") }) :: Value.Obj(Map#{ "apiId" => Value.Str("body") }) :: Nil) }) }), None),
            (Value.Obj(Map#{ "updateField" => Value.Obj(Map#{ "required" => Value.Bool(false), "config" => Value.Obj(Map#{ "maxLength" => Value.Int(50) }) }) }), None),
            (Value.Obj(Map#{ "createEntry" => Value.Obj(Map#{ "id" => Value.Str("e1"), "version" => Value.Int(1), "stage" => Value.Str("DRAFT"), "publishedAt" => Value.Null }) }), None),
            (Value.Str("PUBLISHED"), Value.List(Value.Obj(Map#{ "reason" => Value.Str("PUBLISH") }) :: Nil)),
            (Value.Obj(Map#{ "updateEntry" => Value.Obj(Map#{ "stage" => Value.Str("CHANGED"), "fields" => Value.Obj(Map#{ "title" => Value.Str("b") }) }) }), None),
            Some("entry 'e1' は他で更新されています（今の version は ${versionAfterPublish + 1}）。読み直してから保存してください"),
            (Value.Obj(Map#{ "unpublishEntry" => Value.Obj(Map#{ "stage" => Value.Str("DRAFT"), "publishedAt" => Value.Null }) }), None),
            (Value.Obj(Map#{ "deleteEntry" => Value.Str("e1") }), None),
            (Value.Obj(Map#{ "entry" => Value.Null, "entries" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) }), None),
            (Value.Obj(Map#{ "deleteContentType" => Value.Str(typeId) }), None),
            (Value.Obj(Map#{ "contentTypes" => Value.List(Nil) }), None)),
        (renamed, patched, created,
         (published |> fst |> at(List#{"publishEntry", "stage"}), published |> fst |> at(List#{"publishEntry", "versions"})),
         changed, snd(stale), unpublished, deleted, gone, typeDeleted, noTypes))
