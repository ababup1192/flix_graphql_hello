///
/// HTTP リクエスト。
///
/// - method: "POST" などのメソッド
/// - path: "/graphql" などのパス（クエリ文字列も含めたまま）
/// - headers: (小文字にしたヘッダ名, trim した値) の並び。届いた順
/// - body: Content-Length ぶん読んだボディ
///
pub type alias HttpRequest = { method = String, path = String, headers = List[(String, String)], body = String }

///
/// HTTP レスポンス。
///
/// - status: ステータスコード
/// - headers: Content-Type / Content-Length / Connection の後ろに足す追加ヘッダ
/// - body: JSON ボディ。空ならボディ無し（Content-Type も付けない）
///
pub type alias HttpResponse = { status = Int32, headers = List[(String, String)], body = String }

///
/// HTTP/1.1 の解析と組み立て。ソケットは触らない純粋関数だけ。
///
/// 対応範囲:
/// - Transfer-Encoding: chunked には対応しない。ボディの長さは Content-Length だけで決める
/// - Content-Length が無いリクエストはボディ無し（空文字列）として扱う
/// - Content-Length が複数あって値が食い違うリクエストは 400 にする（RFC 9110 8.6）
/// - keep-alive には対応しない。1 接続につき 1 リクエストで、レスポンスは常に Connection: close
/// - ボディは maxBodyBytes()（1 MiB）まで。超える Content-Length は 413 にする
/// - ヘッダ 1 行は maxHeaderLineBytes()（8 KiB）まで。超える行は 431 にする
///
mod Http {
    import java.nio.charset.StandardCharsets

    ///
    /// Content-Length の読み取りに失敗した理由。
    ///
    /// - Malformed: 数字でない・負の値・複数の Content-Length が食い違う
    /// - TooLarge: maxBodyBytes() を超えている（413 Payload Too Large にする）
    ///
    pub enum HeaderError with Eq, ToString {
        case Malformed(String)
        case TooLarge(Int32)
    }

    ///
    /// 受け付けるボディの上限バイト数（1 MiB）。
    ///
    pub def maxBodyBytes(): Int32 = 1024 * 1024

    ///
    /// 受け付けるヘッダ 1 行（リクエスト行も含む）の上限バイト数（8 KiB）。改行は数えない。
    ///
    pub def maxHeaderLineBytes(): Int32 = 8192

    ///
    /// リクエスト行（"POST /graphql HTTP/1.1"）からメソッドとパスを取り出す。
    /// メソッド・パス・"HTTP/" で始まるバージョンの 3 つがそろっていなければ None。
    ///
    pub def parseRequestLine(line: String): Option[(String, String)] =
        match String.splitOn(substr = " ", line) {
            case method :: path :: version :: Nil if String.startsWith(prefix = "HTTP/", version) => Some((method, path))
            case _                                                                                 => None
        }

    ///
    /// ヘッダ行（"Content-Length: 42"）を (小文字のヘッダ名, trim した値) にする。
    /// ":" が無い行は None。値の中の ":" はそのまま残す。
    ///
    pub def parseHeaderLine(line: String): Option[(String, String)] =
        match String.splitOn(substr = ":", line) {
            case name :: rest if not List.isEmpty(rest) => Some((String.toLowerCase(String.trim(name)), String.trim(List.join(":", rest))))
            case _                                      => None
        }

    ///
    /// ヘッダ行の一覧を解析する。解析できない行は捨てる。
    ///
    pub def parseHeaders(lines: List[String]): List[(String, String)] =
        List.filterMap(parseHeaderLine, lines)

    ///
    /// 解析済みヘッダから Content-Length を読む。無ければ Ok(0)。
    /// 数字でない・負の値は Malformed、maxBodyBytes() を超えると TooLarge。
    /// 同じ値の Content-Length が複数並ぶのは 1 つとして扱い、値が食い違えば Malformed。
    ///
    pub def contentLength(headers: List[(String, String)]): Result[HeaderError, Int32] =
        match headers |> List.filter(pair -> fst(pair) == "content-length") |> List.map(snd) |> List.distinct {
            case Nil          => Ok(0)
            case value :: Nil => match Int32.fromString(value) {
                case Some(length) if length < 0              => Err(HeaderError.Malformed(value))
                case Some(length) if length > maxBodyBytes() => Err(HeaderError.TooLarge(length))
                case Some(length)                            => Ok(length)
                case None                                    => Err(HeaderError.Malformed(value))
            }
            case values       => Err(HeaderError.Malformed(List.join(", ", values)))
        }

    ///
    /// ヘッダ値から行を壊す文字（CR / LF）を落とす。
    ///
    def headerValue(value: String): String =
        value |> String.replace(src = "\r", dst = "") |> String.replace(src = "\n", dst = "")

    ///
    /// レスポンスを HTTP/1.1 の文字列にする。1 リクエストで接続を閉じる。
    /// ボディが空なら Content-Type は付けない。
    /// response#headers は Content-Type / Content-Length / Connection の後ろに並べる。
    ///
    pub def render(response: HttpResponse): String =
        let contentType = if (response#body == "") "" else "Content-Type: application/json; charset=utf-8\r\n";
        // WhyNot: 値の CR / LF を落とすのは、Origin をそのまま返す CORS のヘッダで、行中の裸の CR がレスポンス分割になるのを防ぐため
        let extraHeaders = response#headers |> List.map(match (name, value) -> "${name}: ${headerValue(value)}\r\n") |> List.join("");
        let headers =
            "HTTP/1.1 ${response#status} ${reasonPhrase(response#status)}\r\n" +
            contentType +
            "Content-Length: ${utf8Length(response#body)}\r\n" +
            "Connection: close\r\n" +
            extraHeaders + "\r\n";
        headers + response#body

    ///
    /// ステータスコードの理由句。
    ///
    def reasonPhrase(status: Int32): String = match status {
        case 200 => "OK"
        case 204 => "No Content"
        case 400 => "Bad Request"
        case 404 => "Not Found"
        case 405 => "Method Not Allowed"
        case 413 => "Payload Too Large"
        case 431 => "Request Header Fields Too Large"
        case 500 => "Internal Server Error"
        case 503 => "Service Unavailable"
        case _   => "Unknown"
    }

    ///
    /// UTF-8 にしたときのバイト数。Content-Length は文字数ではなくバイト数なので必要。
    ///
    /// WhyNot: IO エフェクトを付けないのは、文字列のエンコードは呼ぶたびに同じ結果を返し、
    /// 外から見える副作用が無いため。Java の getBytes が IO 扱いなのは interop の都合だけ。
    ///
    pub def utf8Length(text: String): Int32 =
        unchecked_cast(Array.length(text.getBytes(StandardCharsets.UTF_8)) as _ \ {})

}
