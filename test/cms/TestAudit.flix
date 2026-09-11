///
/// Audit.rowOf: 監査の出来事 → 積む行（主体 / action / 対象 / 詳細）の表。純粋。
///
mod TestAudit {

    use Util.Json.Json

    /// 表の主体（ログインした人）。
    def someone(): ActorRef = { kind = ActorKind.User, id = "7", name = "someone@example.com" }

    def blogs(): ApiId = CmsTestKit.apiId("blogs")

    def entry(): EntryId = CmsTestKit.entryId("a1b2c3d4e5f6")

    def asset(): AssetId = AssetId.AssetId("a1b2c3d4e5f6")

    /// 出来事ごとの action と対象。
    ///
    ///   メンバー   招待・役割の変更・削除・招待の取り消し
    ///   鍵         発行・失効
    ///   型         作成・変更・削除
    ///   フィールド  追加・変更・削除・並べ替え
    ///   プロジェクト 公開範囲
    ///   Webhook    作成・変更・削除・再送
    ///   asset      確定・削除
    ///   entry      取り下げ・削除・予約公開の実行
    ///   監査       書き出し（targetId は形式）
    @Test
    def testAuditRowOfTable(): Unit \ Assert =
        let was = Json.JString("変更前");
        let table = List#{
            (AuditChange.MemberInvited("a@example.com", Role.Editor),        ("member.invited", "member", "a@example.com")),
            (AuditChange.MemberRoleChanged(UserId.UserId(7i64), Role.Editor, Role.Owner), ("member.role_changed", "member", "7")),
            (AuditChange.MemberRemoved(UserId.UserId(7i64)),                 ("member.removed", "member", "7")),
            (AuditChange.InvitationCancelled("iv_1"),                        ("invitation.cancelled", "invitation", "iv_1")),
            (AuditChange.ApiKeyCreated("ak_1", "CI"),                        ("api_key.created", "api_key", "ak_1")),
            (AuditChange.ApiKeyRevoked("ak_1"),                              ("api_key.revoked", "api_key", "ak_1")),
            (AuditChange.TypeCreated(blogs()),                               ("type.created", "type", "blogs")),
            (AuditChange.TypeUpdated(blogs(), was),                          ("type.updated", "type", "blogs")),
            (AuditChange.TypeDeleted(blogs(), was, 0),                       ("type.deleted", "type", "blogs")),
            (AuditChange.FieldAdded(blogs(), "title"),                       ("field.added", "field", "blogs.title")),
            (AuditChange.FieldUpdated(blogs(), "title", was),                ("field.updated", "field", "blogs.title")),
            (AuditChange.FieldRemoved(blogs(), "title", was),                ("field.removed", "field", "blogs.title")),
            (AuditChange.FieldsReordered(blogs(), was),                      ("fields.reordered", "type", "blogs")),
            (AuditChange.ProjectVisibilityChanged("docs", Visibility.Private, Visibility.Public), ("project.visibility_changed", "project", "docs")),
            (AuditChange.WebhookCreated("wh_1", was),                        ("webhook.created", "webhook", "wh_1")),
            (AuditChange.WebhookUpdated("wh_1", was),                        ("webhook.updated", "webhook", "wh_1")),
            (AuditChange.WebhookDeleted("wh_1", was),                        ("webhook.deleted", "webhook", "wh_1")),
            (AuditChange.WebhookRedelivered("01ARYZ6S41"),                   ("webhook.redelivered", "webhook_delivery", "01ARYZ6S41")),
            (AuditChange.AssetConfirmed(asset(), was),                       ("asset.confirmed", "asset", "a1b2c3d4e5f6")),
            (AuditChange.AssetDeleted(asset(), was),                         ("asset.deleted", "asset", "a1b2c3d4e5f6")),
            (AuditChange.EntryUnpublished(entry(), blogs(), 3),              ("entry.unpublished", "entry", "a1b2c3d4e5f6")),
            (AuditChange.EntryDeleted(entry(), blogs(), 3),                  ("entry.deleted", "entry", "a1b2c3d4e5f6")),
            (AuditChange.EntryPublishedBySchedule(entry(), blogs(), 3, Timestamp.fromEpochMillis(0i64)), ("entry.published", "entry", "a1b2c3d4e5f6")),
            (AuditChange.AuditExported(AuditExportFormat.Csv, Json.JObject(Map.empty()), 12),  ("audit.exported", "audit", "csv")),
            (AuditChange.AuditExported(AuditExportFormat.Json, Json.JObject(Map.empty()), 0),  ("audit.exported", "audit", "json"))
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(fst) |> List.map(event -> {
                let row = Audit.rowOf(someone(), event);
                (row#action, row#targetKind, row#targetId)
            }))

    /// detail は、役割・名前の付く出来事と、変更前の姿を持つ出来事、entry の型と版を持つ出来事だけが中身を持つ。
    /// Webhook と asset の作成・確定は姿をそのまま、消した物は before に包む。役割の変更は role（変更後）と before（変更前）。
    /// 書き出しは絞り込み（渡した物だけ）に format と count を足した物。
    @Test
    def testAuditDetailTable(): Unit \ Assert =
        let was = Json.JString("変更前");
        let entryDetail = Json.JObject(Map#{ "typeApiId" => Json.JString("blogs"), "version" => CmsTestKit.intJson(3) });
        let table = List#{
            (AuditChange.MemberInvited("a@example.com", Role.Editor),        Json.JObject(Map#{ "role" => Json.JString("editor") })),
            (AuditChange.MemberRoleChanged(UserId.UserId(7i64), Role.Editor, Role.Owner), Json.JObject(Map#{ "role" => Json.JString("owner"), "before" => Json.JString("editor") })),
            (AuditChange.ApiKeyCreated("ak_1", "CI"),                        Json.JObject(Map#{ "name" => Json.JString("CI") })),
            (AuditChange.MemberRemoved(UserId.UserId(7i64)),                 Json.JObject(Map.empty())),
            (AuditChange.TypeCreated(blogs()),                               Json.JObject(Map.empty())),
            (AuditChange.TypeDeleted(blogs(), was, 2),                       Json.JObject(Map#{ "before" => was, "purgedEntries" => CmsTestKit.intJson(2) })),
            (AuditChange.FieldRemoved(blogs(), "title", was),                Json.JObject(Map#{ "before" => was })),
            (AuditChange.ProjectVisibilityChanged("docs", Visibility.Private, Visibility.Public), Json.JObject(Map#{ "before" => Json.JString("private"), "after" => Json.JString("public") })),
            (AuditChange.WebhookCreated("wh_1", was),                        was),
            (AuditChange.WebhookDeleted("wh_1", was),                        Json.JObject(Map#{ "before" => was })),
            (AuditChange.WebhookRedelivered("01ARYZ6S41"),                   Json.JObject(Map.empty())),
            (AuditChange.AssetConfirmed(asset(), was),                       was),
            (AuditChange.AssetDeleted(asset(), was),                         Json.JObject(Map#{ "before" => was })),
            (AuditChange.EntryUnpublished(entry(), blogs(), 3),              entryDetail),
            (AuditChange.EntryDeleted(entry(), blogs(), 3),                  entryDetail),
            (AuditChange.EntryPublishedBySchedule(entry(), blogs(), 3, Timestamp.fromEpochMillis(0i64)),
                Json.JObject(Map#{ "typeApiId" => Json.JString("blogs"), "version" => CmsTestKit.intJson(3), "scheduledFor" => Json.JString(Timestamp.toIso8601(Timestamp.fromEpochMillis(0i64))) })),
            (AuditChange.AuditExported(AuditExportFormat.Csv, Json.JObject(Map#{ "action" => Json.JString("member.") }), 12),
                Json.JObject(Map#{ "format" => Json.JString("csv"), "action" => Json.JString("member."), "count" => CmsTestKit.intJson(12) })),
            (AuditChange.AuditExported(AuditExportFormat.Json, Json.JObject(Map.empty()), 0),
                Json.JObject(Map#{ "format" => Json.JString("json"), "count" => CmsTestKit.intJson(0) }))
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(fst) |> List.map(event -> Audit.rowOf(someone(), event)#detail))

    /// 主体は種類・id・表示名の 3 つがそのまま行に載る（表示名は版の author と同じ形。人は email、鍵は api-key:<名前>）。
    @Test
    def testAuditRowKeepsActor(): Unit \ Assert =
        let key = { kind = ActorKind.ApiKey, id = "CI", name = "api-key:CI" };
        let row = Audit.rowOf(key, AuditChange.TypeDeleted(blogs(), Json.JNull, 0));
        Assert.assertEq(
            expected = (ActorKind.ApiKey, "CI", "api-key:CI"),
            (row#actorKind, row#actorId, row#actor))

    /// 主体の種類の綴りは列に残るので、text と parse が往復する。
    @Test
    def testActorKindRoundTrip(): Unit \ Assert =
        let kinds = List#{ ActorKind.User, ActorKind.Pat, ActorKind.ApiKey, ActorKind.System, ActorKind.Anonymous, ActorKind.Preview };
        Assert.assertEq(
            expected = kinds |> List.map(Some),
            kinds |> List.map(kind -> ActorKind.parse(ActorKind.text(kind))))

    /// Session の主体 → 監査の主体。人は user / pat をどう来たかで分けて id は public_id（引く関数は差し替え）、鍵は名前を id に、System は id 無し。
    @Test
    def testSessionActorRefTable(): Unit \ Assert =
        let user = UserId.UserId(7i64);
        let table = List#{
            (Actor.User(user, "a@example.com", Nil, Login.Interactive),                      (ActorKind.User, "pub-7", "a@example.com")),
            (Actor.User(user, "a@example.com", Nil, Login.PersonalToken(PatScope.Write)),    (ActorKind.Pat, "pub-7", "a@example.com")),
            (Actor.ApiKey("CI", ApiKeyScope.Read),                                            (ActorKind.ApiKey, "CI", "api-key:CI")),
            (Actor.System,                                                                    (ActorKind.System, "", "system"))
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(fst) |> List.map(actor -> {
                let found = Session.actorRefOf(actor, id -> "pub-${id}");
                (found#kind, found#id, found#name)
            }))

}
