///
/// トークンから本人（Principal）を得る境界。本番は発行元の JWKS で JWT を検証し、
/// 手元の開発は `X-Dev-User` の値をそのまま人として扱う（起動時の条件でしか有効にならない）。
///
pub eff TokenVerifier {
    /// トークン（JWT か、開発モードなら email）から本人。駄目なら理由（トークンの中身は含めない）
    def verify(token: String): Result[String, Principal]
}

mod TokenVerifier {
    use Net.Http.Http
    use Net.HttpRequest
    use Net.HttpResponse
    use Time.Clock
    use Util.Json.Json

    import java.util.concurrent.atomic.AtomicReference
    import java.lang.Object

    ///
    /// 発行元の設定。
    ///
    /// - issuer: `iss` と一致させる
    /// - jwksUrl: 公開鍵の置き場
    /// - audience: `aud` に含まれる事を要求
    ///
    pub type alias Config = { issuer = String, jwksUrl = String, audience = String }

    /// JWKS を取り直す間隔。鍵の回転に追従しつつ、毎リクエスト叩かない。
    pub def refreshMillis(): Int64 = 600000i64

    /// kid が無い時の取り直しは、前回からこれ以上経っていないと行わない（知らない kid を投げ続けて JWKS を叩かせる攻撃の防止）。
    pub def minRefreshMillis(): Int64 = 60000i64

    /// 時計のずれとして許す秒数。
    pub def skewSeconds(): Int64 = 60i64

    ///
    /// 取り込んだ鍵の置き場（取った時刻と鍵）。プロセスで 1 つ。
    ///
    pub enum JwksCache {
        case JwksCache(AtomicReference[Object])
    }

    pub def createCache(): JwksCache \ IO =
        let empty: (Int64, List[Jwt.RsaJwk]) = (0i64, Nil);
        JwksCache.JwksCache(new AtomicReference(unchecked_cast(empty as Object)))

    ///
    /// JWKS で検証する handler。
    ///
    pub def runWithJwks(config: Config, cache: JwksCache, f: Unit -> a \ ef): a \ (ef - TokenVerifier) + { Http, Clock, IO } =
        run f() with handler TokenVerifier {
            def verify(token, resume) = resume(verifyWithJwks(config, cache, token))
        }

    ///
    /// 開発モード。トークンを email として信じる。Main が 127.0.0.1 と CMS_VERSION=dev の時にしか選ばない。
    ///
    pub def runDev(f: Unit -> a \ ef): a \ ef - TokenVerifier =
        run f() with handler TokenVerifier {
            def verify(token, resume) = resume(
                if (String.contains(substr = "@", token)) Ok({ issuer = "dev", subject = token, email = token, name = "" })
                else Err("開発モードでは X-Dev-User に email を入れてください"))
        }

    ///
    /// 検証の本体。鍵が無ければ取り、kid が合わなければ 1 回だけ取り直す。
    ///
    def verifyWithJwks(config: Config, cache: JwksCache, token: String): Result[String, Principal] \ { Http, Clock, IO } =
        let nowMillis = Clock.now();
        let expect = { issuer = config#issuer, audience = config#audience, now = nowMillis / 1000i64, skewSeconds = skewSeconds() };
        let keys = currentKeys(config, cache, nowMillis, refreshMillis());
        let first = Jwt.verify(keys, expect, token);
        let attempt = match first {
            case Err("JWT の kid に合う鍵がありません") => Jwt.verify(currentKeys(config, cache, nowMillis, minRefreshMillis()), expect, token)
            case other => other
        };
        attempt |> Result.flatMap(principalOf)

    /// 期限内なら手元の鍵、過ぎていれば取り直す。取れなければ手元の物のまま。
    def currentKeys(config: Config, cache: JwksCache, nowMillis: Int64, maxAgeMillis: Int64): List[Jwt.RsaJwk] \ { Http, IO } =
        let JwksCache.JwksCache(slot) = cache;
        let (fetchedAt, keys): (Int64, List[Jwt.RsaJwk]) = unchecked_cast(slot.get() as (Int64, List[Jwt.RsaJwk]));
        if (nowMillis - fetchedAt < maxAgeMillis) keys
        else match fetchJwks(config#jwksUrl) {
            case Ok(fresh) => { slot.set(unchecked_cast((nowMillis, fresh) as Object)); fresh }
            case Err(_)    => keys
        }

    /// JWKS を取って RSA の鍵だけ拾う。
    def fetchJwks(url: String): Result[String, List[Jwt.RsaJwk]] \ Http =
        Net.Http.send(HttpRequest.get(url) |> HttpRequest.withAccept("application/json"))
            |> Result.mapErr(err -> "${err}")
            |> Result.flatMap(response -> if (HttpResponse.isSuccess(response)) Ok(HttpResponse.body(response)) else Err("JWKS が取れません（HTTP ${HttpResponse.status(response)}）"))
            |> Result.flatMap(parseJwks)

    ///
    /// JWKS の JSON から RSA の鍵。kty が RSA で kid / n / e がある物だけ。
    ///
    pub def parseJwks(text: String): Result[String, List[Jwt.RsaJwk]] =
        Util.Json.parse(text) |> Result.mapErr(err -> "${err}") |> Result.flatMap(json -> match json {
            case Json.JObject(fields) => match Map.get("keys", fields) {
                case Some(Json.JArray(items)) => Ok(items |> Vector.toList |> List.filterMap(rsaKeyOf))
                case _ => Err("JWKS に keys がありません")
            }
            case _ => Err("JWKS がオブジェクトではありません")
        })

    def rsaKeyOf(json: Json): Option[Jwt.RsaJwk] = match json {
        case Json.JObject(fields) =>
            let text = name -> Map.get(name, fields) |> Option.flatMap(EntryValue.asString);
            match (text("kty"), text("kid"), text("n"), text("e")) {
                case (Some("RSA"), Some(kid), Some(n), Some(e)) => Some({ kid = kid, n = n, e = e })
                case _ => None
            }
        case _ => None
    }

    /// claims から本人。email は必須で、email_verified があれば true を要求する。
    def principalOf(claims: Jwt.Claims): Result[String, Principal] =
        match (claims#email, claims#emailVerified) {
            case (None, _)            => Err("JWT に email がありません")
            case (Some(_), Some(false)) => Err("JWT の email が確認されていません")
            case (Some(email), _)     => Ok({ issuer = claims#issuer, subject = claims#subject, email = email, name = claims#name |> Option.getWithDefault("") })
        }

}
