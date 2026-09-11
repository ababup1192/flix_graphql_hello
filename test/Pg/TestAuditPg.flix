///
/// 監査の記録を実 PostgreSQL で通す。操作ごとに 1 行積まれるか、失敗した操作の記録が残らないか、後から書き換えられないか。
///
mod TestAuditPg {

    use Util.Json.Json

    /// 積まれた記録の action を古い順に。
    def actions(): List[String] \ DbRead + Tenant + CmsErr + Session =
        Audit.latest(Session.grant(), 50i64) |> List.map(found -> found#action) |> List.reverse

    /// 積まれた記録の対象を古い順に。
    def targets(): List[String] \ DbRead + Tenant + CmsErr + Session =
        Audit.latest(Session.grant(), 50i64) |> List.map(found -> found#targetId) |> List.reverse

    ///
    /// 型とフィールドを触ると、操作ごとに 1 行ずつ積まれる。
    ///
    ///   型を作る → フィールドを足す → フィールドを直す → 並べ替え → フィールドを消す → 型を消す
    ///
    @Test
    def testPgAuditRecordsTypeChanges(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            let title = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            discard ContentTypes.updateField(Session.grant(), title#id, { name = None, required = Some(true), unique = None, localized = None, config = None });
            discard ContentTypes.reorderFields(Session.grant(), blogs#id, List#{title#id});
            ContentTypes.removeField(Session.grant(), title#id);
            ContentTypes.delete(Session.grant(), blogs#id);
            (actions(), targets())
        });
        Assert.assertEq(expected = Ok(Ok((
            List#{"type.created", "field.added", "field.updated", "fields.reordered", "field.removed", "type.deleted"},
            List#{"blogs", "blogs.title", "blogs.title", "blogs", "blogs.title", "blogs"}))), result)

    ///
    /// 主体は版の author と同じ形（この Tx は System として走る）。
    ///
    @Test
    def testPgAuditKeepsActor(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            discard ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            Audit.latest(Session.grant(), 1i64) |> List.map(found -> found#actor)
        });
        Assert.assertEq(expected = Ok(Ok(List#{"system"})), result)

    ///
    /// メンバーと鍵の変更も 1 行ずつ積まれる。owner として招待 → 役割の変更 → 外す、鍵の発行 → 失効。
    ///
    /// WhyNot: System ではなく owner として走らせるのは、招待が招いた人（`Session.currentUser()`）を要求し、
    /// System には人の id が無いため。
    ///
    @Test
    def testPgAuditRecordsMemberAndKeyChanges(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> PgTestSupport.asOwner(() -> {
            discard Members.invite(Session.grant(), "editor@test.dev", Role.Editor);
            let issued = ApiKeys.create(Session.grant(), Session.grantInteractive(), PgTestSupport.pepper(), { name = "CI", scope = ApiKeyScope.Read, expiresAt = None }, 0i64);
            ApiKeys.revoke(Session.grant(), issued#publicId);
            // 鍵の 2 行は発行した鍵の公開 id を指す（公開 id は乱数なので、値ではなく一致で見る）
            (actions(), targets() == List#{"editor@test.dev", issued#publicId, issued#publicId})
        }));
        Assert.assertEq(expected = Ok(Ok((
            List#{"member.invited", "api_key.created", "api_key.revoked"}, true))), result)

    ///
    /// 人の行は actorKind が user、actorId が users.public_id（内部の連番ではない）、actor が email。
    ///
    @Test
    def testPgAuditPersonRowHasPublicId(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let owner = PgTestSupport.ownerUser();
            PgTestSupport.runAs(owner, () -> discard ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事")));
            Audit.latest(Session.grant(), 1i64)
                |> List.map(found -> (found#actorKind, found#actorId == owner#publicId, found#actorId == "${owner#id}", found#actor))
        });
        Assert.assertEq(expected = Ok(Ok(List#{(ActorKind.User, true, false, "owner@test")})), result)

    ///
    /// 型を直すと type.updated が積まれる（作る・消す以外の道も通る）。
    ///
    @Test
    def testPgAuditRecordsTypeUpdate(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.update(Session.grant(), blogs#id, { name = Some("ブログ"), singular = None, plural = None, previewUrl = None, linkPath = None, icon = None });
            actions()
        });
        Assert.assertEq(expected = Ok(Ok(List#{"type.created", "type.updated"})), result)

    ///
    /// 失敗した操作は記録も残らない。entry が残っている型を消そうとすると invalid になり、
    /// 同じ Tx なので type.deleted の行も一緒に ROLLBACK される。
    ///
    @Test
    def testPgAuditRollsBackWithTheChange(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let typeId = PgTestSupport.seed(() -> {
                let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
                discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
                discard ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("こんにちは"))}));
                blogs#id
            });
            let refused = PgTestSupport.mutate(pool, () -> ContentTypes.delete(Session.grant(), typeId)) |> Result.isOk;
            let recorded = PgTestSupport.mutateOrBug(pool, () -> actions());
            (refused, recorded)
        });
        Assert.assertEq(expected = (false, List#{"type.created", "field.added"}), outcome)

    ///
    /// 積んだ記録は書き換えられない（UPDATE と DELETE の policy が無い）。
    ///
    @Test
    def testPgAuditIsAppendOnly(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> discard ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事")));
            let updated = PgTestSupport.mutate(pool, () -> RawSql.runWithAllow(() -> Sql.execute("UPDATE audit_events SET actor = 'nobody'", Nil)));
            let deleted = PgTestSupport.mutate(pool, () -> RawSql.runWithAllow(() -> Sql.execute("DELETE FROM audit_events", Nil)));
            let remaining = PgTestSupport.mutateOrBug(pool, () -> actions());
            (updated |> Result.map(changed -> changed), deleted |> Result.map(changed -> changed), remaining)
        });
        Assert.assertEq(expected = (Ok(0), Ok(0), List#{"type.created"}), outcome)

    /// detail の中の文字列（無ければ "?"）。
    def detailText(path: List[String], detail: Json): String =
        Value.path(path, JsonValue.fromJson(detail)) |> Value.asStr |> Option.getWithDefault("?")

    ///
    /// Webhook を作って消すと、新しい順に webhook.deleted / webhook.created の 2 行。
    /// 消した行の before.url.urlHash は作った行の url.urlHash と同じで、元の URL の最後のセグメント（トークン）はどちらにも出ない。
    ///
    @Test
    def testPgAuditWebhookRoundTrip(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let issued = Webhooks.create(Session.grant(), { name = "Pages のデプロイ", url = "https://api.cloudflare.com/client/v4/pages/webhooks/deploy_hooks/8f3a1c9e2b47", events = List#{ WebhookEvent.EntryPublished }, active = true });
            Webhooks.delete(Session.grant(), issued#webhook#publicId);
            let rows = Audit.latest(Session.grant(), 10i64);
            let details = rows |> List.map(found -> Util.Json.toCompactString(found#detail));
            (rows |> List.map(found -> (found#action, found#targetId == issued#webhook#publicId)),
             rows |> List.map(found -> found#detail),
             details |> List.exists(text -> String.contains(substr = "8f3a1c9e2b47", text)))
        });
        let outcome = result |> Result.map(Result.map(match (actions, details, leaked) -> {
            let hashes = match details {
                case deleted :: created :: Nil => (detailText(List#{"before", "url", "urlHash"}, deleted), detailText(List#{"url", "urlHash"}, created))
                case _                         => ("?", "!")
            };
            (actions, fst(hashes) == snd(hashes), String.length(fst(hashes)), leaked)
        }));
        Assert.assertEq(expected = Ok(Ok((List#{("webhook.deleted", true), ("webhook.created", true)}, true, 12, false))), outcome)

    ///
    /// asset の confirm を 2 回呼んでも asset.confirmed は 1 行（pending → ready に変わった時だけ）。消すと asset.deleted。
    /// detail に fileName は出ない。
    ///
    @Test
    def testPgAuditAssetConfirmOnce(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"asset001"}, () -> {
            let upload = Assets.createUpload(Session.grant(), { fileName = "取引先の見積.png", mime = "image/png", size = 5i64 });
            discard PgTestSupport.putTo(upload#uploadUrl, "image/png", "hello");
            discard Assets.confirm(Session.grant(), upload#asset#id, { width = Some(10), height = Some(20), alt = None });
            discard Assets.confirm(Session.grant(), upload#asset#id, { width = Some(10), height = Some(20), alt = Some("写真") });
            Assets.delete(Session.grant(), upload#asset#id);
            let rows = Audit.latest(Session.grant(), 10i64);
            (rows |> List.map(found -> found#action),
             rows |> List.exists(found -> String.contains(substr = "見積", Util.Json.toCompactString(found#detail))))
        }));
        Assert.assertEq(expected = Ok(Ok((List#{"asset.deleted", "asset.confirmed"}, false))), result)

    ///
    /// entry を公開して取り下げて消すと、entry.unpublished と entry.deleted が積まれる（手での公開は積まない）。
    /// detail は型の apiId と版。消す時は公開中なら取り下げも通るので、取り下げ → 削除の 2 行。
    ///
    @Test
    def testPgAuditEntryUnpublishAndDelete(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"entry001"}, () -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            let entry = ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("こんにちは"))}));
            discard ContentEntries.publish(Session.grant(), entry#id, "someone", false);
            discard ContentEntries.unpublish(Session.grant(), entry#id);
            discard ContentEntries.publish(Session.grant(), entry#id, "someone", false);
            ContentEntries.delete(Session.grant(), Session.tryGrant(), entry#id);
            Audit.latest(Session.grant(), 10i64)
                |> List.filter(found -> found#targetKind == "entry")
                |> List.map(found -> (found#action, found#targetId, detailText(List#{"typeApiId"}, found#detail)))
        }));
        Assert.assertEq(expected = Ok(Ok(List#{("entry.deleted", "entry001", "blogs"), ("entry.unpublished", "entry001", "blogs"), ("entry.unpublished", "entry001", "blogs")})), result)

    ///
    /// 予約公開を tick が実行すると entry.published が積まれる。主体は system、detail に typeApiId / version / scheduledFor（予約の時刻）。
    /// 手での公開（`ContentEntries.publish`）は積まない。
    ///
    @Test
    def testPgAuditScheduledPublish(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"e1", "e2"}, () -> {
                let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
                discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
                discard ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("予約"))}));
                discard ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("手で"))}));
                discard ContentEntries.publish(Session.grant(), CmsTestKit.entryId("e2"), "someone", false);
                discard Schedules.schedule(Session.grant(), CmsTestKit.entryId("e1"), ScheduleAction.Publish, Timestamp.at("2020-01-01T00:00:00Z"), false)
            }));
            let ran = ServerTestKit.quietly(() -> Scheduler.tick(pool));
            let rows = PgTestSupport.mutateOrBug(pool, () -> Audit.latest(Session.grant(), 10i64))
                |> List.filter(found -> found#targetKind == "entry")
                |> List.map(found -> (found#action, found#targetId, found#actorKind, detailText(List#{"typeApiId"}, found#detail), detailText(List#{"scheduledFor"}, found#detail)));
            (ran, rows)
        });
        Assert.assertEq(expected = (Ok(1), List#{("entry.published", "e1", ActorKind.System, "blogs", "2020-01-01T00:00:00Z")}), outcome)

    ///
    /// 絞り込み。actorKind / action の前方一致 / max / since（時刻 → ULID の下限。未来なら 0 件、過去なら全部）が効く。
    ///
    @Test
    def testPgAuditFilters(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            discard Webhooks.create(Session.grant(), { name = "hook", url = "https://example.com/hooks/cms", events = List#{ WebhookEvent.EntryPublished }, active = true });
            ContentTypes.delete(Session.grant(), blogs#id);
            let all = { max = 10i64, after = None, actorKind = None, actionPrefix = None, since = None, until = None };
            let actions = filter -> Audit.recent(Session.grant(), filter) |> List.map(found -> found#action);
            (actions({ actionPrefix = Some("type.") | all }),
             actions({ actorKind = Some(ActorKind.System) | all }) |> List.length,
             actions({ actorKind = Some(ActorKind.User) | all }) |> List.length,
             actions({ max = 1i64 | all }),
             actions({ since = Some(Timestamp.fromEpochMillis(4102444800000i64)) | all }) |> List.length,
             actions({ since = Some(Timestamp.fromEpochMillis(946684800000i64)), until = Some(Timestamp.fromEpochMillis(4102444800000i64)) | all }) |> List.length)
        });
        Assert.assertEq(expected = Ok(Ok((List#{"type.deleted", "type.created"}, 3, 0, List#{"type.deleted"}, 0, 3))), result)

    ///
    /// 管理 API から読める。型を作って消すと、新しい順に 2 件（owner だけ）。主体はログインした人（USER）。
    /// 絞り込みの引数（actorKind / action / since / until）も通り、action の前方一致で "type." の 2 件、actorKind: SYSTEM で 0 件。
    ///
    @Test
    def testPgAuditEventsOverGraphql(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> (), (api, _) -> {
            let ask = PgTestSupport.askOwner(api);
            let typeId = ask("mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id } }") |> fst |> Value.path(List#{"createContentType", "id"}) |> Value.asStr |> Option.getWithDefault("?");
            discard ask("mutation { deleteContentType(id: \"${typeId}\") }");
            let rowsOf = document -> GraphqlTestKit.listAt(List#{"auditEvents"}, ask(document))
                |> List.filterMap(found -> match (Value.field("action", found) |> Value.asStr, Value.field("targetId", found) |> Value.asStr, Value.field("actorKind", found) |> Value.asStr) {
                    case (Some(action), Some(targetId), Some(kind)) => Some((action, targetId, kind))
                    case _                                          => None
                });
            (rowsOf("{ auditEvents { id actorKind actorId actor action targetKind targetId detail createdAt } }"),
             rowsOf("{ auditEvents(action: \"type.\", since: \"2000-01-01T00:00:00Z\", until: \"2100-01-01T00:00:00Z\") { action targetId actorKind } }") |> List.length,
             rowsOf("{ auditEvents(actorKind: SYSTEM) { action targetId actorKind } }") |> List.length)
        });
        Assert.assertEq(expected = (List#{("type.deleted", "blogs", "USER"), ("type.created", "blogs", "USER")}, 2, 0), outcome)

}
