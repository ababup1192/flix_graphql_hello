///
/// SDL から schemagen が生成したファイル。手で編集しない（`make generate` で作り直す）。
///
mod GeneratedAccount {

    /// 生成元の SDL 本文（改行は LF）。GeneratedCheck が SDL ファイルと照合する
    pub def sdlText(): String = "\"\"\"プロジェクトを選ぶ前の操作。/account/graphql で受け、Tenant を持たない。組織とプロジェクトを作り、組織のメンバーを管理し、自分の Personal Access Token（PAT）を発行する。\nログイン（Bearer の JWT か PAT）が要り、API キーは使えない\"\"\"\ntype Query {\n  \"\"\"自分。ログインしていなければ null。organizations と projects は自分が触れる物だけ\"\"\"\n  me: Me\n  \"\"\"組織 1 つ。member でなければ null（存在も教えない）\"\"\"\n  organization(id: ID!): Organization\n}\n\ntype Mutation {\n  \"\"\"組織を作る。作った人が owner。CMS_SIGNUP=closed なら既定の組織の owner だけ\"\"\"\n  createOrganization(name: String!): Organization!\n  \"\"\"組織の下にプロジェクトを作る。組織の owner だけ。slug はプロジェクト slug（URL の /p/{slug}/ と subdomain に出る）\"\"\"\n  createProject(orgId: ID!, slug: String!, name: String!): Project!\n  \"\"\"既にログインした事のある人を email で組織に足す（owner だけ）。まだ居なければエラー\"\"\"\n  addOrganizationMember(orgId: ID!, email: String!, role: OrgRole!): OrganizationMember!\n  \"\"\"組織から外す（owner だけ）。最後の owner は外せない。外した userId を返す\"\"\"\n  removeOrganizationMember(orgId: ID!, userId: ID!): ID!\n\n  \"\"\"自分の Personal Access Token を発行する。token はこの応答でしか見えない。ttlDays は 1 〜 365（省くと 90）。\n  `Authorization: Bearer cmspat_...` で管理 API と Account API を自分として叩ける（READ なら読むだけ）\"\"\"\n  createPersonalAccessToken(name: String!, scope: PatScope!, ttlDays: Int): IssuedPersonalAccessToken!\n  \"\"\"自分の Personal Access Token を失効する。他人の物は見つからない\"\"\"\n  revokePersonalAccessToken(id: ID!): Boolean!\n}\n\n\"\"\"Personal Access Token の範囲\"\"\"\nenum PatScope {\n  \"\"\"読むだけ（役割は viewer に落ちる）\"\"\"\n  READ\n  \"\"\"本人の役割のまま\"\"\"\n  WRITE\n}\n\n\"\"\"自分の Personal Access Token。生のトークンは出ない\"\"\"\ntype PersonalAccessToken {\n  id: ID!\n  name: String!\n  scope: PatScope!\n  createdAt: String!\n  expiresAt: String!\n  \"\"\"最後に使った時刻（1 分の粒度）\"\"\"\n  lastUsedAt: String\n  revokedAt: String\n}\n\n\"\"\"発行した Personal Access Token。token はこの時だけ\"\"\"\ntype IssuedPersonalAccessToken {\n  id: ID!\n  name: String!\n  scope: PatScope!\n  expiresAt: String!\n  token: String!\n}\n\n\"\"\"プロジェクトでの役割。上が下を含む\"\"\"\nenum Role {\n  VIEWER\n  WRITER\n  EDITOR\n  OWNER\n}\n\n\"\"\"組織での役割。OWNER は組織の全プロジェクトの owner でもある\"\"\"\nenum OrgRole {\n  MEMBER\n  OWNER\n}\n\n\"\"\"プロジェクトの見え方\"\"\"\nenum Visibility {\n  \"\"\"公開中の中身はキー無しで読める\"\"\"\n  PUBLIC\n  \"\"\"read のキーが要る\"\"\"\n  PRIVATE\n}\n\n\"\"\"自分\"\"\"\ntype Me {\n  id: ID!\n  email: String!\n  name: String!\n  organizations: [OrganizationMembership!]!\n  projects: [ProjectMembership!]!\n  \"\"\"自分の Personal Access Token（失効した物も）\"\"\"\n  personalAccessTokens: [PersonalAccessToken!]!\n}\n\ntype Organization {\n  id: ID!\n  name: String!\n  \"\"\"組織のメンバー。owner だけに出る（member には空）\"\"\"\n  members: [OrganizationMember!]!\n  \"\"\"組織の下のプロジェクト\"\"\"\n  projects: [Project!]!\n}\n\ntype OrganizationMember {\n  userId: ID!\n  email: String!\n  name: String!\n  role: OrgRole!\n}\n\ntype OrganizationMembership {\n  organization: Organization!\n  role: OrgRole!\n}\n\ntype Project {\n  id: ID!\n  \"\"\"プロジェクト slug\"\"\"\n  slug: String!\n  name: String!\n  visibility: Visibility!\n}\n\ntype ProjectMembership {\n  project: Project!\n  role: Role!\n}\n"

    /// 生成した schemagen のバージョン
    pub def generatorVersion(): String = "6"

    /// enum PatScope。Personal Access Token の範囲
    pub enum PatScope with Eq, Order, ToString {
        /// 読むだけ（役割は viewer に落ちる）
        case Read
        /// 本人の役割のまま
        case Write
    }

    /// PatScope の Codec
    pub def patScopeCodec(): GqlCodec[PatScope] =
        GqlCodec.enumOf("PatScope", value -> match value { case PatScope.Read => "READ" case PatScope.Write => "WRITE" }, PatScope.Read :: PatScope.Write :: Nil) |> GqlCodec.describe("Personal Access Token の範囲") |> GqlCodec.describeValue(PatScope.Read, "読むだけ（役割は viewer に落ちる）") |> GqlCodec.describeValue(PatScope.Write, "本人の役割のまま")

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

    /// Query.me
    pub type alias QueryMeResolver[ef: Eff] = Context -> Result[FieldError, Option[Me]] \ ef
    /// Query.organization
    pub type alias QueryOrganizationResolver[ef: Eff] = Context -> Id -> Result[FieldError, Option[Organization]] \ ef
    /// Mutation.createOrganization
    pub type alias MutationCreateOrganizationResolver[ef: Eff] = Context -> String -> Result[FieldError, Organization] \ ef
    /// Mutation.createProject
    pub type alias MutationCreateProjectResolver[ef: Eff] = Context -> Id -> String -> String -> Result[FieldError, Project] \ ef
    /// Mutation.addOrganizationMember
    pub type alias MutationAddOrganizationMemberResolver[ef: Eff] = Context -> Id -> String -> OrgRole -> Result[FieldError, OrganizationMember] \ ef
    /// Mutation.removeOrganizationMember
    pub type alias MutationRemoveOrganizationMemberResolver[ef: Eff] = Context -> Id -> Id -> Result[FieldError, Id] \ ef
    /// Mutation.createPersonalAccessToken
    pub type alias MutationCreatePersonalAccessTokenResolver[ef: Eff] = Context -> String -> PatScope -> Option[Int32] -> Result[FieldError, IssuedPersonalAccessToken] \ ef
    /// Mutation.revokePersonalAccessToken
    pub type alias MutationRevokePersonalAccessTokenResolver[ef: Eff] = Context -> Id -> Result[FieldError, Bool] \ ef
    /// PersonalAccessToken.id
    pub type alias PersonalAccessTokenIdResolver[ef: Eff] = Context -> PersonalAccessToken -> Result[FieldError, Id] \ ef
    /// PersonalAccessToken.name
    pub type alias PersonalAccessTokenNameResolver[ef: Eff] = Context -> PersonalAccessToken -> Result[FieldError, String] \ ef
    /// PersonalAccessToken.scope
    pub type alias PersonalAccessTokenScopeResolver[ef: Eff] = Context -> PersonalAccessToken -> Result[FieldError, PatScope] \ ef
    /// PersonalAccessToken.createdAt
    pub type alias PersonalAccessTokenCreatedAtResolver[ef: Eff] = Context -> PersonalAccessToken -> Result[FieldError, String] \ ef
    /// PersonalAccessToken.expiresAt
    pub type alias PersonalAccessTokenExpiresAtResolver[ef: Eff] = Context -> PersonalAccessToken -> Result[FieldError, String] \ ef
    /// PersonalAccessToken.lastUsedAt
    pub type alias PersonalAccessTokenLastUsedAtResolver[ef: Eff] = Context -> PersonalAccessToken -> Result[FieldError, Option[String]] \ ef
    /// PersonalAccessToken.revokedAt
    pub type alias PersonalAccessTokenRevokedAtResolver[ef: Eff] = Context -> PersonalAccessToken -> Result[FieldError, Option[String]] \ ef
    /// IssuedPersonalAccessToken.id
    pub type alias IssuedPersonalAccessTokenIdResolver[ef: Eff] = Context -> IssuedPersonalAccessToken -> Result[FieldError, Id] \ ef
    /// IssuedPersonalAccessToken.name
    pub type alias IssuedPersonalAccessTokenNameResolver[ef: Eff] = Context -> IssuedPersonalAccessToken -> Result[FieldError, String] \ ef
    /// IssuedPersonalAccessToken.scope
    pub type alias IssuedPersonalAccessTokenScopeResolver[ef: Eff] = Context -> IssuedPersonalAccessToken -> Result[FieldError, PatScope] \ ef
    /// IssuedPersonalAccessToken.expiresAt
    pub type alias IssuedPersonalAccessTokenExpiresAtResolver[ef: Eff] = Context -> IssuedPersonalAccessToken -> Result[FieldError, String] \ ef
    /// IssuedPersonalAccessToken.token
    pub type alias IssuedPersonalAccessTokenTokenResolver[ef: Eff] = Context -> IssuedPersonalAccessToken -> Result[FieldError, String] \ ef
    /// Me.id
    pub type alias MeIdResolver[ef: Eff] = Context -> Me -> Result[FieldError, Id] \ ef
    /// Me.email
    pub type alias MeEmailResolver[ef: Eff] = Context -> Me -> Result[FieldError, String] \ ef
    /// Me.name
    pub type alias MeNameResolver[ef: Eff] = Context -> Me -> Result[FieldError, String] \ ef
    /// Me.organizations
    pub type alias MeOrganizationsResolver[ef: Eff] = Context -> Me -> Result[FieldError, List[OrganizationMembership]] \ ef
    /// Me.projects
    pub type alias MeProjectsResolver[ef: Eff] = Context -> Me -> Result[FieldError, List[ProjectMembership]] \ ef
    /// Me.personalAccessTokens
    pub type alias MePersonalAccessTokensResolver[ef: Eff] = Context -> Me -> Result[FieldError, List[PersonalAccessToken]] \ ef
    /// Organization.id
    pub type alias OrganizationIdResolver[ef: Eff] = Context -> Organization -> Result[FieldError, Id] \ ef
    /// Organization.name
    pub type alias OrganizationNameResolver[ef: Eff] = Context -> Organization -> Result[FieldError, String] \ ef
    /// Organization.members
    pub type alias OrganizationMembersResolver[ef: Eff] = Context -> Organization -> Result[FieldError, List[OrganizationMember]] \ ef
    /// Organization.projects
    pub type alias OrganizationProjectsResolver[ef: Eff] = Context -> Organization -> Result[FieldError, List[Project]] \ ef
    /// OrganizationMember.userId
    pub type alias OrganizationMemberUserIdResolver[ef: Eff] = Context -> OrganizationMember -> Result[FieldError, Id] \ ef
    /// OrganizationMember.email
    pub type alias OrganizationMemberEmailResolver[ef: Eff] = Context -> OrganizationMember -> Result[FieldError, String] \ ef
    /// OrganizationMember.name
    pub type alias OrganizationMemberNameResolver[ef: Eff] = Context -> OrganizationMember -> Result[FieldError, String] \ ef
    /// OrganizationMember.role
    pub type alias OrganizationMemberRoleResolver[ef: Eff] = Context -> OrganizationMember -> Result[FieldError, OrgRole] \ ef
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

    /// type Query のリゾルバ一式。ef はリゾルバの効果
    pub type alias QueryResolvers[ef: Eff] = {
        me = QueryMeResolver[ef],
        organization = QueryOrganizationResolver[ef]
    }

    /// type Mutation のリゾルバ一式。ef はリゾルバの効果
    pub type alias MutationResolvers[ef: Eff] = {
        createOrganization = MutationCreateOrganizationResolver[ef],
        createProject = MutationCreateProjectResolver[ef],
        addOrganizationMember = MutationAddOrganizationMemberResolver[ef],
        removeOrganizationMember = MutationRemoveOrganizationMemberResolver[ef],
        createPersonalAccessToken = MutationCreatePersonalAccessTokenResolver[ef],
        revokePersonalAccessToken = MutationRevokePersonalAccessTokenResolver[ef]
    }

    /// type PersonalAccessToken のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias PersonalAccessTokenResolvers[ef: Eff] = {
        id = PersonalAccessTokenIdResolver[ef],
        name = PersonalAccessTokenNameResolver[ef],
        scope = PersonalAccessTokenScopeResolver[ef],
        createdAt = PersonalAccessTokenCreatedAtResolver[ef],
        expiresAt = PersonalAccessTokenExpiresAtResolver[ef],
        lastUsedAt = PersonalAccessTokenLastUsedAtResolver[ef],
        revokedAt = PersonalAccessTokenRevokedAtResolver[ef]
    }

    /// type IssuedPersonalAccessToken のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias IssuedPersonalAccessTokenResolvers[ef: Eff] = {
        id = IssuedPersonalAccessTokenIdResolver[ef],
        name = IssuedPersonalAccessTokenNameResolver[ef],
        scope = IssuedPersonalAccessTokenScopeResolver[ef],
        expiresAt = IssuedPersonalAccessTokenExpiresAtResolver[ef],
        token = IssuedPersonalAccessTokenTokenResolver[ef]
    }

    /// type Me のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias MeResolvers[ef: Eff] = {
        id = MeIdResolver[ef],
        email = MeEmailResolver[ef],
        name = MeNameResolver[ef],
        organizations = MeOrganizationsResolver[ef],
        projects = MeProjectsResolver[ef],
        personalAccessTokens = MePersonalAccessTokensResolver[ef]
    }

    /// type Organization のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias OrganizationResolvers[ef: Eff] = {
        id = OrganizationIdResolver[ef],
        name = OrganizationNameResolver[ef],
        members = OrganizationMembersResolver[ef],
        projects = OrganizationProjectsResolver[ef]
    }

    /// type OrganizationMember のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias OrganizationMemberResolvers[ef: Eff] = {
        userId = OrganizationMemberUserIdResolver[ef],
        email = OrganizationMemberEmailResolver[ef],
        name = OrganizationMemberNameResolver[ef],
        role = OrganizationMemberRoleResolver[ef]
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

    /// type PersonalAccessToken の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def personalAccessTokenDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        name = Context -> { name = String | r1 } -> Result[FieldError, String] \ ef,
        scope = Context -> { scope = PatScope | r2 } -> Result[FieldError, PatScope] \ ef,
        createdAt = Context -> { createdAt = String | r3 } -> Result[FieldError, String] \ ef,
        expiresAt = Context -> { expiresAt = String | r4 } -> Result[FieldError, String] \ ef,
        lastUsedAt = Context -> { lastUsedAt = Option[String] | r5 } -> Result[FieldError, Option[String]] \ ef,
        revokedAt = Context -> { revokedAt = Option[String] | r6 } -> Result[FieldError, Option[String]] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        name = (_context, src) -> Ok(src#name),
        scope = (_context, src) -> Ok(src#scope),
        createdAt = (_context, src) -> Ok(src#createdAt),
        expiresAt = (_context, src) -> Ok(src#expiresAt),
        lastUsedAt = (_context, src) -> Ok(src#lastUsedAt),
        revokedAt = (_context, src) -> Ok(src#revokedAt)
    }

    /// type IssuedPersonalAccessToken の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def issuedPersonalAccessTokenDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        name = Context -> { name = String | r1 } -> Result[FieldError, String] \ ef,
        scope = Context -> { scope = PatScope | r2 } -> Result[FieldError, PatScope] \ ef,
        expiresAt = Context -> { expiresAt = String | r3 } -> Result[FieldError, String] \ ef,
        token = Context -> { token = String | r4 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        name = (_context, src) -> Ok(src#name),
        scope = (_context, src) -> Ok(src#scope),
        expiresAt = (_context, src) -> Ok(src#expiresAt),
        token = (_context, src) -> Ok(src#token)
    }

    /// type Me の既定リゾルバ。source の同名ラベルをそのまま返す。organizations, projects, personalAccessTokens は含まない（オブジェクト型を返すか、引数を持つ）
    pub def meDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        email = Context -> { email = String | r1 } -> Result[FieldError, String] \ ef,
        name = Context -> { name = String | r2 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        email = (_context, src) -> Ok(src#email),
        name = (_context, src) -> Ok(src#name)
    }

    /// type Organization の既定リゾルバ。source の同名ラベルをそのまま返す。members, projects は含まない（オブジェクト型を返すか、引数を持つ）
    pub def organizationDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        name = Context -> { name = String | r1 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        name = (_context, src) -> Ok(src#name)
    }

    /// type OrganizationMember の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def organizationMemberDefaults(): {
        userId = Context -> { userId = Id | r0 } -> Result[FieldError, Id] \ ef,
        email = Context -> { email = String | r1 } -> Result[FieldError, String] \ ef,
        name = Context -> { name = String | r2 } -> Result[FieldError, String] \ ef,
        role = Context -> { role = OrgRole | r3 } -> Result[FieldError, OrgRole] \ ef
    } = {
        userId = (_context, src) -> Ok(src#userId),
        email = (_context, src) -> Ok(src#email),
        name = (_context, src) -> Ok(src#name),
        role = (_context, src) -> Ok(src#role)
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

    /// 全型のリゾルバ。1 つでも欠けるとコンパイルエラー。ef は全リゾルバで共有する 1 つの効果
    pub type alias Resolvers[ef: Eff] = {
        queryRoot = QueryResolvers[ef],
        mutationRoot = MutationResolvers[ef],
        personalAccessToken = PersonalAccessTokenResolvers[ef],
        issuedPersonalAccessToken = IssuedPersonalAccessTokenResolvers[ef],
        me = MeResolvers[ef],
        organization = OrganizationResolvers[ef],
        organizationMember = OrganizationMemberResolvers[ef],
        organizationMembership = OrganizationMembershipResolvers[ef],
        project_ = ProjectResolvers[ef],
        projectMembership = ProjectMembershipResolvers[ef]
    }

    /// リゾルバ一式からスキーマを組み立てる。runner が ef を IO に落とす
    pub def schema(resolvers: Resolvers[ef], runner: Runner[ef]): Schema =
        Schema.make(queryType(resolvers), Some(mutationType(resolvers)), runner)

    /// type Query
    def queryType(resolvers: Resolvers[ef]): ObjectType[Unit, ef] =
        Schema.objectType("Query", () ->
            {
                Schema.fieldRaw("me", Nil, Out.option(Out.obj(meType(resolvers))), (context, _src, _args) ->
                    (resolvers#queryRoot#me)(context)) |> Field.withDescription("自分。ログインしていなければ null。organizations と projects は自分が触れる物だけ")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("organization", Arg.info(arg0) :: Nil, Out.option(Out.obj(organizationType(resolvers))), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#queryRoot#organization)(context, v0)) yield result) |> Field.withDescription("組織 1 つ。member でなければ null（存在も教えない）")
            } ::
            Nil) |> ObjectType.withDescription("プロジェクトを選ぶ前の操作。/account/graphql で受け、Tenant を持たない。組織とプロジェクトを作り、組織のメンバーを管理し、自分の Personal Access Token（PAT）を発行する。\nログイン（Bearer の JWT か PAT）が要り、API キーは使えない")

    /// type Mutation
    def mutationType(resolvers: Resolvers[ef]): ObjectType[Unit, ef] =
        Schema.objectType("Mutation", () ->
            {
                let arg0 = Schema.arg("name", GqlCodec.string());
                Schema.fieldRaw("createOrganization", Arg.info(arg0) :: Nil, Out.obj(organizationType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#createOrganization)(context, v0)) yield result) |> Field.withDescription("組織を作る。作った人が owner。CMS_SIGNUP=closed なら既定の組織の owner だけ")
            } ::
            {
                let arg0 = Schema.arg("orgId", GqlCodec.id());
                let arg1 = Schema.arg("slug", GqlCodec.string());
                let arg2 = Schema.arg("name", GqlCodec.string());
                Schema.fieldRaw("createProject", Arg.info(arg0) :: Arg.info(arg1) :: Arg.info(arg2) :: Nil, Out.obj(projectType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); v2 <- Arg.decode(arg2, args); result <- (resolvers#mutationRoot#createProject)(context, v0, v1, v2)) yield result) |> Field.withDescription("組織の下にプロジェクトを作る。組織の owner だけ。slug はプロジェクト slug（URL の /p/{slug}/ と subdomain に出る）")
            } ::
            {
                let arg0 = Schema.arg("orgId", GqlCodec.id());
                let arg1 = Schema.arg("email", GqlCodec.string());
                let arg2 = Schema.arg("role", orgRoleCodec());
                Schema.fieldRaw("addOrganizationMember", Arg.info(arg0) :: Arg.info(arg1) :: Arg.info(arg2) :: Nil, Out.obj(organizationMemberType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); v2 <- Arg.decode(arg2, args); result <- (resolvers#mutationRoot#addOrganizationMember)(context, v0, v1, v2)) yield result) |> Field.withDescription("既にログインした事のある人を email で組織に足す（owner だけ）。まだ居なければエラー")
            } ::
            {
                let arg0 = Schema.arg("orgId", GqlCodec.id());
                let arg1 = Schema.arg("userId", GqlCodec.id());
                Schema.fieldRaw("removeOrganizationMember", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.id(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#removeOrganizationMember)(context, v0, v1)) yield result) |> Field.withDescription("組織から外す（owner だけ）。最後の owner は外せない。外した userId を返す")
            } ::
            {
                let arg0 = Schema.arg("name", GqlCodec.string());
                let arg1 = Schema.arg("scope", patScopeCodec());
                let arg2 = Schema.arg("ttlDays", GqlCodec.option(GqlCodec.int32()));
                Schema.fieldRaw("createPersonalAccessToken", Arg.info(arg0) :: Arg.info(arg1) :: Arg.info(arg2) :: Nil, Out.obj(issuedPersonalAccessTokenType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); v2 <- Arg.decode(arg2, args); result <- (resolvers#mutationRoot#createPersonalAccessToken)(context, v0, v1, v2)) yield result) |> Field.withDescription("自分の Personal Access Token を発行する。token はこの応答でしか見えない。ttlDays は 1 〜 365（省くと 90）。\n`Authorization: Bearer cmspat_...` で管理 API と Account API を自分として叩ける（READ なら読むだけ）")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("revokePersonalAccessToken", Arg.info(arg0) :: Nil, Out.bool(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#revokePersonalAccessToken)(context, v0)) yield result) |> Field.withDescription("自分の Personal Access Token を失効する。他人の物は見つからない")
            } ::
            Nil)

    /// type PersonalAccessToken
    def personalAccessTokenType(resolvers: Resolvers[ef]): ObjectType[PersonalAccessToken, ef] =
        Schema.objectType("PersonalAccessToken", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#personalAccessToken#id)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#personalAccessToken#name)(context, src))
            } ::
            {
                Schema.fieldRaw("scope", Nil, Out.scalar(patScopeCodec()), (context, src, _args) ->
                    (resolvers#personalAccessToken#scope)(context, src))
            } ::
            {
                Schema.fieldRaw("createdAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#personalAccessToken#createdAt)(context, src))
            } ::
            {
                Schema.fieldRaw("expiresAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#personalAccessToken#expiresAt)(context, src))
            } ::
            {
                Schema.fieldRaw("lastUsedAt", Nil, Out.option(Out.string()), (context, src, _args) ->
                    (resolvers#personalAccessToken#lastUsedAt)(context, src)) |> Field.withDescription("最後に使った時刻（1 分の粒度）")
            } ::
            {
                Schema.fieldRaw("revokedAt", Nil, Out.option(Out.string()), (context, src, _args) ->
                    (resolvers#personalAccessToken#revokedAt)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("自分の Personal Access Token。生のトークンは出ない")

    /// type IssuedPersonalAccessToken
    def issuedPersonalAccessTokenType(resolvers: Resolvers[ef]): ObjectType[IssuedPersonalAccessToken, ef] =
        Schema.objectType("IssuedPersonalAccessToken", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#issuedPersonalAccessToken#id)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#issuedPersonalAccessToken#name)(context, src))
            } ::
            {
                Schema.fieldRaw("scope", Nil, Out.scalar(patScopeCodec()), (context, src, _args) ->
                    (resolvers#issuedPersonalAccessToken#scope)(context, src))
            } ::
            {
                Schema.fieldRaw("expiresAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#issuedPersonalAccessToken#expiresAt)(context, src))
            } ::
            {
                Schema.fieldRaw("token", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#issuedPersonalAccessToken#token)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("発行した Personal Access Token。token はこの時だけ")

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
                Schema.fieldRaw("organizations", Nil, Out.list(Out.obj(organizationMembershipType(resolvers))), (context, src, _args) ->
                    (resolvers#me#organizations)(context, src))
            } ::
            {
                Schema.fieldRaw("projects", Nil, Out.list(Out.obj(projectMembershipType(resolvers))), (context, src, _args) ->
                    (resolvers#me#projects)(context, src))
            } ::
            {
                Schema.fieldRaw("personalAccessTokens", Nil, Out.list(Out.obj(personalAccessTokenType(resolvers))), (context, src, _args) ->
                    (resolvers#me#personalAccessTokens)(context, src)) |> Field.withDescription("自分の Personal Access Token（失効した物も）")
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
            {
                Schema.fieldRaw("members", Nil, Out.list(Out.obj(organizationMemberType(resolvers))), (context, src, _args) ->
                    (resolvers#organization#members)(context, src)) |> Field.withDescription("組織のメンバー。owner だけに出る（member には空）")
            } ::
            {
                Schema.fieldRaw("projects", Nil, Out.list(Out.obj(projectType(resolvers))), (context, src, _args) ->
                    (resolvers#organization#projects)(context, src)) |> Field.withDescription("組織の下のプロジェクト")
            } ::
            Nil)

    /// type OrganizationMember
    def organizationMemberType(resolvers: Resolvers[ef]): ObjectType[OrganizationMember, ef] =
        Schema.objectType("OrganizationMember", () ->
            {
                Schema.fieldRaw("userId", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#organizationMember#userId)(context, src))
            } ::
            {
                Schema.fieldRaw("email", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#organizationMember#email)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#organizationMember#name)(context, src))
            } ::
            {
                Schema.fieldRaw("role", Nil, Out.scalar(orgRoleCodec()), (context, src, _args) ->
                    (resolvers#organizationMember#role)(context, src))
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
                    (resolvers#project_#slug)(context, src)) |> Field.withDescription("プロジェクト slug")
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

}
