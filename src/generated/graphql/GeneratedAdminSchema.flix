///
/// SDL から schemagen が生成したファイル。手で編集しない（`make generate` で作り直す）。
///
mod GeneratedAdmin {

    /// 生成元の SDL 本文（改行は LF）。GeneratedCheck が SDL ファイルと照合する
    pub def sdlText(): String = "\"\"\"任意の JSON 値。entry の中身（フィールドの apiId → 値）に使う\"\"\"\nscalar JSON\n\n\"\"\"管理 API。content type とフィールドの定義と、entry を読み書きする。形は固定で、コンテンツ API は定義から実行時に組む\"\"\"\ntype Query {\n  \"\"\"全 content type。apiId 順\"\"\"\n  contentTypes: [ContentType!]!\n  \"\"\"id か apiId で 1 つ。無ければ null\"\"\"\n  contentType(id: ID, apiId: String): ContentType\n  \"\"\"型の entry の一覧。更新が新しい順。search は下書きの中身に含む文字列\"\"\"\n  entries(typeId: ID!, search: String, first: Int = 50, skip: Int = 0): EntryPage!\n  \"\"\"entry 1 つ。無ければ null\"\"\"\n  entry(id: ID!): Entry\n  \"\"\"asset の一覧。新しい順。アップロード途中（PENDING）の物も出る\"\"\"\n  assets(first: Int = 50, skip: Int = 0): AssetPage!\n  \"\"\"asset 1 つ。無ければ null\"\"\"\n  asset(id: ID!): Asset\n  \"\"\"公開できるか。書き込まない。violations が空なら publishEntry は通る（unique は押した瞬間の競合を除く）\"\"\"\n  publishCheck(id: ID!): PublishReport!\n  \"\"\"操作の影響。取り下げ・削除で壊れる参照元と、公開で一緒に動く参照先\"\"\"\n  impact(id: ID!, action: ImpactAction!): Impact!\n\n  \"\"\"自分。ログインしていなければ null。organizations と projects は自分が触れる物だけ\"\"\"\n  me: Me\n  \"\"\"今のプロジェクトのメンバー（owner だけ）\"\"\"\n  members: [Member!]!\n  \"\"\"今のプロジェクトの招待（owner だけ）\"\"\"\n  invitations: [Invitation!]!\n  \"\"\"今のプロジェクトの API キー（owner だけ）。生の鍵は出ない\"\"\"\n  apiKeys: [ApiKey!]!\n}\n\n\"\"\"入力の 1 つの誤り。path は GraphQL の入力に対応（\"fields.title\" など）\"\"\"\ntype Violation {\n  path: String!\n  message: String!\n}\n\n\"\"\"公開の検査結果（dry-run）\"\"\"\ntype PublishReport {\n  ok: Boolean!\n  \"\"\"required / unique / 参照の消失 / asset の未完了。全部一度に\"\"\"\n  violations: [Violation!]!\n  \"\"\"未公開の参照先。withDependencies: true で一緒に公開できる\"\"\"\n  unpublishedDependencies: [Entry!]!\n}\n\nenum ImpactAction {\n  PUBLISH\n  UNPUBLISH\n  DELETE\n}\n\n\"\"\"この entry を参照している 1 つ\"\"\"\ntype Referrer {\n  entry: Entry!\n  \"\"\"参照しているフィールドの apiId。本文内のリンクなら RICH_TEXT のフィールド\"\"\"\n  via: String!\n  \"\"\"参照している側のどの中身か\"\"\"\n  stage: ContentStage!\n}\n\n\"\"\"中身の段階\"\"\"\nenum ContentStage {\n  DRAFT\n  PUBLISHED\n}\n\n\"\"\"操作の影響\"\"\"\ntype Impact {\n  \"\"\"壊れる（参照先を失う）entry。取り下げ・削除の前に見せる\"\"\"\n  breaks: [Referrer!]!\n  \"\"\"一緒に動く entry。公開なら先に公開される未公開の参照先\"\"\"\n  cascades: [Entry!]!\n}\n\ntype Mutation {\n  createContentType(input: ContentTypeInput!): ContentType!\n  updateContentType(id: ID!, input: ContentTypePatch!): ContentType!\n  \"\"\"フィールドごと消す\"\"\"\n  deleteContentType(id: ID!): ID!\n  \"\"\"末尾に足す\"\"\"\n  addField(typeId: ID!, input: FieldInput!): FieldDef!\n  updateField(id: ID!, input: FieldPatch!): FieldDef!\n  removeField(id: ID!): ID!\n  \"\"\"ids の順に並べ直す。型の全フィールドを過不足なく渡す\"\"\"\n  reorderFields(typeId: ID!, ids: [ID!]!): ContentType!\n\n  \"\"\"下書きを作る。id を渡せば（移行用）それを使い、無ければ振る。fields は apiId → 値\"\"\"\n  createEntry(typeId: ID!, fields: JSON!, id: ID): Entry!\n  \"\"\"下書きを直す。fields のキーだけ上書きし、null で消す。expectedVersion が今の version と違えば CONFLICT\"\"\"\n  updateEntry(id: ID!, fields: JSON!, expectedVersion: Int!): Entry!\n  \"\"\"ゴミ箱へ（soft delete）。公開中なら公開も取り下げる\"\"\"\n  deleteEntry(id: ID!): ID!\n  \"\"\"下書きを公開する。required と unique と参照先の公開はここで検査する。公開中なら公開側を下書きで上書きする。\n  withDependencies なら未公開の参照先を先に公開する\"\"\"\n  publishEntry(id: ID!, withDependencies: Boolean = false): Entry!\n  \"\"\"公開を取り下げる。下書きは残る\"\"\"\n  unpublishEntry(id: ID!): Entry!\n  \"\"\"今の下書きを版として残す\"\"\"\n  saveVersion(id: ID!): EntryVersion!\n  \"\"\"版の中身を下書きに戻す。expectedVersion は updateEntry と同じ\"\"\"\n  restoreVersion(id: ID!, versionId: ID!, expectedVersion: Int!): Entry!\n\n  \"\"\"asset の置き先（署名付き PUT URL）を発行する。ブラウザが Content-Type / Content-Length を宣言どおりにして PUT し、\n  終わったら confirmAsset を呼ぶ。URL は expiresInSeconds で切れる\"\"\"\n  createUploadUrl(input: UploadInput!): Upload!\n  \"\"\"置いた事をストレージで確かめて READY にする。画像なら寸法を渡す。置かれていなければエラー\"\"\"\n  confirmAsset(id: ID!, input: AssetConfirmInput): Asset!\n  \"\"\"alt を変える。ファイルの差し替えは新しい asset を作る\"\"\"\n  updateAsset(id: ID!, input: AssetPatch!): Asset!\n  \"\"\"消す。entry（下書き・公開・richText の画像を含む）が使っていればエラー\"\"\"\n  deleteAsset(id: ID!): ID!\n\n  \"\"\"組織を作る。作った人が owner\"\"\"\n  createOrganization(name: String!): Organization!\n  \"\"\"組織の下にプロジェクトを作る。組織の owner だけ。slug は subdomain と /p/ に出る\"\"\"\n  createProject(orgId: ID!, slug: String!, name: String!): Project!\n  \"\"\"今のプロジェクトの公開範囲（owner だけ）\"\"\"\n  updateProjectVisibility(visibility: Visibility!): Project!\n  \"\"\"email で招待する（owner だけ）。初回ログインで役割が付く\"\"\"\n  inviteMember(email: String!, role: Role!): Invitation!\n  cancelInvitation(id: ID!): ID!\n  \"\"\"役割を変える（owner だけ）。最後の owner は降格できない\"\"\"\n  changeMemberRole(userId: ID!, role: Role!): Member!\n  \"\"\"外す（owner だけ）。最後の owner は外せない\"\"\"\n  removeMember(userId: ID!): ID!\n  \"\"\"API キーを発行する（owner だけ）。key はこの応答でしか見えない\"\"\"\n  createApiKey(name: String!, scope: ApiKeyScope!): IssuedApiKey!\n  \"\"\"失効する（owner だけ）\"\"\"\n  revokeApiKey(id: ID!): ID!\n}\n\n\"\"\"プロジェクトでの役割。上が下を含む\"\"\"\nenum Role {\n  VIEWER\n  WRITER\n  EDITOR\n  OWNER\n}\n\n\"\"\"組織での役割。OWNER は組織の全プロジェクトの owner でもある\"\"\"\nenum OrgRole {\n  MEMBER\n  OWNER\n}\n\n\"\"\"公開 API の鍵の範囲\"\"\"\nenum ApiKeyScope {\n  \"\"\"公開中の中身\"\"\"\n  READ\n  \"\"\"下書きも\"\"\"\n  READ_DRAFT\n}\n\n\"\"\"プロジェクトの見え方\"\"\"\nenum Visibility {\n  \"\"\"公開中の中身はキー無しで読める\"\"\"\n  PUBLIC\n  \"\"\"read のキーが要る\"\"\"\n  PRIVATE\n}\n\n\"\"\"自分\"\"\"\ntype Me {\n  id: ID!\n  email: String!\n  name: String!\n  \"\"\"今のプロジェクトでの役割（無ければ空）と、できる事\"\"\"\n  roles: [Role!]!\n  permissions: [String!]!\n  organizations: [OrganizationMembership!]!\n  projects: [ProjectMembership!]!\n}\n\ntype Organization {\n  id: ID!\n  name: String!\n}\n\ntype OrganizationMembership {\n  organization: Organization!\n  role: OrgRole!\n}\n\ntype Project {\n  id: ID!\n  slug: String!\n  name: String!\n  visibility: Visibility!\n}\n\ntype ProjectMembership {\n  project: Project!\n  role: Role!\n}\n\ntype Member {\n  userId: ID!\n  email: String!\n  name: String!\n  role: Role!\n}\n\ntype Invitation {\n  id: ID!\n  email: String!\n  role: Role!\n  createdAt: String!\n}\n\ntype ApiKey {\n  id: ID!\n  name: String!\n  scope: ApiKeyScope!\n  createdAt: String!\n  revokedAt: String\n}\n\n\"\"\"発行した鍵。key はこの時だけ\"\"\"\ntype IssuedApiKey {\n  id: ID!\n  name: String!\n  scope: ApiKeyScope!\n  key: String!\n}\n\n\"\"\"asset の状態\"\"\"\nenum AssetStatus {\n  \"\"\"URL を出したが、まだ置かれた事を確かめていない\"\"\"\n  PENDING\n  \"\"\"置かれ、confirmAsset が確かめた\"\"\"\n  READY\n}\n\n\"\"\"画像やファイル。中身はストレージにあり、url で配信する\"\"\"\ntype Asset {\n  id: ID!\n  \"\"\"配信 URL\"\"\"\n  url: String!\n  fileName: String!\n  mime: String!\n  \"\"\"バイト数\"\"\"\n  size: Int!\n  \"\"\"画像の幅。画像でなければ null\"\"\"\n  width: Int\n  height: Int\n  alt: String!\n  status: AssetStatus!\n  createdAt: String!\n  \"\"\"この asset を使っている entry（下書き・公開・本文の image）\"\"\"\n  usedBy: [Entry!]!\n}\n\n\"\"\"asset の一覧の 1 ページ\"\"\"\ntype AssetPage {\n  nodes: [Asset!]!\n  totalCount: Int!\n}\n\n\"\"\"署名付き URL の発行結果\"\"\"\ntype Upload {\n  asset: Asset!\n  \"\"\"ここへ PUT する\"\"\"\n  uploadUrl: String!\n  \"\"\"URL の有効期限（秒）\"\"\"\n  expiresInSeconds: Int!\n}\n\ninput UploadInput {\n  fileName: String!\n  \"\"\"image/png などの許可リストにある物\"\"\"\n  mime: String!\n  \"\"\"バイト数。20 MB まで\"\"\"\n  size: Int!\n}\n\ninput AssetConfirmInput {\n  width: Int\n  height: Int\n  alt: String\n}\n\ninput AssetPatch {\n  alt: String!\n}\n\n\"\"\"entry の状態\"\"\"\nenum EntryStage {\n  \"\"\"まだ公開していない\"\"\"\n  DRAFT\n  \"\"\"公開中で、下書きは公開した物と同じ\"\"\"\n  PUBLISHED\n  \"\"\"公開中で、公開後に下書きが進んでいる（再公開で反映）\"\"\"\n  CHANGED\n}\n\n\"\"\"entry。fields は下書きの中身\"\"\"\ntype Entry {\n  id: ID!\n  typeId: ID!\n  \"\"\"楽観ロックの版。updateEntry に expectedVersion として渡す\"\"\"\n  version: Int!\n  stage: EntryStage!\n  fields: JSON!\n  publishedAt: String\n  createdAt: String!\n  updatedAt: String!\n  \"\"\"版。新しい順。公開時と saveVersion で積む\"\"\"\n  versions: [EntryVersion!]!\n}\n\n\"\"\"版を積んだ理由\"\"\"\nenum VersionReason {\n  PUBLISH\n  SAVE\n}\n\n\"\"\"entry の版\"\"\"\ntype EntryVersion {\n  id: ID!\n  \"\"\"積んだ時点の entry の version\"\"\"\n  version: Int!\n  reason: VersionReason!\n  author: String!\n  fields: JSON!\n  createdAt: String!\n}\n\n\"\"\"entry の一覧の 1 ページ\"\"\"\ntype EntryPage {\n  nodes: [Entry!]!\n  totalCount: Int!\n}\n\n\"\"\"content type の種別\"\"\"\nenum TypeKind {\n  \"\"\"entry を何件でも持つ\"\"\"\n  COLLECTION\n  \"\"\"entry を 1 件だけ持つ（サイト設定など）\"\"\"\n  SINGLETON\n}\n\n\"\"\"フィールドの種類\"\"\"\nenum FieldKind {\n  TEXT\n  TEXT_AREA\n  \"\"\"URL に使う識別子。sourceField から自動生成し、型の中で一意\"\"\"\n  SLUG\n  NUMBER\n  BOOLEAN\n  \"\"\"決まった選択肢から 1 つ。config.options\"\"\"\n  SELECT\n  \"\"\"他の entry への参照。targetTypeId が参照先の型\"\"\"\n  REFERENCE\n  \"\"\"子フィールドを持つ入れ子。値は子の apiId → 値のオブジェクト\"\"\"\n  OBJECT\n  \"\"\"複数の OBJECT（variant）から選んで並べる。常に配列。値は { blockType: <variant の apiId>, ... } の並び\"\"\"\n  BLOCKS\n  \"\"\"画像やファイル。値は asset の id（createUploadUrl で作った物）。コンテンツ API では Asset に展開する\"\"\"\n  ASSET\n  \"\"\"構造化した本文。値は ProseMirror の doc（{ type: \"doc\", content: [...] }）。配列にできない。コンテンツ API では json / html / text\"\"\"\n  RICH_TEXT\n}\n\n\"\"\"content type。apiId がコンテンツ API のクエリ名の元になる\"\"\"\ntype ContentType {\n  id: ID!\n  \"\"\"lowerCamel の識別子（\"blogs\"）\"\"\"\n  apiId: String!\n  kind: TypeKind!\n  \"\"\"管理画面に出す名前\"\"\"\n  name: String!\n  \"\"\"コンテンツ API の型名（\"Blog\"）\"\"\"\n  singular: String!\n  \"\"\"コンテンツ API の一覧クエリ名（\"blogs\"）\"\"\"\n  plural: String!\n  \"\"\"管理画面のプレビューが開く URL。{id} を entry の id に置き換える\"\"\"\n  previewUrl: String\n  \"\"\"最上位のフィールド。position 順。子は children\"\"\"\n  fields: [FieldDef!]!\n  createdAt: String!\n  updatedAt: String!\n}\n\n\"\"\"フィールドの定義\"\"\"\ntype FieldDef {\n  id: ID!\n  apiId: String!\n  name: String!\n  kind: FieldKind!\n  \"\"\"配列か\"\"\"\n  many: Boolean!\n  \"\"\"公開時に値が要るか\"\"\"\n  required: Boolean!\n  \"\"\"型の中で値が一意か\"\"\"\n  unique: Boolean!\n  \"\"\"言語ごとに値を持つか\"\"\"\n  localized: Boolean!\n  \"\"\"REFERENCE の参照先の型\"\"\"\n  targetTypeId: ID\n  \"\"\"OBJECT / BLOCKS の子なら親のフィールド\"\"\"\n  parentFieldId: ID\n  \"\"\"OBJECT の子フィールド、BLOCKS の variant。position 順\"\"\"\n  children: [FieldDef!]!\n  config: FieldConfig!\n  \"\"\"兄弟の中の並び順\"\"\"\n  position: Int!\n}\n\n\"\"\"kind ごとの設定。使わない項目は null\"\"\"\ntype FieldConfig {\n  \"\"\"TEXT / TEXT_AREA / SLUG の最大文字数\"\"\"\n  maxLength: Int\n  \"\"\"SLUG の元にするフィールドの apiId\"\"\"\n  sourceField: String\n  \"\"\"NUMBER の下限\"\"\"\n  min: Float\n  \"\"\"NUMBER の上限\"\"\"\n  max: Float\n  \"\"\"NUMBER を整数に限るか\"\"\"\n  integer: Boolean\n  \"\"\"SELECT の選択肢。UPPER_SNAKE\"\"\"\n  options: [String!]\n}\n\ninput ContentTypeInput {\n  apiId: String!\n  kind: TypeKind = COLLECTION\n  name: String!\n  \"\"\"省くと apiId から導く\"\"\"\n  singular: String\n  \"\"\"省くと apiId から導く\"\"\"\n  plural: String\n  previewUrl: String\n}\n\n\"\"\"触らない項目は省く\"\"\"\ninput ContentTypePatch {\n  name: String\n  singular: String\n  plural: String\n  previewUrl: String\n}\n\ninput FieldInput {\n  apiId: String!\n  name: String!\n  kind: FieldKind!\n  many: Boolean = false\n  required: Boolean = false\n  unique: Boolean = false\n  localized: Boolean = false\n  \"\"\"REFERENCE の参照先の型\"\"\"\n  targetTypeId: ID\n  \"\"\"OBJECT / BLOCKS の子として足すなら親のフィールド\"\"\"\n  parentFieldId: ID\n  config: FieldConfigInput\n}\n\n\"\"\"触らない項目は省く。config は丸ごと置き換える\"\"\"\ninput FieldPatch {\n  name: String\n  required: Boolean\n  unique: Boolean\n  localized: Boolean\n  config: FieldConfigInput\n}\n\ninput FieldConfigInput {\n  maxLength: Int\n  sourceField: String\n  min: Float\n  max: Float\n  integer: Boolean\n  options: [String!]\n}\n"

    /// 生成した schemagen のバージョン
    pub def generatorVersion(): String = "6"

    /// enum ImpactAction
    pub enum ImpactAction with Eq, Order, ToString {
        /// PUBLISH
        case Publish
        /// UNPUBLISH
        case Unpublish
        /// DELETE
        case Delete
    }

    /// ImpactAction の Codec
    pub def impactActionCodec(): GqlCodec[ImpactAction] =
        GqlCodec.enumOf("ImpactAction", value -> match value { case ImpactAction.Publish => "PUBLISH" case ImpactAction.Unpublish => "UNPUBLISH" case ImpactAction.Delete => "DELETE" }, ImpactAction.Publish :: ImpactAction.Unpublish :: ImpactAction.Delete :: Nil)

    /// enum ContentStage。中身の段階
    pub enum ContentStage with Eq, Order, ToString {
        /// DRAFT
        case Draft
        /// PUBLISHED
        case Published
    }

    /// ContentStage の Codec
    pub def contentStageCodec(): GqlCodec[ContentStage] =
        GqlCodec.enumOf("ContentStage", value -> match value { case ContentStage.Draft => "DRAFT" case ContentStage.Published => "PUBLISHED" }, ContentStage.Draft :: ContentStage.Published :: Nil) |> GqlCodec.describe("中身の段階")

    /// enum Role。プロジェクトでの役割。上が下を含む
    pub enum Role with Eq, Order, ToString {
        /// VIEWER
        case Viewer
        /// WRITER
        case Writer
        /// EDITOR
        case Editor
        /// OWNER
        case Owner
    }

    /// Role の Codec
    pub def roleCodec(): GqlCodec[Role] =
        GqlCodec.enumOf("Role", value -> match value { case Role.Viewer => "VIEWER" case Role.Writer => "WRITER" case Role.Editor => "EDITOR" case Role.Owner => "OWNER" }, Role.Viewer :: Role.Writer :: Role.Editor :: Role.Owner :: Nil) |> GqlCodec.describe("プロジェクトでの役割。上が下を含む")

    /// enum OrgRole。組織での役割。OWNER は組織の全プロジェクトの owner でもある
    pub enum OrgRole with Eq, Order, ToString {
        /// MEMBER
        case Member
        /// OWNER
        case Owner
    }

    /// OrgRole の Codec
    pub def orgRoleCodec(): GqlCodec[OrgRole] =
        GqlCodec.enumOf("OrgRole", value -> match value { case OrgRole.Member => "MEMBER" case OrgRole.Owner => "OWNER" }, OrgRole.Member :: OrgRole.Owner :: Nil) |> GqlCodec.describe("組織での役割。OWNER は組織の全プロジェクトの owner でもある")

    /// enum ApiKeyScope。公開 API の鍵の範囲
    pub enum ApiKeyScope with Eq, Order, ToString {
        /// 公開中の中身
        case Read
        /// 下書きも
        case ReadDraft
    }

    /// ApiKeyScope の Codec
    pub def apiKeyScopeCodec(): GqlCodec[ApiKeyScope] =
        GqlCodec.enumOf("ApiKeyScope", value -> match value { case ApiKeyScope.Read => "READ" case ApiKeyScope.ReadDraft => "READ_DRAFT" }, ApiKeyScope.Read :: ApiKeyScope.ReadDraft :: Nil) |> GqlCodec.describe("公開 API の鍵の範囲") |> GqlCodec.describeValue(ApiKeyScope.Read, "公開中の中身") |> GqlCodec.describeValue(ApiKeyScope.ReadDraft, "下書きも")

    /// enum Visibility。プロジェクトの見え方
    pub enum Visibility with Eq, Order, ToString {
        /// 公開中の中身はキー無しで読める
        case Public
        /// read のキーが要る
        case Private
    }

    /// Visibility の Codec
    pub def visibilityCodec(): GqlCodec[Visibility] =
        GqlCodec.enumOf("Visibility", value -> match value { case Visibility.Public => "PUBLIC" case Visibility.Private => "PRIVATE" }, Visibility.Public :: Visibility.Private :: Nil) |> GqlCodec.describe("プロジェクトの見え方") |> GqlCodec.describeValue(Visibility.Public, "公開中の中身はキー無しで読める") |> GqlCodec.describeValue(Visibility.Private, "read のキーが要る")

    /// enum AssetStatus。asset の状態
    pub enum AssetStatus with Eq, Order, ToString {
        /// URL を出したが、まだ置かれた事を確かめていない
        case Pending
        /// 置かれ、confirmAsset が確かめた
        case Ready
    }

    /// AssetStatus の Codec
    pub def assetStatusCodec(): GqlCodec[AssetStatus] =
        GqlCodec.enumOf("AssetStatus", value -> match value { case AssetStatus.Pending => "PENDING" case AssetStatus.Ready => "READY" }, AssetStatus.Pending :: AssetStatus.Ready :: Nil) |> GqlCodec.describe("asset の状態") |> GqlCodec.describeValue(AssetStatus.Pending, "URL を出したが、まだ置かれた事を確かめていない") |> GqlCodec.describeValue(AssetStatus.Ready, "置かれ、confirmAsset が確かめた")

    /// enum EntryStage。entry の状態
    pub enum EntryStage with Eq, Order, ToString {
        /// まだ公開していない
        case Draft
        /// 公開中で、下書きは公開した物と同じ
        case Published
        /// 公開中で、公開後に下書きが進んでいる（再公開で反映）
        case Changed
    }

    /// EntryStage の Codec
    pub def entryStageCodec(): GqlCodec[EntryStage] =
        GqlCodec.enumOf("EntryStage", value -> match value { case EntryStage.Draft => "DRAFT" case EntryStage.Published => "PUBLISHED" case EntryStage.Changed => "CHANGED" }, EntryStage.Draft :: EntryStage.Published :: EntryStage.Changed :: Nil) |> GqlCodec.describe("entry の状態") |> GqlCodec.describeValue(EntryStage.Draft, "まだ公開していない") |> GqlCodec.describeValue(EntryStage.Published, "公開中で、下書きは公開した物と同じ") |> GqlCodec.describeValue(EntryStage.Changed, "公開中で、公開後に下書きが進んでいる（再公開で反映）")

    /// enum VersionReason。版を積んだ理由
    pub enum VersionReason with Eq, Order, ToString {
        /// PUBLISH
        case Publish
        /// SAVE
        case Save
    }

    /// VersionReason の Codec
    pub def versionReasonCodec(): GqlCodec[VersionReason] =
        GqlCodec.enumOf("VersionReason", value -> match value { case VersionReason.Publish => "PUBLISH" case VersionReason.Save => "SAVE" }, VersionReason.Publish :: VersionReason.Save :: Nil) |> GqlCodec.describe("版を積んだ理由")

    /// enum TypeKind。content type の種別
    pub enum TypeKind with Eq, Order, ToString {
        /// entry を何件でも持つ
        case Collection
        /// entry を 1 件だけ持つ（サイト設定など）
        case Singleton
    }

    /// TypeKind の Codec
    pub def typeKindCodec(): GqlCodec[TypeKind] =
        GqlCodec.enumOf("TypeKind", value -> match value { case TypeKind.Collection => "COLLECTION" case TypeKind.Singleton => "SINGLETON" }, TypeKind.Collection :: TypeKind.Singleton :: Nil) |> GqlCodec.describe("content type の種別") |> GqlCodec.describeValue(TypeKind.Collection, "entry を何件でも持つ") |> GqlCodec.describeValue(TypeKind.Singleton, "entry を 1 件だけ持つ（サイト設定など）")

    /// enum FieldKind。フィールドの種類
    pub enum FieldKind with Eq, Order, ToString {
        /// TEXT
        case Text
        /// TEXT_AREA
        case TextArea
        /// URL に使う識別子。sourceField から自動生成し、型の中で一意
        case Slug
        /// NUMBER
        case Number
        /// BOOLEAN
        case Boolean
        /// 決まった選択肢から 1 つ。config.options
        case Select
        /// 他の entry への参照。targetTypeId が参照先の型
        case Reference
        /// 子フィールドを持つ入れ子。値は子の apiId → 値のオブジェクト
        case Object
        /// 複数の OBJECT（variant）から選んで並べる。常に配列。値は { blockType: <variant の apiId>, ... } の並び
        case Blocks
        /// 画像やファイル。値は asset の id（createUploadUrl で作った物）。コンテンツ API では Asset に展開する
        case Asset
        /// 構造化した本文。値は ProseMirror の doc（{ type: "doc", content: [...] }）。配列にできない。コンテンツ API では json / html / text
        case RichText
    }

    /// FieldKind の Codec
    pub def fieldKindCodec(): GqlCodec[FieldKind] =
        GqlCodec.enumOf("FieldKind", value -> match value { case FieldKind.Text => "TEXT" case FieldKind.TextArea => "TEXT_AREA" case FieldKind.Slug => "SLUG" case FieldKind.Number => "NUMBER" case FieldKind.Boolean => "BOOLEAN" case FieldKind.Select => "SELECT" case FieldKind.Reference => "REFERENCE" case FieldKind.Object => "OBJECT" case FieldKind.Blocks => "BLOCKS" case FieldKind.Asset => "ASSET" case FieldKind.RichText => "RICH_TEXT" }, FieldKind.Text :: FieldKind.TextArea :: FieldKind.Slug :: FieldKind.Number :: FieldKind.Boolean :: FieldKind.Select :: FieldKind.Reference :: FieldKind.Object :: FieldKind.Blocks :: FieldKind.Asset :: FieldKind.RichText :: Nil) |> GqlCodec.describe("フィールドの種類") |> GqlCodec.describeValue(FieldKind.Slug, "URL に使う識別子。sourceField から自動生成し、型の中で一意") |> GqlCodec.describeValue(FieldKind.Select, "決まった選択肢から 1 つ。config.options") |> GqlCodec.describeValue(FieldKind.Reference, "他の entry への参照。targetTypeId が参照先の型") |> GqlCodec.describeValue(FieldKind.Object, "子フィールドを持つ入れ子。値は子の apiId → 値のオブジェクト") |> GqlCodec.describeValue(FieldKind.Blocks, "複数の OBJECT（variant）から選んで並べる。常に配列。値は { blockType: <variant の apiId>, ... } の並び") |> GqlCodec.describeValue(FieldKind.Asset, "画像やファイル。値は asset の id（createUploadUrl で作った物）。コンテンツ API では Asset に展開する") |> GqlCodec.describeValue(FieldKind.RichText, "構造化した本文。値は ProseMirror の doc（{ type: \"doc\", content: [...] }）。配列にできない。コンテンツ API では json / html / text")

    /// input UploadInput
    pub type alias UploadInput = { fileName = String, mime = String, size = Int32 }

    /// UploadInput の Codec
    pub def uploadInputCodec(): GqlCodec[UploadInput] =
        let f0 = Schema.arg("fileName", GqlCodec.string());
        let f1 = Schema.arg("mime", GqlCodec.string()) |> Arg.withDescription("image/png などの許可リストにある物");
        let f2 = Schema.arg("size", GqlCodec.int32()) |> Arg.withDescription("バイト数。20 MB まで");
        GqlCodec.inputObject("UploadInput", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields)) yield { fileName = v0, mime = v1, size = v2 })

    /// input AssetConfirmInput
    pub type alias AssetConfirmInput = { width = Option[Int32], height = Option[Int32], alt = Option[String] }

    /// AssetConfirmInput の Codec
    pub def assetConfirmInputCodec(): GqlCodec[AssetConfirmInput] =
        let f0 = Schema.arg("width", GqlCodec.option(GqlCodec.int32()));
        let f1 = Schema.arg("height", GqlCodec.option(GqlCodec.int32()));
        let f2 = Schema.arg("alt", GqlCodec.option(GqlCodec.string()));
        GqlCodec.inputObject("AssetConfirmInput", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields)) yield { width = v0, height = v1, alt = v2 })

    /// input AssetPatch
    pub type alias AssetPatch = { alt = String }

    /// AssetPatch の Codec
    pub def assetPatchCodec(): GqlCodec[AssetPatch] =
        let f0 = Schema.arg("alt", GqlCodec.string());
        GqlCodec.inputObject("AssetPatch", Arg.info(f0) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields)) yield { alt = v0 })

    /// input ContentTypeInput
    pub type alias ContentTypeInput = { apiId = String, kind = Option[TypeKind], name = String, singular = Option[String], plural = Option[String], previewUrl = Option[String] }

    /// ContentTypeInput の Codec
    pub def contentTypeInputCodec(): GqlCodec[ContentTypeInput] =
        let f0 = Schema.arg("apiId", GqlCodec.string());
        let f1 = Schema.arg("kind", GqlCodec.option(typeKindCodec())) |> Arg.withDefaultValue(Value.Str("COLLECTION"));
        let f2 = Schema.arg("name", GqlCodec.string());
        let f3 = Schema.arg("singular", GqlCodec.option(GqlCodec.string())) |> Arg.withDescription("省くと apiId から導く");
        let f4 = Schema.arg("plural", GqlCodec.option(GqlCodec.string())) |> Arg.withDescription("省くと apiId から導く");
        let f5 = Schema.arg("previewUrl", GqlCodec.option(GqlCodec.string()));
        GqlCodec.inputObject("ContentTypeInput", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Arg.info(f3) :: Arg.info(f4) :: Arg.info(f5) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields); v3 <- Arg.decodeField(f3, fields); v4 <- Arg.decodeField(f4, fields); v5 <- Arg.decodeField(f5, fields)) yield { apiId = v0, kind = v1, name = v2, singular = v3, plural = v4, previewUrl = v5 })

    /// input ContentTypePatch
    pub type alias ContentTypePatch = { name = Option[String], singular = Option[String], plural = Option[String], previewUrl = Option[String] }

    /// ContentTypePatch の Codec
    pub def contentTypePatchCodec(): GqlCodec[ContentTypePatch] =
        let f0 = Schema.arg("name", GqlCodec.option(GqlCodec.string()));
        let f1 = Schema.arg("singular", GqlCodec.option(GqlCodec.string()));
        let f2 = Schema.arg("plural", GqlCodec.option(GqlCodec.string()));
        let f3 = Schema.arg("previewUrl", GqlCodec.option(GqlCodec.string()));
        GqlCodec.inputObject("ContentTypePatch", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Arg.info(f3) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields); v3 <- Arg.decodeField(f3, fields)) yield { name = v0, singular = v1, plural = v2, previewUrl = v3 }) |> GqlCodec.describe("触らない項目は省く")

    /// input FieldInput
    pub type alias FieldInput = { apiId = String, name = String, kind = FieldKind, many = Option[Bool], required = Option[Bool], unique = Option[Bool], localized = Option[Bool], targetTypeId = Option[Id], parentFieldId = Option[Id], config = Option[FieldConfigInput] }

    /// FieldInput の Codec
    pub def fieldInputCodec(): GqlCodec[FieldInput] =
        let f0 = Schema.arg("apiId", GqlCodec.string());
        let f1 = Schema.arg("name", GqlCodec.string());
        let f2 = Schema.arg("kind", fieldKindCodec());
        let f3 = Schema.arg("many", GqlCodec.option(GqlCodec.bool())) |> Arg.withDefaultValue(Value.Bool(false));
        let f4 = Schema.arg("required", GqlCodec.option(GqlCodec.bool())) |> Arg.withDefaultValue(Value.Bool(false));
        let f5 = Schema.arg("unique", GqlCodec.option(GqlCodec.bool())) |> Arg.withDefaultValue(Value.Bool(false));
        let f6 = Schema.arg("localized", GqlCodec.option(GqlCodec.bool())) |> Arg.withDefaultValue(Value.Bool(false));
        let f7 = Schema.arg("targetTypeId", GqlCodec.option(GqlCodec.id())) |> Arg.withDescription("REFERENCE の参照先の型");
        let f8 = Schema.arg("parentFieldId", GqlCodec.option(GqlCodec.id())) |> Arg.withDescription("OBJECT / BLOCKS の子として足すなら親のフィールド");
        let f9 = Schema.arg("config", GqlCodec.option(fieldConfigInputCodec()));
        GqlCodec.inputObject("FieldInput", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Arg.info(f3) :: Arg.info(f4) :: Arg.info(f5) :: Arg.info(f6) :: Arg.info(f7) :: Arg.info(f8) :: Arg.info(f9) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields); v3 <- Arg.decodeField(f3, fields); v4 <- Arg.decodeField(f4, fields); v5 <- Arg.decodeField(f5, fields); v6 <- Arg.decodeField(f6, fields); v7 <- Arg.decodeField(f7, fields); v8 <- Arg.decodeField(f8, fields); v9 <- Arg.decodeField(f9, fields)) yield { apiId = v0, name = v1, kind = v2, many = v3, required = v4, unique = v5, localized = v6, targetTypeId = v7, parentFieldId = v8, config = v9 })

    /// input FieldPatch
    pub type alias FieldPatch = { name = Option[String], required = Option[Bool], unique = Option[Bool], localized = Option[Bool], config = Option[FieldConfigInput] }

    /// FieldPatch の Codec
    pub def fieldPatchCodec(): GqlCodec[FieldPatch] =
        let f0 = Schema.arg("name", GqlCodec.option(GqlCodec.string()));
        let f1 = Schema.arg("required", GqlCodec.option(GqlCodec.bool()));
        let f2 = Schema.arg("unique", GqlCodec.option(GqlCodec.bool()));
        let f3 = Schema.arg("localized", GqlCodec.option(GqlCodec.bool()));
        let f4 = Schema.arg("config", GqlCodec.option(fieldConfigInputCodec()));
        GqlCodec.inputObject("FieldPatch", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Arg.info(f3) :: Arg.info(f4) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields); v3 <- Arg.decodeField(f3, fields); v4 <- Arg.decodeField(f4, fields)) yield { name = v0, required = v1, unique = v2, localized = v3, config = v4 }) |> GqlCodec.describe("触らない項目は省く。config は丸ごと置き換える")

    /// input FieldConfigInput
    pub type alias FieldConfigInput = { maxLength = Option[Int32], sourceField = Option[String], min = Option[Float64], max = Option[Float64], integer = Option[Bool], options = Option[List[String]] }

    /// FieldConfigInput の Codec
    pub def fieldConfigInputCodec(): GqlCodec[FieldConfigInput] =
        let f0 = Schema.arg("maxLength", GqlCodec.option(GqlCodec.int32()));
        let f1 = Schema.arg("sourceField", GqlCodec.option(GqlCodec.string()));
        let f2 = Schema.arg("min", GqlCodec.option(GqlCodec.float64()));
        let f3 = Schema.arg("max", GqlCodec.option(GqlCodec.float64()));
        let f4 = Schema.arg("integer", GqlCodec.option(GqlCodec.bool()));
        let f5 = Schema.arg("options", GqlCodec.option(GqlCodec.list(GqlCodec.string())));
        GqlCodec.inputObject("FieldConfigInput", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Arg.info(f3) :: Arg.info(f4) :: Arg.info(f5) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields); v3 <- Arg.decodeField(f3, fields); v4 <- Arg.decodeField(f4, fields); v5 <- Arg.decodeField(f5, fields)) yield { maxLength = v0, sourceField = v1, min = v2, max = v3, integer = v4, options = v5 })

    /// Query.contentTypes
    pub type alias QueryContentTypesResolver[ef: Eff] = Context -> Result[FieldError, List[ContentType]] \ ef
    /// Query.contentType
    pub type alias QueryContentTypeResolver[ef: Eff] = Context -> Option[Id] -> Option[String] -> Result[FieldError, Option[ContentType]] \ ef
    /// Query.entries
    pub type alias QueryEntriesResolver[ef: Eff] = Context -> Id -> Option[String] -> Option[Int32] -> Option[Int32] -> Result[FieldError, EntryPage] \ ef
    /// Query.entry
    pub type alias QueryEntryResolver[ef: Eff] = Context -> Id -> Result[FieldError, Option[Entry]] \ ef
    /// Query.assets
    pub type alias QueryAssetsResolver[ef: Eff] = Context -> Option[Int32] -> Option[Int32] -> Result[FieldError, AssetPage] \ ef
    /// Query.asset
    pub type alias QueryAssetResolver[ef: Eff] = Context -> Id -> Result[FieldError, Option[Asset]] \ ef
    /// Query.publishCheck
    pub type alias QueryPublishCheckResolver[ef: Eff] = Context -> Id -> Result[FieldError, PublishReport] \ ef
    /// Query.impact
    pub type alias QueryImpactResolver[ef: Eff] = Context -> Id -> ImpactAction -> Result[FieldError, Impact] \ ef
    /// Query.me
    pub type alias QueryMeResolver[ef: Eff] = Context -> Result[FieldError, Option[Me]] \ ef
    /// Query.members
    pub type alias QueryMembersResolver[ef: Eff] = Context -> Result[FieldError, List[Member]] \ ef
    /// Query.invitations
    pub type alias QueryInvitationsResolver[ef: Eff] = Context -> Result[FieldError, List[Invitation]] \ ef
    /// Query.apiKeys
    pub type alias QueryApiKeysResolver[ef: Eff] = Context -> Result[FieldError, List[ApiKey]] \ ef
    /// Violation.path
    pub type alias ViolationPathResolver[ef: Eff] = Context -> Violation -> Result[FieldError, String] \ ef
    /// Violation.message
    pub type alias ViolationMessageResolver[ef: Eff] = Context -> Violation -> Result[FieldError, String] \ ef
    /// PublishReport.ok
    pub type alias PublishReportOkResolver[ef: Eff] = Context -> PublishReport -> Result[FieldError, Bool] \ ef
    /// PublishReport.violations
    pub type alias PublishReportViolationsResolver[ef: Eff] = Context -> PublishReport -> Result[FieldError, List[Violation]] \ ef
    /// PublishReport.unpublishedDependencies
    pub type alias PublishReportUnpublishedDependenciesResolver[ef: Eff] = Context -> PublishReport -> Result[FieldError, List[Entry]] \ ef
    /// Referrer.entry
    pub type alias ReferrerEntryResolver[ef: Eff] = Context -> Referrer -> Result[FieldError, Entry] \ ef
    /// Referrer.via
    pub type alias ReferrerViaResolver[ef: Eff] = Context -> Referrer -> Result[FieldError, String] \ ef
    /// Referrer.stage
    pub type alias ReferrerStageResolver[ef: Eff] = Context -> Referrer -> Result[FieldError, ContentStage] \ ef
    /// Impact.breaks
    pub type alias ImpactBreaksResolver[ef: Eff] = Context -> Impact -> Result[FieldError, List[Referrer]] \ ef
    /// Impact.cascades
    pub type alias ImpactCascadesResolver[ef: Eff] = Context -> Impact -> Result[FieldError, List[Entry]] \ ef
    /// Mutation.createContentType
    pub type alias MutationCreateContentTypeResolver[ef: Eff] = Context -> ContentTypeInput -> Result[FieldError, ContentType] \ ef
    /// Mutation.updateContentType
    pub type alias MutationUpdateContentTypeResolver[ef: Eff] = Context -> Id -> ContentTypePatch -> Result[FieldError, ContentType] \ ef
    /// Mutation.deleteContentType
    pub type alias MutationDeleteContentTypeResolver[ef: Eff] = Context -> Id -> Result[FieldError, Id] \ ef
    /// Mutation.addField
    pub type alias MutationAddFieldResolver[ef: Eff] = Context -> Id -> FieldInput -> Result[FieldError, FieldDef] \ ef
    /// Mutation.updateField
    pub type alias MutationUpdateFieldResolver[ef: Eff] = Context -> Id -> FieldPatch -> Result[FieldError, FieldDef] \ ef
    /// Mutation.removeField
    pub type alias MutationRemoveFieldResolver[ef: Eff] = Context -> Id -> Result[FieldError, Id] \ ef
    /// Mutation.reorderFields
    pub type alias MutationReorderFieldsResolver[ef: Eff] = Context -> Id -> List[Id] -> Result[FieldError, ContentType] \ ef
    /// Mutation.createEntry
    pub type alias MutationCreateEntryResolver[ef: Eff] = Context -> Id -> Value -> Option[Id] -> Result[FieldError, Entry] \ ef
    /// Mutation.updateEntry
    pub type alias MutationUpdateEntryResolver[ef: Eff] = Context -> Id -> Value -> Int32 -> Result[FieldError, Entry] \ ef
    /// Mutation.deleteEntry
    pub type alias MutationDeleteEntryResolver[ef: Eff] = Context -> Id -> Result[FieldError, Id] \ ef
    /// Mutation.publishEntry
    pub type alias MutationPublishEntryResolver[ef: Eff] = Context -> Id -> Option[Bool] -> Result[FieldError, Entry] \ ef
    /// Mutation.unpublishEntry
    pub type alias MutationUnpublishEntryResolver[ef: Eff] = Context -> Id -> Result[FieldError, Entry] \ ef
    /// Mutation.saveVersion
    pub type alias MutationSaveVersionResolver[ef: Eff] = Context -> Id -> Result[FieldError, EntryVersion] \ ef
    /// Mutation.restoreVersion
    pub type alias MutationRestoreVersionResolver[ef: Eff] = Context -> Id -> Id -> Int32 -> Result[FieldError, Entry] \ ef
    /// Mutation.createUploadUrl
    pub type alias MutationCreateUploadUrlResolver[ef: Eff] = Context -> UploadInput -> Result[FieldError, Upload] \ ef
    /// Mutation.confirmAsset
    pub type alias MutationConfirmAssetResolver[ef: Eff] = Context -> Id -> Option[AssetConfirmInput] -> Result[FieldError, Asset] \ ef
    /// Mutation.updateAsset
    pub type alias MutationUpdateAssetResolver[ef: Eff] = Context -> Id -> AssetPatch -> Result[FieldError, Asset] \ ef
    /// Mutation.deleteAsset
    pub type alias MutationDeleteAssetResolver[ef: Eff] = Context -> Id -> Result[FieldError, Id] \ ef
    /// Mutation.createOrganization
    pub type alias MutationCreateOrganizationResolver[ef: Eff] = Context -> String -> Result[FieldError, Organization] \ ef
    /// Mutation.createProject
    pub type alias MutationCreateProjectResolver[ef: Eff] = Context -> Id -> String -> String -> Result[FieldError, Project] \ ef
    /// Mutation.updateProjectVisibility
    pub type alias MutationUpdateProjectVisibilityResolver[ef: Eff] = Context -> Visibility -> Result[FieldError, Project] \ ef
    /// Mutation.inviteMember
    pub type alias MutationInviteMemberResolver[ef: Eff] = Context -> String -> Role -> Result[FieldError, Invitation] \ ef
    /// Mutation.cancelInvitation
    pub type alias MutationCancelInvitationResolver[ef: Eff] = Context -> Id -> Result[FieldError, Id] \ ef
    /// Mutation.changeMemberRole
    pub type alias MutationChangeMemberRoleResolver[ef: Eff] = Context -> Id -> Role -> Result[FieldError, Member] \ ef
    /// Mutation.removeMember
    pub type alias MutationRemoveMemberResolver[ef: Eff] = Context -> Id -> Result[FieldError, Id] \ ef
    /// Mutation.createApiKey
    pub type alias MutationCreateApiKeyResolver[ef: Eff] = Context -> String -> ApiKeyScope -> Result[FieldError, IssuedApiKey] \ ef
    /// Mutation.revokeApiKey
    pub type alias MutationRevokeApiKeyResolver[ef: Eff] = Context -> Id -> Result[FieldError, Id] \ ef
    /// Me.id
    pub type alias MeIdResolver[ef: Eff] = Context -> Me -> Result[FieldError, Id] \ ef
    /// Me.email
    pub type alias MeEmailResolver[ef: Eff] = Context -> Me -> Result[FieldError, String] \ ef
    /// Me.name
    pub type alias MeNameResolver[ef: Eff] = Context -> Me -> Result[FieldError, String] \ ef
    /// Me.roles
    pub type alias MeRolesResolver[ef: Eff] = Context -> Me -> Result[FieldError, List[Role]] \ ef
    /// Me.permissions
    pub type alias MePermissionsResolver[ef: Eff] = Context -> Me -> Result[FieldError, List[String]] \ ef
    /// Me.organizations
    pub type alias MeOrganizationsResolver[ef: Eff] = Context -> Me -> Result[FieldError, List[OrganizationMembership]] \ ef
    /// Me.projects
    pub type alias MeProjectsResolver[ef: Eff] = Context -> Me -> Result[FieldError, List[ProjectMembership]] \ ef
    /// Organization.id
    pub type alias OrganizationIdResolver[ef: Eff] = Context -> Organization -> Result[FieldError, Id] \ ef
    /// Organization.name
    pub type alias OrganizationNameResolver[ef: Eff] = Context -> Organization -> Result[FieldError, String] \ ef
    /// OrganizationMembership.organization
    pub type alias OrganizationMembershipOrganizationResolver[ef: Eff] = Context -> OrganizationMembership -> Result[FieldError, Organization] \ ef
    /// OrganizationMembership.role
    pub type alias OrganizationMembershipRoleResolver[ef: Eff] = Context -> OrganizationMembership -> Result[FieldError, OrgRole] \ ef
    /// Project.id
    pub type alias ProjectIdResolver[ef: Eff] = Context -> Project -> Result[FieldError, Id] \ ef
    /// Project.slug
    pub type alias ProjectSlugResolver[ef: Eff] = Context -> Project -> Result[FieldError, String] \ ef
    /// Project.name
    pub type alias ProjectNameResolver[ef: Eff] = Context -> Project -> Result[FieldError, String] \ ef
    /// Project.visibility
    pub type alias ProjectVisibilityResolver[ef: Eff] = Context -> Project -> Result[FieldError, Visibility] \ ef
    /// ProjectMembership.project
    pub type alias ProjectMembershipProjectResolver[ef: Eff] = Context -> ProjectMembership -> Result[FieldError, Project] \ ef
    /// ProjectMembership.role
    pub type alias ProjectMembershipRoleResolver[ef: Eff] = Context -> ProjectMembership -> Result[FieldError, Role] \ ef
    /// Member.userId
    pub type alias MemberUserIdResolver[ef: Eff] = Context -> Member -> Result[FieldError, Id] \ ef
    /// Member.email
    pub type alias MemberEmailResolver[ef: Eff] = Context -> Member -> Result[FieldError, String] \ ef
    /// Member.name
    pub type alias MemberNameResolver[ef: Eff] = Context -> Member -> Result[FieldError, String] \ ef
    /// Member.role
    pub type alias MemberRoleResolver[ef: Eff] = Context -> Member -> Result[FieldError, Role] \ ef
    /// Invitation.id
    pub type alias InvitationIdResolver[ef: Eff] = Context -> Invitation -> Result[FieldError, Id] \ ef
    /// Invitation.email
    pub type alias InvitationEmailResolver[ef: Eff] = Context -> Invitation -> Result[FieldError, String] \ ef
    /// Invitation.role
    pub type alias InvitationRoleResolver[ef: Eff] = Context -> Invitation -> Result[FieldError, Role] \ ef
    /// Invitation.createdAt
    pub type alias InvitationCreatedAtResolver[ef: Eff] = Context -> Invitation -> Result[FieldError, String] \ ef
    /// ApiKey.id
    pub type alias ApiKeyIdResolver[ef: Eff] = Context -> ApiKey -> Result[FieldError, Id] \ ef
    /// ApiKey.name
    pub type alias ApiKeyNameResolver[ef: Eff] = Context -> ApiKey -> Result[FieldError, String] \ ef
    /// ApiKey.scope
    pub type alias ApiKeyScopeResolver[ef: Eff] = Context -> ApiKey -> Result[FieldError, ApiKeyScope] \ ef
    /// ApiKey.createdAt
    pub type alias ApiKeyCreatedAtResolver[ef: Eff] = Context -> ApiKey -> Result[FieldError, String] \ ef
    /// ApiKey.revokedAt
    pub type alias ApiKeyRevokedAtResolver[ef: Eff] = Context -> ApiKey -> Result[FieldError, Option[String]] \ ef
    /// IssuedApiKey.id
    pub type alias IssuedApiKeyIdResolver[ef: Eff] = Context -> IssuedApiKey -> Result[FieldError, Id] \ ef
    /// IssuedApiKey.name
    pub type alias IssuedApiKeyNameResolver[ef: Eff] = Context -> IssuedApiKey -> Result[FieldError, String] \ ef
    /// IssuedApiKey.scope
    pub type alias IssuedApiKeyScopeResolver[ef: Eff] = Context -> IssuedApiKey -> Result[FieldError, ApiKeyScope] \ ef
    /// IssuedApiKey.key
    pub type alias IssuedApiKeyKeyResolver[ef: Eff] = Context -> IssuedApiKey -> Result[FieldError, String] \ ef
    /// Asset.id
    pub type alias AssetIdResolver[ef: Eff] = Context -> Asset -> Result[FieldError, Id] \ ef
    /// Asset.url
    pub type alias AssetUrlResolver[ef: Eff] = Context -> Asset -> Result[FieldError, String] \ ef
    /// Asset.fileName
    pub type alias AssetFileNameResolver[ef: Eff] = Context -> Asset -> Result[FieldError, String] \ ef
    /// Asset.mime
    pub type alias AssetMimeResolver[ef: Eff] = Context -> Asset -> Result[FieldError, String] \ ef
    /// Asset.size
    pub type alias AssetSizeResolver[ef: Eff] = Context -> Asset -> Result[FieldError, Int32] \ ef
    /// Asset.width
    pub type alias AssetWidthResolver[ef: Eff] = Context -> Asset -> Result[FieldError, Option[Int32]] \ ef
    /// Asset.height
    pub type alias AssetHeightResolver[ef: Eff] = Context -> Asset -> Result[FieldError, Option[Int32]] \ ef
    /// Asset.alt
    pub type alias AssetAltResolver[ef: Eff] = Context -> Asset -> Result[FieldError, String] \ ef
    /// Asset.status
    pub type alias AssetStatusResolver[ef: Eff] = Context -> Asset -> Result[FieldError, AssetStatus] \ ef
    /// Asset.createdAt
    pub type alias AssetCreatedAtResolver[ef: Eff] = Context -> Asset -> Result[FieldError, String] \ ef
    /// Asset.usedBy
    pub type alias AssetUsedByResolver[ef: Eff] = Context -> Asset -> Result[FieldError, List[Entry]] \ ef
    /// AssetPage.nodes
    pub type alias AssetPageNodesResolver[ef: Eff] = Context -> AssetPage -> Result[FieldError, List[Asset]] \ ef
    /// AssetPage.totalCount
    pub type alias AssetPageTotalCountResolver[ef: Eff] = Context -> AssetPage -> Result[FieldError, Int32] \ ef
    /// Upload.asset
    pub type alias UploadAssetResolver[ef: Eff] = Context -> Upload -> Result[FieldError, Asset] \ ef
    /// Upload.uploadUrl
    pub type alias UploadUploadUrlResolver[ef: Eff] = Context -> Upload -> Result[FieldError, String] \ ef
    /// Upload.expiresInSeconds
    pub type alias UploadExpiresInSecondsResolver[ef: Eff] = Context -> Upload -> Result[FieldError, Int32] \ ef
    /// Entry.id
    pub type alias EntryIdResolver[ef: Eff] = Context -> Entry -> Result[FieldError, Id] \ ef
    /// Entry.typeId
    pub type alias EntryTypeIdResolver[ef: Eff] = Context -> Entry -> Result[FieldError, Id] \ ef
    /// Entry.version
    pub type alias EntryVersionResolver[ef: Eff] = Context -> Entry -> Result[FieldError, Int32] \ ef
    /// Entry.stage
    pub type alias EntryStageResolver[ef: Eff] = Context -> Entry -> Result[FieldError, EntryStage] \ ef
    /// Entry.fields
    pub type alias EntryFieldsResolver[ef: Eff] = Context -> Entry -> Result[FieldError, Value] \ ef
    /// Entry.publishedAt
    pub type alias EntryPublishedAtResolver[ef: Eff] = Context -> Entry -> Result[FieldError, Option[String]] \ ef
    /// Entry.createdAt
    pub type alias EntryCreatedAtResolver[ef: Eff] = Context -> Entry -> Result[FieldError, String] \ ef
    /// Entry.updatedAt
    pub type alias EntryUpdatedAtResolver[ef: Eff] = Context -> Entry -> Result[FieldError, String] \ ef
    /// Entry.versions
    pub type alias EntryVersionsResolver[ef: Eff] = Context -> Entry -> Result[FieldError, List[EntryVersion]] \ ef
    /// EntryVersion.id
    pub type alias EntryVersionIdResolver[ef: Eff] = Context -> EntryVersion -> Result[FieldError, Id] \ ef
    /// EntryVersion.version
    pub type alias EntryVersionVersionResolver[ef: Eff] = Context -> EntryVersion -> Result[FieldError, Int32] \ ef
    /// EntryVersion.reason
    pub type alias EntryVersionReasonResolver[ef: Eff] = Context -> EntryVersion -> Result[FieldError, VersionReason] \ ef
    /// EntryVersion.author
    pub type alias EntryVersionAuthorResolver[ef: Eff] = Context -> EntryVersion -> Result[FieldError, String] \ ef
    /// EntryVersion.fields
    pub type alias EntryVersionFieldsResolver[ef: Eff] = Context -> EntryVersion -> Result[FieldError, Value] \ ef
    /// EntryVersion.createdAt
    pub type alias EntryVersionCreatedAtResolver[ef: Eff] = Context -> EntryVersion -> Result[FieldError, String] \ ef
    /// EntryPage.nodes
    pub type alias EntryPageNodesResolver[ef: Eff] = Context -> EntryPage -> Result[FieldError, List[Entry]] \ ef
    /// EntryPage.totalCount
    pub type alias EntryPageTotalCountResolver[ef: Eff] = Context -> EntryPage -> Result[FieldError, Int32] \ ef
    /// ContentType.id
    pub type alias ContentTypeIdResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, Id] \ ef
    /// ContentType.apiId
    pub type alias ContentTypeApiIdResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// ContentType.kind
    pub type alias ContentTypeKindResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, TypeKind] \ ef
    /// ContentType.name
    pub type alias ContentTypeNameResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// ContentType.singular
    pub type alias ContentTypeSingularResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// ContentType.plural
    pub type alias ContentTypePluralResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// ContentType.previewUrl
    pub type alias ContentTypePreviewUrlResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, Option[String]] \ ef
    /// ContentType.fields
    pub type alias ContentTypeFieldsResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, List[FieldDef]] \ ef
    /// ContentType.createdAt
    pub type alias ContentTypeCreatedAtResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// ContentType.updatedAt
    pub type alias ContentTypeUpdatedAtResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// FieldDef.id
    pub type alias FieldDefIdResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Id] \ ef
    /// FieldDef.apiId
    pub type alias FieldDefApiIdResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, String] \ ef
    /// FieldDef.name
    pub type alias FieldDefNameResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, String] \ ef
    /// FieldDef.kind
    pub type alias FieldDefKindResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, FieldKind] \ ef
    /// FieldDef.many
    pub type alias FieldDefManyResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Bool] \ ef
    /// FieldDef.required
    pub type alias FieldDefRequiredResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Bool] \ ef
    /// FieldDef.unique
    pub type alias FieldDefUniqueResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Bool] \ ef
    /// FieldDef.localized
    pub type alias FieldDefLocalizedResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Bool] \ ef
    /// FieldDef.targetTypeId
    pub type alias FieldDefTargetTypeIdResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Option[Id]] \ ef
    /// FieldDef.parentFieldId
    pub type alias FieldDefParentFieldIdResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Option[Id]] \ ef
    /// FieldDef.children
    pub type alias FieldDefChildrenResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, List[FieldDef]] \ ef
    /// FieldDef.config
    pub type alias FieldDefConfigResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, FieldConfig] \ ef
    /// FieldDef.position
    pub type alias FieldDefPositionResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Int32] \ ef
    /// FieldConfig.maxLength
    pub type alias FieldConfigMaxLengthResolver[ef: Eff] = Context -> FieldConfig -> Result[FieldError, Option[Int32]] \ ef
    /// FieldConfig.sourceField
    pub type alias FieldConfigSourceFieldResolver[ef: Eff] = Context -> FieldConfig -> Result[FieldError, Option[String]] \ ef
    /// FieldConfig.min
    pub type alias FieldConfigMinResolver[ef: Eff] = Context -> FieldConfig -> Result[FieldError, Option[Float64]] \ ef
    /// FieldConfig.max
    pub type alias FieldConfigMaxResolver[ef: Eff] = Context -> FieldConfig -> Result[FieldError, Option[Float64]] \ ef
    /// FieldConfig.integer
    pub type alias FieldConfigIntegerResolver[ef: Eff] = Context -> FieldConfig -> Result[FieldError, Option[Bool]] \ ef
    /// FieldConfig.options
    pub type alias FieldConfigOptionsResolver[ef: Eff] = Context -> FieldConfig -> Result[FieldError, Option[List[String]]] \ ef

    /// type Query のリゾルバ一式。ef はリゾルバの効果
    pub type alias QueryResolvers[ef: Eff] = {
        contentTypes = QueryContentTypesResolver[ef],
        contentType = QueryContentTypeResolver[ef],
        entries = QueryEntriesResolver[ef],
        entry = QueryEntryResolver[ef],
        assets = QueryAssetsResolver[ef],
        asset = QueryAssetResolver[ef],
        publishCheck = QueryPublishCheckResolver[ef],
        impact = QueryImpactResolver[ef],
        me = QueryMeResolver[ef],
        members = QueryMembersResolver[ef],
        invitations = QueryInvitationsResolver[ef],
        apiKeys = QueryApiKeysResolver[ef]
    }

    /// type Violation のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias ViolationResolvers[ef: Eff] = {
        path = ViolationPathResolver[ef],
        message = ViolationMessageResolver[ef]
    }

    /// type PublishReport のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias PublishReportResolvers[ef: Eff] = {
        ok = PublishReportOkResolver[ef],
        violations = PublishReportViolationsResolver[ef],
        unpublishedDependencies = PublishReportUnpublishedDependenciesResolver[ef]
    }

    /// type Referrer のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias ReferrerResolvers[ef: Eff] = {
        entry = ReferrerEntryResolver[ef],
        via = ReferrerViaResolver[ef],
        stage = ReferrerStageResolver[ef]
    }

    /// type Impact のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias ImpactResolvers[ef: Eff] = {
        breaks = ImpactBreaksResolver[ef],
        cascades = ImpactCascadesResolver[ef]
    }

    /// type Mutation のリゾルバ一式。ef はリゾルバの効果
    pub type alias MutationResolvers[ef: Eff] = {
        createContentType = MutationCreateContentTypeResolver[ef],
        updateContentType = MutationUpdateContentTypeResolver[ef],
        deleteContentType = MutationDeleteContentTypeResolver[ef],
        addField = MutationAddFieldResolver[ef],
        updateField = MutationUpdateFieldResolver[ef],
        removeField = MutationRemoveFieldResolver[ef],
        reorderFields = MutationReorderFieldsResolver[ef],
        createEntry = MutationCreateEntryResolver[ef],
        updateEntry = MutationUpdateEntryResolver[ef],
        deleteEntry = MutationDeleteEntryResolver[ef],
        publishEntry = MutationPublishEntryResolver[ef],
        unpublishEntry = MutationUnpublishEntryResolver[ef],
        saveVersion = MutationSaveVersionResolver[ef],
        restoreVersion = MutationRestoreVersionResolver[ef],
        createUploadUrl = MutationCreateUploadUrlResolver[ef],
        confirmAsset = MutationConfirmAssetResolver[ef],
        updateAsset = MutationUpdateAssetResolver[ef],
        deleteAsset = MutationDeleteAssetResolver[ef],
        createOrganization = MutationCreateOrganizationResolver[ef],
        createProject = MutationCreateProjectResolver[ef],
        updateProjectVisibility = MutationUpdateProjectVisibilityResolver[ef],
        inviteMember = MutationInviteMemberResolver[ef],
        cancelInvitation = MutationCancelInvitationResolver[ef],
        changeMemberRole = MutationChangeMemberRoleResolver[ef],
        removeMember = MutationRemoveMemberResolver[ef],
        createApiKey = MutationCreateApiKeyResolver[ef],
        revokeApiKey = MutationRevokeApiKeyResolver[ef]
    }

    /// type Me のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias MeResolvers[ef: Eff] = {
        id = MeIdResolver[ef],
        email = MeEmailResolver[ef],
        name = MeNameResolver[ef],
        roles = MeRolesResolver[ef],
        permissions = MePermissionsResolver[ef],
        organizations = MeOrganizationsResolver[ef],
        projects = MeProjectsResolver[ef]
    }

    /// type Organization のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias OrganizationResolvers[ef: Eff] = {
        id = OrganizationIdResolver[ef],
        name = OrganizationNameResolver[ef]
    }

    /// type OrganizationMembership のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias OrganizationMembershipResolvers[ef: Eff] = {
        organization = OrganizationMembershipOrganizationResolver[ef],
        role = OrganizationMembershipRoleResolver[ef]
    }

    /// type Project のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias ProjectResolvers[ef: Eff] = {
        id = ProjectIdResolver[ef],
        slug = ProjectSlugResolver[ef],
        name = ProjectNameResolver[ef],
        visibility = ProjectVisibilityResolver[ef]
    }

    /// type ProjectMembership のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias ProjectMembershipResolvers[ef: Eff] = {
        project_ = ProjectMembershipProjectResolver[ef],
        role = ProjectMembershipRoleResolver[ef]
    }

    /// type Member のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias MemberResolvers[ef: Eff] = {
        userId = MemberUserIdResolver[ef],
        email = MemberEmailResolver[ef],
        name = MemberNameResolver[ef],
        role = MemberRoleResolver[ef]
    }

    /// type Invitation のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias InvitationResolvers[ef: Eff] = {
        id = InvitationIdResolver[ef],
        email = InvitationEmailResolver[ef],
        role = InvitationRoleResolver[ef],
        createdAt = InvitationCreatedAtResolver[ef]
    }

    /// type ApiKey のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias ApiKeyResolvers[ef: Eff] = {
        id = ApiKeyIdResolver[ef],
        name = ApiKeyNameResolver[ef],
        scope = ApiKeyScopeResolver[ef],
        createdAt = ApiKeyCreatedAtResolver[ef],
        revokedAt = ApiKeyRevokedAtResolver[ef]
    }

    /// type IssuedApiKey のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias IssuedApiKeyResolvers[ef: Eff] = {
        id = IssuedApiKeyIdResolver[ef],
        name = IssuedApiKeyNameResolver[ef],
        scope = IssuedApiKeyScopeResolver[ef],
        key = IssuedApiKeyKeyResolver[ef]
    }

    /// type Asset のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias AssetResolvers[ef: Eff] = {
        id = AssetIdResolver[ef],
        url = AssetUrlResolver[ef],
        fileName = AssetFileNameResolver[ef],
        mime = AssetMimeResolver[ef],
        size = AssetSizeResolver[ef],
        width = AssetWidthResolver[ef],
        height = AssetHeightResolver[ef],
        alt = AssetAltResolver[ef],
        status = AssetStatusResolver[ef],
        createdAt = AssetCreatedAtResolver[ef],
        usedBy = AssetUsedByResolver[ef]
    }

    /// type AssetPage のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias AssetPageResolvers[ef: Eff] = {
        nodes = AssetPageNodesResolver[ef],
        totalCount = AssetPageTotalCountResolver[ef]
    }

    /// type Upload のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias UploadResolvers[ef: Eff] = {
        asset = UploadAssetResolver[ef],
        uploadUrl = UploadUploadUrlResolver[ef],
        expiresInSeconds = UploadExpiresInSecondsResolver[ef]
    }

    /// type Entry のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias EntryResolvers[ef: Eff] = {
        id = EntryIdResolver[ef],
        typeId = EntryTypeIdResolver[ef],
        version = EntryVersionResolver[ef],
        stage = EntryStageResolver[ef],
        fields = EntryFieldsResolver[ef],
        publishedAt = EntryPublishedAtResolver[ef],
        createdAt = EntryCreatedAtResolver[ef],
        updatedAt = EntryUpdatedAtResolver[ef],
        versions = EntryVersionsResolver[ef]
    }

    /// type EntryVersion のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias EntryVersionResolvers[ef: Eff] = {
        id = EntryVersionIdResolver[ef],
        version = EntryVersionVersionResolver[ef],
        reason = EntryVersionReasonResolver[ef],
        author = EntryVersionAuthorResolver[ef],
        fields = EntryVersionFieldsResolver[ef],
        createdAt = EntryVersionCreatedAtResolver[ef]
    }

    /// type EntryPage のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias EntryPageResolvers[ef: Eff] = {
        nodes = EntryPageNodesResolver[ef],
        totalCount = EntryPageTotalCountResolver[ef]
    }

    /// type ContentType のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias ContentTypeResolvers[ef: Eff] = {
        id = ContentTypeIdResolver[ef],
        apiId = ContentTypeApiIdResolver[ef],
        kind = ContentTypeKindResolver[ef],
        name = ContentTypeNameResolver[ef],
        singular = ContentTypeSingularResolver[ef],
        plural = ContentTypePluralResolver[ef],
        previewUrl = ContentTypePreviewUrlResolver[ef],
        fields = ContentTypeFieldsResolver[ef],
        createdAt = ContentTypeCreatedAtResolver[ef],
        updatedAt = ContentTypeUpdatedAtResolver[ef]
    }

    /// type FieldDef のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias FieldDefResolvers[ef: Eff] = {
        id = FieldDefIdResolver[ef],
        apiId = FieldDefApiIdResolver[ef],
        name = FieldDefNameResolver[ef],
        kind = FieldDefKindResolver[ef],
        many = FieldDefManyResolver[ef],
        required = FieldDefRequiredResolver[ef],
        unique = FieldDefUniqueResolver[ef],
        localized = FieldDefLocalizedResolver[ef],
        targetTypeId = FieldDefTargetTypeIdResolver[ef],
        parentFieldId = FieldDefParentFieldIdResolver[ef],
        children = FieldDefChildrenResolver[ef],
        config = FieldDefConfigResolver[ef],
        position = FieldDefPositionResolver[ef]
    }

    /// type FieldConfig のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias FieldConfigResolvers[ef: Eff] = {
        maxLength = FieldConfigMaxLengthResolver[ef],
        sourceField = FieldConfigSourceFieldResolver[ef],
        min = FieldConfigMinResolver[ef],
        max = FieldConfigMaxResolver[ef],
        integer = FieldConfigIntegerResolver[ef],
        options = FieldConfigOptionsResolver[ef]
    }

    /// type Violation の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def violationDefaults(): {
        path = Context -> { path = String | r0 } -> Result[FieldError, String] \ ef,
        message = Context -> { message = String | r1 } -> Result[FieldError, String] \ ef
    } = {
        path = (_context, src) -> Ok(src#path),
        message = (_context, src) -> Ok(src#message)
    }

    /// type PublishReport の既定リゾルバ。source の同名ラベルをそのまま返す。violations, unpublishedDependencies は含まない（オブジェクト型を返すか、引数を持つ）
    pub def publishReportDefaults(): {
        ok = Context -> { ok = Bool | r0 } -> Result[FieldError, Bool] \ ef
    } = {
        ok = (_context, src) -> Ok(src#ok)
    }

    /// type Referrer の既定リゾルバ。source の同名ラベルをそのまま返す。entry は含まない（オブジェクト型を返すか、引数を持つ）
    pub def referrerDefaults(): {
        via = Context -> { via = String | r0 } -> Result[FieldError, String] \ ef,
        stage = Context -> { stage = ContentStage | r1 } -> Result[FieldError, ContentStage] \ ef
    } = {
        via = (_context, src) -> Ok(src#via),
        stage = (_context, src) -> Ok(src#stage)
    }

    /// type Me の既定リゾルバ。source の同名ラベルをそのまま返す。organizations, projects は含まない（オブジェクト型を返すか、引数を持つ）
    pub def meDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        email = Context -> { email = String | r1 } -> Result[FieldError, String] \ ef,
        name = Context -> { name = String | r2 } -> Result[FieldError, String] \ ef,
        roles = Context -> { roles = List[Role] | r3 } -> Result[FieldError, List[Role]] \ ef,
        permissions = Context -> { permissions = List[String] | r4 } -> Result[FieldError, List[String]] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        email = (_context, src) -> Ok(src#email),
        name = (_context, src) -> Ok(src#name),
        roles = (_context, src) -> Ok(src#roles),
        permissions = (_context, src) -> Ok(src#permissions)
    }

    /// type Organization の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def organizationDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        name = Context -> { name = String | r1 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        name = (_context, src) -> Ok(src#name)
    }

    /// type OrganizationMembership の既定リゾルバ。source の同名ラベルをそのまま返す。organization は含まない（オブジェクト型を返すか、引数を持つ）
    pub def organizationMembershipDefaults(): {
        role = Context -> { role = OrgRole | r0 } -> Result[FieldError, OrgRole] \ ef
    } = {
        role = (_context, src) -> Ok(src#role)
    }

    /// type Project の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def projectDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        slug = Context -> { slug = String | r1 } -> Result[FieldError, String] \ ef,
        name = Context -> { name = String | r2 } -> Result[FieldError, String] \ ef,
        visibility = Context -> { visibility = Visibility | r3 } -> Result[FieldError, Visibility] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        slug = (_context, src) -> Ok(src#slug),
        name = (_context, src) -> Ok(src#name),
        visibility = (_context, src) -> Ok(src#visibility)
    }

    /// type ProjectMembership の既定リゾルバ。source の同名ラベルをそのまま返す。project は含まない（オブジェクト型を返すか、引数を持つ）
    pub def projectMembershipDefaults(): {
        role = Context -> { role = Role | r0 } -> Result[FieldError, Role] \ ef
    } = {
        role = (_context, src) -> Ok(src#role)
    }

    /// type Member の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def memberDefaults(): {
        userId = Context -> { userId = Id | r0 } -> Result[FieldError, Id] \ ef,
        email = Context -> { email = String | r1 } -> Result[FieldError, String] \ ef,
        name = Context -> { name = String | r2 } -> Result[FieldError, String] \ ef,
        role = Context -> { role = Role | r3 } -> Result[FieldError, Role] \ ef
    } = {
        userId = (_context, src) -> Ok(src#userId),
        email = (_context, src) -> Ok(src#email),
        name = (_context, src) -> Ok(src#name),
        role = (_context, src) -> Ok(src#role)
    }

    /// type Invitation の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def invitationDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        email = Context -> { email = String | r1 } -> Result[FieldError, String] \ ef,
        role = Context -> { role = Role | r2 } -> Result[FieldError, Role] \ ef,
        createdAt = Context -> { createdAt = String | r3 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        email = (_context, src) -> Ok(src#email),
        role = (_context, src) -> Ok(src#role),
        createdAt = (_context, src) -> Ok(src#createdAt)
    }

    /// type ApiKey の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def apiKeyDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        name = Context -> { name = String | r1 } -> Result[FieldError, String] \ ef,
        scope = Context -> { scope = ApiKeyScope | r2 } -> Result[FieldError, ApiKeyScope] \ ef,
        createdAt = Context -> { createdAt = String | r3 } -> Result[FieldError, String] \ ef,
        revokedAt = Context -> { revokedAt = Option[String] | r4 } -> Result[FieldError, Option[String]] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        name = (_context, src) -> Ok(src#name),
        scope = (_context, src) -> Ok(src#scope),
        createdAt = (_context, src) -> Ok(src#createdAt),
        revokedAt = (_context, src) -> Ok(src#revokedAt)
    }

    /// type IssuedApiKey の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def issuedApiKeyDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        name = Context -> { name = String | r1 } -> Result[FieldError, String] \ ef,
        scope = Context -> { scope = ApiKeyScope | r2 } -> Result[FieldError, ApiKeyScope] \ ef,
        key = Context -> { key = String | r3 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        name = (_context, src) -> Ok(src#name),
        scope = (_context, src) -> Ok(src#scope),
        key = (_context, src) -> Ok(src#key)
    }

    /// type Asset の既定リゾルバ。source の同名ラベルをそのまま返す。usedBy は含まない（オブジェクト型を返すか、引数を持つ）
    pub def assetDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        url = Context -> { url = String | r1 } -> Result[FieldError, String] \ ef,
        fileName = Context -> { fileName = String | r2 } -> Result[FieldError, String] \ ef,
        mime = Context -> { mime = String | r3 } -> Result[FieldError, String] \ ef,
        size = Context -> { size = Int32 | r4 } -> Result[FieldError, Int32] \ ef,
        width = Context -> { width = Option[Int32] | r5 } -> Result[FieldError, Option[Int32]] \ ef,
        height = Context -> { height = Option[Int32] | r6 } -> Result[FieldError, Option[Int32]] \ ef,
        alt = Context -> { alt = String | r7 } -> Result[FieldError, String] \ ef,
        status = Context -> { status = AssetStatus | r8 } -> Result[FieldError, AssetStatus] \ ef,
        createdAt = Context -> { createdAt = String | r9 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        url = (_context, src) -> Ok(src#url),
        fileName = (_context, src) -> Ok(src#fileName),
        mime = (_context, src) -> Ok(src#mime),
        size = (_context, src) -> Ok(src#size),
        width = (_context, src) -> Ok(src#width),
        height = (_context, src) -> Ok(src#height),
        alt = (_context, src) -> Ok(src#alt),
        status = (_context, src) -> Ok(src#status),
        createdAt = (_context, src) -> Ok(src#createdAt)
    }

    /// type AssetPage の既定リゾルバ。source の同名ラベルをそのまま返す。nodes は含まない（オブジェクト型を返すか、引数を持つ）
    pub def assetPageDefaults(): {
        totalCount = Context -> { totalCount = Int32 | r0 } -> Result[FieldError, Int32] \ ef
    } = {
        totalCount = (_context, src) -> Ok(src#totalCount)
    }

    /// type Upload の既定リゾルバ。source の同名ラベルをそのまま返す。asset は含まない（オブジェクト型を返すか、引数を持つ）
    pub def uploadDefaults(): {
        uploadUrl = Context -> { uploadUrl = String | r0 } -> Result[FieldError, String] \ ef,
        expiresInSeconds = Context -> { expiresInSeconds = Int32 | r1 } -> Result[FieldError, Int32] \ ef
    } = {
        uploadUrl = (_context, src) -> Ok(src#uploadUrl),
        expiresInSeconds = (_context, src) -> Ok(src#expiresInSeconds)
    }

    /// type Entry の既定リゾルバ。source の同名ラベルをそのまま返す。versions は含まない（オブジェクト型を返すか、引数を持つ）
    pub def entryDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        typeId = Context -> { typeId = Id | r1 } -> Result[FieldError, Id] \ ef,
        version = Context -> { version = Int32 | r2 } -> Result[FieldError, Int32] \ ef,
        stage = Context -> { stage = EntryStage | r3 } -> Result[FieldError, EntryStage] \ ef,
        fields = Context -> { fields = Value | r4 } -> Result[FieldError, Value] \ ef,
        publishedAt = Context -> { publishedAt = Option[String] | r5 } -> Result[FieldError, Option[String]] \ ef,
        createdAt = Context -> { createdAt = String | r6 } -> Result[FieldError, String] \ ef,
        updatedAt = Context -> { updatedAt = String | r7 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        typeId = (_context, src) -> Ok(src#typeId),
        version = (_context, src) -> Ok(src#version),
        stage = (_context, src) -> Ok(src#stage),
        fields = (_context, src) -> Ok(src#fields),
        publishedAt = (_context, src) -> Ok(src#publishedAt),
        createdAt = (_context, src) -> Ok(src#createdAt),
        updatedAt = (_context, src) -> Ok(src#updatedAt)
    }

    /// type EntryVersion の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def entryVersionDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        version = Context -> { version = Int32 | r1 } -> Result[FieldError, Int32] \ ef,
        reason = Context -> { reason = VersionReason | r2 } -> Result[FieldError, VersionReason] \ ef,
        author = Context -> { author = String | r3 } -> Result[FieldError, String] \ ef,
        fields = Context -> { fields = Value | r4 } -> Result[FieldError, Value] \ ef,
        createdAt = Context -> { createdAt = String | r5 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        version = (_context, src) -> Ok(src#version),
        reason = (_context, src) -> Ok(src#reason),
        author = (_context, src) -> Ok(src#author),
        fields = (_context, src) -> Ok(src#fields),
        createdAt = (_context, src) -> Ok(src#createdAt)
    }

    /// type EntryPage の既定リゾルバ。source の同名ラベルをそのまま返す。nodes は含まない（オブジェクト型を返すか、引数を持つ）
    pub def entryPageDefaults(): {
        totalCount = Context -> { totalCount = Int32 | r0 } -> Result[FieldError, Int32] \ ef
    } = {
        totalCount = (_context, src) -> Ok(src#totalCount)
    }

    /// type ContentType の既定リゾルバ。source の同名ラベルをそのまま返す。fields は含まない（オブジェクト型を返すか、引数を持つ）
    pub def contentTypeDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        apiId = Context -> { apiId = String | r1 } -> Result[FieldError, String] \ ef,
        kind = Context -> { kind = TypeKind | r2 } -> Result[FieldError, TypeKind] \ ef,
        name = Context -> { name = String | r3 } -> Result[FieldError, String] \ ef,
        singular = Context -> { singular = String | r4 } -> Result[FieldError, String] \ ef,
        plural = Context -> { plural = String | r5 } -> Result[FieldError, String] \ ef,
        previewUrl = Context -> { previewUrl = Option[String] | r6 } -> Result[FieldError, Option[String]] \ ef,
        createdAt = Context -> { createdAt = String | r7 } -> Result[FieldError, String] \ ef,
        updatedAt = Context -> { updatedAt = String | r8 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        apiId = (_context, src) -> Ok(src#apiId),
        kind = (_context, src) -> Ok(src#kind),
        name = (_context, src) -> Ok(src#name),
        singular = (_context, src) -> Ok(src#singular),
        plural = (_context, src) -> Ok(src#plural),
        previewUrl = (_context, src) -> Ok(src#previewUrl),
        createdAt = (_context, src) -> Ok(src#createdAt),
        updatedAt = (_context, src) -> Ok(src#updatedAt)
    }

    /// type FieldDef の既定リゾルバ。source の同名ラベルをそのまま返す。children, config は含まない（オブジェクト型を返すか、引数を持つ）
    pub def fieldDefDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        apiId = Context -> { apiId = String | r1 } -> Result[FieldError, String] \ ef,
        name = Context -> { name = String | r2 } -> Result[FieldError, String] \ ef,
        kind = Context -> { kind = FieldKind | r3 } -> Result[FieldError, FieldKind] \ ef,
        many = Context -> { many = Bool | r4 } -> Result[FieldError, Bool] \ ef,
        required = Context -> { required = Bool | r5 } -> Result[FieldError, Bool] \ ef,
        unique = Context -> { unique = Bool | r6 } -> Result[FieldError, Bool] \ ef,
        localized = Context -> { localized = Bool | r7 } -> Result[FieldError, Bool] \ ef,
        targetTypeId = Context -> { targetTypeId = Option[Id] | r8 } -> Result[FieldError, Option[Id]] \ ef,
        parentFieldId = Context -> { parentFieldId = Option[Id] | r9 } -> Result[FieldError, Option[Id]] \ ef,
        position = Context -> { position = Int32 | r10 } -> Result[FieldError, Int32] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        apiId = (_context, src) -> Ok(src#apiId),
        name = (_context, src) -> Ok(src#name),
        kind = (_context, src) -> Ok(src#kind),
        many = (_context, src) -> Ok(src#many),
        required = (_context, src) -> Ok(src#required),
        unique = (_context, src) -> Ok(src#unique),
        localized = (_context, src) -> Ok(src#localized),
        targetTypeId = (_context, src) -> Ok(src#targetTypeId),
        parentFieldId = (_context, src) -> Ok(src#parentFieldId),
        position = (_context, src) -> Ok(src#position)
    }

    /// type FieldConfig の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def fieldConfigDefaults(): {
        maxLength = Context -> { maxLength = Option[Int32] | r0 } -> Result[FieldError, Option[Int32]] \ ef,
        sourceField = Context -> { sourceField = Option[String] | r1 } -> Result[FieldError, Option[String]] \ ef,
        min = Context -> { min = Option[Float64] | r2 } -> Result[FieldError, Option[Float64]] \ ef,
        max = Context -> { max = Option[Float64] | r3 } -> Result[FieldError, Option[Float64]] \ ef,
        integer = Context -> { integer = Option[Bool] | r4 } -> Result[FieldError, Option[Bool]] \ ef,
        options = Context -> { options = Option[List[String]] | r5 } -> Result[FieldError, Option[List[String]]] \ ef
    } = {
        maxLength = (_context, src) -> Ok(src#maxLength),
        sourceField = (_context, src) -> Ok(src#sourceField),
        min = (_context, src) -> Ok(src#min),
        max = (_context, src) -> Ok(src#max),
        integer = (_context, src) -> Ok(src#integer),
        options = (_context, src) -> Ok(src#options)
    }

    /// 全型のリゾルバ。1 つでも欠けるとコンパイルエラー。ef は全リゾルバで共有する 1 つの効果
    pub type alias Resolvers[ef: Eff] = {
        queryRoot = QueryResolvers[ef],
        violation = ViolationResolvers[ef],
        publishReport = PublishReportResolvers[ef],
        referrer = ReferrerResolvers[ef],
        impact = ImpactResolvers[ef],
        mutationRoot = MutationResolvers[ef],
        me = MeResolvers[ef],
        organization = OrganizationResolvers[ef],
        organizationMembership = OrganizationMembershipResolvers[ef],
        project_ = ProjectResolvers[ef],
        projectMembership = ProjectMembershipResolvers[ef],
        member = MemberResolvers[ef],
        invitation = InvitationResolvers[ef],
        apiKey = ApiKeyResolvers[ef],
        issuedApiKey = IssuedApiKeyResolvers[ef],
        asset = AssetResolvers[ef],
        assetPage = AssetPageResolvers[ef],
        upload = UploadResolvers[ef],
        entry = EntryResolvers[ef],
        entryVersion = EntryVersionResolvers[ef],
        entryPage = EntryPageResolvers[ef],
        contentType = ContentTypeResolvers[ef],
        fieldDef = FieldDefResolvers[ef],
        fieldConfig = FieldConfigResolvers[ef]
    }

    /// リゾルバ一式からスキーマを組み立てる。runner が ef を IO に落とす
    pub def schema(resolvers: Resolvers[ef], runner: Runner[ef]): Schema =
        Schema.make(queryType(resolvers), Some(mutationType(resolvers)), runner)

    /// type Query
    def queryType(resolvers: Resolvers[ef]): ObjectType[Unit, ef] =
        Schema.objectType("Query", () ->
            {
                Schema.fieldRaw("contentTypes", Nil, Out.list(Out.obj(contentTypeType(resolvers))), (context, _src, _args) ->
                    (resolvers#queryRoot#contentTypes)(context)) |> Field.withDescription("全 content type。apiId 順")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.option(GqlCodec.id()));
                let arg1 = Schema.arg("apiId", GqlCodec.option(GqlCodec.string()));
                Schema.fieldRaw("contentType", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.option(Out.obj(contentTypeType(resolvers))), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#queryRoot#contentType)(context, v0, v1)) yield result) |> Field.withDescription("id か apiId で 1 つ。無ければ null")
            } ::
            {
                let arg0 = Schema.arg("typeId", GqlCodec.id());
                let arg1 = Schema.arg("search", GqlCodec.option(GqlCodec.string()));
                let arg2 = Schema.arg("first", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(50));
                let arg3 = Schema.arg("skip", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(0));
                Schema.fieldRaw("entries", Arg.info(arg0) :: Arg.info(arg1) :: Arg.info(arg2) :: Arg.info(arg3) :: Nil, Out.obj(entryPageType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); v2 <- Arg.decode(arg2, args); v3 <- Arg.decode(arg3, args); result <- (resolvers#queryRoot#entries)(context, v0, v1, v2, v3)) yield result) |> Field.withDescription("型の entry の一覧。更新が新しい順。search は下書きの中身に含む文字列")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("entry", Arg.info(arg0) :: Nil, Out.option(Out.obj(entryType(resolvers))), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#queryRoot#entry)(context, v0)) yield result) |> Field.withDescription("entry 1 つ。無ければ null")
            } ::
            {
                let arg0 = Schema.arg("first", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(50));
                let arg1 = Schema.arg("skip", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(0));
                Schema.fieldRaw("assets", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(assetPageType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#queryRoot#assets)(context, v0, v1)) yield result) |> Field.withDescription("asset の一覧。新しい順。アップロード途中（PENDING）の物も出る")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("asset", Arg.info(arg0) :: Nil, Out.option(Out.obj(assetType(resolvers))), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#queryRoot#asset)(context, v0)) yield result) |> Field.withDescription("asset 1 つ。無ければ null")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("publishCheck", Arg.info(arg0) :: Nil, Out.obj(publishReportType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#queryRoot#publishCheck)(context, v0)) yield result) |> Field.withDescription("公開できるか。書き込まない。violations が空なら publishEntry は通る（unique は押した瞬間の競合を除く）")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                let arg1 = Schema.arg("action", impactActionCodec());
                Schema.fieldRaw("impact", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(impactType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#queryRoot#impact)(context, v0, v1)) yield result) |> Field.withDescription("操作の影響。取り下げ・削除で壊れる参照元と、公開で一緒に動く参照先")
            } ::
            {
                Schema.fieldRaw("me", Nil, Out.option(Out.obj(meType(resolvers))), (context, _src, _args) ->
                    (resolvers#queryRoot#me)(context)) |> Field.withDescription("自分。ログインしていなければ null。organizations と projects は自分が触れる物だけ")
            } ::
            {
                Schema.fieldRaw("members", Nil, Out.list(Out.obj(memberType(resolvers))), (context, _src, _args) ->
                    (resolvers#queryRoot#members)(context)) |> Field.withDescription("今のプロジェクトのメンバー（owner だけ）")
            } ::
            {
                Schema.fieldRaw("invitations", Nil, Out.list(Out.obj(invitationType(resolvers))), (context, _src, _args) ->
                    (resolvers#queryRoot#invitations)(context)) |> Field.withDescription("今のプロジェクトの招待（owner だけ）")
            } ::
            {
                Schema.fieldRaw("apiKeys", Nil, Out.list(Out.obj(apiKeyType(resolvers))), (context, _src, _args) ->
                    (resolvers#queryRoot#apiKeys)(context)) |> Field.withDescription("今のプロジェクトの API キー（owner だけ）。生の鍵は出ない")
            } ::
            Nil) |> ObjectType.withDescription("管理 API。content type とフィールドの定義と、entry を読み書きする。形は固定で、コンテンツ API は定義から実行時に組む")

    /// type Violation
    def violationType(resolvers: Resolvers[ef]): ObjectType[Violation, ef] =
        Schema.objectType("Violation", () ->
            {
                Schema.fieldRaw("path", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#violation#path)(context, src))
            } ::
            {
                Schema.fieldRaw("message", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#violation#message)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("入力の 1 つの誤り。path は GraphQL の入力に対応（\"fields.title\" など）")

    /// type PublishReport
    def publishReportType(resolvers: Resolvers[ef]): ObjectType[PublishReport, ef] =
        Schema.objectType("PublishReport", () ->
            {
                Schema.fieldRaw("ok", Nil, Out.bool(), (context, src, _args) ->
                    (resolvers#publishReport#ok)(context, src))
            } ::
            {
                Schema.fieldRaw("violations", Nil, Out.list(Out.obj(violationType(resolvers))), (context, src, _args) ->
                    (resolvers#publishReport#violations)(context, src)) |> Field.withDescription("required / unique / 参照の消失 / asset の未完了。全部一度に")
            } ::
            {
                Schema.fieldRaw("unpublishedDependencies", Nil, Out.list(Out.obj(entryType(resolvers))), (context, src, _args) ->
                    (resolvers#publishReport#unpublishedDependencies)(context, src)) |> Field.withDescription("未公開の参照先。withDependencies: true で一緒に公開できる")
            } ::
            Nil) |> ObjectType.withDescription("公開の検査結果（dry-run）")

    /// type Referrer
    def referrerType(resolvers: Resolvers[ef]): ObjectType[Referrer, ef] =
        Schema.objectType("Referrer", () ->
            {
                Schema.fieldRaw("entry", Nil, Out.obj(entryType(resolvers)), (context, src, _args) ->
                    (resolvers#referrer#entry)(context, src))
            } ::
            {
                Schema.fieldRaw("via", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#referrer#via)(context, src)) |> Field.withDescription("参照しているフィールドの apiId。本文内のリンクなら RICH_TEXT のフィールド")
            } ::
            {
                Schema.fieldRaw("stage", Nil, Out.scalar(contentStageCodec()), (context, src, _args) ->
                    (resolvers#referrer#stage)(context, src)) |> Field.withDescription("参照している側のどの中身か")
            } ::
            Nil) |> ObjectType.withDescription("この entry を参照している 1 つ")

    /// type Impact
    def impactType(resolvers: Resolvers[ef]): ObjectType[Impact, ef] =
        Schema.objectType("Impact", () ->
            {
                Schema.fieldRaw("breaks", Nil, Out.list(Out.obj(referrerType(resolvers))), (context, src, _args) ->
                    (resolvers#impact#breaks)(context, src)) |> Field.withDescription("壊れる（参照先を失う）entry。取り下げ・削除の前に見せる")
            } ::
            {
                Schema.fieldRaw("cascades", Nil, Out.list(Out.obj(entryType(resolvers))), (context, src, _args) ->
                    (resolvers#impact#cascades)(context, src)) |> Field.withDescription("一緒に動く entry。公開なら先に公開される未公開の参照先")
            } ::
            Nil) |> ObjectType.withDescription("操作の影響")

    /// type Mutation
    def mutationType(resolvers: Resolvers[ef]): ObjectType[Unit, ef] =
        Schema.objectType("Mutation", () ->
            {
                let arg0 = Schema.arg("input", contentTypeInputCodec());
                Schema.fieldRaw("createContentType", Arg.info(arg0) :: Nil, Out.obj(contentTypeType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#createContentType)(context, v0)) yield result)
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                let arg1 = Schema.arg("input", contentTypePatchCodec());
                Schema.fieldRaw("updateContentType", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(contentTypeType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#updateContentType)(context, v0, v1)) yield result)
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("deleteContentType", Arg.info(arg0) :: Nil, Out.id(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#deleteContentType)(context, v0)) yield result) |> Field.withDescription("フィールドごと消す")
            } ::
            {
                let arg0 = Schema.arg("typeId", GqlCodec.id());
                let arg1 = Schema.arg("input", fieldInputCodec());
                Schema.fieldRaw("addField", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(fieldDefType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#addField)(context, v0, v1)) yield result) |> Field.withDescription("末尾に足す")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                let arg1 = Schema.arg("input", fieldPatchCodec());
                Schema.fieldRaw("updateField", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(fieldDefType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#updateField)(context, v0, v1)) yield result)
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("removeField", Arg.info(arg0) :: Nil, Out.id(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#removeField)(context, v0)) yield result)
            } ::
            {
                let arg0 = Schema.arg("typeId", GqlCodec.id());
                let arg1 = Schema.arg("ids", GqlCodec.list(GqlCodec.id()));
                Schema.fieldRaw("reorderFields", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(contentTypeType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#reorderFields)(context, v0, v1)) yield result) |> Field.withDescription("ids の順に並べ直す。型の全フィールドを過不足なく渡す")
            } ::
            {
                let arg0 = Schema.arg("typeId", GqlCodec.id());
                let arg1 = Schema.arg("fields", GqlCodec.json());
                let arg2 = Schema.arg("id", GqlCodec.option(GqlCodec.id()));
                Schema.fieldRaw("createEntry", Arg.info(arg0) :: Arg.info(arg1) :: Arg.info(arg2) :: Nil, Out.obj(entryType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); v2 <- Arg.decode(arg2, args); result <- (resolvers#mutationRoot#createEntry)(context, v0, v1, v2)) yield result) |> Field.withDescription("下書きを作る。id を渡せば（移行用）それを使い、無ければ振る。fields は apiId → 値")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                let arg1 = Schema.arg("fields", GqlCodec.json());
                let arg2 = Schema.arg("expectedVersion", GqlCodec.int32());
                Schema.fieldRaw("updateEntry", Arg.info(arg0) :: Arg.info(arg1) :: Arg.info(arg2) :: Nil, Out.obj(entryType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); v2 <- Arg.decode(arg2, args); result <- (resolvers#mutationRoot#updateEntry)(context, v0, v1, v2)) yield result) |> Field.withDescription("下書きを直す。fields のキーだけ上書きし、null で消す。expectedVersion が今の version と違えば CONFLICT")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("deleteEntry", Arg.info(arg0) :: Nil, Out.id(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#deleteEntry)(context, v0)) yield result) |> Field.withDescription("ゴミ箱へ（soft delete）。公開中なら公開も取り下げる")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                let arg1 = Schema.arg("withDependencies", GqlCodec.option(GqlCodec.bool())) |> Arg.withDefaultValue(Value.Bool(false));
                Schema.fieldRaw("publishEntry", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(entryType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#publishEntry)(context, v0, v1)) yield result) |> Field.withDescription("下書きを公開する。required と unique と参照先の公開はここで検査する。公開中なら公開側を下書きで上書きする。\nwithDependencies なら未公開の参照先を先に公開する")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("unpublishEntry", Arg.info(arg0) :: Nil, Out.obj(entryType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#unpublishEntry)(context, v0)) yield result) |> Field.withDescription("公開を取り下げる。下書きは残る")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("saveVersion", Arg.info(arg0) :: Nil, Out.obj(entryVersionType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#saveVersion)(context, v0)) yield result) |> Field.withDescription("今の下書きを版として残す")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                let arg1 = Schema.arg("versionId", GqlCodec.id());
                let arg2 = Schema.arg("expectedVersion", GqlCodec.int32());
                Schema.fieldRaw("restoreVersion", Arg.info(arg0) :: Arg.info(arg1) :: Arg.info(arg2) :: Nil, Out.obj(entryType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); v2 <- Arg.decode(arg2, args); result <- (resolvers#mutationRoot#restoreVersion)(context, v0, v1, v2)) yield result) |> Field.withDescription("版の中身を下書きに戻す。expectedVersion は updateEntry と同じ")
            } ::
            {
                let arg0 = Schema.arg("input", uploadInputCodec());
                Schema.fieldRaw("createUploadUrl", Arg.info(arg0) :: Nil, Out.obj(uploadType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#createUploadUrl)(context, v0)) yield result) |> Field.withDescription("asset の置き先（署名付き PUT URL）を発行する。ブラウザが Content-Type / Content-Length を宣言どおりにして PUT し、\n終わったら confirmAsset を呼ぶ。URL は expiresInSeconds で切れる")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                let arg1 = Schema.arg("input", GqlCodec.option(assetConfirmInputCodec()));
                Schema.fieldRaw("confirmAsset", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(assetType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#confirmAsset)(context, v0, v1)) yield result) |> Field.withDescription("置いた事をストレージで確かめて READY にする。画像なら寸法を渡す。置かれていなければエラー")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                let arg1 = Schema.arg("input", assetPatchCodec());
                Schema.fieldRaw("updateAsset", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(assetType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#updateAsset)(context, v0, v1)) yield result) |> Field.withDescription("alt を変える。ファイルの差し替えは新しい asset を作る")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("deleteAsset", Arg.info(arg0) :: Nil, Out.id(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#deleteAsset)(context, v0)) yield result) |> Field.withDescription("消す。entry（下書き・公開・richText の画像を含む）が使っていればエラー")
            } ::
            {
                let arg0 = Schema.arg("name", GqlCodec.string());
                Schema.fieldRaw("createOrganization", Arg.info(arg0) :: Nil, Out.obj(organizationType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#createOrganization)(context, v0)) yield result) |> Field.withDescription("組織を作る。作った人が owner")
            } ::
            {
                let arg0 = Schema.arg("orgId", GqlCodec.id());
                let arg1 = Schema.arg("slug", GqlCodec.string());
                let arg2 = Schema.arg("name", GqlCodec.string());
                Schema.fieldRaw("createProject", Arg.info(arg0) :: Arg.info(arg1) :: Arg.info(arg2) :: Nil, Out.obj(projectType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); v2 <- Arg.decode(arg2, args); result <- (resolvers#mutationRoot#createProject)(context, v0, v1, v2)) yield result) |> Field.withDescription("組織の下にプロジェクトを作る。組織の owner だけ。slug は subdomain と /p/ に出る")
            } ::
            {
                let arg0 = Schema.arg("visibility", visibilityCodec());
                Schema.fieldRaw("updateProjectVisibility", Arg.info(arg0) :: Nil, Out.obj(projectType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#updateProjectVisibility)(context, v0)) yield result) |> Field.withDescription("今のプロジェクトの公開範囲（owner だけ）")
            } ::
            {
                let arg0 = Schema.arg("email", GqlCodec.string());
                let arg1 = Schema.arg("role", roleCodec());
                Schema.fieldRaw("inviteMember", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(invitationType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#inviteMember)(context, v0, v1)) yield result) |> Field.withDescription("email で招待する（owner だけ）。初回ログインで役割が付く")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("cancelInvitation", Arg.info(arg0) :: Nil, Out.id(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#cancelInvitation)(context, v0)) yield result)
            } ::
            {
                let arg0 = Schema.arg("userId", GqlCodec.id());
                let arg1 = Schema.arg("role", roleCodec());
                Schema.fieldRaw("changeMemberRole", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(memberType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#changeMemberRole)(context, v0, v1)) yield result) |> Field.withDescription("役割を変える（owner だけ）。最後の owner は降格できない")
            } ::
            {
                let arg0 = Schema.arg("userId", GqlCodec.id());
                Schema.fieldRaw("removeMember", Arg.info(arg0) :: Nil, Out.id(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#removeMember)(context, v0)) yield result) |> Field.withDescription("外す（owner だけ）。最後の owner は外せない")
            } ::
            {
                let arg0 = Schema.arg("name", GqlCodec.string());
                let arg1 = Schema.arg("scope", apiKeyScopeCodec());
                Schema.fieldRaw("createApiKey", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(issuedApiKeyType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#createApiKey)(context, v0, v1)) yield result) |> Field.withDescription("API キーを発行する（owner だけ）。key はこの応答でしか見えない")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("revokeApiKey", Arg.info(arg0) :: Nil, Out.id(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#revokeApiKey)(context, v0)) yield result) |> Field.withDescription("失効する（owner だけ）")
            } ::
            Nil)

    /// type Me
    def meType(resolvers: Resolvers[ef]): ObjectType[Me, ef] =
        Schema.objectType("Me", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#me#id)(context, src))
            } ::
            {
                Schema.fieldRaw("email", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#me#email)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#me#name)(context, src))
            } ::
            {
                Schema.fieldRaw("roles", Nil, Out.list(Out.scalar(roleCodec())), (context, src, _args) ->
                    (resolvers#me#roles)(context, src)) |> Field.withDescription("今のプロジェクトでの役割（無ければ空）と、できる事")
            } ::
            {
                Schema.fieldRaw("permissions", Nil, Out.list(Out.string()), (context, src, _args) ->
                    (resolvers#me#permissions)(context, src))
            } ::
            {
                Schema.fieldRaw("organizations", Nil, Out.list(Out.obj(organizationMembershipType(resolvers))), (context, src, _args) ->
                    (resolvers#me#organizations)(context, src))
            } ::
            {
                Schema.fieldRaw("projects", Nil, Out.list(Out.obj(projectMembershipType(resolvers))), (context, src, _args) ->
                    (resolvers#me#projects)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("自分")

    /// type Organization
    def organizationType(resolvers: Resolvers[ef]): ObjectType[Organization, ef] =
        Schema.objectType("Organization", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#organization#id)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#organization#name)(context, src))
            } ::
            Nil)

    /// type OrganizationMembership
    def organizationMembershipType(resolvers: Resolvers[ef]): ObjectType[OrganizationMembership, ef] =
        Schema.objectType("OrganizationMembership", () ->
            {
                Schema.fieldRaw("organization", Nil, Out.obj(organizationType(resolvers)), (context, src, _args) ->
                    (resolvers#organizationMembership#organization)(context, src))
            } ::
            {
                Schema.fieldRaw("role", Nil, Out.scalar(orgRoleCodec()), (context, src, _args) ->
                    (resolvers#organizationMembership#role)(context, src))
            } ::
            Nil)

    /// type Project
    def projectType(resolvers: Resolvers[ef]): ObjectType[Project, ef] =
        Schema.objectType("Project", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#project_#id)(context, src))
            } ::
            {
                Schema.fieldRaw("slug", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#project_#slug)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#project_#name)(context, src))
            } ::
            {
                Schema.fieldRaw("visibility", Nil, Out.scalar(visibilityCodec()), (context, src, _args) ->
                    (resolvers#project_#visibility)(context, src))
            } ::
            Nil)

    /// type ProjectMembership
    def projectMembershipType(resolvers: Resolvers[ef]): ObjectType[ProjectMembership, ef] =
        Schema.objectType("ProjectMembership", () ->
            {
                Schema.fieldRaw("project", Nil, Out.obj(projectType(resolvers)), (context, src, _args) ->
                    (resolvers#projectMembership#project_)(context, src))
            } ::
            {
                Schema.fieldRaw("role", Nil, Out.scalar(roleCodec()), (context, src, _args) ->
                    (resolvers#projectMembership#role)(context, src))
            } ::
            Nil)

    /// type Member
    def memberType(resolvers: Resolvers[ef]): ObjectType[Member, ef] =
        Schema.objectType("Member", () ->
            {
                Schema.fieldRaw("userId", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#member#userId)(context, src))
            } ::
            {
                Schema.fieldRaw("email", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#member#email)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#member#name)(context, src))
            } ::
            {
                Schema.fieldRaw("role", Nil, Out.scalar(roleCodec()), (context, src, _args) ->
                    (resolvers#member#role)(context, src))
            } ::
            Nil)

    /// type Invitation
    def invitationType(resolvers: Resolvers[ef]): ObjectType[Invitation, ef] =
        Schema.objectType("Invitation", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#invitation#id)(context, src))
            } ::
            {
                Schema.fieldRaw("email", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#invitation#email)(context, src))
            } ::
            {
                Schema.fieldRaw("role", Nil, Out.scalar(roleCodec()), (context, src, _args) ->
                    (resolvers#invitation#role)(context, src))
            } ::
            {
                Schema.fieldRaw("createdAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#invitation#createdAt)(context, src))
            } ::
            Nil)

    /// type ApiKey
    def apiKeyType(resolvers: Resolvers[ef]): ObjectType[ApiKey, ef] =
        Schema.objectType("ApiKey", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#apiKey#id)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#apiKey#name)(context, src))
            } ::
            {
                Schema.fieldRaw("scope", Nil, Out.scalar(apiKeyScopeCodec()), (context, src, _args) ->
                    (resolvers#apiKey#scope)(context, src))
            } ::
            {
                Schema.fieldRaw("createdAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#apiKey#createdAt)(context, src))
            } ::
            {
                Schema.fieldRaw("revokedAt", Nil, Out.option(Out.string()), (context, src, _args) ->
                    (resolvers#apiKey#revokedAt)(context, src))
            } ::
            Nil)

    /// type IssuedApiKey
    def issuedApiKeyType(resolvers: Resolvers[ef]): ObjectType[IssuedApiKey, ef] =
        Schema.objectType("IssuedApiKey", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#issuedApiKey#id)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#issuedApiKey#name)(context, src))
            } ::
            {
                Schema.fieldRaw("scope", Nil, Out.scalar(apiKeyScopeCodec()), (context, src, _args) ->
                    (resolvers#issuedApiKey#scope)(context, src))
            } ::
            {
                Schema.fieldRaw("key", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#issuedApiKey#key)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("発行した鍵。key はこの時だけ")

    /// type Asset
    def assetType(resolvers: Resolvers[ef]): ObjectType[Asset, ef] =
        Schema.objectType("Asset", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#asset#id)(context, src))
            } ::
            {
                Schema.fieldRaw("url", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#asset#url)(context, src)) |> Field.withDescription("配信 URL")
            } ::
            {
                Schema.fieldRaw("fileName", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#asset#fileName)(context, src))
            } ::
            {
                Schema.fieldRaw("mime", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#asset#mime)(context, src))
            } ::
            {
                Schema.fieldRaw("size", Nil, Out.int32(), (context, src, _args) ->
                    (resolvers#asset#size)(context, src)) |> Field.withDescription("バイト数")
            } ::
            {
                Schema.fieldRaw("width", Nil, Out.option(Out.int32()), (context, src, _args) ->
                    (resolvers#asset#width)(context, src)) |> Field.withDescription("画像の幅。画像でなければ null")
            } ::
            {
                Schema.fieldRaw("height", Nil, Out.option(Out.int32()), (context, src, _args) ->
                    (resolvers#asset#height)(context, src))
            } ::
            {
                Schema.fieldRaw("alt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#asset#alt)(context, src))
            } ::
            {
                Schema.fieldRaw("status", Nil, Out.scalar(assetStatusCodec()), (context, src, _args) ->
                    (resolvers#asset#status)(context, src))
            } ::
            {
                Schema.fieldRaw("createdAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#asset#createdAt)(context, src))
            } ::
            {
                Schema.fieldRaw("usedBy", Nil, Out.list(Out.obj(entryType(resolvers))), (context, src, _args) ->
                    (resolvers#asset#usedBy)(context, src)) |> Field.withDescription("この asset を使っている entry（下書き・公開・本文の image）")
            } ::
            Nil) |> ObjectType.withDescription("画像やファイル。中身はストレージにあり、url で配信する")

    /// type AssetPage
    def assetPageType(resolvers: Resolvers[ef]): ObjectType[AssetPage, ef] =
        Schema.objectType("AssetPage", () ->
            {
                Schema.fieldRaw("nodes", Nil, Out.list(Out.obj(assetType(resolvers))), (context, src, _args) ->
                    (resolvers#assetPage#nodes)(context, src))
            } ::
            {
                Schema.fieldRaw("totalCount", Nil, Out.int32(), (context, src, _args) ->
                    (resolvers#assetPage#totalCount)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("asset の一覧の 1 ページ")

    /// type Upload
    def uploadType(resolvers: Resolvers[ef]): ObjectType[Upload, ef] =
        Schema.objectType("Upload", () ->
            {
                Schema.fieldRaw("asset", Nil, Out.obj(assetType(resolvers)), (context, src, _args) ->
                    (resolvers#upload#asset)(context, src))
            } ::
            {
                Schema.fieldRaw("uploadUrl", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#upload#uploadUrl)(context, src)) |> Field.withDescription("ここへ PUT する")
            } ::
            {
                Schema.fieldRaw("expiresInSeconds", Nil, Out.int32(), (context, src, _args) ->
                    (resolvers#upload#expiresInSeconds)(context, src)) |> Field.withDescription("URL の有効期限（秒）")
            } ::
            Nil) |> ObjectType.withDescription("署名付き URL の発行結果")

    /// type Entry
    def entryType(resolvers: Resolvers[ef]): ObjectType[Entry, ef] =
        Schema.objectType("Entry", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#entry#id)(context, src))
            } ::
            {
                Schema.fieldRaw("typeId", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#entry#typeId)(context, src))
            } ::
            {
                Schema.fieldRaw("version", Nil, Out.int32(), (context, src, _args) ->
                    (resolvers#entry#version)(context, src)) |> Field.withDescription("楽観ロックの版。updateEntry に expectedVersion として渡す")
            } ::
            {
                Schema.fieldRaw("stage", Nil, Out.scalar(entryStageCodec()), (context, src, _args) ->
                    (resolvers#entry#stage)(context, src))
            } ::
            {
                Schema.fieldRaw("fields", Nil, Out.json(), (context, src, _args) ->
                    (resolvers#entry#fields)(context, src))
            } ::
            {
                Schema.fieldRaw("publishedAt", Nil, Out.option(Out.string()), (context, src, _args) ->
                    (resolvers#entry#publishedAt)(context, src))
            } ::
            {
                Schema.fieldRaw("createdAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#entry#createdAt)(context, src))
            } ::
            {
                Schema.fieldRaw("updatedAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#entry#updatedAt)(context, src))
            } ::
            {
                Schema.fieldRaw("versions", Nil, Out.list(Out.obj(entryVersionType(resolvers))), (context, src, _args) ->
                    (resolvers#entry#versions)(context, src)) |> Field.withDescription("版。新しい順。公開時と saveVersion で積む")
            } ::
            Nil) |> ObjectType.withDescription("entry。fields は下書きの中身")

    /// type EntryVersion
    def entryVersionType(resolvers: Resolvers[ef]): ObjectType[EntryVersion, ef] =
        Schema.objectType("EntryVersion", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#entryVersion#id)(context, src))
            } ::
            {
                Schema.fieldRaw("version", Nil, Out.int32(), (context, src, _args) ->
                    (resolvers#entryVersion#version)(context, src)) |> Field.withDescription("積んだ時点の entry の version")
            } ::
            {
                Schema.fieldRaw("reason", Nil, Out.scalar(versionReasonCodec()), (context, src, _args) ->
                    (resolvers#entryVersion#reason)(context, src))
            } ::
            {
                Schema.fieldRaw("author", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#entryVersion#author)(context, src))
            } ::
            {
                Schema.fieldRaw("fields", Nil, Out.json(), (context, src, _args) ->
                    (resolvers#entryVersion#fields)(context, src))
            } ::
            {
                Schema.fieldRaw("createdAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#entryVersion#createdAt)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("entry の版")

    /// type EntryPage
    def entryPageType(resolvers: Resolvers[ef]): ObjectType[EntryPage, ef] =
        Schema.objectType("EntryPage", () ->
            {
                Schema.fieldRaw("nodes", Nil, Out.list(Out.obj(entryType(resolvers))), (context, src, _args) ->
                    (resolvers#entryPage#nodes)(context, src))
            } ::
            {
                Schema.fieldRaw("totalCount", Nil, Out.int32(), (context, src, _args) ->
                    (resolvers#entryPage#totalCount)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("entry の一覧の 1 ページ")

    /// type ContentType
    def contentTypeType(resolvers: Resolvers[ef]): ObjectType[ContentType, ef] =
        Schema.objectType("ContentType", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#contentType#id)(context, src))
            } ::
            {
                Schema.fieldRaw("apiId", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#apiId)(context, src)) |> Field.withDescription("lowerCamel の識別子（\"blogs\"）")
            } ::
            {
                Schema.fieldRaw("kind", Nil, Out.scalar(typeKindCodec()), (context, src, _args) ->
                    (resolvers#contentType#kind)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#name)(context, src)) |> Field.withDescription("管理画面に出す名前")
            } ::
            {
                Schema.fieldRaw("singular", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#singular)(context, src)) |> Field.withDescription("コンテンツ API の型名（\"Blog\"）")
            } ::
            {
                Schema.fieldRaw("plural", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#plural)(context, src)) |> Field.withDescription("コンテンツ API の一覧クエリ名（\"blogs\"）")
            } ::
            {
                Schema.fieldRaw("previewUrl", Nil, Out.option(Out.string()), (context, src, _args) ->
                    (resolvers#contentType#previewUrl)(context, src)) |> Field.withDescription("管理画面のプレビューが開く URL。{id} を entry の id に置き換える")
            } ::
            {
                Schema.fieldRaw("fields", Nil, Out.list(Out.obj(fieldDefType(resolvers))), (context, src, _args) ->
                    (resolvers#contentType#fields)(context, src)) |> Field.withDescription("最上位のフィールド。position 順。子は children")
            } ::
            {
                Schema.fieldRaw("createdAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#createdAt)(context, src))
            } ::
            {
                Schema.fieldRaw("updatedAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#updatedAt)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("content type。apiId がコンテンツ API のクエリ名の元になる")

    /// type FieldDef
    def fieldDefType(resolvers: Resolvers[ef]): ObjectType[FieldDef, ef] =
        Schema.objectType("FieldDef", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#fieldDef#id)(context, src))
            } ::
            {
                Schema.fieldRaw("apiId", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#fieldDef#apiId)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#fieldDef#name)(context, src))
            } ::
            {
                Schema.fieldRaw("kind", Nil, Out.scalar(fieldKindCodec()), (context, src, _args) ->
                    (resolvers#fieldDef#kind)(context, src))
            } ::
            {
                Schema.fieldRaw("many", Nil, Out.bool(), (context, src, _args) ->
                    (resolvers#fieldDef#many)(context, src)) |> Field.withDescription("配列か")
            } ::
            {
                Schema.fieldRaw("required", Nil, Out.bool(), (context, src, _args) ->
                    (resolvers#fieldDef#required)(context, src)) |> Field.withDescription("公開時に値が要るか")
            } ::
            {
                Schema.fieldRaw("unique", Nil, Out.bool(), (context, src, _args) ->
                    (resolvers#fieldDef#unique)(context, src)) |> Field.withDescription("型の中で値が一意か")
            } ::
            {
                Schema.fieldRaw("localized", Nil, Out.bool(), (context, src, _args) ->
                    (resolvers#fieldDef#localized)(context, src)) |> Field.withDescription("言語ごとに値を持つか")
            } ::
            {
                Schema.fieldRaw("targetTypeId", Nil, Out.option(Out.id()), (context, src, _args) ->
                    (resolvers#fieldDef#targetTypeId)(context, src)) |> Field.withDescription("REFERENCE の参照先の型")
            } ::
            {
                Schema.fieldRaw("parentFieldId", Nil, Out.option(Out.id()), (context, src, _args) ->
                    (resolvers#fieldDef#parentFieldId)(context, src)) |> Field.withDescription("OBJECT / BLOCKS の子なら親のフィールド")
            } ::
            {
                Schema.fieldRaw("children", Nil, Out.list(Out.obj(fieldDefType(resolvers))), (context, src, _args) ->
                    (resolvers#fieldDef#children)(context, src)) |> Field.withDescription("OBJECT の子フィールド、BLOCKS の variant。position 順")
            } ::
            {
                Schema.fieldRaw("config", Nil, Out.obj(fieldConfigType(resolvers)), (context, src, _args) ->
                    (resolvers#fieldDef#config)(context, src))
            } ::
            {
                Schema.fieldRaw("position", Nil, Out.int32(), (context, src, _args) ->
                    (resolvers#fieldDef#position)(context, src)) |> Field.withDescription("兄弟の中の並び順")
            } ::
            Nil) |> ObjectType.withDescription("フィールドの定義")

    /// type FieldConfig
    def fieldConfigType(resolvers: Resolvers[ef]): ObjectType[FieldConfig, ef] =
        Schema.objectType("FieldConfig", () ->
            {
                Schema.fieldRaw("maxLength", Nil, Out.option(Out.int32()), (context, src, _args) ->
                    (resolvers#fieldConfig#maxLength)(context, src)) |> Field.withDescription("TEXT / TEXT_AREA / SLUG の最大文字数")
            } ::
            {
                Schema.fieldRaw("sourceField", Nil, Out.option(Out.string()), (context, src, _args) ->
                    (resolvers#fieldConfig#sourceField)(context, src)) |> Field.withDescription("SLUG の元にするフィールドの apiId")
            } ::
            {
                Schema.fieldRaw("min", Nil, Out.option(Out.float64()), (context, src, _args) ->
                    (resolvers#fieldConfig#min)(context, src)) |> Field.withDescription("NUMBER の下限")
            } ::
            {
                Schema.fieldRaw("max", Nil, Out.option(Out.float64()), (context, src, _args) ->
                    (resolvers#fieldConfig#max)(context, src)) |> Field.withDescription("NUMBER の上限")
            } ::
            {
                Schema.fieldRaw("integer", Nil, Out.option(Out.bool()), (context, src, _args) ->
                    (resolvers#fieldConfig#integer)(context, src)) |> Field.withDescription("NUMBER を整数に限るか")
            } ::
            {
                Schema.fieldRaw("options", Nil, Out.option(Out.list(Out.string())), (context, src, _args) ->
                    (resolvers#fieldConfig#options)(context, src)) |> Field.withDescription("SELECT の選択肢。UPPER_SNAKE")
            } ::
            Nil) |> ObjectType.withDescription("kind ごとの設定。使わない項目は null")

}
