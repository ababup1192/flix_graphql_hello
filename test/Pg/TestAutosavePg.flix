///
/// 利用者ごとの自動保存を、管理 API（GraphQL のリゾルバ）越しに実 PostgreSQL で通す。
/// 接続は cms_app なので RLS が効いた状態で見る（PgTestSupport.withPool）。
///
/// type EntryAutosave の全フィールド（baseVersion / fields / state / updatedAt）と Entry.autosave は
/// ここで選ぶ（TestApiSurface の決まり。選ばないフィールドのリゾルバは誰も実行せず、
/// ラムダの VerifyError が出ない）。
///
mod TestAutosavePg {

    /// blogs 型（title / body）と、公開済みの entry 1 件。
    def seed(): (TypeId, EntryId) \ Db + CmsErr + IdGen + Tenant + Session + Time.Clock.Clock =
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("body", FieldKind.Text, FieldConfig.empty()));
        let entry = ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(List#{("title", Util.Json.Json.JString("a"))}));
        discard ContentEntries.publish(Session.grant(), entry#id, "seed", false);
        // alice と bob を編集者として招く（最初の問い合わせの認証で membership に写る）。
        // 招くのは人でなければならない（Members.invite が Session.currentUser() を読む）ので owner として
        PgTestSupport.asOwner(() -> {
            discard Members.invite(Session.grant(), "alice@example.com", Role.Editor);
            discard Members.invite(Session.grant(), "bob@example.com", Role.Editor)
        });
        (blogs#id, entry#id)

    def alice(api: PgTestSupport.Api): (String -> (Value, Option[String]) \ IO) \ IO =
        PgTestSupport.askAs(api, PgTestSupport.bearer("alice", "alice@example.com"))

    def bob(api: PgTestSupport.Api): (String -> (Value, Option[String]) \ IO) \ IO =
        PgTestSupport.askAs(api, PgTestSupport.bearer("bob", "bob@example.com"))

    /// entry_autosaves の行数（RLS を通さない所有者の接続で数える）。
    def rowCount(): Int64 \ IO =
        PgTestSupport.countSql("SELECT count(*)::bigint AS total FROM entry_autosaves", Nil)

    /// 自分の自動保存付きで entry を読む selection。
    def entryQuery(entryId: EntryId): String =
        "{ entry(id: \"${entryId}\") { id version stage autosave { baseVersion fields state updatedAt } } }"

    ///
    /// **自動保存を書いても公開状態が変わらない。** 公開済みの entry に autosaveEntry を投げても、
    /// stage は PUBLISHED のままで CHANGED にならず、version も進まない（下書きを触っていない）。
    /// 明示的な保存（updateEntry）をして初めて CHANGED になる。
    ///
    @Test
    def testPgAutosaveDoesNotChangePublishState(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> CmsTestKit.withIds(List#{"e1"}, seed), (api, seeded) -> {
            let (_, entryId) = seeded;
            let ask = alice(api);
            let before = ask("{ entry(id: \"${entryId}\") { version stage } }");
            let saved = ask("mutation { autosaveEntry(id: \"${entryId}\", fields: { title: \"a\", body: \"下書き中\" }) { baseVersion fields state updatedAt } }");
            let after = ask("{ entry(id: \"${entryId}\") { version stage } }");
            let explicit = ask("mutation { updateEntry(id: \"${entryId}\", fields: { body: \"保存した\" }, expectedVersion: 1) { version stage } }");
            List#{
                PgTestSupport.named("読む前", GraphqlTestKit.valueAt(List#{"entry", "stage"}, before)),
                PgTestSupport.named("自動保存の baseVersion", GraphqlTestKit.valueAt(List#{"autosaveEntry", "baseVersion"}, saved)),
                PgTestSupport.named("自動保存の state", GraphqlTestKit.valueAt(List#{"autosaveEntry", "state"}, saved)),
                PgTestSupport.named("自動保存の中身", GraphqlTestKit.valueAt(List#{"autosaveEntry", "fields"}, saved)),
                PgTestSupport.named("自動保存の後の stage", GraphqlTestKit.valueAt(List#{"entry", "stage"}, after)),
                PgTestSupport.named("自動保存の後の version", GraphqlTestKit.valueAt(List#{"entry", "version"}, after)),
                PgTestSupport.named("明示的な保存の後の stage", GraphqlTestKit.valueAt(List#{"updateEntry", "stage"}, explicit)),
                PgTestSupport.named("明示的な保存の後の version", GraphqlTestKit.valueAt(List#{"updateEntry", "version"}, explicit))
            }
        });
        Assert.assertEq(
            expected = List#{
                PgTestSupport.named("読む前", Value.Str("PUBLISHED")),
                PgTestSupport.named("自動保存の baseVersion", Value.Int(1)),
                PgTestSupport.named("自動保存の state", Value.Str("RESTORABLE")),
                PgTestSupport.named("自動保存の中身", Value.Obj(Map#{ "body" => Value.Str("下書き中"), "title" => Value.Str("a") })),
                PgTestSupport.named("自動保存の後の stage", Value.Str("PUBLISHED")),
                PgTestSupport.named("自動保存の後の version", Value.Int(1)),
                PgTestSupport.named("明示的な保存の後の stage", Value.Str("CHANGED")),
                PgTestSupport.named("明示的な保存の後の version", Value.Int(2))
            },
            outcome)

    ///
    /// **他人の自動保存は読めない。** alice と bob が同じ entry にそれぞれ預けても、
    /// 各自の Entry.autosave は自分の中身だけを返す（RLS が自分の行しか見せない）。
    /// 表には 2 行あるので、「そもそも書けていない」のではなく「見えない」事を数で確かめる。
    ///
    @Test
    def testPgAutosaveIsPrivatePerUser(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> CmsTestKit.withIds(List#{"e1"}, seed), (api, seeded) -> {
            let (_, entryId) = seeded;
            let askAlice = alice(api);
            let askBob = bob(api);
            discard askAlice("mutation { autosaveEntry(id: \"${entryId}\", fields: { title: \"a\", body: \"alice の下書き\" }) { baseVersion } }");
            discard askBob("mutation { autosaveEntry(id: \"${entryId}\", fields: { title: \"a\", body: \"bob の下書き\" }) { baseVersion } }");
            List#{
                PgTestSupport.named("alice が読む", GraphqlTestKit.valueAt(List#{"entry", "autosave", "fields"}, askAlice(entryQuery(entryId)))),
                PgTestSupport.named("bob が読む", GraphqlTestKit.valueAt(List#{"entry", "autosave", "fields"}, askBob(entryQuery(entryId)))),
                PgTestSupport.named("owner が読む", GraphqlTestKit.valueAt(List#{"entry", "autosave"}, PgTestSupport.askOwner(api)(entryQuery(entryId)))),
                PgTestSupport.named("表の行数", rowCount())
            }
        });
        Assert.assertEq(
            expected = List#{
                PgTestSupport.named("alice が読む", Value.Obj(Map#{ "body" => Value.Str("alice の下書き"), "title" => Value.Str("a") })),
                PgTestSupport.named("bob が読む", Value.Obj(Map#{ "body" => Value.Str("bob の下書き"), "title" => Value.Str("a") })),
                PgTestSupport.named("owner が読む", Value.Null),
                PgTestSupport.named("表の行数", 2i64)
            },
            outcome)

    ///
    /// **下書きが先へ進むと OUTDATED。** bob が預けた後に alice が明示的に保存すると、
    /// bob の預かり物は消えずに OUTDATED になる（消すと bob の打鍵が黙って失われる）。
    /// alice の側は、保存した中身と同じになった自動保存が SameAsDraft で捨てられて null になる。
    ///
    @Test
    def testPgAutosaveGoesOutdatedWhenDraftMovesOn(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> CmsTestKit.withIds(List#{"e1"}, seed), (api, seeded) -> {
            let (_, entryId) = seeded;
            let askAlice = alice(api);
            let askBob = bob(api);
            discard askBob("mutation { autosaveEntry(id: \"${entryId}\", fields: { title: \"a\", body: \"bob の下書き\" }) { baseVersion } }");
            discard askAlice("mutation { autosaveEntry(id: \"${entryId}\", fields: { title: \"a\", body: \"alice の下書き\" }) { baseVersion } }");
            discard askAlice("mutation { updateEntry(id: \"${entryId}\", fields: { body: \"alice の下書き\" }, expectedVersion: 1) { version } }");
            // 保存した中身と同じ物を預け直すと、置き場を空にして null を返す
            let aliceAgain = askAlice("mutation { autosaveEntry(id: \"${entryId}\", fields: { title: \"a\", body: \"alice の下書き\" }) { state } }");
            List#{
                PgTestSupport.named("bob の state", GraphqlTestKit.valueAt(List#{"entry", "autosave", "state"}, askBob(entryQuery(entryId)))),
                PgTestSupport.named("bob の baseVersion", GraphqlTestKit.valueAt(List#{"entry", "autosave", "baseVersion"}, askBob(entryQuery(entryId)))),
                PgTestSupport.named("同じ中身を預け直した戻り", GraphqlTestKit.valueAt(List#{"autosaveEntry"}, aliceAgain)),
                PgTestSupport.named("alice が読む", GraphqlTestKit.valueAt(List#{"entry", "autosave"}, askAlice(entryQuery(entryId)))),
                PgTestSupport.named("表の行数", rowCount())
            }
        });
        Assert.assertEq(
            expected = List#{
                PgTestSupport.named("bob の state", Value.Str("OUTDATED")),
                PgTestSupport.named("bob の baseVersion", Value.Int(1)),
                PgTestSupport.named("同じ中身を預け直した戻り", Value.Null),
                PgTestSupport.named("alice が読む", Value.Null),
                PgTestSupport.named("表の行数", 1i64)
            },
            outcome)

    ///
    /// **掃除。** discardAutosave は自分の行だけを消し、entry をゴミ箱に入れると
    /// その entry の全員分が消える（論理削除なので外部キーの CASCADE は効かない）。
    ///
    @Test
    def testPgAutosaveCleanup(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> CmsTestKit.withIds(List#{"e1"}, seed), (api, seeded) -> {
            let (_, entryId) = seeded;
            let askAlice = alice(api);
            let askBob = bob(api);
            discard askAlice("mutation { autosaveEntry(id: \"${entryId}\", fields: { body: \"alice\" }) { baseVersion } }");
            discard askBob("mutation { autosaveEntry(id: \"${entryId}\", fields: { body: \"bob\" }) { baseVersion } }");
            let discarded = askAlice("mutation { discardAutosave(id: \"${entryId}\") }");
            let afterDiscard = rowCount();
            let discardedAgain = askAlice("mutation { discardAutosave(id: \"${entryId}\") }") |> snd;
            let bobBeforeDelete = GraphqlTestKit.valueAt(List#{"entry", "autosave", "fields"}, askBob(entryQuery(entryId)));
            let deleted = PgTestSupport.askOwner(api)("mutation { deleteEntry(id: \"${entryId}\") }");
            List#{
                PgTestSupport.named("捨てた id", GraphqlTestKit.valueAt(List#{"discardAutosave"}, discarded)),
                PgTestSupport.named("捨てた後の行数", afterDiscard),
                PgTestSupport.named("無い物を捨てる", discardedAgain),
                PgTestSupport.named("bob から見える物", bobBeforeDelete),
                PgTestSupport.named("ゴミ箱にした結果", deleted),
                PgTestSupport.named("ゴミ箱の後の行数", rowCount())
            }
        });
        Assert.assertEq(
            expected = List#{
                PgTestSupport.named("捨てた id", Value.Str("e1")),
                PgTestSupport.named("捨てた後の行数", 1i64),
                PgTestSupport.named("無い物を捨てる", (None: Option[String])),
                PgTestSupport.named("bob から見える物", Value.Obj(Map#{ "body" => Value.Str("bob") })),
                PgTestSupport.named("ゴミ箱にした結果", (Value.Obj(Map#{ "deleteEntry" => Value.Str("e1") }), (None: Option[String]))),
                PgTestSupport.named("ゴミ箱の後の行数", 0i64)
            },
            outcome)

    ///
    /// **人でなければ置き場を持たない。** WRITE の API キーは entry を書けるが、
    /// 自動保存は「その人の置き場」なので autosaveEntry は FORBIDDEN、Entry.autosave は常に null
    /// （鍵で読んだだけで落とさない）。
    ///
    @Test
    def testPgAutosaveNeedsAPerson(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> CmsTestKit.withIds(List#{"e1"}, seed), (api, seeded) -> {
            let (_, entryId) = seeded;
            let owner = PgTestSupport.askOwner(api);
            let key = GraphqlTestKit.stringAt(List#{"createApiKey", "key"}, owner("mutation { createApiKey(name: \"ci\", scope: WRITE, role: EDITOR) { key } }"));
            let askKey = PgTestSupport.askAs(api, Credential.ApiKey(key));
            discard alice(api)("mutation { autosaveEntry(id: \"${entryId}\", fields: { body: \"alice\" }) { baseVersion } }");
            List#{
                PgTestSupport.named("鍵で預ける", askKey("mutation { autosaveEntry(id: \"${entryId}\", fields: { body: \"x\" }) { baseVersion } }") |> snd),
                PgTestSupport.named("鍵で捨てる", askKey("mutation { discardAutosave(id: \"${entryId}\") }") |> snd),
                PgTestSupport.named("鍵で読む", GraphqlTestKit.valueAt(List#{"entry", "autosave"}, askKey(entryQuery(entryId)))),
                PgTestSupport.named("鍵で entry は書ける", askKey("mutation { updateEntry(id: \"${entryId}\", fields: { body: \"y\" }, expectedVersion: 1) { version } }") |> snd),
                PgTestSupport.named("表の行数", rowCount())
            }
        });
        Assert.assertEq(
            expected = List#{
                PgTestSupport.named("鍵で預ける", Some("この操作（readDraft）の権限がありません")),
                PgTestSupport.named("鍵で捨てる", Some("この操作（readDraft）の権限がありません")),
                PgTestSupport.named("鍵で読む", Value.Null),
                PgTestSupport.named("鍵で entry は書ける", (None: Option[String])),
                PgTestSupport.named("表の行数", 1i64)
            },
            outcome)

    ///
    /// **一覧で自動保存を選んでも SQL は 1 本。** ページの分をまとめて引く先読みに乗る
    /// （行ごとに引くと 1 ページで 50 本増える）。
    ///
    @Test
    def testPgAutosaveIsPreloadedInLists(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> CmsTestKit.withIds(List#{"e1", "e2", "e3"}, () -> {
            let (blogs, first) = seed();
            discard ContentEntries.create(Session.grant(), blogs, None, CmsTestKit.entryData(List#{("title", Util.Json.Json.JString("b"))}));
            discard ContentEntries.create(Session.grant(), blogs, None, CmsTestKit.entryData(List#{("title", Util.Json.Json.JString("c"))}));
            (blogs, first)
        }), (api, seeded) -> {
            let (blogs, _) = seeded;
            let askAlice = alice(api);
            discard askAlice("mutation { autosaveEntry(id: \"e1\", fields: { title: \"a!\" }) { baseVersion } }");
            discard askAlice("mutation { autosaveEntry(id: \"e3\", fields: { title: \"c!\" }) { baseVersion } }");
            askAlice("{ entries(typeId: \"${TypeId.toInt64(blogs)}\", orderBy: [{ field: \"id\", direction: ASC }]) { nodes { id autosave { state fields } } } }")
        });
        Assert.assertEq(
            expected = (Value.Obj(Map#{ "entries" => Value.Obj(Map#{ "nodes" => Value.List(
                Value.Obj(Map#{ "id" => Value.Str("e1"), "autosave" => Value.Obj(Map#{ "state" => Value.Str("RESTORABLE"), "fields" => Value.Obj(Map#{ "title" => Value.Str("a!") }) }) }) ::
                Value.Obj(Map#{ "id" => Value.Str("e2"), "autosave" => Value.Null }) ::
                Value.Obj(Map#{ "id" => Value.Str("e3"), "autosave" => Value.Obj(Map#{ "state" => Value.Str("RESTORABLE"), "fields" => Value.Obj(Map#{ "title" => Value.Str("c!") }) }) }) :: Nil) }) }), None),
            outcome)

    ///
    /// **明示的な保存で版も積む。** updateEntry(saveVersion: true) は保存と版積みを同じ Tx でする。
    /// 既定（false）では版は積まれない。
    ///
    @Test
    def testPgUpdateEntryCanSaveVersion(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> CmsTestKit.withIds(List#{"e1"}, seed), (api, seeded) -> {
            let (_, entryId) = seeded;
            let ask = alice(api);
            let plain = ask("mutation { updateEntry(id: \"${entryId}\", fields: { body: \"x\" }, expectedVersion: 1) { version versions { reason } } }");
            let withVersion = ask("mutation { updateEntry(id: \"${entryId}\", fields: { body: \"y\" }, expectedVersion: 2, saveVersion: true) { version versions { reason author fields } } }");
            List#{
                PgTestSupport.named("既定の版", GraphqlTestKit.valueAt(List#{"updateEntry", "versions"}, plain)),
                PgTestSupport.named("saveVersion の版", GraphqlTestKit.valueAt(List#{"updateEntry", "versions"}, withVersion))
            }
        });
        Assert.assertEq(
            expected = List#{
                PgTestSupport.named("既定の版", Value.List(Value.Obj(Map#{ "reason" => Value.Str("PUBLISH") }) :: Nil)),
                PgTestSupport.named("saveVersion の版", Value.List(
                    Value.Obj(Map#{ "reason" => Value.Str("SAVE"), "author" => Value.Str("alice@example.com"), "fields" => Value.Obj(Map#{ "body" => Value.Str("y"), "title" => Value.Str("a") }) }) ::
                    Value.Obj(Map#{ "reason" => Value.Str("PUBLISH"), "author" => Value.Str("seed"), "fields" => Value.Obj(Map#{ "title" => Value.Str("a") }) }) :: Nil))
            },
            outcome)

}
