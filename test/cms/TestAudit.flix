///
/// Audit.rowOf: 監査の出来事 → 積む行（action / 対象 / 詳細）の表。純粋。
///
mod TestAudit {

    use Util.Json.Json

    /// 出来事ごとの action と対象。
    ///
    ///   メンバー  招待・役割の変更・削除・招待の取り消し
    ///   鍵        発行・失効
    ///   型        作成・変更・削除
    ///   フィールド 追加・変更・削除・並べ替え
    @Test
    def testAuditRowOfTable(): Unit \ Assert =
        let blogs = CmsTestKit.apiId("blogs");
        let was = Json.JString("変更前");
        let table = List#{
            (AuditChange.MemberInvited("a@example.com", Role.Editor),        ("member.invited", "member", "a@example.com")),
            (AuditChange.MemberRoleChanged(UserId.UserId(7i64), Role.Owner), ("member.role_changed", "member", "7")),
            (AuditChange.MemberRemoved(UserId.UserId(7i64)),                 ("member.removed", "member", "7")),
            (AuditChange.InvitationCancelled("iv_1"),                        ("invitation.cancelled", "invitation", "iv_1")),
            (AuditChange.ApiKeyCreated("ak_1", "CI"),                        ("api_key.created", "api_key", "ak_1")),
            (AuditChange.ApiKeyRevoked("ak_1"),                              ("api_key.revoked", "api_key", "ak_1")),
            (AuditChange.TypeCreated(blogs),                                 ("type.created", "type", "blogs")),
            (AuditChange.TypeUpdated(blogs, was),                            ("type.updated", "type", "blogs")),
            (AuditChange.TypeDeleted(blogs, was),                            ("type.deleted", "type", "blogs")),
            (AuditChange.FieldAdded(blogs, "title"),                         ("field.added", "field", "blogs.title")),
            (AuditChange.FieldUpdated(blogs, "title", was),                  ("field.updated", "field", "blogs.title")),
            (AuditChange.FieldRemoved(blogs, "title", was),                  ("field.removed", "field", "blogs.title")),
            (AuditChange.FieldsReordered(blogs, was),                        ("fields.reordered", "type", "blogs"))
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(fst) |> List.map(event -> {
                let row = Audit.rowOf("someone@example.com", event);
                (row#action, row#targetKind, row#targetId)
            }))

    /// detail は、役割・名前の付く出来事と、スキーマの変更前を持つ出来事だけが中身を持つ。
    @Test
    def testAuditDetailTable(): Unit \ Assert =
        let blogs = CmsTestKit.apiId("blogs");
        let was = Json.JString("変更前");
        let table = List#{
            (AuditChange.MemberInvited("a@example.com", Role.Editor),        Json.JObject(Map#{ "role" => Json.JString("editor") })),
            (AuditChange.MemberRoleChanged(UserId.UserId(7i64), Role.Owner), Json.JObject(Map#{ "role" => Json.JString("owner") })),
            (AuditChange.ApiKeyCreated("ak_1", "CI"),                        Json.JObject(Map#{ "name" => Json.JString("CI") })),
            (AuditChange.MemberRemoved(UserId.UserId(7i64)),                 Json.JObject(Map.empty())),
            (AuditChange.TypeCreated(blogs),                                 Json.JObject(Map.empty())),
            (AuditChange.TypeDeleted(blogs, was),                            Json.JObject(Map#{ "before" => was })),
            (AuditChange.FieldRemoved(blogs, "title", was),                  Json.JObject(Map#{ "before" => was }))
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(fst) |> List.map(event -> Audit.rowOf("someone@example.com", event)#detail))

    /// 主体はそのまま行に載る（版の author と同じ形。人は email、鍵は api-key:<名前>）。
    @Test
    def testAuditRowKeepsActor(): Unit \ Assert =
        Assert.assertEq(
            expected = "api-key:CI",
            Audit.rowOf("api-key:CI", AuditChange.TypeDeleted(CmsTestKit.apiId("blogs"), Json.JNull))#actor)

}
