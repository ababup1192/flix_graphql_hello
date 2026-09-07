///
/// JWT（RS256）の検証。鍵と期待する発行元・audience・今の時刻を引数で受けるので純粋。
/// 発行はしない。alg は RS256 だけ許し、`none` と HS256（共有鍵と取り違える攻撃）は拒む。
///
/// WhyNot: ライブラリ（nimbus-jose 等）を入れないのは、要るのが RS256 の検証 1 つで、依存を増やすより
/// 自分で鍵を作って署名したテストで固定する方が見通しがよいため。ES256 は要る時に足す。
///
mod Jwt {

    use Util.Json.Json

    import java.util.Base64
    import java.math.BigInteger
    import java.security.KeyFactory
    import java.security.Signature
    import java.security.spec.RSAPublicKeySpec
    import java.lang.Exception

    ///
    /// JWKS の RSA 公開鍵 1 つ。n / e は base64url。
    ///
    pub type alias RsaJwk = { kid = String, n = String, e = String }

    ///
    /// 検証で確かめる物。
    ///
    /// - issuer: `iss` と一致
    /// - audience: `aud`（文字列か配列）に含まれる
    /// - now: エポック秒
    /// - skewSeconds: 時計のずれとして許す秒数
    ///
    pub type alias Expectation = { issuer = String, audience = String, now = Int64, skewSeconds = Int64 }

    ///
    /// 検証を通った claims。
    ///
    pub type alias Claims = { issuer = String, subject = String, email = Option[String], emailVerified = Option[Bool], name = Option[String], expiresAt = Int64 }

    ///
    /// 検証する。署名・alg・kid・iss・aud・exp・nbf を全部見て、1 つでも駄目なら理由を Err に入れる（トークンの中身は Err に含めない）。
    ///
    pub def verify(keys: List[RsaJwk], expect: Expectation, token: String): Result[String, Claims] =
        forM (
            (headerText, payloadText, signatureText) <- split(token);
            header <- decodeJson(headerText) |> Result.mapErr(_ -> "JWT のヘッダが読めません");
            _ <- checkAlg(header);
            key <- keyFor(keys, header);
            _ <- checkSignature(key, "${headerText}.${payloadText}", signatureText);
            payload <- decodeJson(payloadText) |> Result.mapErr(_ -> "JWT の中身が読めません");
            claims <- claimsOf(payload);
            _ <- checkClaims(expect, payload, claims)
        ) yield claims

    /// `header.payload.signature` の 3 つに分ける。
    def split(token: String): Result[String, (String, String, String)] = match String.splitOn(substr = ".", token) {
        case header :: payload :: signature :: Nil => Ok((header, payload, signature))
        case _ => Err("JWT の形ではありません")
    }

    def checkAlg(header: Map[String, Json]): Result[String, Unit] = match Map.get("alg", header) |> Option.flatMap(EntryValue.asString) {
        case Some("RS256") => Ok(())
        case Some(other)   => Err("JWT の alg '${other}' は受け付けません（RS256 だけ）")
        case None          => Err("JWT に alg がありません")
    }

    /// kid で鍵を引く。kid が無く鍵が 1 つだけならそれを使う。
    def keyFor(keys: List[RsaJwk], header: Map[String, Json]): Result[String, RsaJwk] =
        match (Map.get("kid", header) |> Option.flatMap(EntryValue.asString), keys) {
            case (Some(kid), _)      => List.find(key -> key#kid == kid, keys) |> Option.toOk("JWT の kid に合う鍵がありません")
            case (None, only :: Nil) => Ok(only)
            case (None, _)           => Err("JWT に kid がありません")
        }

    /// RSA の公開鍵を組んで SHA256withRSA で確かめる。鍵や署名が壊れていれば Err。
    def checkSignature(key: RsaJwk, signed: String, signatureText: String): Result[String, Unit] =
        forM (
            n <- decodeBase64Url(key#n);
            e <- decodeBase64Url(key#e);
            signature <- decodeBase64Url(signatureText);
            _ <- verifyRsa(n, e, String.toBytes(signed), signature)
        ) yield ()

    def verifyRsa(n: Vector[Int8], e: Vector[Int8], data: Vector[Int8], signature: Vector[Int8]): Result[String, Unit] =
        let outcome = unsafe IO {
            try {
                let modulus = new BigInteger(1, Vector.toArray(Static, n));
                let exponent = new BigInteger(1, Vector.toArray(Static, e));
                let publicKey = KeyFactory.getInstance("RSA").generatePublic(new RSAPublicKeySpec(modulus, exponent));
                let verifier = Signature.getInstance("SHA256withRSA");
                verifier.initVerify(publicKey);
                verifier.update(Vector.toArray(Static, data));
                Ok(verifier.verify(Vector.toArray(Static, signature)))
            } catch {
                case _: Exception => Err("JWT の鍵か署名が壊れています")
            }
        };
        match outcome {
            case Ok(true)  => Ok(())
            case Ok(false) => Err("JWT の署名が合いません")
            case Err(message) => Err(message)
        }

    def claimsOf(payload: Map[String, Json]): Result[String, Claims] =
        forM (
            issuer <- Map.get("iss", payload) |> Option.flatMap(EntryValue.asString) |> Option.toOk("JWT に iss がありません");
            subject <- Map.get("sub", payload) |> Option.flatMap(EntryValue.asString) |> Option.toOk("JWT に sub がありません");
            expiresAt <- Map.get("exp", payload) |> Option.flatMap(asInt64) |> Option.toOk("JWT に exp がありません")
        ) yield {
            issuer = issuer, subject = subject, expiresAt = expiresAt,
            email = Map.get("email", payload) |> Option.flatMap(EntryValue.asString),
            emailVerified = Map.get("email_verified", payload) |> Option.flatMap(EntryValue.asBool),
            name = Map.get("name", payload) |> Option.flatMap(EntryValue.asString)
        }

    /// iss / aud / exp / nbf。
    def checkClaims(expect: Expectation, payload: Map[String, Json], claims: Claims): Result[String, Unit] =
        let audiences = match Map.get("aud", payload) {
            case Some(Json.JString(one))    => one :: Nil
            case Some(Json.JArray(items))   => items |> Vector.toList |> List.filterMap(EntryValue.asString)
            case _                          => Nil
        };
        let notBefore = Map.get("nbf", payload) |> Option.flatMap(asInt64) |> Option.getWithDefault(0i64);
        if (claims#issuer != expect#issuer) Err("JWT の発行元が違います")
        else if (not List.memberOf(expect#audience, audiences)) Err("JWT の audience が違います")
        else if (claims#expiresAt + expect#skewSeconds < expect#now) Err("JWT の期限が切れています")
        else if (notBefore - expect#skewSeconds > expect#now) Err("JWT はまだ有効ではありません")
        else Ok(())

    def asInt64(json: Json): Option[Int64] = match json {
        case Json.JNumber(n) => Some(n.longValue())
        case _               => None
    }

    ///
    /// base64url（パディング無し）の文字列を JSON のオブジェクトに。
    ///
    pub def decodeJson(text: String): Result[String, Map[String, Json]] =
        decodeBase64Url(text) |> Result.map(String.fromBytes) |> Result.flatMap(raw -> Util.Json.parse(raw) |> Result.mapErr(err -> "${err}")) |> Result.flatMap(json -> match json {
            case Json.JObject(fields) => Ok(fields)
            case _                    => Err("オブジェクトではありません")
        })

    ///
    /// base64url を bytes に。壊れていれば Err。
    ///
    pub def decodeBase64Url(text: String): Result[String, Vector[Int8]] =
        unsafe IO {
            try {
                Ok(Array.toVector(Base64.getUrlDecoder().decode(text)))
            } catch {
                case _: Exception => Err("base64url が壊れています")
            }
        }

    ///
    /// bytes を base64url（パディング無し）に。テストと JWKS の鍵の組み立てで使う。
    ///
    pub def encodeBase64Url(bytes: Vector[Int8]): String =
        unsafe IO { Base64.getUrlEncoder().withoutPadding().encodeToString(Vector.toArray(Static, bytes)) }

}
