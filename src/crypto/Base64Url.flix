///
/// base64url（パディング無し）。JWT、プレビュートークン、API キーの本体で使う。
///
mod Base64Url {

    import java.util.Base64
    import java.lang.Exception

    ///
    /// bytes を base64url に。
    ///
    pub def encode(bytes: Vector[Int8]): String =
        unsafe IO { Base64.getUrlEncoder().withoutPadding().encodeToString(Vector.toArray(Static, bytes)) }

    ///
    /// base64url を bytes に。壊れていれば Err。
    ///
    pub def decode(text: String): Result[String, Vector[Int8]] =
        unsafe IO {
            try {
                Ok(Array.toVector(Base64.getUrlDecoder().decode(text)))
            } catch {
                case _: Exception => Err("base64url が壊れています")
            }
        }

}
