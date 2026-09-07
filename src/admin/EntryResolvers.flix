///
/// 管理 API の type Entry のリゾルバ。source はドメインの Entry で、ID と stage と中身と時刻を GraphQL の形に写す。
/// 素通しのフィールドは生成された既定リゾルバに任せる。
///
mod EntryResolvers {

    /// type Entry のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.EntryResolvers[AdminEff] =
        {
            id          = (_context, source) -> Ok(AdminMapping.idOfEntry(source#id)),
            typeId      = (_context, source) -> Ok(AdminMapping.idOfType(source#typeId)),
            stage       = (_context, source) -> Ok(AdminMapping.entryStageToGql(source)),
            fields      = (_context, source) -> Ok(AdminMapping.entryDataValue(source#data)),
            publishedAt = (_context, source) -> Ok(source#publishedAt |> Option.map(Timestamp.toIso8601)),
            createdAt   = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt)),
            updatedAt   = (_context, source) -> Ok(Timestamp.toIso8601(source#updatedAt)),
            +versions   = (_context, source) -> Ok(ContentEntries.versions(source#id)),
            +diff       = (_context, source, fromRef, toRef) -> Ok(diffOf(source, fromRef, toRef))
            | GeneratedAdmin.entryDefaults()
        }

    /// Entry.diff。参照を読んでドメインの差分を取る。
    def diffOf(source: Entry, fromRef: GeneratedAdmin.VersionRef, toRef: GeneratedAdmin.VersionRef): List[FieldChange] \ DbRead + CmsErr + Tenant + Session =
        ContentEntries.diff(source#id, AdminMapping.versionRefOf("from", fromRef), AdminMapping.versionRefOf("to", toRef))

}

///
/// 管理 API の type FieldChange のリゾルバ。source はドメインの FieldChange（パスは最上位から辿った表記）。
///
mod FieldChangeResolvers {

    /// type FieldChange のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.FieldChangeResolvers[AdminEff] =
        {
            path     = (_context, source) -> Ok(FieldChange.path(source)),
            kind     = (_context, source) -> Ok(AdminMapping.changeKindToGql(FieldChange.change(source))),
            before   = (_context, source) -> Ok(AdminMapping.changeBefore(FieldChange.change(source))),
            after    = (_context, source) -> Ok(AdminMapping.changeAfter(FieldChange.change(source))),
            children = (_context, source) -> Ok(AdminMapping.changeChildren(FieldChange.change(source))),
            lines    = (_context, source) -> Ok(AdminMapping.changeLines(FieldChange.change(source)))
        }

}

///
/// 管理 API の type DiffLine のリゾルバ。source はドメインの DiffLine。
///
mod DiffLineResolvers {

    /// type DiffLine のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.DiffLineResolvers[AdminEff] =
        {
            kind = (_context, source) -> Ok(AdminMapping.lineKindToGql(source)),
            text = (_context, source) -> Ok(AdminMapping.lineText(source))
        }

}

///
/// 管理 API の type EntryVersion のリゾルバ。
///
mod EntryVersionResolvers {

    /// type EntryVersion のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.EntryVersionResolvers[AdminEff] =
        {
            id        = (_context, source) -> Ok(AdminMapping.idOfVersion(source#id)),
            reason    = (_context, source) -> Ok(AdminMapping.reasonToGql(source#reason)),
            fields    = (_context, source) -> Ok(AdminMapping.entryDataValue(source#data)),
            createdAt = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt))
            | GeneratedAdmin.entryVersionDefaults()
        }

}

///
/// 管理 API の type EntryPage のリゾルバ。totalCount は GraphQL の Int に収める。
///
mod EntryPageResolvers {

    /// type EntryPage のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.EntryPageResolvers[AdminEff] =
        {
            nodes      = (_context, source) -> Ok(source#entries),
            totalCount = (_context, source) -> Ok(EntryPage.totalCountInt32(source))
        }

}
