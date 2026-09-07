///
/// 権限の判定。純粋。役割が持つ権限・役割の包含・組織の owner の継承を Datalog の事実と規則で持ち、
/// 「この主体はこの操作ができるか」を引く。
///
/// WhyNot: match で書かないのは、包含（owner ⊃ editor ⊃ writer ⊃ viewer）と組織からの継承が再帰で、
/// 後から「この型だけ」「この entry の担当」のような細かい事実を足す時に判定の関数を変えずに済ませるため。
/// 事実の表がそのまま仕様書になる。DB や JWT にはこの mod は関わらない。
///
mod Authz {

    ///
    /// 判定に渡す対象。プレビュートークンは entryId で判定する。typeId はまだ使っていない
    /// （後で「この型だけ編集可」のような事実を足す時に、呼び出し側を変えないために最初から受ける）。
    ///
    pub type alias Resource = { typeId = Option[TypeId], entryId = Option[EntryId] }

    /// 対象を指定しない。
    pub def anyResource(): Resource = { typeId = None, entryId = None }

    /// この entry を対象にする。
    pub def entryResource(id: EntryId): Resource = { typeId = None, entryId = Some(id) }

    ///
    /// 役割の表。Grants(役割, 権限) と Implies(上の役割, 含む役割)。
    ///
    def rules(): #{ Grants(String, String), Implies(String, String), Has(String), Allowed(String) } = #{
        Grants("viewer", "readDraft").
        Grants("writer", "writeEntries").
        Grants("editor", "manageTypes").
        Grants("editor", "publishEntries").
        Grants("editor", "manageAssets").
        Grants("owner",  "manageMembers").
        Grants("owner",  "manageApiKeys").
        Grants("owner",  "manageProject").
        Implies("writer", "viewer").
        Implies("editor", "writer").
        Implies("owner",  "editor").
        Has(lower) :- Has(role), Implies(role, lower).
        Allowed(p) :- Has(role), Grants(role, p).
    }

    ///
    /// 主体がこの操作をできるか。人は役割（read の PAT なら viewer に落とした物）の表で引き、write の鍵はその役割で引く（ただし管理は不可）、
    /// 読む鍵は読み取りだけ、誰でもない人は何もできない。
    ///
    pub def can(actor: Actor, permission: Permission, resource: Resource): Bool = match actor {
        case Actor.User(_, _, roles, login)           => canWithRoles(effectiveRoles(login, roles), permission)
        case Actor.Preview(id)                        => permission == Permission.ReadDraft and resource#entryId == Some(id)
        case Actor.ApiKey(_, ApiKeyScope.Write(role)) => not isManagement(permission) and canWithRoles(role :: Nil, permission)
        case Actor.ApiKey(_, ApiKeyScope.ReadDraft)   => permission == Permission.ReadDraft
        case Actor.ApiKey(_, ApiKeyScope.Read)        => false
        case Actor.Anonymous                          => false
        case Actor.System                             => true
    }

    ///
    /// 来かたで役割を落とす。read の PAT は viewer、ログインの JWT と write の PAT は本人の役割のまま。
    ///
    pub def effectiveRoles(login: Login, roles: List[Role]): List[Role] = match login {
        case Login.PersonalToken(PatScope.Read)  => capToViewer(roles)
        case Login.PersonalToken(PatScope.Write) => roles
        case Login.Interactive                   => roles
    }

    ///
    /// メンバー・鍵・プロジェクトの管理。API キーではできない（鍵で鍵やメンバーを作る道を作らない）。
    ///
    pub def isManagement(permission: Permission): Bool = match permission {
        case Permission.ManageMembers => true
        case Permission.ManageApiKeys => true
        case Permission.ManageProject => true
        case _                        => false
    }

    ///
    /// 役割の並びを読むだけ（viewer）に落とす。役割が無ければ無いまま（メンバーでない人は viewer にもならない）。
    ///
    pub def capToViewer(roles: List[Role]): List[Role] =
        if (List.isEmpty(roles)) Nil else Role.Viewer :: Nil

    ///
    /// 役割の並びの中で一番高い物。無ければ None。発行者より高い鍵を作らせない検査に使う。
    ///
    pub def highestRole(roles: List[Role]): Option[Role] =
        List.maximum(roles)

    ///
    /// 役割の並びで引く。包含は Datalog が閉じる。
    ///
    pub def canWithRoles(roles: List[Role], permission: Permission): Bool =
        let facts = inject List.map(Role.text, roles) into Has/1;
        let allowed = query rules(), facts select p from Allowed(p);
        Vector.memberOf(Permission.text(permission), allowed)

    ///
    /// 役割の並びが持つ権限の一覧（管理画面で「できる事」を出す用）。
    ///
    pub def permissionsOf(roles: List[Role]): List[String] =
        let facts = inject List.map(Role.text, roles) into Has/1;
        query rules(), facts select p from Allowed(p) |> Vector.toList |> List.sort

    ///
    /// 直接の membership と組織の役割から、このプロジェクトでの役割の並び。組織の owner はプロジェクトの owner。
    ///
    pub def rolesOf(membership: Option[Role], orgRole: Option[OrgRole]): List[Role] =
        (membership |> Option.toList) ::: (if (orgRole == Some(OrgRole.Owner)) Role.Owner :: Nil else Nil)

    ///
    /// 一覧の絞り込み。今は空（誰でも全件）。後で属性ベースの権限（このタグの記事だけ）をここから SQL の条件として出す。
    ///
    pub def readFilter(_actor: Actor): List[Condition] = Nil

}
