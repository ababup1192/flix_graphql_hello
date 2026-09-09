///
/// ログインの email の正規化。招待は小文字で置くので、ログイン側も同じ形に揃えないと突き合わせが当たらない。
///
mod TestTokenVerifier {

    // ---- 正規化の規則 ----

    /// 大文字・前後の空白は落ち、既に小文字の物は変わらない。
    @Test
    def testEmailNormalizeTable(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ "editor@example.com", "editor@example.com", "editor@example.com", "editor@example.com", "" },
            List#{ "Editor@Example.com", "  editor@example.com  ", "EDITOR@EXAMPLE.COM", "editor@example.com", "" }
                |> List.map(Email.normalize))

    /// 本人の email は正規化され、発行元にとって意味のある issuer / subject はそのまま。
    @Test
    def testPrincipalNormalizedKeepsIdentity(): Unit \ Assert =
        Assert.assertEq(
            expected = ("https://team.cloudflareaccess.com", "SUB-1", "editor@example.com", "Editor"),
            Principal.normalized({ issuer = "https://team.cloudflareaccess.com", subject = "SUB-1", email = " Editor@Example.COM ", name = "Editor" }) |> parts)

    // ---- 開発モード（X-Dev-User） ----

    /// X-Dev-User の値は正規化した email になり、subject も同じ値（大文字違いで別人にしない）。
    @Test
    def testDevVerifyNormalizesEmail(): Unit \ Assert =
        Assert.assertEq(
            expected = Ok(("dev", "editor@example.com", "editor@example.com", "")),
            TokenVerifier.runDev(() -> TokenVerifier.verify("Editor@Example.com")) |> Result.map(parts))

    /// email でなければ断る（正規化の前に形を見る）。
    @Test
    def testDevVerifyRejectsNonEmail(): Unit \ Assert =
        Assert.assertEq(
            expected = Err("開発モードでは X-Dev-User に email を入れてください"),
            TokenVerifier.runDev(() -> TokenVerifier.verify("Editor")) |> Result.map(parts))

    /// 本人を比べられる組に開く（レコードには Eq が無い）。
    def parts(principal: Principal): (String, String, String, String) =
        (principal#issuer, principal#subject, principal#email, principal#name)

}
