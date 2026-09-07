///
/// CORS の設定。
///
/// - allowedOrigins: 許すオリジン（"https://admin.example.com" の形）。"*" を含めば全部許す。空なら CORS ヘッダを一切付けない
///
pub type alias CorsConfig = { allowedOrigins = List[String] }

///
/// CORS。ブラウザから別オリジン（Pages の管理画面など）で API を叩けるようにする、純粋関数だけのモジュール。
///
/// 対応範囲:
/// - 許したオリジンにだけ Access-Control-Allow-Origin を返す。許していないオリジンにはヘッダを付けず、ブラウザ側で止まる
/// - preflight（OPTIONS）は 204 で、許すメソッドとヘッダを返す
/// - 資格情報（Cookie）は扱わない。認証は Authorization ヘッダの予定なので Allow-Credentials は要らない
///
mod Cors {

    ///
    /// CORS ヘッダを付けない設定。
    ///
    pub def none(): CorsConfig = { allowedOrigins = Nil }

    ///
    /// "a, b" のようなカンマ区切りをオリジンの一覧にする。空白は取り除き、空の要素は捨てる。
    ///
    pub def parseOrigins(text: String): List[String] =
        String.splitOn(substr = ",", text) |> List.map(String.trim) |> List.filter(origin -> origin != "")

    ///
    /// リクエストの Origin ヘッダ。無ければ None（同一オリジンか curl）。
    ///
    pub def originOf(request: HttpRequest): Option[String] =
        request#headers |> List.findMap(match (name, value) -> if (name == "origin") Some(value) else None)

    ///
    /// このオリジンを許すか。
    ///
    pub def isAllowed(config: CorsConfig, origin: String): Bool =
        List.memberOf("*", config#allowedOrigins) or List.memberOf(origin, config#allowedOrigins)

    ///
    /// Origin 付きのリクエストに付けるヘッダ。許したオリジンなら Allow-Origin と Vary、許していなくても Vary は付ける
    /// （応答が Origin で変わるので、共有キャッシュが許否の違う応答を混ぜないため）。Origin が無い・CORS を使わない設定なら空。
    /// "*" で許した場合も "*" ではなく届いたオリジンをそのまま返す。
    ///
    pub def responseHeaders(config: CorsConfig, request: HttpRequest): List[(String, String)] =
        match originOf(request) {
            case Some(origin) if isAllowed(config, origin)          => ("Access-Control-Allow-Origin", origin) :: ("Vary", "Origin") :: Nil
            case Some(_) if not List.isEmpty(config#allowedOrigins) => ("Vary", "Origin") :: Nil
            case _                                                  => Nil
        }

    ///
    /// レスポンスに CORS ヘッダを足す。response を最後に取るのでパイプで使える。
    ///
    pub def withHeaders(config: CorsConfig, request: HttpRequest, response: HttpResponse): HttpResponse =
        { status = response#status, headers = response#headers ::: responseHeaders(config, request), body = response#body }

    ///
    /// preflight（OPTIONS）への応答。許したオリジンなら許すメソッド（表から。OPTIONS を足す）・ヘッダ・キャッシュ時間を返し、
    /// そうでなければ何も付けない 204。Allow-Origin と Vary は他のレスポンスと同じく withHeaders が足す。
    ///
    pub def preflight(config: CorsConfig, methods: List[Method], request: HttpRequest): HttpResponse =
        let allowed = originOf(request) |> Option.exists(origin -> isAllowed(config, origin));
        let allowHeaders =
            if (allowed)
                ("Access-Control-Allow-Methods", Method.join(methods ::: (Method.Options :: Nil))) ::
                ("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Api-Key, X-Preview-Token") ::
                ("Access-Control-Max-Age", "86400") :: Nil
            else Nil;
        { status = 204, headers = allowHeaders, body = "" }

    ///
    /// CORS の middleware。OPTIONS でそのパスに受けるメソッドがあれば preflight を返し（next は呼ばない）、
    /// それ以外は next の応答に CORS ヘッダを足す。404 / 503 にも付く。
    /// allowedMethods はパス → 受けるメソッド（`Router.allowedMethods(routes)`）。
    ///
    pub def wrap(config: CorsConfig, allowedMethods: String -> List[Method], next: Handler[ef]): Handler[ef] =
        routeRequest ->
            let request = routeRequest#request;
            let methods = allowedMethods(request#path);
            if (request#method == "OPTIONS" and not List.isEmpty(methods))
                preflight(config, methods, request) |> withHeaders(config, request)
            else
                next(routeRequest) |> withHeaders(config, request)

}
