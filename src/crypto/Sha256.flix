///
/// SHA-256 と HMAC-SHA256。署名（SigV4、Webhook、プレビュートークン）と鍵のハッシュ（API キー）が共通で使う。
/// ドメイン（src/cms）が storage や auth のモジュールに依存しないよう、ここに置く。
///
mod Sha256 {

    import java.security.MessageDigest
    import javax.crypto.Mac
    import javax.crypto.spec.SecretKeySpec

    ///
    /// SHA-256 の 16 進（小文字）。
    ///
    pub def hex(data: String): String =
        let digest = unsafe IO {
            let bytes = Vector.toArray(Static, String.toBytes(data));
            Array.toVector(MessageDigest.getInstance("SHA-256").digest(bytes))
        };
        hexOf(digest)

    ///
    /// 文字列の鍵で HMAC-SHA256 を取り、16 進（小文字）に。
    ///
    pub def hmacHex(key: String, data: String): String =
        hexOf(hmac(String.toBytes(key), data))

    ///
    /// HMAC-SHA256（バイト列の鍵）。SigV4 の署名鍵の導出のように、鍵を重ねる時はこちら。
    ///
    pub def hmac(key: Vector[Int8], data: String): Vector[Int8] =
        unsafe IO {
            let keyBytes = Vector.toArray(Static, key);
            let dataBytes = Vector.toArray(Static, String.toBytes(data));
            let mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(keyBytes, "HmacSHA256"));
            Array.toVector(mac.doFinal(dataBytes))
        }

    ///
    /// バイト列を 16 進（小文字）に。
    ///
    pub def hexOf(bytes: Vector[Int8]): String =
        bytes |> Vector.map(byte -> hexByte(unsignedOf(byte))) |> Vector.join("")

    /// 0..255 を 2 桁の 16 進（小文字）に。
    def hexByte(n: Int32): String =
        "${hexDigit(n / 16)}${hexDigit(Int32.remainder(n, 16))}"

    /// 0..15 を 1 桁の 16 進（小文字）に。
    def hexDigit(n: Int32): String =
        String.charAt(n, "0123456789abcdef") |> Char.toString

    /// Int8 を 0..255 に。
    def unsignedOf(byte: Int8): Int32 =
        let n = Int8.toInt32(byte);
        if (n < 0) n + 256 else n

}
