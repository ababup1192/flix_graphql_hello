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
            path        = (_context, source) -> Ok(pathOf(source)),
            +versions   = (_context, source) -> Ok(versionsOf(source#id)),
            +autosave   = (_context, source) -> Ok(autosaveOf(source)),
            +diff       = (_context, source, fromRef, toRef) -> Ok(diffOf(source, fromRef, toRef))
            | GeneratedAdmin.entryDefaults()
        }

    ///
    /// Entry.path。型の linkPath に id と slug を差し込む。型紙が無い型は None。
    ///
    /// **コンテンツ API と同じ物を出す。** 本文のリンクの href（`RichText.toHtml`）も
    /// 同じ `LinkPath` で作るので、管理画面で見えたパスがそのまま配信で出る。
    ///
    def pathOf(source: Entry): Option[String] \ DbRead + CmsErr + Tenant + Session + Preloaded =
        let owner = contentTypeOf(source#typeId);
        LinkPath.of(owner#linkPath, EntryId.text(source#id), EntryValue.slugOf(owner, source#data))

    ///
    /// Entry.versions。写しにあればそれ。無ければ一覧のページの分を 1 本でまとめて引いて写しに入れる（ページの最初の行だけ SQL が出る）。
    /// ページに無い entry（mutation の戻り、Query.entry）は 1 件で引く。
    ///
    def versionsOf(id: EntryId): List[EntryVersion] \ DbRead + CmsErr + Tenant + Session + Preloaded =
        match Preloaded.versions(id) {
            case Some(found) => found
            case None        =>
                let page = Preloaded.entryIds();
                if (Set.memberOf(id, page)) {
                    let fetched = ContentEntries.versionsOf(Session.grant(), Set.toList(page));
                    Preloaded.keepVersions(fetched);
                    Map.getWithDefault(id, Nil, fetched)
                } else ContentEntries.versions(Session.grant(), id)
        }

    ///
    /// Entry.autosave。自分の預かり物を下書きと突き合わせる。引き方は versions と同じで、
    /// 一覧なら最初の行でページの分を 1 本でまとめて引いて写しに入れる。
    /// 突き合わせ（state）は行ごとに source（その行の下書き）とするので、写しには生の預かり物を置く。
    ///
    def autosaveOf(source: Entry): Option[EntryAutosave] \ DbRead + CmsErr + Tenant + Session + Preloaded =
        storedOf(source#id) |> Option.flatMap(EntryAutosaves.attach(source))

    /// 預かり物（生）。写しにあればそれ。無ければページの分をまとめて引くか、1 件で引く。
    def storedOf(id: EntryId): Option[StoredAutosave] \ DbRead + CmsErr + Tenant + Session + Preloaded =
        match Preloaded.autosave(id) {
            case Some(found) => found
            case None        =>
                let page = Preloaded.entryIds();
                if (Set.memberOf(id, page)) {
                    let fetched = EntryAutosaves.storedOf(Session.grant(), Set.toList(page));
                    Preloaded.keepAutosaves(fetched);
                    Map.getWithDefault(id, None, fetched)
                } else EntryAutosaves.stored(Session.grant(), id)
        }

    ///
    /// Entry.diff。参照を読んでドメインの差分を取る。entry は source（読み込み済み）、型は写し（無ければ引いて写しに入れる）。
    ///
    def diffOf(source: Entry, fromRef: GeneratedAdmin.VersionRef, toRef: GeneratedAdmin.VersionRef): List[FieldChange] \ DbRead + CmsErr + Tenant + Session + Preloaded =
        ContentEntries.diffOf(Session.grant(), contentTypeOf(source#typeId), source, AdminMapping.versionRefOf("from", fromRef), AdminMapping.versionRefOf("to", toRef))

    /// 型の定義。写しにあればそれ、無ければ引いて写しに入れる（同じ型の行が続く一覧で 1 回だけ引く）。
    def contentTypeOf(id: TypeId): ContentType \ DbRead + CmsErr + Tenant + Session + Preloaded =
        match Preloaded.contentType(id) {
            case Some(found) => found
            case None        => {
                let owner = ContentTypes.get(Session.grant(), id);
                Preloaded.keepContentType(owner);
                owner
            }
        }

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
/// 管理 API の type EntryAutosave のリゾルバ。source はドメインの EntryAutosave。
///
mod EntryAutosaveResolvers {

    /// type EntryAutosave のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.EntryAutosaveResolvers[AdminEff] =
        {
            fields    = (_context, source) -> Ok(AdminMapping.entryDataValue(source#data)),
            state     = (_context, source) -> Ok(AdminMapping.autosaveStateToGql(source#state)),
            updatedAt = (_context, source) -> Ok(Timestamp.toIso8601(source#updatedAt))
            | GeneratedAdmin.entryAutosaveDefaults()
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
            edges      = (_context, source) -> Ok(EntryPage.edges(source)),
            pageInfo   = (_context, source) -> Ok(EntryPage.pageInfo(source)),
            totalCount = (_context, source) -> Ok(EntryPage.totalCountInt32(source))
        }

}

///
/// 管理 API の type EntryEdge のリゾルバ。
///
mod EntryEdgeResolvers {

    /// type EntryEdge のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.EntryEdgeResolvers[AdminEff] =
        {
            +node = (_context, source) -> Ok(source#node)
            | GeneratedAdmin.entryEdgeDefaults()
        }

}

///
/// 管理 API の type PageInfo のリゾルバ。素通し。
///
mod PageInfoResolvers {

    /// type PageInfo のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.PageInfoResolvers[AdminEff] = GeneratedAdmin.pageInfoDefaults()

}
