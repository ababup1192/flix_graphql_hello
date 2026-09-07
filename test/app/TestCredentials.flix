///
/// ヘッダから身元を組む。PAT（Authorization: Bearer cmspat_）は JWT のヘッダの設定に関わらず先に拾い、それ以外は今まで通り。
///
mod TestCredentials {

    /// JWT の検証は固定。"good" だけ本人、他は落ちる。
    def verify(token: String): Result[String, Principal] =
        if (token == "good") Ok({ issuer = "test", subject = "u1", email = "a@example.com", name = "A" }) else Err("bad token")

    def ofHeaders(tokenHeader: String, headers: List[(String, String)]): Credential =
        Credentials.ofHeaders(tokenHeader, verify, headers)

    /// Authorization の Bearer が cmspat_ で始まれば PAT、そうでなければ JWT として検証、X-Api-Key / X-Preview-Token / 無しはそれぞれ。
    @Test
    def testCredentialsByHeader(): Unit \ Assert =
        Assert.assertEq(
            expected = (
                Credential.PersonalToken("cmspat_abc"),
                Credential.Bearer("test", "u1", "a@example.com", "A"),
                Credential.Invalid("bad token"),
                Credential.ApiKey("cms_k"),
                Credential.Preview("pv_x"),
                Credential.Missing),
            (ofHeaders("Authorization", ("Authorization", "Bearer cmspat_abc") :: Nil),
             ofHeaders("Authorization", ("Authorization", "Bearer good") :: Nil),
             ofHeaders("Authorization", ("Authorization", "Bearer nope") :: Nil),
             ofHeaders("Authorization", ("X-Api-Key", "cms_k") :: Nil),
             ofHeaders("Authorization", ("X-Preview-Token", "pv_x") :: Nil),
             ofHeaders("Authorization", Nil)))

    /// 同じリクエストに 2 つ付いていれば、ログインの JWT と PAT が X-Api-Key より先。Bearer の scheme は小文字でも読む。
    @Test
    def testCredentialsPrecedenceAndLowercaseScheme(): Unit \ Assert =
        Assert.assertEq(
            expected = (
                Credential.Bearer("test", "u1", "a@example.com", "A"),
                Credential.PersonalToken("cmspat_abc"),
                Credential.Bearer("test", "u1", "a@example.com", "A"),
                Credential.PersonalToken("cmspat_abc")),
            (ofHeaders("Authorization", ("Authorization", "Bearer good") :: ("X-Api-Key", "cms_k") :: Nil),
             ofHeaders("Authorization", ("Authorization", "Bearer cmspat_abc") :: ("X-Api-Key", "cms_k") :: Nil),
             ofHeaders("Authorization", ("Authorization", "bearer good") :: Nil),
             ofHeaders("Authorization", ("Authorization", "bearer cmspat_abc") :: Nil)))

    /// JWT が別のヘッダ（Cf-Access-Jwt-Assertion）で来る設定でも、PAT は Authorization から読め、JWT はそのヘッダから読む。PAT が JWT より先。
    @Test
    def testCredentialsWithSeparateJwtHeader(): Unit \ Assert =
        Assert.assertEq(
            expected = (
                Credential.PersonalToken("cmspat_abc"),
                Credential.Bearer("test", "u1", "a@example.com", "A"),
                Credential.PersonalToken("cmspat_abc"),
                Credential.ApiKey("cms_k")),
            (ofHeaders("Cf-Access-Jwt-Assertion", ("Authorization", "Bearer cmspat_abc") :: Nil),
             ofHeaders("Cf-Access-Jwt-Assertion", ("Cf-Access-Jwt-Assertion", "good") :: Nil),
             ofHeaders("Cf-Access-Jwt-Assertion", ("Cf-Access-Jwt-Assertion", "good") :: ("Authorization", "Bearer cmspat_abc") :: Nil),
             ofHeaders("Cf-Access-Jwt-Assertion", ("Authorization", "Bearer cms_k") :: ("X-Api-Key", "cms_k") :: Nil)))

}
