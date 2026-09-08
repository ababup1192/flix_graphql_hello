///
/// request id。X-Request-Id を受け（形が合わなければ捨てて自分で作る）、応答ヘッダで必ず返す。ログの request.id と INTERNAL の extensions.requestId に使う。
///
/// WhyNot: 受けた値をそのまま使わないのは、ログの行に入る物なので長さと文字を絞らないと log injection と行の肥大化の入口になるため。
/// 形が違う物は「無かった」事にして作り直す（400 にはしない。前段が付ける物で、クライアントには直せない）。
///
mod RequestId {

    /// ヘッダの名前。受ける時も返す時も同じ。
    pub def header(): String = "X-Request-Id"

    /// 受け付ける最大の長さ。ULID（26）と UUID（36）と Cloudflare の CF-Ray（20 前後）が入る。
    pub def maxLength(): Int32 = 64

    ///
    /// 受けた値を使うか。1 〜 64 文字で `[A-Za-z0-9_-]` だけなら Some、それ以外は None。
    ///
    pub def accept(value: String): Option[String] =
        if (String.isEmpty(value) or String.length(value) > maxLength()) None
        else if (String.forAll(ch -> (Char.isAscii(ch) and Char.isLetter(ch)) or Char.isAsciiDigit(ch) or ch == '_' or ch == '-', value)) Some(value)
        else None

    ///
    /// リクエストのヘッダから使える request id。無い・形が違うなら None。
    ///
    pub def ofHeaders(headers: List[(String, String)]): Option[String] =
        Http.findHeader(header(), headers) |> Option.flatMap(accept)

    ///
    /// ヘッダの物か、無ければ新しい ULID。
    ///
    pub def resolve(headers: List[(String, String)]): String \ IO =
        match ofHeaders(headers) {
            case Some(found) => found
            case None        => IdGen.runWithRandom(IdGen.freshUlid)
        }

    ///
    /// 応答に X-Request-Id を足す middleware。next の応答（404 / 503 も）に必ず付く。
    ///
    pub def wrap(requestId: String, next: Handler[ef]): Handler[ef] =
        routeRequest ->
            let response = next(routeRequest);
            { headers = (header(), requestId) :: response#headers | response }

}
