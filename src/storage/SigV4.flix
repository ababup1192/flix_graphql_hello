///
/// AWS Signature Version 4。S3 互換ストレージ（R2 / MinIO）へのリクエストに署名する。
///
/// 2 つの形を出す。
/// - `presign`: 署名を URL のクエリに入れる。ブラウザが直接 PUT する時の URL に使う
/// - `authorize`: 署名を Authorization ヘッダに入れる。サーバから HEAD / DELETE する時に使う
///
/// 時刻は引数で受ける（`Timestamp`）ので、この mod は全部純粋。
///
/// WhyNot: AWS SDK を Maven で入れないのは、要るのがこの 2 つだけで、SDK は netty 等の依存が
/// 大きく JVM の起動も遅くなるため。署名の手順は AWS の文書に固定されていて、公式の例で検証できる。
///
mod SigV4 {
    import java.security.MessageDigest
    import javax.crypto.Mac
    import javax.crypto.spec.SecretKeySpec

    ///
    /// 署名に使う鍵と region。
    ///
    /// - accessKey / secretKey: ストレージの鍵
    /// - regionName: MinIO は `us-east-1`、R2 は `auto`
    ///
    pub type alias Credentials = { accessKey = String, secretKey = String, regionName = String }

    ///
    /// 署名する時刻。UTC。
    ///
    /// - date: `20130524` の形（scope に入る）
    /// - time: `20130524T000000Z` の形（X-Amz-Date に入る）
    ///
    pub type alias Timestamp = { date = String, time = String }

    ///
    /// 署名する対象。
    ///
    /// - method: `PUT` / `HEAD` / `DELETE`
    /// - scheme: `http` / `https`
    /// - host: `127.0.0.1:9000` のように、既定でないポートは含める（Host ヘッダと同じ文字列）
    /// - path: `/bucket/key` の形。エンコード前の生の文字列で、この mod がセグメントごとにエンコードする
    /// - headers: 署名に含めるヘッダ。名前は小文字。`host` は自動で足す
    ///
    pub type alias Request = {
        method = String,
        scheme = String,
        host = String,
        path = String,
        headers = Map[String, String]
    }

    /// 署名する service。この CMS は S3 互換 API しか使わない。
    def service(): String = "s3"

    ///
    /// エポックミリ秒から署名の時刻を組む。
    ///
    pub def timestampOf(epochMillis: Int64): Timestamp =
        let seconds = epochMillis / 1000i64;
        let days = seconds / 86400i64;
        let secondOfDay = seconds - days * 86400i64;
        let (year, month, day) = civilOf(days);
        let date = "${pad4(year)}${pad2(month)}${pad2(day)}";
        let hour = secondOfDay / 3600i64;
        let minute = (secondOfDay - hour * 3600i64) / 60i64;
        let second = secondOfDay - hour * 3600i64 - minute * 60i64;
        { date = date, time = "${date}T${pad2(hour)}${pad2(minute)}${pad2(second)}Z" }

    ///
    /// 署名をクエリに入れた URL を返す。有効期限は秒。ペイロードは署名しない（UNSIGNED-PAYLOAD）ので、
    /// 中身は何でも置けるが、`headers` に入れた content-type / content-length は一致しないと拒まれる。
    ///
    pub def presign(cred: Credentials, at: Timestamp, expiresSeconds: Int32, req: Request): String =
        let headers = Map.insert("host", req#host, req#headers);
        let signedHeaders = signedHeaderNames(headers);
        let params = Map#{
            "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
            "X-Amz-Credential" => "${cred#accessKey}/${scope(cred, at)}",
            "X-Amz-Date" => at#time,
            "X-Amz-Expires" => Int32.toString(expiresSeconds),
            "X-Amz-SignedHeaders" => signedHeaders
        };
        let signature = sign(cred, at, req, params, headers, "UNSIGNED-PAYLOAD");
        let fullParams = Map.insert("X-Amz-Signature", signature, params);
        "${req#scheme}://${req#host}${encodePath(req#path)}?${canonicalQuery(fullParams)}"

    ///
    /// 署名を Authorization ヘッダに入れる形で、足すべきヘッダを返す（x-amz-date、x-amz-content-sha256、
    /// authorization）。本文の無いリクエスト（HEAD / DELETE）向け。
    ///
    pub def authorize(cred: Credentials, at: Timestamp, req: Request): Map[String, String] =
        let emptyHash = sha256Hex("");
        let headers = req#headers
            |> Map.insert("host", req#host)
            |> Map.insert("x-amz-date", at#time)
            |> Map.insert("x-amz-content-sha256", emptyHash);
        let signature = sign(cred, at, req, Map.empty(), headers, emptyHash);
        let credential = "Credential=${cred#accessKey}/${scope(cred, at)}";
        let signed = "SignedHeaders=${signedHeaderNames(headers)}";
        Map#{
            "x-amz-date" => at#time,
            "x-amz-content-sha256" => emptyHash,
            "authorization" => "AWS4-HMAC-SHA256 ${credential}, ${signed}, Signature=${signature}"
        }

    ///
    /// canonical request → string to sign → 署名、の手順。`headers` は host を含んだ署名対象のヘッダ。
    ///
    def sign(cred: Credentials, at: Timestamp, req: Request, params: Map[String, String], headers: Map[String, String], payloadHash: String): String =
        let canonicalHeaders = headers
            |> Map.toList
            |> List.map(match (name, value) -> "${name}:${String.trim(value)}\n")
            |> List.join("");
        let canonicalRequest = List.join("\n", List#{
            req#method,
            encodePath(req#path),
            canonicalQuery(params),
            canonicalHeaders,
            signedHeaderNames(headers),
            payloadHash
        });
        let stringToSign = List.join("\n", List#{
            "AWS4-HMAC-SHA256",
            at#time,
            scope(cred, at),
            sha256Hex(canonicalRequest)
        });
        hexOf(hmacSha256(signingKey(cred, at), stringToSign))

    /// `date/region/s3/aws4_request`。
    def scope(cred: Credentials, at: Timestamp): String =
        "${at#date}/${cred#regionName}/${service()}/aws4_request"

    /// 署名対象のヘッダ名を `;` で繋ぐ。Map なので名前順。
    def signedHeaderNames(headers: Map[String, String]): String =
        headers |> Map.keysOf |> Set.toList |> List.join(";")

    /// 名前順に `k=v` を `&` で繋ぐ。名前も値もエンコードする。
    def canonicalQuery(params: Map[String, String]): String =
        params
            |> Map.toList
            |> List.map(match (name, value) -> "${uriEncode(name)}=${uriEncode(value)}")
            |> List.join("&")

    /// パスをセグメントごとにエンコードする。`/` はそのまま。
    def encodePath(path: String): String =
        path |> String.splitOn(substr = "/") |> List.map(uriEncode) |> List.join("/")

    /// 秘密鍵から日付 → region → service → aws4_request の順に HMAC を重ねた署名鍵。
    def signingKey(cred: Credentials, at: Timestamp): Vector[Int8] =
        List#{ at#date, cred#regionName, service(), "aws4_request" }
            |> List.foldLeft(hmacSha256, String.toBytes("AWS4${cred#secretKey}"))

    ///
    /// AWS 流の URI エンコード。`A-Z a-z 0-9 - _ . ~` 以外は UTF-8 のバイトごとに `%XX`（大文字）。
    ///
    pub def uriEncode(s: String): String =
        String.toBytes(s)
            |> Vector.map(byte -> {
                let n = unsignedOf(byte);
                if (isUnreserved(n)) String.fromBytes(Vector#{byte}) else "%${hexByte(n)}"
            })
            |> Vector.join("")

    /// エンコードせずに残す文字か。
    def isUnreserved(n: Int32): Bool =
        (n >= 65 and n <= 90) or (n >= 97 and n <= 122) or (n >= 48 and n <= 57)
            or n == 45 or n == 95 or n == 46 or n == 126

    ///
    /// SHA-256 の 16 進（小文字）。
    ///
    pub def sha256Hex(data: String): String =
        let digest = unsafe IO {
            let bytes = Vector.toArray(Static, String.toBytes(data));
            Array.toVector(MessageDigest.getInstance("SHA-256").digest(bytes))
        };
        hexOf(digest)

    /// HMAC-SHA256。
    def hmacSha256(key: Vector[Int8], data: String): Vector[Int8] =
        unsafe IO {
            let keyBytes = Vector.toArray(Static, key);
            let dataBytes = Vector.toArray(Static, String.toBytes(data));
            let mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(keyBytes, "HmacSHA256"));
            Array.toVector(mac.doFinal(dataBytes))
        }

    /// バイト列を 16 進（小文字）に。
    def hexOf(bytes: Vector[Int8]): String =
        bytes |> Vector.map(byte -> String.toLowerCase(hexByte(unsignedOf(byte)))) |> Vector.join("")

    /// 0..255 を 2 桁の 16 進（大文字）に。
    def hexByte(n: Int32): String =
        "${hexDigit(n / 16)}${hexDigit(Int32.remainder(n, 16))}"

    /// 0..15 を 1 桁の 16 進（大文字）に。
    def hexDigit(n: Int32): String =
        String.charAt(n, "0123456789ABCDEF") |> Char.toString

    /// Int8 を 0..255 に。
    def unsignedOf(byte: Int8): Int32 =
        let n = Int8.toInt32(byte);
        if (n < 0) n + 256 else n

    /// エポックからの日数を (年, 月, 日) に。グレゴリオ暦。
    def civilOf(days: Int64): (Int64, Int64, Int64) =
        let z = days + 719468i64;
        let era = (if (z >= 0i64) z else z - 146096i64) / 146097i64;
        let dayOfEra = z - era * 146097i64;
        let yearOfEra = (dayOfEra - dayOfEra / 1460i64 + dayOfEra / 36524i64 - dayOfEra / 146096i64) / 365i64;
        let dayOfYear = dayOfEra - (365i64 * yearOfEra + yearOfEra / 4i64 - yearOfEra / 100i64);
        let monthIndex = (5i64 * dayOfYear + 2i64) / 153i64;
        let day = dayOfYear - (153i64 * monthIndex + 2i64) / 5i64 + 1i64;
        let month = if (monthIndex < 10i64) monthIndex + 3i64 else monthIndex - 9i64;
        let year = yearOfEra + era * 400i64 + (if (month <= 2i64) 1i64 else 0i64);
        (year, month, day)

    def pad2(n: Int64): String = String.padLeft(2, '0', Int64.toString(n))

    def pad4(n: Int64): String = String.padLeft(4, '0', Int64.toString(n))

}
