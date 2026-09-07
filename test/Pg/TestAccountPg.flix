///
/// Account API（プロジェクトを選ぶ前の操作）を実 PostgreSQL で見る。組織とプロジェクトの作成、組織のメンバー、他人の組織は見えない、API キーは使えない。
///
mod TestAccountPg {

    def bearer(subject: String, email: String): Credential = Credential.Bearer("test", subject, email, subject)

    def asUser(schema: Schema, credential: Credential): String -> (Value, Option[String]) \ IO =
        queryText -> GraphqlTestKit.askWith(schema, Context.withCredential(credential), queryText)

    def obj(fields: List[(String, Value)]): Value = Value.Obj(List.toMap(fields))

    /// 応答の data から id の文字列を取る（"createOrganization" → "id" など）。テストは連番の値を知らず、返ってきた物をそのまま次に渡す。
    def idIn(path: List[String], response: (Value, Option[String])): String =
        List.foldLeft((value, name) -> Value.field(name, value), fst(response), path) |> Value.asStr |> Option.getWithDefault("")

    ///
    /// 登録したての人（どのプロジェクトにも属さない）が組織を作り、その下にプロジェクトを作ると、me に owner として出る。
    /// プロジェクト slug の形が違えば invalid、予約した物は使えない。
    ///
    @Test
    def testPgAccountCreateOrganizationAndProject(): Unit \ {IO, Assert} =
        let (before, created, createdProject, badSlug, reserved, after) = PgTestSupport.withAccountApi(() -> (), (schema, _) -> {
            let ask = asUser(schema, bearer("alice", "alice@example.com"));
            let before = ask("{ me { email organizations { role } projects { role } } }");
            let created = ask("mutation { createOrganization(name: \"Acme\") { id name } }");
            let orgId = idIn(List#{"createOrganization", "id"}, created);
            let createdProject = ask("mutation { createProject(orgId: \"${orgId}\", slug: \"blog\", name: \"Blog\") { slug name visibility } }");
            let badSlug = ask("mutation { createProject(orgId: \"${orgId}\", slug: \"Blog\", name: \"x\") { id } }") |> snd;
            let reserved = ask("mutation { createProject(orgId: \"${orgId}\", slug: \"account\", name: \"x\") { id } }") |> snd;
            let after = ask("{ me { organizations { organization { name } role } projects { project { slug } role } } }");
            (before, created |> fst |> Value.field("createOrganization") |> Value.field("name"), createdProject, badSlug, reserved, after)
        });
        Assert.assertEq(
            expected = (
                (obj(("me", obj(("email", Value.Str("alice@example.com")) :: ("organizations", Value.List(Nil)) :: ("projects", Value.List(Nil)) :: Nil)) :: Nil), None),
                Value.Str("Acme"),
                (obj(("createProject", obj(("slug", Value.Str("blog")) :: ("name", Value.Str("Blog")) :: ("visibility", Value.Str("PUBLIC")) :: Nil)) :: Nil), None),
                Some("slug: 'Blog' は 英小文字・数字・- を 1 〜 64 文字（先頭は英数字） にしてください"),
                Some("slug: 'account' は予約されています"),
                (obj(("me", obj(
                    ("organizations", Value.List(obj(("organization", obj(("name", Value.Str("Acme")) :: Nil)) :: ("role", Value.Str("OWNER")) :: Nil) :: Nil)) ::
                    ("projects", Value.List(obj(("project", obj(("slug", Value.Str("blog")) :: Nil)) :: ("role", Value.Str("OWNER")) :: Nil) :: Nil)) :: Nil)) :: Nil), None)),
            (before, created, createdProject, badSlug, reserved, after))

    ///
    /// 組織のメンバー。owner は既にログインした人を email で足せ、member は足せず（forbidden）、外から見ると組織自体が null。
    /// 最後の owner は外せない。
    ///
    @Test
    def testPgAccountOrganizationMembers(): Unit \ {IO, Assert} =
        let (added, members, memberAdds, outsiderSees, memberSees, lastOwner, removed) = PgTestSupport.withAccountApi(() -> (), (schema, _) -> {
            let alice = asUser(schema, bearer("alice", "alice@example.com"));
            let bob = asUser(schema, bearer("bob", "bob@example.com"));
            let carol = asUser(schema, bearer("carol", "carol@example.com"));
            let bobId = idIn(List#{"me", "id"}, bob("{ me { id } }"));
            let aliceId = idIn(List#{"me", "id"}, alice("{ me { id } }"));
            discard carol("{ me { id } }");
            let orgId = idIn(List#{"createOrganization", "id"}, alice("mutation { createOrganization(name: \"Acme\") { id } }"));
            let added = alice("mutation { addOrganizationMember(orgId: \"${orgId}\", email: \"Bob@Example.com\", role: MEMBER) { email role } }");
            let members = alice("{ organization(id: \"${orgId}\") { members { email role } } }");
            let memberAdds = bob("mutation { addOrganizationMember(orgId: \"${orgId}\", email: \"carol@example.com\", role: MEMBER) { email } }") |> snd;
            let outsiderSees = carol("{ organization(id: \"${orgId}\") { name } }");
            let memberSees = bob("{ organization(id: \"${orgId}\") { name members { email } } }");
            let lastOwner = alice("mutation { removeOrganizationMember(orgId: \"${orgId}\", userId: \"${aliceId}\") }") |> snd;
            let removed = alice("mutation { removeOrganizationMember(orgId: \"${orgId}\", userId: \"${bobId}\") }");
            (added, members, memberAdds, outsiderSees, memberSees, lastOwner, removed |> fst |> Value.field("removeOrganizationMember") |> Value.asStr |> Option.map(id -> id == bobId))
        });
        Assert.assertEq(
            expected = (
                (obj(("addOrganizationMember", obj(("email", Value.Str("bob@example.com")) :: ("role", Value.Str("MEMBER")) :: Nil)) :: Nil), None),
                (obj(("organization", obj(("members", Value.List(
                    obj(("email", Value.Str("bob@example.com")) :: ("role", Value.Str("MEMBER")) :: Nil) ::
                    obj(("email", Value.Str("alice@example.com")) :: ("role", Value.Str("OWNER")) :: Nil) :: Nil)) :: Nil)) :: Nil), None),
                Some("この操作（manageProject）の権限がありません"),
                (obj(("organization", Value.Null) :: Nil), None),
                (obj(("organization", obj(("name", Value.Str("Acme")) :: ("members", Value.List(Nil)) :: Nil)) :: Nil), None),
                Some("role: 最後の owner は外せません。先に別の owner を付けてください"),
                Some(true)),
            (added, members, memberAdds, outsiderSees, memberSees, lastOwner, removed))

    ///
    /// 身元が無ければ me は null で mutation は forbidden。API キーは Account API では断られる。
    ///
    @Test
    def testPgAccountRequiresLogin(): Unit \ {IO, Assert} =
        let (anonymousMe, anonymousCreate, withKey) = PgTestSupport.withAccountApi(() -> (), (schema, _) -> {
            let anonymous = asUser(schema, Credential.Missing);
            let keyed = asUser(schema, Credential.ApiKey("cms_whatever"));
            (anonymous("{ me { email } }"),
             anonymous("mutation { createOrganization(name: \"x\") { id } }") |> snd,
             keyed("{ me { email } }") |> snd)
        });
        Assert.assertEq(
            expected = (
                (obj(("me", Value.Null) :: Nil), None),
                Some("この操作（readDraft）の権限がありません"),
                Some("Account API は API キーでは使えません。ログインしてください")),
            (anonymousMe, anonymousCreate, withKey))

    ///
    /// Account API で作った組織の owner は、そのプロジェクトの管理 API で owner として振る舞える（型を作れる）。
    ///
    @Test
    def testPgAccountOwnerReachesProjectAdmin(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let alice = Accounts.resolveUser({ ownerEmail = None }, { issuer = "test", subject = "alice", email = "alice@example.com", name = "alice" });
            let org = Session.runWith(Accounts.actorWithoutProject(alice), () -> Organizations.create(Signup.Open, "Acme"));
            let blog = Session.runWith(Accounts.actorWithoutProject(alice), () -> Organizations.createProject(org#id, ProjectSlug.ProjectSlug("blog"), "Blog"));
            Tenant.runWith(blog#id, () -> Session.runWith(Accounts.actorFor(alice, blog#id), () ->
                (ContentTypes.create(CmsTestKit.typeDraft("posts", "記事"))#apiId, Session.current() == Actor.User(alice#id, "alice@example.com", Role.Owner :: Nil))))
        });
        Assert.assertEq(expected = Ok(Ok((ApiId.ApiId("posts"), true))), result)

    ///
    /// CMS_SIGNUP=closed なら既定の組織の owner だけが組織を作れる。
    ///
    @Test
    def testPgAccountClosedSignup(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let owner = Accounts.resolveUser({ ownerEmail = Some("owner@test") }, { issuer = "test", subject = "owner", email = "owner@test", name = "owner" });
            let stranger = Accounts.resolveUser({ ownerEmail = Some("owner@test") }, { issuer = "test", subject = "s", email = "s@example.com", name = "s" });
            (Session.runWith(Accounts.actorWithoutProject(stranger), () -> CmsTestKit.failureMessage(() -> Organizations.create(Signup.Closed, "x"))),
             Session.runWith(Accounts.actorWithoutProject(owner), () -> Organizations.create(Signup.Closed, "Acme"))#name)
        });
        Assert.assertEq(expected = Ok(Ok((Err("この操作（manageProject）の権限がありません"), "Acme"))), result)

}
