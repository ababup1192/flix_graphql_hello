///
/// AdminMapping: GraphQL の型 ↔ ドメインの写し。DB 無し。
///
mod TestAdminMapping {

    /// id は数字の文字列で往復する（TypeId / FieldId / VersionId）。数字でなければ invalid。
    @Test
    def testAdminMappingIdRoundTrip(): Unit \ Assert =
        let roundTrip = () -> (
            AdminMapping.typeId("id", AdminMapping.idOfType(TypeId.TypeId(42i64))),
            AdminMapping.fieldId("id", AdminMapping.idOfField(FieldId.FieldId(7i64))),
            AdminMapping.versionId("id", AdminMapping.idOfVersion(VersionId.VersionId(9i64))));
        Assert.assertEq(expected = (Ok((TypeId.TypeId(42i64), FieldId.FieldId(7i64), VersionId.VersionId(9i64))), List#{"id"}),
            (CmsErr.runWithResult(roundTrip),
             CmsTestKit.failurePaths(CmsErr.runWithResult(() -> AdminMapping.typeId("id", Id.Id("TypeId(1)"))))))

    /// FieldKind と TypeKind は GraphQL の enum と全 case で往復する。
    @Test
    def testAdminMappingKindRoundTrip(): Unit \ Assert =
        let kinds = List#{FieldKind.Text, FieldKind.TextArea, FieldKind.Slug, FieldKind.Number, FieldKind.Boolean, FieldKind.Select, FieldKind.Reference, FieldKind.Object, FieldKind.Blocks, FieldKind.Asset, FieldKind.RichText, FieldKind.Date};
        Assert.assertEq(expected = (kinds, List#{TypeKind.Collection, TypeKind.Singleton}),
            (kinds |> List.map(kind -> AdminMapping.fieldKindOf(AdminMapping.fieldKindToGql(kind))),
             List#{TypeKind.Collection, TypeKind.Singleton} |> List.map(kind -> AdminMapping.typeKindOf(AdminMapping.typeKindToGql(kind)))))

}
