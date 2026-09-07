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
pub type alias User = { id = UserId, issuer = String, subject = String, email = String, name = String }

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
///
pub enum Actor with Eq, Order, ToString {
    case User(UserId, String, List[Role])
    case ApiKey(ApiKeyScope)
    case Anonymous
}

///
/// API キーの範囲。
///
pub enum ApiKeyScope with Eq, Order, ToString {
    /// 公開中の中身
    case Read
    /// 下書きも
    case ReadDraft
}

mod ApiKeyScope {
    pub def text(scope: ApiKeyScope): String = match scope {
        case ApiKeyScope.Read      => "read"
        case ApiKeyScope.ReadDraft => "readDraft"
    }

    pub def parse(text: String): Option[ApiKeyScope] = match text {
        case "read"      => Some(ApiKeyScope.Read)
        case "readDraft" => Some(ApiKeyScope.ReadDraft)
        case _           => None
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
