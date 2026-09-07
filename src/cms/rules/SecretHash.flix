///
/// 秘密（API キー・PAT・プレビュートークン）の保存と期限の共通の規則。純粋。
/// DB には生の値を置かず sha256(pepper + 値) の 16 進だけ置き、生きているかは失効と期限で決める。
///
mod SecretHash {

    ///
    /// ハッシュに混ぜる秘密と、その版。
    ///
    /// - pepperId: 版。行に残す（回した時に古い物を見分ける）
    /// - secret: 環境変数から来る秘密
    ///
    pub type alias Pepper = { pepperId = String, secret = String }

    ///
    /// 秘密の寿命。expiresAt が無ければ切れない。
    ///
    pub type alias Lifetime = { expiresAt = Option[Timestamp.Timestamp], revokedAt = Option[Timestamp.Timestamp] }

    ///
    /// sha256(pepper + 値) の 16 進。
    ///
    pub def hash(pepper: Pepper, raw: String): String =
        Sha256.hex("${pepper#secret}:${raw}")

    ///
    /// 失効しておらず、期限が来ていないか。期限ちょうどは切れている。
    ///
    pub def isAlive(lifetime: Lifetime, nowMillis: Int64): Bool =
        Option.isEmpty(lifetime#revokedAt) and (lifetime#expiresAt |> Option.forAll(deadline -> Timestamp.toEpochMillis(deadline) > nowMillis))

}
