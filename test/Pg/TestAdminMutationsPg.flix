///
/// 管理 API（admin.graphql）の全 Mutation と全 Query を、GraphQL のリゾルバ越しに実 PostgreSQL と MinIO で 1 度ずつ通す。
/// ユースケースを直に呼ぶテストでは見えない、リゾルバ・AdminMapping・graphql-java の境界の不具合（型の写し漏れ・ラムダの VerifyError）を拾う。
/// id は前の応答から取り、決め打ちしない。
///
mod TestAdminMutationsPg {

    use Net.HttpRequest
    use Net.HttpResponse

    /// 応答の data から文字列（id など）を取る。無ければ空。
    def strIn(path: List[String], response: (Value, Option[String])): String =
        Value.path(path, fst(response)) |> Value.asStr |> Option.getWithDefault("")

    /// 応答の data から Int を取る。無ければ -1。
    def intIn(path: List[String], response: (Value, Option[String])): Int32 =
        Value.path(path, fst(response)) |> Value.asInt |> Option.getWithDefault(-1)

    /// 応答の data から配列を取る。配列でなければ空。
    def listIn(path: List[String], response: (Value, Option[String])): List[Value] = match Value.path(path, fst(response)) {
        case Value.List(items) => items
        case _                 => Nil
    }

    /// 応答の data の一部を切り出す（期待値との比較用）。
    def dataIn(path: List[String], response: (Value, Option[String])): Value =
        Value.path(path, fst(response))

    /// 応答の errors の先頭を errors に積みつつ、そのまま返す ask。期待しないエラーは最後にまとめて見る。
    def recording(ask: String -> (Value, Option[String]) \ IO, errors: Ref[List[String], Static]): String -> (Value, Option[String]) \ IO =
        queryText -> {
            let response = ask(queryText);
            Option.forEach(message -> Ref.put(message :: Ref.get(errors), errors), snd(response));
            response
        }

    /// 署名付き URL へ置く。宣言した Content-Type で送る。成功なら status。
    def putTo(url: String, mime: String, body: String): Result[String, Int32] \ IO =
        Net.Http.runWithIO(() ->
            Net.Http.send(HttpRequest.put(url, body) |> HttpRequest.withContentType(mime))
                |> Result.map(HttpResponse.status)
                |> Result.mapErr(err -> "${err}"))

    /// blogs 型を作り、title（required）と body を足す。戻り値は (typeId, titleId, bodyId)。
    def createBlogs(ask: String -> (Value, Option[String]) \ IO): (String, String, String) \ IO =
        let typeId = strIn(List#{"createContentType", "id"}, ask("mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id } }"));
        let titleId = strIn(List#{"addField", "id"}, ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"title\", name: \"題名\", kind: TEXT, required: true }) { id } }"));
        let bodyId = strIn(List#{"addField", "id"}, ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"body\", name: \"本文\", kind: TEXT_AREA }) { id } }"));
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
            let webhookCreated = ask("mutation { createWebhook(input: { name: \"site\", url: \"https://example.com/hook\", events: [SCHEMA_CHANGED] }) { webhook { id name events active } secret } }");
            let webhookId = strIn(List#{"createWebhook", "webhook", "id"}, webhookCreated);
            let typeCreated = ask("mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id apiId kind name singular plural previewUrl fields { id } } }");
            let typeId = strIn(List#{"createContentType", "id"}, typeCreated);
            let titleAdded = ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"title\", name: \"題名\", kind: TEXT, required: true }) { id apiId kind many required unique localized targetTypeId parentFieldId position children { id } config { maxLength } } }");
            let titleId = strIn(List#{"addField", "id"}, titleAdded);
            let bodyId = strIn(List#{"addField", "id"}, ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"body\", name: \"本文\", kind: TEXT_AREA }) { id } }"));
            let tagId = strIn(List#{"addField", "id"}, ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"tag\", name: \"タグ\", kind: TEXT }) { id } }"));
            let fieldUpdated = ask("mutation { updateField(id: \"${titleId}\", input: { name: \"タイトル\", config: { maxLength: 50 } }) { name required config { maxLength } } }");
            let fieldRemoved = ask("mutation { removeField(id: \"${tagId}\") }");
            let reordered = ask("mutation { reorderFields(typeId: \"${typeId}\", ids: [\"${bodyId}\", \"${titleId}\"]) { fields { apiId position } } }");
            let typeUpdated = ask("mutation { updateContentType(id: \"${typeId}\", input: { name: \"ブログ\", previewUrl: \"https://example.com/{id}\" }) { name previewUrl } }");
            let listed = ask("{ contentTypes { apiId } contentType(id: \"${typeId}\") { apiId } byApiId: contentType(apiId: \"blogs\") { id } }");
            let webhooksListed = ask("{ webhooks { id name events active } }");
            let webhookUpdated = ask("mutation { updateWebhook(id: \"${webhookId}\", input: { name: \"site2\", url: \"https://example.com/hook2\", events: [SCHEMA_CHANGED, ENTRY_PUBLISHED], active: true }) { name url events active } }");
            let deliveries = ask("{ webhookDeliveries(webhookId: \"${webhookId}\") { id event status attempts nextAttemptAt lastStatus lastError createdAt deliveredAt } }");
            let deliveryId = listIn(List#{"webhookDeliveries"}, deliveries) |> List.head |> Option.map(Value.field("id")) |> Option.flatMap(Value.asStr) |> Option.getWithDefault("");
            let redelivered = ask("mutation { redeliverWebhook(deliveryId: \"${deliveryId}\") { id event status attempts } }");
            let webhookDeleted = ask("mutation { deleteWebhook(id: \"${webhookId}\") }");
            let typeDeleted = ask("mutation { deleteContentType(id: \"${typeId}\") }");
            let afterDelete = ask("{ contentTypes { id } webhooks { id } }");
            ((String.startsWith(prefix = "whsec_", strIn(List#{"createWebhook", "secret"}, webhookCreated)),
             dataIn(List#{"createWebhook", "webhook", "events"}, webhookCreated),
             (dataIn(List#{"createContentType", "apiId"}, typeCreated), dataIn(List#{"createContentType", "kind"}, typeCreated), dataIn(List#{"createContentType", "singular"}, typeCreated), dataIn(List#{"createContentType", "plural"}, typeCreated), dataIn(List#{"createContentType", "previewUrl"}, typeCreated), dataIn(List#{"createContentType", "fields"}, typeCreated)),
             (dataIn(List#{"addField", "apiId"}, titleAdded), dataIn(List#{"addField", "kind"}, titleAdded), dataIn(List#{"addField", "required"}, titleAdded), dataIn(List#{"addField", "many"}, titleAdded), dataIn(List#{"addField", "position"}, titleAdded), dataIn(List#{"addField", "children"}, titleAdded), dataIn(List#{"addField", "config"}, titleAdded)),
             fst(fieldUpdated),
             strIn(List#{"removeField"}, fieldRemoved) == tagId,
             fst(reordered),
             fst(typeUpdated)),
             ((dataIn(List#{"contentTypes"}, listed), dataIn(List#{"contentType"}, listed), strIn(List#{"byApiId", "id"}, listed) == typeId),
             fst(webhooksListed) == Value.Obj(Map#{ "webhooks" => Value.List(Value.Obj(Map#{ "id" => Value.Str(webhookId), "name" => Value.Str("site"), "events" => Value.List(Value.Str("SCHEMA_CHANGED") :: Nil), "active" => Value.Bool(true) }) :: Nil) }),
             fst(webhookUpdated),
             (List.length(listIn(List#{"webhookDeliveries"}, deliveries)), listIn(List#{"webhookDeliveries"}, deliveries) |> List.head |> Option.map(delivery -> (Value.field("event", delivery), Value.field("status", delivery), Value.field("attempts", delivery), Value.field("lastStatus", delivery), Value.field("deliveredAt", delivery)))),
             fst(redelivered) == Value.Obj(Map#{ "redeliverWebhook" => Value.Obj(Map#{ "id" => Value.Str(deliveryId), "event" => Value.Str("SCHEMA_CHANGED"), "status" => Value.Str("PENDING"), "attempts" => Value.Int(0) }) }),
             strIn(List#{"deleteWebhook"}, webhookDeleted) == webhookId,
             strIn(List#{"deleteContentType"}, typeDeleted) == typeId,
             fst(afterDelete)))
        });
        Assert.assertEq(
            expected = (((
                true,
                Value.List(Value.Str("SCHEMA_CHANGED") :: Nil),
                (Value.Str("blogs"), Value.Str("COLLECTION"), Value.Str("Blog"), Value.Str("blogs"), Value.Null, Value.List(Nil)),
                (Value.Str("title"), Value.Str("TEXT"), Value.Bool(true), Value.Bool(false), Value.Int(0), Value.List(Nil), Value.Obj(Map#{ "maxLength" => Value.Null })),
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
            let entryId = strIn(List#{"createEntry", "id"}, created);
            let checked = ask("{ publishCheck(id: \"${entryId}\") { ok violations { path message } unpublishedDependencies { id } } impact(id: \"${entryId}\", action: PUBLISH) { breaks { via stage entry { id } } cascades { id } } }");
            let published = ask("mutation { publishEntry(id: \"${entryId}\") { version stage versions { reason author } } }");
            let versionAfterPublish = intIn(List#{"publishEntry", "version"}, published);
            let updated = ask("mutation { updateEntry(id: \"${entryId}\", fields: { body: \"y\" }, expectedVersion: ${versionAfterPublish}) { version stage fields } }");
            let saved = ask("mutation { saveVersion(id: \"${entryId}\") { id version reason author fields createdAt } }");
            let versionId = strIn(List#{"saveVersion", "id"}, saved);
            let cleared = ask("mutation { updateEntry(id: \"${entryId}\", fields: { body: null }, expectedVersion: ${versionAfterPublish + 1}) { version fields } }");
            let restored = ask("mutation { restoreVersion(id: \"${entryId}\", versionId: \"${versionId}\", expectedVersion: ${versionAfterPublish + 2}) { version fields } }");
            let fetched = ask("{ entry(id: \"${entryId}\") { id stage versions { reason } } entries(typeId: \"${typeId}\", search: \"a\") { totalCount nodes { id } } }");
            let scheduled = ask("mutation { schedulePublish(entryId: \"${entryId}\", at: \"2020-01-01T00:00:00Z\") { id entryId action runAt withDependencies status requestedBy lastError overdue createdAt doneAt } }");
            let unpublishScheduled = ask("mutation { scheduleUnpublish(entryId: \"${entryId}\", at: \"2100-01-01T00:00:00Z\") { id action status overdue } }");
            let unpublishScheduleId = strIn(List#{"scheduleUnpublish", "id"}, unpublishScheduled);
            let schedulesListed = ask("{ schedules(entryId: \"${entryId}\") { action status overdue } }");
            let cancelled = ask("mutation { cancelSchedule(id: \"${unpublishScheduleId}\") { id status overdue } }");
            let preview = ask("mutation { createPreviewToken(entryId: \"${entryId}\") { token entryId expiresAt url } }");
            let unpublished = ask("mutation { unpublishEntry(id: \"${entryId}\") { stage publishedAt } }");
            let deleted = ask("mutation { deleteEntry(id: \"${entryId}\") }");
            let afterDelete = ask("{ entry(id: \"${entryId}\") { id } entries(typeId: \"${typeId}\") { totalCount } }");
            ((String.length(entryId) > 0,
             (strIn(List#{"createEntry", "typeId"}, created) == typeId, dataIn(List#{"createEntry", "version"}, created), dataIn(List#{"createEntry", "stage"}, created), dataIn(List#{"createEntry", "fields"}, created), dataIn(List#{"createEntry", "publishedAt"}, created), dataIn(List#{"createEntry", "versions"}, created)),
             fst(checked),
             (dataIn(List#{"publishEntry", "stage"}, published), dataIn(List#{"publishEntry", "versions"}, published)),
             (dataIn(List#{"updateEntry", "version"}, updated) == Value.Int(versionAfterPublish + 1), dataIn(List#{"updateEntry", "stage"}, updated), dataIn(List#{"updateEntry", "fields"}, updated)),
             (dataIn(List#{"saveVersion", "version"}, saved) == Value.Int(versionAfterPublish + 1), dataIn(List#{"saveVersion", "reason"}, saved), dataIn(List#{"saveVersion", "fields"}, saved)),
             dataIn(List#{"updateEntry", "fields"}, cleared),
             (dataIn(List#{"restoreVersion", "version"}, restored) == Value.Int(versionAfterPublish + 3), dataIn(List#{"restoreVersion", "fields"}, restored)),
             fst(fetched) == Value.Obj(Map#{
                 "entry" => Value.Obj(Map#{ "id" => Value.Str(entryId), "stage" => Value.Str("CHANGED"), "versions" => Value.List(Value.Obj(Map#{ "reason" => Value.Str("SAVE") }) :: Value.Obj(Map#{ "reason" => Value.Str("PUBLISH") }) :: Nil) }),
                 "entries" => Value.Obj(Map#{ "totalCount" => Value.Int(1), "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str(entryId) }) :: Nil) }) })),
             ((strIn(List#{"schedulePublish", "entryId"}, scheduled) == entryId, dataIn(List#{"schedulePublish", "action"}, scheduled), dataIn(List#{"schedulePublish", "withDependencies"}, scheduled), dataIn(List#{"schedulePublish", "status"}, scheduled), dataIn(List#{"schedulePublish", "requestedBy"}, scheduled), dataIn(List#{"schedulePublish", "lastError"}, scheduled), dataIn(List#{"schedulePublish", "overdue"}, scheduled), dataIn(List#{"schedulePublish", "doneAt"}, scheduled)),
             (dataIn(List#{"scheduleUnpublish", "action"}, unpublishScheduled), dataIn(List#{"scheduleUnpublish", "status"}, unpublishScheduled), dataIn(List#{"scheduleUnpublish", "overdue"}, unpublishScheduled)),
             fst(schedulesListed),
             fst(cancelled) == Value.Obj(Map#{ "cancelSchedule" => Value.Obj(Map#{ "id" => Value.Str(unpublishScheduleId), "status" => Value.Str("CANCELLED"), "overdue" => Value.Bool(false) }) }),
             (String.startsWith(prefix = "pv_", strIn(List#{"createPreviewToken", "token"}, preview)), strIn(List#{"createPreviewToken", "entryId"}, preview) == entryId, dataIn(List#{"createPreviewToken", "url"}, preview)),
             fst(unpublished),
             strIn(List#{"deleteEntry"}, deleted) == entryId,
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
            let assetId = strIn(List#{"createUploadUrl", "asset", "id"}, upload);
            let putStatus = putTo(strIn(List#{"createUploadUrl", "uploadUrl"}, upload), "image/png", "hello");
            let confirmed = ask("mutation { confirmAsset(id: \"${assetId}\", input: { width: 10, height: 20, alt: \"写真\" }) { status size width height alt url createdAt usedBy { id } } }");
            let altChanged = ask("mutation { updateAsset(id: \"${assetId}\", input: { alt: \"表紙\" }) { id alt } }");
            let listed = ask("{ assets { totalCount nodes { id } } asset(id: \"${assetId}\") { alt status } }");
            let deleted = ask("mutation { deleteAsset(id: \"${assetId}\") }");
            let afterDelete = ask("{ assets { totalCount } asset(id: \"${assetId}\") { id } }");
            (String.length(assetId) > 0,
             (dataIn(List#{"createUploadUrl", "asset", "status"}, upload), dataIn(List#{"createUploadUrl", "asset", "fileName"}, upload), dataIn(List#{"createUploadUrl", "asset", "mime"}, upload), dataIn(List#{"createUploadUrl", "asset", "size"}, upload), dataIn(List#{"createUploadUrl", "asset", "width"}, upload), dataIn(List#{"createUploadUrl", "expiresInSeconds"}, upload)),
             putStatus,
             (dataIn(List#{"confirmAsset", "status"}, confirmed), dataIn(List#{"confirmAsset", "size"}, confirmed), dataIn(List#{"confirmAsset", "width"}, confirmed), dataIn(List#{"confirmAsset", "height"}, confirmed), dataIn(List#{"confirmAsset", "alt"}, confirmed), dataIn(List#{"confirmAsset", "usedBy"}, confirmed)),
             strIn(List#{"confirmAsset", "url"}, confirmed) == "http://127.0.0.1:9000/cms/1/${assetId}/photo-x.png",
             fst(altChanged) == Value.Obj(Map#{ "updateAsset" => Value.Obj(Map#{ "id" => Value.Str(assetId), "alt" => Value.Str("表紙") }) }),
             fst(listed) == Value.Obj(Map#{ "assets" => Value.Obj(Map#{ "totalCount" => Value.Int(1), "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str(assetId) }) :: Nil) }), "asset" => Value.Obj(Map#{ "alt" => Value.Str("表紙"), "status" => Value.Str("READY") }) }),
             strIn(List#{"deleteAsset"}, deleted) == assetId,
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
            let bobInvitationId = strIn(List#{"inviteMember", "id"}, invitedBob);
            let invitations = ask("{ invitations { email role } }");
            let bobCancelled = ask("mutation { cancelInvitation(id: \"${bobInvitationId}\") }");
            let aliceMe = alice("{ me { id email roles } }");
            let aliceId = strIn(List#{"me", "id"}, aliceMe);
            let members = ask("{ members { userId email name role } }");
            let roleChanged = ask("mutation { changeMemberRole(userId: \"${aliceId}\", role: WRITER) { userId email role } }");
            let removed = ask("mutation { removeMember(userId: \"${aliceId}\") }");
            let membersAfter = ask("{ members { email } invitations { email } }");
            let issued = ask("mutation { createApiKey(name: \"site\", scope: READ) { id name scope key } }");
            let keyId = strIn(List#{"createApiKey", "id"}, issued);
            let keys = ask("{ apiKeys { id name scope revokedAt } }");
            let revoked = ask("mutation { revokeApiKey(id: \"${keyId}\") }");
            let keysAfter = ask("{ apiKeys { name revokedAt } }");
            (fst(me),
             fst(visibility),
             (dataIn(List#{"inviteMember", "email"}, invitedAlice), dataIn(List#{"inviteMember", "role"}, invitedAlice)),
             fst(invitations),
             strIn(List#{"cancelInvitation"}, bobCancelled) == bobInvitationId,
             (dataIn(List#{"me", "email"}, aliceMe), dataIn(List#{"me", "roles"}, aliceMe)),
             fst(members) == Value.Obj(Map#{ "members" => Value.List(Value.Obj(Map#{ "userId" => Value.Str(aliceId), "email" => Value.Str("alice@example.com"), "name" => Value.Str("Alice"), "role" => Value.Str("EDITOR") }) :: Nil) }),
             fst(roleChanged) == Value.Obj(Map#{ "changeMemberRole" => Value.Obj(Map#{ "userId" => Value.Str(aliceId), "email" => Value.Str("alice@example.com"), "role" => Value.Str("WRITER") }) }),
             strIn(List#{"removeMember"}, removed) == aliceId,
             fst(membersAfter),
             (dataIn(List#{"createApiKey", "name"}, issued), dataIn(List#{"createApiKey", "scope"}, issued), String.startsWith(prefix = "cms_", strIn(List#{"createApiKey", "key"}, issued))),
             fst(keys) == Value.Obj(Map#{ "apiKeys" => Value.List(Value.Obj(Map#{ "id" => Value.Str(keyId), "name" => Value.Str("site"), "scope" => Value.Str("READ"), "revokedAt" => Value.Null }) :: Nil) }),
             strIn(List#{"revokeApiKey"}, revoked) == keyId,
             listIn(List#{"apiKeys"}, keysAfter) |> List.map(key -> (Value.field("name", key), Value.field("revokedAt", key) != Value.Null)))
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
