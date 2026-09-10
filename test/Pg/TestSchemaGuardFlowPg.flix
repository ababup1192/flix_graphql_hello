///
/// SchemaGuard.withImpact を実 PostgreSQL で通しで動かす。
///
/// 影響が空なら素通り、空でなければ止めて書き込みごと巻き戻る。指紋を渡した時は
/// 見た時より悪くなっていなければ通す。
///
mod TestSchemaGuardFlowPg {

    use Util.Json.Json

    ///
    /// blogs(title, body) と、body に値を持つ公開済みの entry 1 件。返すのは (型 id, body の id)。
    ///
    def seedBlog(): (TypeId, FieldId) \ Db + CmsErr + Tenant + IdGen + Session =
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        let body = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("body", FieldKind.Text, FieldConfig.empty()));
        let entry = ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b1")),
            CmsTestKit.entryData(List#{("title", Json.JString("題")), ("body", Json.JString("本文"))}));
        discard ContentEntries.publish(Session.grant(), entry#id, "tester", false);
        (blogs#id, body#id)

    /// 止まった理由の path。通った時は空（failurePaths は成功を渡すと止まる）。
    def pathsOf(result: Result[CmsErr.CmsFailure, a]): List[String] = match result {
        case Ok(_)  => Nil
        case Err(_) => CmsTestKit.failurePaths(result)
    }

    /// その型に今あるフィールドの apiId。
    def fieldsOf(typeId: TypeId): List[String] \ DbRead + CmsErr + Tenant + Session =
        ContentTypes.get(Session.grant(), typeId)#fields |> List.map(field -> ApiId.text(field#apiId)) |> List.sort

    ///
    /// 影響の無い操作は指紋を渡さずに通る。
    ///
    /// フィールドを足す・並べ替える・型を作るのは既存のデータに触らない。ここで止まると
    /// microCMS の取り込みも初期セットアップも動かなくなる。
    ///
    @Test
    def testPgHarmlessChangesPassWithoutFingerprint(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1"}, () -> {
            let (blogs, _) = seedBlog();
            // 足す
            let added = SchemaGuard.withImpact(Session.grant(), None, () ->
                ContentTypes.addField(Session.grant(), blogs, CmsTestKit.fieldDraft("memo", FieldKind.Text, FieldConfig.empty())));
            // 並べ替える
            let ids = ContentTypes.get(Session.grant(), blogs)#fields |> List.map(field -> field#id) |> List.reverse;
            discard SchemaGuard.withImpact(Session.grant(), None, () -> ContentTypes.reorderFields(Session.grant(), blogs, ids));
            (ApiId.text(added#apiId), fieldsOf(blogs))
        }));
        Assert.assertEq(expected = Ok(Ok(("memo", List#{"body", "memo", "title"}))), result)

    ///
    /// 値のあるフィールドを指紋なしで消すと止まる。
    ///
    /// withImpact 自身は巻き戻さない（CmsErr を上げるだけ）。実際に書き込みが戻るのは
    /// Tx の境界＝DbRunner.transact で、それは testPgStoppedChangeRollsBack が見る。
    ///
    @Test
    def testPgDestructiveChangeStops(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1"}, () -> {
            let (_, body) = seedBlog();
            CmsTestKit.failurePaths(CmsTestKit.runWithResult(() ->
                SchemaGuard.withImpact(Session.grant(), None, () -> ContentTypes.removeField(Session.grant(), body))))
        }));
        Assert.assertEq(expected = Ok(Ok(List#{"fields.body"})), result)

    ///
    /// 止まった時、フィールドを消す SQL ごと巻き戻る。
    ///
    /// Runner（DbRunner.transact）を通して確かめる。ここを通らないと、業務エラーで止めても
    /// 書き込みが残ってしまう。
    ///
    @Test
    def testPgStoppedChangeRollsBack(): Unit \ {IO, Assert} =
        let body = PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"b1"}, () -> seedBlog() |> snd));
        let outcome = PgTestSupport.withPool(pool -> {
            let stopped = PgTestSupport.mutate(pool, () ->
                SchemaGuard.withImpact(Session.grant(), None, () -> ContentTypes.removeField(Session.grant(), body))) |> Result.isErr;
            let left = PgTestSupport.mutateOrBug(pool, () -> ContentTypes.list(Session.grant())
                |> List.flatMap(owner -> owner#fields) |> List.map(field -> ApiId.text(field#apiId)) |> List.sort);
            (stopped, left)
        });
        Assert.assertEq(expected = (true, List#{"body", "title"}), outcome)

    ///
    /// 見た影響と同じなら通る。消えた後はフィールドが無くなっている。
    ///
    @Test
    def testPgConfirmedChangePasses(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1"}, () -> {
            let (blogs, body) = seedBlog();
            let seen = { kinds = List#{SchemaEffectKind.ValuesHidden}, published = 1i64 };
            SchemaGuard.withImpact(Session.grant(), Some(seen), () -> ContentTypes.removeField(Session.grant(), body));
            fieldsOf(blogs)
        }));
        Assert.assertEq(expected = Ok(Ok(List#{"title"})), result)

    ///
    /// 見た時より件数が増えていれば止まる。減っている（＝見た時の方が多い）時は止めない。
    ///
    /// 件数は他人が別の entry を保存するたびに動くので、一致で止めると確認の画面を
    /// 開いて考えている間に必ず外れる。
    ///
    @Test
    def testPgFingerprintStopsOnlyWhenWorse(): Unit \ {IO, Assert} =
        let stale = { kinds = List#{SchemaEffectKind.ValuesHidden}, published = 0i64 };
        let generous = { kinds = List#{SchemaEffectKind.ValuesHidden}, published = 9i64 };
        let attempt = seen -> PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1"}, () -> {
            let (_, body) = seedBlog();
            pathsOf(CmsTestKit.runWithResult(() ->
                SchemaGuard.withImpact(Session.grant(), Some(seen), () -> ContentTypes.removeField(Session.grant(), body))))
        }));
        Assert.assertEq(expected = (Ok(Ok(List#{"expected"})), Ok(Ok(Nil))), (attempt(stale), attempt(generous)))

}
