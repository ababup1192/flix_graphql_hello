///
/// ユーザーの id。users.id。
///
pub enum UserId with Eq, Order {
    case UserId(Int64)
}

instance ToString[UserId] {
    pub def toString(id: UserId): String = Int64.toString(UserId.toInt64(id))
}

mod UserId {
    pub def toInt64(id: UserId): Int64 =
        let UserId.UserId(inner) = id;
        inner
}

///
/// 組織の id。organizations.id。
///
pub enum OrgId with Eq, Order {
    case OrgId(Int64)
}

instance ToString[OrgId] {
    pub def toString(id: OrgId): String = Int64.toString(OrgId.toInt64(id))
}

mod OrgId {
    pub def toInt64(id: OrgId): Int64 =
        let OrgId.OrgId(inner) = id;
        inner

    /// 既定の組織。migration が作る。
    pub def default(): OrgId = OrgId.OrgId(1i64)
}

///
/// 本人確認の結果。JWT の発行元が言っている事で、この CMS はこれを検証するだけで作らない。
///
/// - issuer / subject: 本人の鍵。email は表示と招待の突き合わせにだけ使う
/// - name: 表示名。無ければ空
///
pub type alias Principal = { issuer = String, subject = String, email = String, name = String }

///
/// ユーザー。
///
pub type alias User = { id = UserId, publicId = String, issuer = String, subject = String, email = String, name = String }

///
/// 外向きの id（GraphQL の ID に出す乱数）。内部の主キーは連番なので外に出さない（存在する id と規模が推測できる）。
/// 型は String のまま: 境界（AdminMapping / AccountMapping）で DB を引いて内部 id に戻すので、中では持ち回らない。
///

///
/// プロジェクトでの役割。上が下を含む（owner ⊃ editor ⊃ writer ⊃ viewer。包含は Authz の規則）。
///
pub enum Role with Eq, Order, ToString {
    /// 読むだけ
    case Viewer
    /// entry の作成と下書き
    case Writer
    /// 型の編集、公開、asset
    case Editor
    /// メンバー、API キー、プロジェクトの削除
    case Owner
}

mod Role {
    /// DB と Datalog の事実に使う文字列。
    pub def text(role: Role): String = match role {
        case Role.Viewer => "viewer"
        case Role.Writer => "writer"
        case Role.Editor => "editor"
        case Role.Owner  => "owner"
    }

    /// 文字列から。知らない物は None。
    pub def parse(text: String): Option[Role] = match text {
        case "viewer" => Some(Role.Viewer)
        case "writer" => Some(Role.Writer)
        case "editor" => Some(Role.Editor)
        case "owner"  => Some(Role.Owner)
        case _        => None
    }
}

///
/// 組織での役割。owner は組織の全プロジェクトの owner でもある。
///
pub enum OrgRole with Eq, Order, ToString {
    case Member
    case Owner
}

mod OrgRole {
    pub def text(role: OrgRole): String = match role {
        case OrgRole.Member => "member"
        case OrgRole.Owner  => "owner"
    }

    pub def parse(text: String): Option[OrgRole] = match text {
        case "member" => Some(OrgRole.Member)
        case "owner"  => Some(OrgRole.Owner)
        case _        => None
    }
}

///
/// 操作の種類。ユースケースが `Actor.require` で要求する。
///
pub enum Permission with Eq, Order, ToString {
    /// 下書きと型の定義を読む（管理 API の Query 全部）
    case ReadDraft
    /// entry の作成・更新・削除（下書き）
    case WriteEntries
    /// 公開と取り下げ
    case PublishEntries
    /// 型とフィールドの編集
    case ManageTypes
    /// asset のアップロードと削除
    case ManageAssets
    /// メンバーの招待と役割
    case ManageMembers
    /// API キーの発行と失効
    case ManageApiKeys
    /// プロジェクトの設定と削除
    case ManageProject
}

mod Permission {
    pub def text(permission: Permission): String = match permission {
        case Permission.ReadDraft      => "readDraft"
        case Permission.WriteEntries   => "writeEntries"
        case Permission.PublishEntries => "publishEntries"
        case Permission.ManageTypes    => "manageTypes"
        case Permission.ManageAssets   => "manageAssets"
        case Permission.ManageMembers  => "manageMembers"
        case Permission.ManageApiKeys  => "manageApiKeys"
        case Permission.ManageProject  => "manageProject"
    }
}

///
/// 今のリクエストの主体。人（JWT）か、公開 API の鍵か、誰でもない（公開の読み取り）か。
///
/// - user: 人。roles は今のプロジェクトで持つ役割（直接の membership と、組織の owner として持つ物）
/// - apiKey: 鍵。scope は read か readDraft
/// - anonymous: 公開 API をキー無しで読む人
/// - system: サーバ自身の内部処理
///
pub enum Actor with Eq, Order, ToString {
    case User(UserId, String, List[Role])
    /// read の PAT で来た人。役割は本人の物だが、読む操作しかできない（Authz が viewer に落とす。書く操作の入口 Session.currentUser は拒む）
    case ReadOnlyUser(UserId, String, List[Role])
    case ApiKey(ApiKeyScope)
    case Anonymous
    /// プレビュートークンの持ち主。その entry（と参照先）の下書きだけ読める
    case Preview(EntryId)
    /// サーバ自身（エンジンの組み直しなど、リクエストの主体が無い内部の処理）。何でもできる
    case System
}

///
/// API キーの範囲。
///
pub enum ApiKeyScope with Eq, Order, ToString {
    /// 公開中の中身
    case Read
    /// 下書きも
    case ReadDraft
    /// 管理 API をこの役割で叩ける（CI やスクリプト用）。メンバー・鍵・プロジェクトの管理はできない
    case Write(Role)
}

mod ApiKeyScope {
    /// DB の scope 列。役割は別の列（role）。
    pub def text(scope: ApiKeyScope): String = match scope {
        case ApiKeyScope.Read      => "read"
        case ApiKeyScope.ReadDraft => "readDraft"
        case ApiKeyScope.Write(_)  => "write"
    }

    /// DB の role 列。write の鍵だけ Some。
    pub def roleOf(scope: ApiKeyScope): Option[Role] = match scope {
        case ApiKeyScope.Write(role) => Some(role)
        case _                       => None
    }

    /// scope 列と role 列から。write に役割が無い、read に役割がある、write の役割が viewer、知らない物は None。
    pub def parse(text: String, role: Option[String]): Option[ApiKeyScope] = match (text, role) {
        case ("read", None)             => Some(ApiKeyScope.Read)
        case ("readDraft", None)        => Some(ApiKeyScope.ReadDraft)
        case ("write", Some(roleText))  => Role.parse(roleText) |> Option.filter(isWritingRole) |> Option.map(ApiKeyScope.Write)
        case _                          => None
    }

    /// write の鍵に付けられる役割か（writer 以上。viewer の write は readDraft の鍵と同じなので作らせない）。
    pub def isWritingRole(role: Role): Bool = role >= Role.Writer
}

///
/// Personal Access Token（PAT）の範囲。人の代わりに使うトークンで、役割は本人の物。
///
pub enum PatScope with Eq, Order, ToString {
    /// 読むだけ（役割は viewer に落ちる）
    case Read
    /// 本人の役割のまま
    case Write
}

mod PatScope {
    pub def text(scope: PatScope): String = match scope {
        case PatScope.Read  => "read"
        case PatScope.Write => "write"
    }

    pub def parse(text: String): Option[PatScope] = match text {
        case "read"  => Some(PatScope.Read)
        case "write" => Some(PatScope.Write)
        case _       => None
    }
}

///
/// プロジェクトの見え方。public は公開中の中身をキー無しで読める。
///
pub enum Visibility with Eq, Order, ToString {
    case Public
    case Private
}

mod Visibility {
    pub def text(visibility: Visibility): String = match visibility {
        case Visibility.Public  => "public"
        case Visibility.Private => "private"
    }

    pub def parse(text: String): Option[Visibility] = match text {
        case "public"  => Some(Visibility.Public)
        case "private" => Some(Visibility.Private)
        case _         => None
    }
}

///
/// 組織。
///
pub type alias Organization = { id = OrgId, publicId = String, name = String }

///
/// 自分が属する組織と役割。
///
pub type alias OrganizationMembership = { organization = Organization, role = OrgRole }

///
/// プロジェクト（認証の文脈で見る形）。
///
pub type alias Project = { id = ProjectId, publicId = String, slug = ProjectSlug, name = String, visibility = Visibility }

///
/// 自分が触れるプロジェクトと役割。
///
pub type alias ProjectMembership = { target = Project, role = Role }

///
/// 自分。roles は今のプロジェクトでの役割。
///
pub type alias Me = { user = User, roles = List[Role], organizations = List[OrganizationMembership], projects = List[ProjectMembership] }

///
/// 組織のメンバー 1 人。
///
pub type alias OrganizationMember = { userId = UserId, publicId = String, email = String, name = String, role = OrgRole }

///
/// 組織を誰が作れるか。クラウド版は Open（ログインした人なら誰でも）、セルフホストは Closed（既定の組織の owner だけ）にできる。
///
pub enum Signup with Eq, ToString {
    case Open
    case Closed
}

///
/// プロジェクトのメンバー 1 人。
///
pub type alias Member = { userId = UserId, publicId = String, email = String, name = String, role = Role }

///
/// 招待 1 つ。
///
pub type alias Invitation = { id = Int64, publicId = String, email = String, role = Role, createdAt = Timestamp.Timestamp }

///
/// API キーの 1 行。生の鍵は持たない。
///
pub type alias ApiKey = { id = Int64, publicId = String, name = String, scope = ApiKeyScope, createdAt = Timestamp.Timestamp,
                          expiresAt = Option[Timestamp.Timestamp], lastUsedAt = Option[Timestamp.Timestamp], revokedAt = Option[Timestamp.Timestamp] }

///
/// 発行した鍵。key はこの時だけ見える。
///
pub type alias IssuedApiKey = { id = Int64, publicId = String, name = String, scope = ApiKeyScope, expiresAt = Option[Timestamp.Timestamp], key = String }

///
/// API キーの発行の入力。expiresAt が無ければ期限無し。
///
pub type alias ApiKeyDraft = { name = String, scope = ApiKeyScope, expiresAt = Option[Timestamp.Timestamp] }

///
/// PAT の 1 行。生のトークンは持たない。
///
pub type alias PersonalAccessToken = { id = Int64, publicId = String, name = String, scope = PatScope, createdAt = Timestamp.Timestamp,
                                       expiresAt = Timestamp.Timestamp, lastUsedAt = Option[Timestamp.Timestamp], revokedAt = Option[Timestamp.Timestamp] }

///
/// 発行した PAT。token はこの時だけ見える。
///
pub type alias IssuedPersonalAccessToken = { id = Int64, publicId = String, name = String, scope = PatScope, expiresAt = Timestamp.Timestamp, token = String }

///
/// PAT の発行の入力。ttlDays が無ければ既定（90 日）。
///
pub type alias PersonalTokenDraft = { name = String, scope = PatScope, ttlDays = Option[Int32] }

///
/// hash で解決した PAT。主体を組むのに要る物だけ。
///
pub type alias ResolvedPersonalToken = { id = Int64, userId = UserId, scope = PatScope }
