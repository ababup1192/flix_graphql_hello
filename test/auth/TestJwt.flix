///
/// JWT の検証。自分で RSA の鍵を作って署名し、通る物と落ちる物を見る。
///
mod TestJwt {

    import java.security.KeyPairGenerator
    import java.security.KeyPair
    import java.security.Signature
    import java.security.interfaces.RSAPublicKey
    import java.security.interfaces.RSAPrivateKey

    /// 2048 bit の RSA の鍵。
    def keyPair(): KeyPair \ IO =
        let generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        generator.generateKeyPair()

    /// 公開鍵を JWK に。
    def jwkOf(kid: String, pair: KeyPair): Jwt.RsaJwk \ IO =
        let publicKey: RSAPublicKey = unchecked_cast(pair.getPublic() as RSAPublicKey);
        { kid = kid, n = Jwt.encodeBase64Url(Array.toVector(publicKey.getModulus().toByteArray())), e = Jwt.encodeBase64Url(Array.toVector(publicKey.getPublicExponent().toByteArray())) }

    /// header と payload の JSON を署名して JWT にする。
    def sign(pair: KeyPair, header: String, payload: String): String \ IO =
        let signed = "${Jwt.encodeBase64Url(String.toBytes(header))}.${Jwt.encodeBase64Url(String.toBytes(payload))}";
        let signer = Signature.getInstance("SHA256withRSA");
        let privateKey: RSAPrivateKey = unchecked_cast(pair.getPrivate() as RSAPrivateKey);
        signer.initSign(privateKey);
        signer.update(Vector.toArray(Static, String.toBytes(signed)));
        "${signed}.${Jwt.encodeBase64Url(Array.toVector(signer.sign()))}"

    def expectation(): Jwt.Expectation = { issuer = "https://team.cloudflareaccess.com", audience = "cms-app", now = 1000000i64, skewSeconds = 60i64 }

    def header(alg: String, kid: String): String = "{\"alg\":\"${alg}\",\"typ\":\"JWT\",\"kid\":\"${kid}\"}"

    def payload(iss: String, aud: String, exp: Int64): String =
        "{\"iss\":\"${iss}\",\"sub\":\"user-1\",\"aud\":\"${aud}\",\"exp\":${exp},\"email\":\"a@example.com\",\"email_verified\":true,\"name\":\"A\"}"

    /// 正しい鍵・alg・iss・aud・期限なら claims が取れる。aud が配列でも通る。
    @Test
    def testVerifyValid(): Unit \ {IO, Assert} =
        let pair = keyPair();
        let keys = jwkOf("k1", pair) :: Nil;
        let single = Jwt.verify(keys, expectation(), sign(pair, header("RS256", "k1"), payload("https://team.cloudflareaccess.com", "cms-app", 1003600i64)));
        let arrayAud = Jwt.verify(keys, expectation(), sign(pair, header("RS256", "k1"),
            "{\"iss\":\"https://team.cloudflareaccess.com\",\"sub\":\"user-2\",\"aud\":[\"other\",\"cms-app\"],\"exp\":1003600}"));
        Assert.assertEq(
            expected = (Ok(("user-1", Some("a@example.com"), Some(true), Some("A"))), Ok("user-2")),
            (single |> Result.map(claims -> (claims#subject, claims#email, claims#emailVerified, claims#name)), arrayAud |> Result.map(claims -> claims#subject)))

    /// 落ちる物: alg が違う、知らない kid、別の鍵の署名、改ざん、iss / aud が違う、期限切れ、nbf が未来、形が違う。
    @Test
    def testVerifyRejects(): Unit \ {IO, Assert} =
        let pair = keyPair();
        let other = keyPair();
        let keys = jwkOf("k1", pair) :: Nil;
        let good = payload("https://team.cloudflareaccess.com", "cms-app", 1003600i64);
        let tampered = {
            let token = sign(pair, header("RS256", "k1"), good);
            let parts = String.splitOn(substr = ".", token);
            let forged = Jwt.encodeBase64Url(String.toBytes(payload("https://team.cloudflareaccess.com", "cms-app", 9999999i64)));
            List.join(".", List#{ List.head(parts) |> Option.getWithDefault(""), forged, List.last(parts) |> Option.getWithDefault("") })
        };
        Assert.assertEq(
            expected = List#{
                Err("JWT の alg 'HS256' は受け付けません（RS256 だけ）"),
                Err("JWT の alg 'none' は受け付けません（RS256 だけ）"),
                Err("JWT の kid に合う鍵がありません"),
                Err("JWT の署名が合いません"),
                Err("JWT の署名が合いません"),
                Err("JWT の発行元が違います"),
                Err("JWT の audience が違います"),
                Err("JWT の期限が切れています"),
                Err("JWT はまだ有効ではありません"),
                Err("JWT の形ではありません")
            },
            List#{
                sign(pair, header("HS256", "k1"), good),
                sign(pair, header("none", "k1"), good),
                sign(pair, header("RS256", "k9"), good),
                sign(other, header("RS256", "k1"), good),
                tampered,
                sign(pair, header("RS256", "k1"), payload("https://evil.example", "cms-app", 1003600i64)),
                sign(pair, header("RS256", "k1"), payload("https://team.cloudflareaccess.com", "other-app", 1003600i64)),
                sign(pair, header("RS256", "k1"), payload("https://team.cloudflareaccess.com", "cms-app", 999000i64)),
                sign(pair, header("RS256", "k1"), "{\"iss\":\"https://team.cloudflareaccess.com\",\"sub\":\"u\",\"aud\":\"cms-app\",\"exp\":1003600,\"nbf\":1000100}"),
                "not.a"
            } |> List.map(Jwt.verify(keys, expectation())) |> List.map(Result.map(claims -> claims#subject)))

    /// 期限は時計のずれ 60 秒まで許す。
    @Test
    def testVerifySkew(): Unit \ {IO, Assert} =
        let pair = keyPair();
        let keys = jwkOf("k1", pair) :: Nil;
        Assert.assertEq(
            expected = (true, false),
            (Jwt.verify(keys, expectation(), sign(pair, header("RS256", "k1"), payload("https://team.cloudflareaccess.com", "cms-app", 999950i64))) |> Result.isOk,
             Jwt.verify(keys, expectation(), sign(pair, header("RS256", "k1"), payload("https://team.cloudflareaccess.com", "cms-app", 999900i64))) |> Result.isOk))

    /// JWKS の JSON から RSA の鍵だけ拾う。
    @Test
    def testParseJwks(): Unit \ Assert =
        Assert.assertEq(
            expected = Ok(List#{ "k1" }),
            TokenVerifier.parseJwks("{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"k1\",\"n\":\"AQAB\",\"e\":\"AQAB\"},{\"kty\":\"EC\",\"kid\":\"k2\",\"crv\":\"P-256\",\"x\":\"a\",\"y\":\"b\"}]}")
                |> Result.map(List.map(key -> key#kid)))

}
