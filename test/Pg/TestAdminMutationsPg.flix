///
/// 管理 API（admin.graphql）の全 Mutation と全 Query を、GraphQL のリゾルバ越しに実 PostgreSQL と MinIO で 1 度ずつ通す。
/// ユースケースを直に呼ぶテストでは見えない、リゾルバ・AdminMapping・graphql-java の境界の不具合（型の写し漏れ・ラムダの VerifyError）を拾う。
/// id は前の応答から取り、決め打ちしない。
///
/// admin.graphql の全 object 型の全フィールドを 1 度は選ぶ（値を見ない物も selection には並べる）。
/// フィールドを足したら、ここの selection にも足す事。選ばれないフィールドのリゾルバは誰も実行しない。
/// 型の一覧との突き合わせは test/admin/TestApiSurface。
///
mod TestAdminMutationsPg {

    /// 応答の errors の先頭を errors に積みつつ、そのまま返す ask。期待しないエラーは最後にまとめて見る。
    def recording(ask: String -> (Value, Option[String]) \ IO, errors: Ref[List[String], Static]): String -> (Value, Option[String]) \ IO =
        queryText -> {
            let response = ask(queryText);
            Option.forEach(message -> Ref.put(message :: Ref.get(errors), errors), snd(response));
            response
        }

    /// blogs 型を作り、title（required）と body を足す。戻り値は (typeId, titleId, bodyId)。
    def createBlogs(ask: String -> (Value, Option[String]) \ IO): (String, String, String) \ IO =
        let typeId = GraphqlTestKit.stringAt(List#{"createContentType", "id"}, ask("mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id } }"));
        let titleId = GraphqlTestKit.stringAt(List#{"addField", "id"}, ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"title\", name: \"題名\", kind: TEXT, required: true }) { id } }"));
        let bodyId = GraphqlTestKit.stringAt(List#{"addField", "id"}, ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"body\", name: \"本文\", kind: TEXT_AREA }) { id } }"));
        (typeId, titleId, bodyId)

    ///
    /// content type とフィールドと Webhook の mutation。SCHEMA_CHANGED を受ける Webhook を先に作り、型の変更で配信が積まれ、redeliver で送る番に戻せる。
    ///
    ///   createWebhook(SCHEMA_CHANGED) ─ createContentType ─ addField ×3 ─ updateField ─ removeField ─ reorderFields ─ updateContentType
    ///     └ contentTypes / contentType(id) / contentType(apiId) / webhooks / webhookDeliveries
    ///     └ updateWebhook ─ redeliverWebhook ─ deleteWebhook ─ deleteContentType
    ///
    @Test
    def testPgAdminSchemaAndWebhookMutations(): Unit \ {IO, Assert} =
        let errors = Ref.fresh(Static, Nil);
        let outcome = PgTestSupport.withAdminApi(() -> (), (schema, _) -> {
            let ask = recording(PgTestSupport.askOwner(schema), errors);
            let webhookCreated = ask("mutation { createWebhook(input: { name: \"site\", url: \"https://example.com/hook\", events: [SCHEMA_CHANGED] }) { webhook { id name url events active createdAt } secret } }");
            let webhookId = GraphqlTestKit.stringAt(List#{"createWebhook", "webhook", "id"}, webhookCreated);
            let typeCreated = ask("mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id apiId kind name singular plural previewUrl fields { id } createdAt updatedAt } }");
            let typeId = GraphqlTestKit.stringAt(List#{"createContentType", "id"}, typeCreated);
            let titleAdded = ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"title\", name: \"題名\", kind: TEXT, required: true }) { id apiId kind many required unique localized targetTypeId parentFieldId position children { id } config { maxLength sourceField min max integer options } } }");
            let titleId = GraphqlTestKit.stringAt(List#{"addField", "id"}, titleAdded);
            let bodyId = GraphqlTestKit.stringAt(List#{"addField", "id"}, ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"body\", name: \"本文\", kind: TEXT_AREA }) { id } }"));
            let tagId = GraphqlTestKit.stringAt(List#{"addField", "id"}, ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"tag\", name: \"タグ\", kind: TEXT }) { id } }"));
            let fieldUpdated = ask("mutation { updateField(id: \"${titleId}\", input: { name: \"タイトル\", config: { maxLength: 50 } }) { name required config { maxLength } } }");
            let fieldRemoved = ask("mutation { removeField(id: \"${tagId}\") }");
            let reordered = ask("mutation { reorderFields(typeId: \"${typeId}\", ids: [\"${bodyId}\", \"${titleId}\"]) { fields { apiId position } } }");
            let typeUpdated = ask("mutation { updateContentType(id: \"${typeId}\", input: { name: \"ブログ\", previewUrl: \"https://example.com/{id}\" }) { name previewUrl } }");
            let listed = ask("{ contentTypes { apiId } contentType(id: \"${typeId}\") { apiId } byApiId: contentType(apiId: \"blogs\") { id } }");
            let webhooksListed = ask("{ webhooks { id name events active } }");
            let webhookUpdated = ask("mutation { updateWebhook(id: \"${webhookId}\", input: { name: \"site2\", url: \"https://example.com/hook2\", events: [SCHEMA_CHANGED, ENTRY_PUBLISHED], active: true }) { name url events active } }");
            let deliveries = ask("{ webhookDeliveries(webhookId: \"${webhookId}\") { id event status attempts nextAttemptAt lastStatus lastError createdAt deliveredAt } }");
            let deliveryId = GraphqlTestKit.listAt(List#{"webhookDeliveries"}, deliveries) |> List.head |> Option.map(Value.field("id")) |> Option.flatMap(Value.asStr) |> Option.getWithDefault("");
            let redelivered = ask("mutation { redeliverWebhook(deliveryId: \"${deliveryId}\") { id event status attempts } }");
            let webhookDeleted = ask("mutation { deleteWebhook(id: \"${webhookId}\") }");
            let typeDeleted = ask("mutation { deleteContentType(id: \"${typeId}\") }");
            let afterDelete = ask("{ contentTypes { id } webhooks { id } }");
            ((String.startsWith(prefix = "whsec_", GraphqlTestKit.stringAt(List#{"createWebhook", "secret"}, webhookCreated)),
             GraphqlTestKit.valueAt(List#{"createWebhook", "webhook", "events"}, webhookCreated),
             (GraphqlTestKit.valueAt(List#{"createContentType", "apiId"}, typeCreated), GraphqlTestKit.valueAt(List#{"createContentType", "kind"}, typeCreated), GraphqlTestKit.valueAt(List#{"createContentType", "singular"}, typeCreated), GraphqlTestKit.valueAt(List#{"createContentType", "plural"}, typeCreated), GraphqlTestKit.valueAt(List#{"createContentType", "previewUrl"}, typeCreated), GraphqlTestKit.valueAt(List#{"createContentType", "fields"}, typeCreated)),
             (GraphqlTestKit.valueAt(List#{"addField", "apiId"}, titleAdded), GraphqlTestKit.valueAt(List#{"addField", "kind"}, titleAdded), GraphqlTestKit.valueAt(List#{"addField", "required"}, titleAdded), GraphqlTestKit.valueAt(List#{"addField", "many"}, titleAdded), GraphqlTestKit.valueAt(List#{"addField", "position"}, titleAdded), GraphqlTestKit.valueAt(List#{"addField", "children"}, titleAdded), GraphqlTestKit.valueAt(List#{"addField", "config"}, titleAdded)),
             fst(fieldUpdated),
             GraphqlTestKit.stringAt(List#{"removeField"}, fieldRemoved) == tagId,
             fst(reordered),
             fst(typeUpdated)),
             ((GraphqlTestKit.valueAt(List#{"contentTypes"}, listed), GraphqlTestKit.valueAt(List#{"contentType"}, listed), GraphqlTestKit.stringAt(List#{"byApiId", "id"}, listed) == typeId),
             fst(webhooksListed) == Value.Obj(Map#{ "webhooks" => Value.List(Value.Obj(Map#{ "id" => Value.Str(webhookId), "name" => Value.Str("site"), "events" => Value.List(Value.Str("SCHEMA_CHANGED") :: Nil), "active" => Value.Bool(true) }) :: Nil) }),
             fst(webhookUpdated),
             (List.length(GraphqlTestKit.listAt(List#{"webhookDeliveries"}, deliveries)), GraphqlTestKit.listAt(List#{"webhookDeliveries"}, deliveries) |> List.head |> Option.map(delivery -> (Value.field("event", delivery), Value.field("status", delivery), Value.field("attempts", delivery), Value.field("lastStatus", delivery), Value.field("deliveredAt", delivery)))),
             fst(redelivered) == Value.Obj(Map#{ "redeliverWebhook" => Value.Obj(Map#{ "id" => Value.Str(deliveryId), "event" => Value.Str("SCHEMA_CHANGED"), "status" => Value.Str("PENDING"), "attempts" => Value.Int(0) }) }),
             GraphqlTestKit.stringAt(List#{"deleteWebhook"}, webhookDeleted) == webhookId,
             GraphqlTestKit.stringAt(List#{"deleteContentType"}, typeDeleted) == typeId,
             fst(afterDelete)))
        });
        Assert.assertEq(
            expected = (((
                true,
                Value.List(Value.Str("SCHEMA_CHANGED") :: Nil),
                (Value.Str("blogs"), Value.Str("COLLECTION"), Value.Str("Blog"), Value.Str("blogs"), Value.Null, Value.List(Nil)),
                (Value.Str("title"), Value.Str("TEXT"), Value.Bool(true), Value.Bool(false), Value.Int(0), Value.List(Nil), Value.Obj(Map#{ "maxLength" => Value.Null, "sourceField" => Value.Null, "min" => Value.Null, "max" => Value.Null, "integer" => Value.Null, "options" => Value.Null })),
                Value.Obj(Map#{ "updateField" => Value.Obj(Map#{ "name" => Value.Str("タイトル"), "required" => Value.Bool(true), "config" => Value.Obj(Map#{ "maxLength" => Value.Int(50) }) }) }),
                true,
                Value.Obj(Map#{ "reorderFields" => Value.Obj(Map#{ "fields" => Value.List(Value.Obj(Map#{ "apiId" => Value.Str("body"), "position" => Value.Int(0) }) :: Value.Obj(Map#{ "apiId" => Value.Str("title"), "position" => Value.Int(1) }) :: Nil) }) }),
                Value.Obj(Map#{ "updateContentType" => Value.Obj(Map#{ "name" => Value.Str("ブログ"), "previewUrl" => Value.Str("https://example.com/{id}") }) })),
                ((Value.List(Value.Obj(Map#{ "apiId" => Value.Str("blogs") }) :: Nil), Value.Obj(Map#{ "apiId" => Value.Str("blogs") }), true),
                true,
                Value.Obj(Map#{ "updateWebhook" => Value.Obj(Map#{ "name" => Value.Str("site2"), "url" => Value.Str("https://example.com/hook2"), "events" => Value.List(Value.Str("SCHEMA_CHANGED") :: Value.Str("ENTRY_PUBLISHED") :: Nil), "active" => Value.Bool(true) }) }),
                (8, Some((Value.Str("SCHEMA_CHANGED"), Value.Str("PENDING"), Value.Int(0), Value.Int(0), Value.Null))),
                true,
                true,
                true,
                Value.Obj(Map#{ "contentTypes" => Value.List(Nil), "webhooks" => Value.List(Nil) }))),
                Nil),
            (outcome, Ref.get(errors)))

    ///
    /// entry の mutation と、版・予約公開・プレビュートークン・公開検査。schedulePublish は過去の時刻なので overdue が true になり、
    /// scheduleUnpublish は未来なので false。
    ///
    ///   createEntry ─ publishCheck / impact ─ publishEntry ─ updateEntry ─ saveVersion ─ updateEntry(null で消す) ─ restoreVersion
    ///     └ entry / entries(search) ─ schedulePublish(過去) ─ scheduleUnpublish(未来) ─ schedules ─ cancelSchedule
    ///     └ createPreviewToken ─ unpublishEntry ─ deleteEntry
    ///
    @Test
    def testPgAdminEntryMutations(): Unit \ {IO, Assert} =
        let errors = Ref.fresh(Static, Nil);
        let outcome = PgTestSupport.withAdminApi(() -> (), (schema, _) -> {
            let ask = recording(PgTestSupport.askOwner(schema), errors);
            let (typeId, _, _) = createBlogs(ask);
            let created = ask("mutation { createEntry(typeId: \"${typeId}\", fields: { title: \"a\", body: \"x\" }) { id typeId version stage fields publishedAt createdAt updatedAt versions { id } } }");
            let entryId = GraphqlTestKit.stringAt(List#{"createEntry", "id"}, created);
            let checked = ask("{ publishCheck(id: \"${entryId}\") { ok violations { path message } unpublishedDependencies { id } } impact(id: \"${entryId}\", action: PUBLISH) { breaks { via stage entry { id } } cascades { id } } }");
            let published = ask("mutation { publishEntry(id: \"${entryId}\") { version stage versions { reason author } } }");
            let versionAfterPublish = GraphqlTestKit.intAt(List#{"publishEntry", "version"}, published);
            let updated = ask("mutation { updateEntry(id: \"${entryId}\", fields: { body: \"y\" }, expectedVersion: ${versionAfterPublish}) { version stage fields } }");
            let saved = ask("mutation { saveVersion(id: \"${entryId}\") { id version reason author fields createdAt } }");
            let versionId = GraphqlTestKit.stringAt(List#{"saveVersion", "id"}, saved);
            let cleared = ask("mutation { updateEntry(id: \"${entryId}\", fields: { body: null }, expectedVersion: ${versionAfterPublish + 1}) { version fields } }");
            let restored = ask("mutation { restoreVersion(id: \"${entryId}\", versionId: \"${versionId}\", expectedVersion: ${versionAfterPublish + 2}) { version fields } }");
            let fetched = ask("{ entry(id: \"${entryId}\") { id stage versions { reason } } entries(typeId: \"${typeId}\", search: \"a\") { totalCount nodes { id } } }");
            let scheduled = ask("mutation { schedulePublish(entryId: \"${entryId}\", at: \"2020-01-01T00:00:00Z\") { id entryId action runAt withDependencies status requestedBy lastError overdue createdAt doneAt } }");
            let unpublishScheduled = ask("mutation { scheduleUnpublish(entryId: \"${entryId}\", at: \"2100-01-01T00:00:00Z\") { id action status overdue } }");
            let unpublishScheduleId = GraphqlTestKit.stringAt(List#{"scheduleUnpublish", "id"}, unpublishScheduled);
            let schedulesListed = ask("{ schedules(entryId: \"${entryId}\") { action status overdue } }");
            let cancelled = ask("mutation { cancelSchedule(id: \"${unpublishScheduleId}\") { id status overdue } }");
            let preview = ask("mutation { createPreviewToken(entryId: \"${entryId}\") { token entryId expiresAt url } }");
            let unpublished = ask("mutation { unpublishEntry(id: \"${entryId}\") { stage publishedAt } }");
            let deleted = ask("mutation { deleteEntry(id: \"${entryId}\") }");
            let afterDelete = ask("{ entry(id: \"${entryId}\") { id } entries(typeId: \"${typeId}\") { totalCount } }");
            ((String.length(entryId) > 0,
             (GraphqlTestKit.stringAt(List#{"createEntry", "typeId"}, created) == typeId, GraphqlTestKit.valueAt(List#{"createEntry", "version"}, created), GraphqlTestKit.valueAt(List#{"createEntry", "stage"}, created), GraphqlTestKit.valueAt(List#{"createEntry", "fields"}, created), GraphqlTestKit.valueAt(List#{"createEntry", "publishedAt"}, created), GraphqlTestKit.valueAt(List#{"createEntry", "versions"}, created)),
             fst(checked),
             (GraphqlTestKit.valueAt(List#{"publishEntry", "stage"}, published), GraphqlTestKit.valueAt(List#{"publishEntry", "versions"}, published)),
             (GraphqlTestKit.valueAt(List#{"updateEntry", "version"}, updated) == Value.Int(versionAfterPublish + 1), GraphqlTestKit.valueAt(List#{"updateEntry", "stage"}, updated), GraphqlTestKit.valueAt(List#{"updateEntry", "fields"}, updated)),
             (GraphqlTestKit.valueAt(List#{"saveVersion", "version"}, saved) == Value.Int(versionAfterPublish + 1), GraphqlTestKit.valueAt(List#{"saveVersion", "reason"}, saved), GraphqlTestKit.valueAt(List#{"saveVersion", "fields"}, saved)),
             GraphqlTestKit.valueAt(List#{"updateEntry", "fields"}, cleared),
             (GraphqlTestKit.valueAt(List#{"restoreVersion", "version"}, restored) == Value.Int(versionAfterPublish + 3), GraphqlTestKit.valueAt(List#{"restoreVersion", "fields"}, restored)),
             fst(fetched) == Value.Obj(Map#{
                 "entry" => Value.Obj(Map#{ "id" => Value.Str(entryId), "stage" => Value.Str("CHANGED"), "versions" => Value.List(Value.Obj(Map#{ "reason" => Value.Str("SAVE") }) :: Value.Obj(Map#{ "reason" => Value.Str("PUBLISH") }) :: Nil) }),
                 "entries" => Value.Obj(Map#{ "totalCount" => Value.Int(1), "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str(entryId) }) :: Nil) }) })),
             ((GraphqlTestKit.stringAt(List#{"schedulePublish", "entryId"}, scheduled) == entryId, GraphqlTestKit.valueAt(List#{"schedulePublish", "action"}, scheduled), GraphqlTestKit.valueAt(List#{"schedulePublish", "withDependencies"}, scheduled), GraphqlTestKit.valueAt(List#{"schedulePublish", "status"}, scheduled), GraphqlTestKit.valueAt(List#{"schedulePublish", "requestedBy"}, scheduled), GraphqlTestKit.valueAt(List#{"schedulePublish", "lastError"}, scheduled), GraphqlTestKit.valueAt(List#{"schedulePublish", "overdue"}, scheduled), GraphqlTestKit.valueAt(List#{"schedulePublish", "doneAt"}, scheduled)),
             (GraphqlTestKit.valueAt(List#{"scheduleUnpublish", "action"}, unpublishScheduled), GraphqlTestKit.valueAt(List#{"scheduleUnpublish", "status"}, unpublishScheduled), GraphqlTestKit.valueAt(List#{"scheduleUnpublish", "overdue"}, unpublishScheduled)),
             fst(schedulesListed),
             fst(cancelled) == Value.Obj(Map#{ "cancelSchedule" => Value.Obj(Map#{ "id" => Value.Str(unpublishScheduleId), "status" => Value.Str("CANCELLED"), "overdue" => Value.Bool(false) }) }),
             (String.startsWith(prefix = "pv_", GraphqlTestKit.stringAt(List#{"createPreviewToken", "token"}, preview)), GraphqlTestKit.stringAt(List#{"createPreviewToken", "entryId"}, preview) == entryId, GraphqlTestKit.valueAt(List#{"createPreviewToken", "url"}, preview)),
             fst(unpublished),
             GraphqlTestKit.stringAt(List#{"deleteEntry"}, deleted) == entryId,
             fst(afterDelete)))
        });
        Assert.assertEq(
            expected = (((
                true,
                (true, Value.Int(1), Value.Str("DRAFT"), Value.Obj(Map#{ "title" => Value.Str("a"), "body" => Value.Str("x") }), Value.Null, Value.List(Nil)),
                Value.Obj(Map#{
                    "publishCheck" => Value.Obj(Map#{ "ok" => Value.Bool(true), "violations" => Value.List(Nil), "unpublishedDependencies" => Value.List(Nil) }),
                    "impact" => Value.Obj(Map#{ "breaks" => Value.List(Nil), "cascades" => Value.List(Nil) }) }),
                (Value.Str("PUBLISHED"), Value.List(Value.Obj(Map#{ "reason" => Value.Str("PUBLISH"), "author" => Value.Str("owner@test") }) :: Nil)),
                (true, Value.Str("CHANGED"), Value.Obj(Map#{ "title" => Value.Str("a"), "body" => Value.Str("y") })),
                (true, Value.Str("SAVE"), Value.Obj(Map#{ "title" => Value.Str("a"), "body" => Value.Str("y") })),
                Value.Obj(Map#{ "title" => Value.Str("a") }),
                (true, Value.Obj(Map#{ "title" => Value.Str("a"), "body" => Value.Str("y") })),
                true),
                ((true, Value.Str("PUBLISH"), Value.Bool(false), Value.Str("PENDING"), Value.Str("owner@test"), Value.Str(""), Value.Bool(true), Value.Null),
                (Value.Str("UNPUBLISH"), Value.Str("PENDING"), Value.Bool(false)),
                Value.Obj(Map#{ "schedules" => Value.List(
                    Value.Obj(Map#{ "action" => Value.Str("UNPUBLISH"), "status" => Value.Str("PENDING"), "overdue" => Value.Bool(false) }) ::
                    Value.Obj(Map#{ "action" => Value.Str("PUBLISH"), "status" => Value.Str("PENDING"), "overdue" => Value.Bool(true) }) :: Nil) }),
                true,
                (true, true, Value.Null),
                Value.Obj(Map#{ "unpublishEntry" => Value.Obj(Map#{ "stage" => Value.Str("DRAFT"), "publishedAt" => Value.Null }) }),
                true,
                Value.Obj(Map#{ "entry" => Value.Null, "entries" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) }))),
                Nil),
            (outcome, Ref.get(errors)))

    ///
    /// asset の mutation。署名付き URL を発行し（fileName は安全な形 "photo-x.png" に直る）、MinIO へ本当に PUT し、confirm で READY になり、alt を直し、一覧と 1 件で読め、消せる。
    ///
    ///   createUploadUrl ─ PUT ─ confirmAsset ─ updateAsset ─ assets / asset ─ deleteAsset
    ///
    @Test
    def testPgAdminAssetMutations(): Unit \ {IO, Assert} =
        let errors = Ref.fresh(Static, Nil);
        let outcome = PgTestSupport.withAdminApi(() -> (), (schema, _) -> {
            let ask = recording(PgTestSupport.askOwner(schema), errors);
            let upload = ask("mutation { createUploadUrl(input: { fileName: \"photo x.png\", mime: \"image/png\", size: 5 }) { asset { id status fileName mime size width alt } uploadUrl expiresInSeconds } }");
            let assetId = GraphqlTestKit.stringAt(List#{"createUploadUrl", "asset", "id"}, upload);
            let putStatus = PgTestSupport.putTo(GraphqlTestKit.stringAt(List#{"createUploadUrl", "uploadUrl"}, upload), "image/png", "hello");
            let confirmed = ask("mutation { confirmAsset(id: \"${assetId}\", input: { width: 10, height: 20, alt: \"写真\" }) { status size width height alt url createdAt usedBy { id } } }");
            let altChanged = ask("mutation { updateAsset(id: \"${assetId}\", input: { alt: \"表紙\" }) { id alt } }");
            let listed = ask("{ assets { totalCount nodes { id } } asset(id: \"${assetId}\") { alt status } }");
            let deleted = ask("mutation { deleteAsset(id: \"${assetId}\") }");
            let afterDelete = ask("{ assets { totalCount } asset(id: \"${assetId}\") { id } }");
            (String.length(assetId) > 0,
             (GraphqlTestKit.valueAt(List#{"createUploadUrl", "asset", "status"}, upload), GraphqlTestKit.valueAt(List#{"createUploadUrl", "asset", "fileName"}, upload), GraphqlTestKit.valueAt(List#{"createUploadUrl", "asset", "mime"}, upload), GraphqlTestKit.valueAt(List#{"createUploadUrl", "asset", "size"}, upload), GraphqlTestKit.valueAt(List#{"createUploadUrl", "asset", "width"}, upload), GraphqlTestKit.valueAt(List#{"createUploadUrl", "expiresInSeconds"}, upload)),
             putStatus,
             (GraphqlTestKit.valueAt(List#{"confirmAsset", "status"}, confirmed), GraphqlTestKit.valueAt(List#{"confirmAsset", "size"}, confirmed), GraphqlTestKit.valueAt(List#{"confirmAsset", "width"}, confirmed), GraphqlTestKit.valueAt(List#{"confirmAsset", "height"}, confirmed), GraphqlTestKit.valueAt(List#{"confirmAsset", "alt"}, confirmed), GraphqlTestKit.valueAt(List#{"confirmAsset", "usedBy"}, confirmed)),
             GraphqlTestKit.stringAt(List#{"confirmAsset", "url"}, confirmed) == "http://127.0.0.1:9000/cms/1/${assetId}/photo-x.png",
             fst(altChanged) == Value.Obj(Map#{ "updateAsset" => Value.Obj(Map#{ "id" => Value.Str(assetId), "alt" => Value.Str("表紙") }) }),
             fst(listed) == Value.Obj(Map#{ "assets" => Value.Obj(Map#{ "totalCount" => Value.Int(1), "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str(assetId) }) :: Nil) }), "asset" => Value.Obj(Map#{ "alt" => Value.Str("表紙"), "status" => Value.Str("READY") }) }),
             GraphqlTestKit.stringAt(List#{"deleteAsset"}, deleted) == assetId,
             fst(afterDelete))
        });
        Assert.assertEq(
            expected = ((
                true,
                (Value.Str("PENDING"), Value.Str("photo-x.png"), Value.Str("image/png"), Value.Int(5), Value.Null, Value.Int(600)),
                Ok(200),
                (Value.Str("READY"), Value.Int(5), Value.Int(10), Value.Int(20), Value.Str("写真"), Value.List(Nil)),
                true,
                true,
                true,
                true,
                Value.Obj(Map#{ "assets" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }), "asset" => Value.Null })),
                Nil),
            (outcome, Ref.get(errors)))

    ///
    /// プロジェクトの mutation。公開範囲・招待（受けた人は初回ログインでメンバーになる）・役割の変更・除名・API キー。
    ///
    ///   me ─ updateProjectVisibility ─ inviteMember ×2 ─ invitations ─ cancelInvitation(bob)
    ///     └ alice がログイン ─ members ─ changeMemberRole(alice) ─ removeMember(alice)
    ///     └ createApiKey ─ apiKeys ─ revokeApiKey
    ///
    @Test
    def testPgAdminProjectMutations(): Unit \ {IO, Assert} =
        let errors = Ref.fresh(Static, Nil);
        let outcome = PgTestSupport.withAdminApi(() -> (), (schema, _) -> {
            let ask = recording(PgTestSupport.askOwner(schema), errors);
            let alice = recording(queryText -> GraphqlTestKit.askWith(schema, Context.withCredential(Credential.Bearer("test", "alice", "alice@example.com", "Alice")), queryText), errors);
            let me = ask("{ me { email name roles } }");
            let visibility = ask("mutation { updateProjectVisibility(visibility: PRIVATE) { slug name visibility } }");
            let invitedAlice = ask("mutation { inviteMember(email: \"alice@example.com\", role: EDITOR) { id email role createdAt } }");
            let invitedBob = ask("mutation { inviteMember(email: \"bob@example.com\", role: VIEWER) { id } }");
            let bobInvitationId = GraphqlTestKit.stringAt(List#{"inviteMember", "id"}, invitedBob);
            let invitations = ask("{ invitations { email role } }");
            let bobCancelled = ask("mutation { cancelInvitation(id: \"${bobInvitationId}\") }");
            let aliceMe = alice("{ me { id email roles } }");
            let aliceId = GraphqlTestKit.stringAt(List#{"me", "id"}, aliceMe);
            let members = ask("{ members { userId email name role } }");
            let roleChanged = ask("mutation { changeMemberRole(userId: \"${aliceId}\", role: WRITER) { userId email role } }");
            let removed = ask("mutation { removeMember(userId: \"${aliceId}\") }");
            let membersAfter = ask("{ members { email } invitations { email } }");
            let issued = ask("mutation { createApiKey(name: \"site\", scope: READ) { id name scope key } }");
            let keyId = GraphqlTestKit.stringAt(List#{"createApiKey", "id"}, issued);
            let keys = ask("{ apiKeys { id name scope revokedAt } }");
            let revoked = ask("mutation { revokeApiKey(id: \"${keyId}\") }");
            let keysAfter = ask("{ apiKeys { name createdAt expiresAt revokedAt } }");
            (fst(me),
             fst(visibility),
             (GraphqlTestKit.valueAt(List#{"inviteMember", "email"}, invitedAlice), GraphqlTestKit.valueAt(List#{"inviteMember", "role"}, invitedAlice)),
             fst(invitations),
             GraphqlTestKit.stringAt(List#{"cancelInvitation"}, bobCancelled) == bobInvitationId,
             (GraphqlTestKit.valueAt(List#{"me", "email"}, aliceMe), GraphqlTestKit.valueAt(List#{"me", "roles"}, aliceMe)),
             fst(members) == Value.Obj(Map#{ "members" => Value.List(Value.Obj(Map#{ "userId" => Value.Str(aliceId), "email" => Value.Str("alice@example.com"), "name" => Value.Str("Alice"), "role" => Value.Str("EDITOR") }) :: Nil) }),
             fst(roleChanged) == Value.Obj(Map#{ "changeMemberRole" => Value.Obj(Map#{ "userId" => Value.Str(aliceId), "email" => Value.Str("alice@example.com"), "role" => Value.Str("WRITER") }) }),
             GraphqlTestKit.stringAt(List#{"removeMember"}, removed) == aliceId,
             fst(membersAfter),
             (GraphqlTestKit.valueAt(List#{"createApiKey", "name"}, issued), GraphqlTestKit.valueAt(List#{"createApiKey", "scope"}, issued), String.startsWith(prefix = "cms_", GraphqlTestKit.stringAt(List#{"createApiKey", "key"}, issued))),
             fst(keys) == Value.Obj(Map#{ "apiKeys" => Value.List(Value.Obj(Map#{ "id" => Value.Str(keyId), "name" => Value.Str("site"), "scope" => Value.Str("READ"), "revokedAt" => Value.Null }) :: Nil) }),
             GraphqlTestKit.stringAt(List#{"revokeApiKey"}, revoked) == keyId,
             GraphqlTestKit.listAt(List#{"apiKeys"}, keysAfter) |> List.map(key -> (Value.field("name", key), Value.field("revokedAt", key) != Value.Null)))
        });
        Assert.assertEq(
            expected = ((
                Value.Obj(Map#{ "me" => Value.Obj(Map#{ "email" => Value.Str("owner@test"), "name" => Value.Str("Owner"), "roles" => Value.List(Value.Str("OWNER") :: Nil) }) }),
                Value.Obj(Map#{ "updateProjectVisibility" => Value.Obj(Map#{ "slug" => Value.Str("default"), "name" => Value.Str("default"), "visibility" => Value.Str("PRIVATE") }) }),
                (Value.Str("alice@example.com"), Value.Str("EDITOR")),
                Value.Obj(Map#{ "invitations" => Value.List(Value.Obj(Map#{ "email" => Value.Str("alice@example.com"), "role" => Value.Str("EDITOR") }) :: Value.Obj(Map#{ "email" => Value.Str("bob@example.com"), "role" => Value.Str("VIEWER") }) :: Nil) }),
                true,
                (Value.Str("alice@example.com"), Value.List(Value.Str("EDITOR") :: Nil)),
                true,
                true,
                true,
                Value.Obj(Map#{ "members" => Value.List(Nil), "invitations" => Value.List(Nil) }),
                (Value.Str("site"), Value.Str("READ"), true),
                true,
                true,
                List#{ (Value.Str("site"), true) }),
                Nil),
            (outcome, Ref.get(errors)))

}
