///
/// 管理 API と Account API の object 型とフィールドの一覧（表面）を introspection で読み、SDL のとおりである事を見る。
/// スキーマが組める事もここで見る（リゾルバを 1 つでも当て損ねると組めない）。
///
/// 型かフィールドを足すと、このテストが落ちる。期待値に足すだけでは足りない。
/// **そのフィールドを test/Pg/TestAdminMutationsPg（Account API は TestAccountPg / TestPersonalTokenPg、
/// コンテンツ API は TestAssetsPg、Viewer は TestMcpPg の whoami）の selection にも足して、GraphQL 越しに 1 度は選ぶ事。**
/// リゾルバのラムダは JVM の VerifyError で落ちる事があり、それは型検査でもスキーマの組み立てでも出ず、
/// そのフィールドを選んだ query を実行した時にだけ出る。
///
mod TestApiSurface {

    /// リゾルバを呼ばない Runner。スキーマを組むだけなら DB もプールも要らない。
    def unusedRunner(): Runner[AdminEff] = (_context, _f) -> Err(FieldError.internal("組み立てだけ"))

    /// リゾルバを呼ばない Runner（Account API）。
    def unusedAccountRunner(): Runner[AccountEff] = (_context, _f) -> Err(FieldError.internal("組み立てだけ"))

    /// 配列。配列でなければテストの前提が壊れている。
    def items(value: Value): List[Value] = match value {
        case Value.List(found) => found
        case other             => bug!("配列ではありません: ${other}")
    }

    /// 1 つの object 型を "TypeName: field field ..."（SDL の並び）にする。
    def lineOf(objectType: Value): String =
        "${GraphqlTestKit.nameOf(objectType)}: ${Value.field("fields", objectType) |> items |> List.map(GraphqlTestKit.nameOf) |> List.join(" ")}"

    ///
    /// スキーマの object 型を型名で並べた "TypeName: field ..." の一覧。graphql-java が足す `__` の型は外す。
    ///
    def surface(schema: Schema): List[String] \ IO =
        GraphqlTestKit.ask(schema, "{ __schema { types { name kind fields { name } } } }")
            |> GraphqlTestKit.listAt(List#{"__schema", "types"})
            |> List.filter(found -> Value.field("kind", found) == Value.Str("OBJECT") and not String.startsWith(prefix = "__", GraphqlTestKit.nameOf(found)))
            |> List.map(lineOf)
            |> List.sort

    /// 管理 API（admin.graphql）の object 型とフィールド。
    @Test
    def testAdminSchemaSurface(): Unit \ {IO, Assert} =
        Assert.assertEq(
            expected =
                "ApiKey: id name keyHint scope role createdAt expiresAt lastUsedAt revokedAt" ::
                // Asset に見せ方（focalPoint / crop）を足した。FocalPoint / CropRect はその中身の型
                "Asset: id url fileName mime size width height alt status createdAt usedBy focalPoint crop" ::
                "AssetEdge: cursor node" ::
                "AssetPage: nodes edges pageInfo totalCount" ::
                "AuditEvent: id actorKind actorId actor action targetKind targetId detail createdAt" ::
                "ContentType: id apiId kind name singular plural previewUrl linkPath icon fields createdAt updatedAt" ::
                "CropRect: left top width height" ::
                "DiffLine: kind text" ::
                "Entry: id typeId version stage fields publishedAt createdAt updatedAt path versions autosave diff" ::
                "EntryAutosave: baseVersion fields state updatedAt" ::
                "EntryEdge: cursor node" ::
                "EntryPage: nodes edges pageInfo totalCount" ::
                "EntryVersion: id version reason author fields createdAt" ::
                "FieldChange: path kind before after children lines" ::
                "FieldConfig: maxLength sourceField min max integer options" ::
                "FieldDef: id apiId name kind many required unique localized targetTypeId parentFieldId children config position" ::
                "FocalPoint: x y" ::
                "Impact: breaks cascades" ::
                "Invitation: id email role createdAt" ::
                "IssuedApiKey: id name scope role expiresAt key" ::
                "IssuedWebhook: webhook secret" ::
                "LinkCard: url title description imageUrl siteName fetchedAt error" ::
                "Me: id email name roles permissions organizations projects" ::
                "Member: userId email name role" ::
                "Mutation: createContentType updateContentType deleteContentType addField updateField removeField reorderFields createEntry updateEntry deleteEntry publishEntry publishMany unpublishEntry saveVersion restoreVersion autosaveEntry discardAutosave createUploadUrl confirmAsset updateAsset deleteAsset createPreviewToken schedulePublish scheduleUnpublish cancelSchedule updateProjectVisibility inviteMember cancelInvitation changeMemberRole removeMember createApiKey revokeApiKey createWebhook updateWebhook deleteWebhook redeliverWebhook recordAuditExport fetchLinkCard" ::
                "Organization: id name" ::
                "OrganizationMembership: organization role" ::
                "PageInfo: hasNextPage endCursor" ::
                "PreviewToken: token entryId expiresAt url" ::
                "Project: id slug name visibility" ::
                "ProjectMembership: project role" ::
                "PublishPlan: ok steps violations" ::
                "PublishPlanStep: entry reason report" ::
                "PublishReport: ok violations unpublishedDependencies" ::
                "Query: contentTypes contentType entries entry assets asset publishCheck impact publishPlan viewer publicOrigin me members invitations apiKeys webhooks webhookDeliveries schedules auditEvents auditEventsCount fieldImpact linkCards" ::
                "Referrer: entry via stage" ::
                "Schedule: id entryId action runAt withDependencies status requestedBy lastError overdue createdAt doneAt" ::
                "SchemaEffect: kind field draft published entries" ::
                "SchemaImpact: safe effects" ::
                "Upload: asset uploadUrl expiresInSeconds" ::
                "Viewer: kind name roles scope permissions" ::
                "Violation: path message" ::
                "Webhook: id name url events active createdAt" ::
                "WebhookDelivery: id event status attempts nextAttemptAt lastStatus lastError createdAt deliveredAt" :: Nil,
            surface(AdminSchema.make(Deps.forTest(None), unusedRunner())))

    /// Account API（account.graphql）の object 型とフィールド。
    @Test
    def testAccountSchemaSurface(): Unit \ {IO, Assert} =
        Assert.assertEq(
            expected =
                "IssuedPersonalAccessToken: id name scope expiresAt token" ::
                "Me: id email name organizations projects personalAccessTokens" ::
                "Mutation: createOrganization createProject addOrganizationMember removeOrganizationMember createPersonalAccessToken revokePersonalAccessToken" ::
                "Organization: id name members projects" ::
                "OrganizationMember: userId email name role" ::
                "OrganizationMembership: organization role" ::
                "PersonalAccessToken: id name scope createdAt expiresAt lastUsedAt revokedAt" ::
                "Project: id slug name visibility" ::
                "ProjectMembership: project role" ::
                "Query: me organization" :: Nil,
            surface(AccountSchema.make(Deps.forTest(None), unusedAccountRunner())))

}
