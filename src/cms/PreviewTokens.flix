///
/// プレビュートークン。下書きを公開前のサイトで見るための、短命で無状態の署名付きトークン。
/// `pv_<base64url(projectId.entryId.exp)>.<HMAC-SHA256(pepper, payload) の 16 進>`。表は持たず、期限で切れる。
///
/// WhyNot: 表に置いて失効できるようにしないのは、既定 1 時間で切れる物に失効の操作と掃除を足す価値が薄いため。
/// 鍵（pepper）を回せば全部無効になる。長く使う物が要るなら API キー（readDraft）を使う。
///

///
/// 発行したトークン。url は型の previewUrl の {id} を entry の id に置き換えて `?preview=<token>` を付けた物（previewUrl が無ければ None）。
///
pub type alias PreviewToken = { token = String, entryId = EntryId, expiresAt = Timestamp.Timestamp, url = Option[String] }

mod PreviewTokens {

    def prefix(): String = "pv_"

    /// 既定と上限の有効期間（秒）。
    pub def defaultTtlSeconds(): Int64 = 3600i64
    pub def maxTtlSeconds(): Int64 = 86400i64

    ///
    /// 発行する。readDraft を持つ人（writer 以上・readDraft の鍵）だけ。entry が無ければ notFound。
    ///
    pub def issue(pepper: SecretHash.Pepper, entryId: EntryId, window: { ttlSeconds = Int64, nowMillis = Int64 }): PreviewToken \ DbRead + CmsErr + Tenant + Session =
        Session.require(Permission.ReadDraft);
        let entry = ContentEntries.get(entryId);
        let owner = ContentTypes.get(entry#typeId);
        let ttl = Int64.max(60i64, Int64.min(maxTtlSeconds(), window#ttlSeconds));
        let exp = window#nowMillis / 1000i64 + ttl;
        let payload = "${Tenant.currentId()}.${EntryId.text(entryId)}.${exp}";
        let encoded = Base64Url.encode(String.toBytes(payload));
        let token = prefix() + encoded + "." + Sha256.hmacHex(pepper#secret, payload);
        { token = token, entryId = entryId, expiresAt = Timestamp.fromEpochMillis(exp * 1000i64), url = owner#previewUrl |> Option.map(template -> previewUrl(template, entryId, token)) }

    ///
    /// previewUrl の {id} を置き換え、preview のクエリを付ける。既にクエリがあれば & で繋ぐ。
    ///
    pub def previewUrl(template: String, entryId: EntryId, token: String): String =
        let base = String.replace(src = "{id}", dst = EntryId.text(entryId), template);
        base + (if (String.contains(substr = "?", base)) "&" else "?") + "preview=" + token

    ///
    /// 検証する。署名・期限・プロジェクトが合えば entry の id。純粋。
    ///
    pub def verify(pepper: SecretHash.Pepper, raw: String, projectId: ProjectId, nowMillis: Int64): Option[EntryId] =
        if (not String.startsWith(prefix = prefix(), raw)) None
        else match String.splitOn(substr = ".", String.drop(String.length(prefix()), raw)) {
            case encoded :: signature :: Nil => match Base64Url.decode(encoded) {
                case Err(_)    => None
                case Ok(bytes) => verifyPayload(pepper, String.fromBytes(bytes), signature, projectId, nowMillis)
            }
            case _ => None
        }

    /// 復号した payload（projectId.entryId.exp）を、署名・期限・プロジェクトで確かめる。
    def verifyPayload(pepper: SecretHash.Pepper, payload: String, signature: String, projectId: ProjectId, nowMillis: Int64): Option[EntryId] =
        if (Sha256.hmacHex(pepper#secret, payload) != signature) None
        else match String.splitOn(substr = ".", payload) {
            case projectText :: entryText :: expText :: Nil =>
                let fresh = Int64.fromString(expText) |> Option.exists(deadline -> deadline * 1000i64 > nowMillis);
                if (fresh and projectText == "${projectId}") EntryId.parse(entryText) else None
            case _ => None
        }

}
