///
/// 権限の証明（Granted）。印の型 → Permission の表、Session.grant が Authz の判定を通す / 通さない表、tryGrant / grantInteractive、含意。DB 無し。
///
mod TestGranted {

    use CmsErr.CmsFailure

    def user(roles: List[Role]): Actor = Actor.User(UserId.UserId(1i64), "a@example.com", roles, Login.Interactive)

    ///
    /// この主体で証明を作ってみて、できれば証明が指す Permission、できなければ業務エラー。
    /// 印の型は make の側で `Session.grant() : Granted[…]` と決める。
    ///
    def tryGrant(actor: Actor, make: Unit -> Granted[p] \ Session + CmsErr): Result[CmsFailure, Permission] with Perm[p] =
        Session.runWith(actor, () -> CmsTestKit.runWithResult(make)) |> Result.map(Perm.permission)

    /// 印の型 → Permission の表。System は全部できるので、8 つの印の証明を作って Permission に戻すと Permission.all() と同じ並びになる。
    @Test
    def testPermOfEachMark(): Unit \ Assert =
        Assert.assertEq(
            expected = Permission.all() |> List.map(Ok),
            List#{
                tryGrant(Actor.System, () -> (Session.grant() : Granted[ReadDraft])),
                tryGrant(Actor.System, () -> (Session.grant() : Granted[WriteEntries])),
                tryGrant(Actor.System, () -> (Session.grant() : Granted[PublishEntries])),
                tryGrant(Actor.System, () -> (Session.grant() : Granted[ManageTypes])),
                tryGrant(Actor.System, () -> (Session.grant() : Granted[ManageAssets])),
                tryGrant(Actor.System, () -> (Session.grant() : Granted[ManageMembers])),
                tryGrant(Actor.System, () -> (Session.grant() : Granted[ManageApiKeys])),
                tryGrant(Actor.System, () -> (Session.grant() : Granted[ManageProject]))
            })

    /// 主体 × 印の表。viewer は読めるが型を触れず、editor は型を触れるがメンバーを触れず、匿名は読めず、
    /// owner の write の鍵でもプロジェクトの管理はできない。断りは要求した Permission を持つ forbidden。
    @Test
    def testGrantFollowsAuthz(): Unit \ Assert =
        let ownerKey = Actor.ApiKey("ci", ApiKeyScope.Write(Role.Owner));
        Assert.assertEq(
            expected = List#{
                ("viewer readDraft",       Ok(Permission.ReadDraft)),
                ("viewer manageTypes",     Err(CmsFailure.Forbidden(Permission.ManageTypes))),
                ("editor manageTypes",     Ok(Permission.ManageTypes)),
                ("editor manageMembers",   Err(CmsFailure.Forbidden(Permission.ManageMembers))),
                ("anonymous readDraft",    Err(CmsFailure.Forbidden(Permission.ReadDraft))),
                ("ownerKey manageAssets",  Ok(Permission.ManageAssets)),
                ("ownerKey manageProject", Err(CmsFailure.Forbidden(Permission.ManageProject)))
            },
            List#{
                ("viewer readDraft",       tryGrant(user(Role.Viewer :: Nil), () -> (Session.grant() : Granted[ReadDraft]))),
                ("viewer manageTypes",     tryGrant(user(Role.Viewer :: Nil), () -> (Session.grant() : Granted[ManageTypes]))),
                ("editor manageTypes",     tryGrant(user(Role.Editor :: Nil), () -> (Session.grant() : Granted[ManageTypes]))),
                ("editor manageMembers",   tryGrant(user(Role.Editor :: Nil), () -> (Session.grant() : Granted[ManageMembers]))),
                ("anonymous readDraft",    tryGrant(Actor.Anonymous, () -> (Session.grant() : Granted[ReadDraft]))),
                ("ownerKey manageAssets",  tryGrant(ownerKey, () -> (Session.grant() : Granted[ManageAssets]))),
                ("ownerKey manageProject", tryGrant(ownerKey, () -> (Session.grant() : Granted[ManageProject])))
            })

    /// 対象付きの証明。プレビューは自分の entry の readDraft だけで、他の entry と対象無しは forbidden。
    @Test
    def testGrantOnResource(): Unit \ Assert =
        let e1 = CmsTestKit.entryId("e1");
        let preview = Actor.Preview(e1);
        Assert.assertEq(
            expected = (Ok(Permission.ReadDraft), Err(CmsFailure.Forbidden(Permission.ReadDraft)), Err(CmsFailure.Forbidden(Permission.ReadDraft))),
            (tryGrant(preview, () -> (Session.grantOn(Authz.entryResource(e1)) : Granted[ReadDraft])),
             tryGrant(preview, () -> (Session.grantOn(Authz.entryResource(CmsTestKit.entryId("e2"))) : Granted[ReadDraft])),
             tryGrant(preview, () -> (Session.grant() : Granted[ReadDraft]))))

    /// できるかどうかを forbidden にせず Option で返す。owner は publishEntries を持てるが、writer は持てず None。
    @Test
    def testTryGrantIsOptional(): Unit \ Assert =
        let attempt = actor -> Session.runWith(actor, () -> (Session.tryGrant() : Option[Granted[PublishEntries]])) |> Option.map(Perm.permission);
        Assert.assertEq(
            expected = (Some(Permission.PublishEntries), None, None),
            (attempt(user(Role.Owner :: Nil)), attempt(user(Role.Writer :: Nil)), attempt(Actor.Anonymous)))

    /// ログインの JWT で来た本人の証明。ログインの JWT とサーバ自身は通り、PAT（write でも）と鍵は requiresLogin。
    @Test
    def testGrantInteractive(): Unit \ Assert =
        let attempt = actor -> Session.runWith(actor, () -> CmsTestKit.runWithResult(() -> discard Session.grantInteractive()));
        let notInteractive = Err(CmsFailure.RequiresLogin(LoginRequirement.Interactive));
        Assert.assertEq(
            expected = List#{Ok(()), Ok(()), notInteractive, notInteractive},
            List#{
                attempt(user(Role.Owner :: Nil)),
                attempt(Actor.System),
                attempt(Actor.User(UserId.UserId(1i64), "a@example.com", Role.Owner :: Nil, Login.PersonalToken(PatScope.Write))),
                attempt(Actor.ApiKey("ci", ApiKeyScope.Write(Role.Owner)))
            })

    ///
    /// 判定し直さない含意（`Session.readDraftOfWriter` / `readDraftOfPublisher`）が Authz と合っている事。
    /// 主体の一覧（役割ごとの人、write の鍵、readDraft の鍵、匿名、System）で、writeEntries か publishEntries を持てる物は必ず readDraft も持てる。
    ///
    @Test
    def testReadDraftIsImpliedByWriteAndPublish(): Unit \ Assert =
        let actors = List#{
            user(Role.Viewer :: Nil), user(Role.Writer :: Nil), user(Role.Editor :: Nil), user(Role.Owner :: Nil),
            Actor.ApiKey("w", ApiKeyScope.Write(Role.Writer)), Actor.ApiKey("e", ApiKeyScope.Write(Role.Editor)), Actor.ApiKey("o", ApiKeyScope.Write(Role.Owner)),
            Actor.ApiKey("d", ApiKeyScope.ReadDraft), Actor.ApiKey("r", ApiKeyScope.Read), Actor.Anonymous, Actor.System
        };
        let holds = actor -> {
            let can = permission -> Authz.can(actor, permission, Authz.anyResource());
            (not can(Permission.WriteEntries) or can(Permission.ReadDraft)) and (not can(Permission.PublishEntries) or can(Permission.ReadDraft))
        };
        Assert.assertEq(expected = List.map(_ -> true, actors), List.map(holds, actors))

}
