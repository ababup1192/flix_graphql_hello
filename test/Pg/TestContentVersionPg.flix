///
/// プロジェクトの版（content_version）を実 PostgreSQL で見る。公開・取り下げ・削除・型の変更で +1、下書きの保存では変わらない、他のプロジェクトは変わらない。
///
mod TestContentVersionPg {

    use Util.Json.Json

    ///
    /// 操作の列 → 版の値。
    ///
    ///   最初                       0
    ///   型を作る（schema）          1
    ///   フィールドを足す（schema）  2
    ///   entry を作る（下書き）      2
    ///   下書きを直す               2
    ///   公開                       3
    ///   取り下げ                   4
    ///   ゴミ箱へ                   5
    ///   別のプロジェクト（shop）    0
    ///
    @Test
    def testPgContentVersionAdvancesOnPublishedChanges(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"e1"}, () -> {
            let shop = Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店");
            let initial = Projects.contentVersion();
            let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
            let afterType = Projects.contentVersion();
            discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            let afterField = Projects.contentVersion();
            let entry = ContentEntries.create(blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("hi"))}));
            let afterCreate = Projects.contentVersion();
            discard ContentEntries.update(entry#id, CmsTestKit.entryData(List#{("title", Json.JString("hello"))}), entry#version);
            let afterDraft = Projects.contentVersion();
            discard ContentEntries.publish(entry#id, "tester", false);
            let afterPublish = Projects.contentVersion();
            discard ContentEntries.unpublish(entry#id);
            let afterUnpublish = Projects.contentVersion();
            ContentEntries.delete(entry#id);
            let afterDelete = Projects.contentVersion();
            let other = PgTestSupport.asProject(shop, () -> Projects.contentVersion());
            List#{
                ("initial", initial), ("type", afterType), ("field", afterField), ("create", afterCreate), ("draft", afterDraft),
                ("publish", afterPublish), ("unpublish", afterUnpublish), ("delete", afterDelete), ("other project", other)
            }
        }));
        Assert.assertEq(
            expected = Ok(Ok(List#{
                ("initial", 0i64), ("type", 1i64), ("field", 2i64), ("create", 2i64), ("draft", 2i64),
                ("publish", 3i64), ("unpublish", 4i64), ("delete", 5i64), ("other project", 0i64)
            })),
            result)

}
