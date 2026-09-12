///
/// richText の linkCard の OGP。編集画面が URL を貼った瞬間に管理 API（fetchLinkCard）がここを呼んでその場で取り、
/// 表（link_cards）に残す。公開の HTML（コンテンツ API）は表から `cards` を組む。取り直しは app の LinkCardRefresh。
///
/// WhyNot: 監査（Audit.record）を積まないのは、これがコンテンツの変更ではなく外のページの写しで、行そのもの（fetched_at と error）が
/// 記録になっているため。貼るたびに 1 行積むと監査の一覧が埋まる。
///
/// WhyNot: 取れなかった時に CmsErr にしないのは、編集画面が「カードにならない理由」を見せるのが設計で、失敗も値（error）として返すため。
///
mod LinkCards {

    use Net.Http.Http
    use Net.HttpRequest
    use Net.HttpResponse

    ///
    /// 取る。表に取り直しの番でない行があればそれを返し、無ければ取りに行って upsert する。失敗も error の行にして返す。
    /// 取りに行けない URL（http(s) 以外・プライベートアドレス）は表に入れず、error だけ付けて返す。
    ///
    /// WhyNot: 取りに行けない URL を表に入れないのは、取り直しの仕事が拾っても永久に同じ理由で失敗し、行が増えるだけのため。
    ///
    pub def fetch(_proof: Granted[WriteEntries], url: String): LinkCard \ Db + Tenant + Http + Time.Clock.Clock =
        let now = Time.Clock.now();
        match Ogp.refuseReason(url) {
            case Some(reason) => refused(url, now, reason)
            case None => match find(url) |> Option.filter(card -> not Ogp.needsRefetch(now, Timestamp.toEpochMillis(card#fetchedAt), Option.nonEmpty(card#error))) {
                case Some(card) => card
                case None       =>
                    let projectName = Projects.find(Tenant.current()) |> Option.map(found -> found#name) |> Option.getWithDefault("cms");
                    store(Tenant.currentId(), url, fetchOver(userAgent(projectName), url));
                    find(url) |> Option.getWithDefault(refused(url, now, "取った直後の行が読めません"))
            }
        }

    ///
    /// 表にある物だけ引く（取りに行かない）。編集画面が開き直した時と、公開の HTML の `cards` に使う。無い url は落ちる。
    ///
    pub def findMany(urls: List[String]): List[LinkCard] \ DbRead + Tenant =
        if (List.isEmpty(urls)) Nil
        else LinkCardsQueries.findLinkCards({ projectId = Tenant.currentId(), urls = List.distinct(urls) }) |> List.map(LinkCardRows.toLinkCard)

    ///
    /// 公開の HTML に出せる物だけ（error が無く title のある行）を url → 中身に。
    ///
    pub def cardsOf(urls: List[String]): Map[String, RichText.CardRef] \ DbRead + Tenant =
        findMany(urls)
            |> List.filterMap(card -> match (card#error, card#title) {
                case (None, Some(title)) => Some((card#url, { title = title, description = card#description, imageUrl = card#imageUrl, siteName = card#siteName }))
                case _                   => None
            })
            |> List.toMap

    ///
    /// 相手のページを取って OGP を読む。失敗は人が読む理由。取り直しの仕事もこれを使う。
    /// リダイレクトは client（OutboundHttp。JDK の NORMAL）に任せ、着いた先がプライベートアドレスなら捨てる。
    ///
    /// WhyNot: リダイレクトの回数を自分で数えないのは、標準ライブラリが「追わない」を指定した request ごとに HttpClient を作り直し、
    /// スレッドが残る（OutboundHttp の WhyNot）ため。JDK の NORMAL は 5 回で止まる。
    ///
    /// WhyNot: 本文を先頭 512KB で切るのが受信の後なのは、標準ライブラリの Http が本文を全部読んでから返すため。
    /// 読む量の上限はタイムアウト（5 秒）が兼ねる。
    ///
    pub def fetchOver(userAgent: String, url: String): Result[String, Ogp.Meta] \ Http =
        match Ogp.refuseReason(url) {
            case Some(reason) => Err(reason)
            case None => match Net.Http.send(buildRequest(userAgent, url)) {
                case Err(error)    => Err(describeSendError(error))
                case Ok(response)  => readResponse(url, response)
            }
        }

    /// 管理 API が受けた URL の GET。HTML を欲しがっていると伝える。
    def buildRequest(userAgent: String, url: String): HttpRequest =
        HttpRequest.get(url)
            |> HttpRequest.setHeader("User-Agent", userAgent)
            |> HttpRequest.setHeader("Accept", "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5")
            |> HttpRequest.withTimeout(Time.Duration.seconds(Ogp.timeoutSeconds()))

    ///
    /// User-Agent。プロジェクト名入り（相手のサイトが誰が取りに来たか分かる）。
    ///
    /// WhyNot: プロジェクト名をそのまま入れない。HTTP のヘッダの値は ASCII だけで、日本語の名前を
    /// 入れると送る前に JDK の HttpClient が弾き、そのプロジェクトのリンクカードが 1 件も取れなくなる
    /// （「ブログの作例」という名前で実際に全部落ちた）。日本語の CMS で日本語の名前は普通なので、
    /// 名前を捨てるのではなく入れられる文字だけ残す。
    ///
    /// WhyNot: 括弧も落とす。User-Agent の注記は `(` と `)` で囲む決まりなので、名前の中の括弧が
    /// 途中で閉じると相手のパーサが読み違える。
    ///
    pub def userAgent(projectName: String): String =
        let safe = projectName
            |> String.replaceMatches(regex = "[^\\x20-\\x7E]", to = "")
            |> String.replaceMatches(regex = "[()]", to = "")
            |> String.trim;
        if (String.isEmpty(safe)) "flix-cms-linkcard/1.0" else "flix-cms-linkcard/1.0 (+${safe})"

    /// 応答 → OGP か理由。着いた先（リダイレクト後）がプライベートなら断り、2xx 以外・HTML 以外・OGP も title も無い物は理由。
    def readResponse(url: String, response: HttpResponse): Result[String, Ogp.Meta] =
        let landed = HttpResponse.url(response);
        match Ogp.refuseReason(if (String.isEmpty(landed)) url else landed) {
            case Some(reason) => Err(reason)
            case None => match Ogp.describeStatus(HttpResponse.status(response)) {
                case Some(reason) => Err(reason)
                case None => match HttpResponse.contentType(response) |> Option.filter(found -> not isHtml(found)) {
                    case Some(contentType) => Err(Ogp.notHtmlReason(contentType))
                    case None =>
                        let meta = Ogp.parse(url, HttpResponse.body(response) |> String.take(Ogp.bodyLimitBytes()));
                        if (Option.isEmpty(meta#title)) Err(Ogp.noMetaReason()) else Ok(meta)
                }
            }
        }

    def isHtml(contentType: String): Bool =
        let lowered = String.toLowerCase(contentType);
        String.contains(substr = "html", lowered) or String.contains(substr = "xml", lowered)

    /// 繋がらなかった理由の人向けの文。
    def describeSendError(error: IoError.IoError): String = match error {
        case IoError.IoError(IoError.ErrorKind.ConnectionFailed, detail) => "接続できませんでした: ${detail}"
        case IoError.IoError(IoError.ErrorKind.UnknownHost, detail)      => "ホストが見つかりません: ${detail}"
        case IoError.IoError(IoError.ErrorKind.Timeout, detail)          => "応答がありませんでした（タイムアウト）: ${detail}"
        case IoError.IoError(kind, detail)                               => "取得できませんでした（${kind}）: ${detail}"
    }

    ///
    /// 取った結果を upsert する。失敗は error に理由を入れ、他の列は空にする。取り直しの仕事はプロジェクトの Tx の中でこれを呼ぶ。
    ///
    pub def store(projectId: Int64, url: String, outcome: Result[String, Ogp.Meta]): Unit \ DbWrite =
        discard LinkCardsQueries.upsertLinkCard(match outcome {
            case Ok(meta)    => { projectId = projectId, url = url, title = meta#title, description = meta#description, imageUrl = meta#imageUrl, siteName = meta#siteName, error = None }
            case Err(reason) => { projectId = projectId, url = url, title = None, description = None, imageUrl = None, siteName = None, error = Some(reason) }
        })

    def find(url: String): Option[LinkCard] \ DbRead + Tenant =
        LinkCardsQueries.findLinkCard({ projectId = Tenant.currentId(), url = url }) |> Option.map(LinkCardRows.toLinkCard)

    /// 表に入れない、理由だけの値。
    def refused(url: String, now: Int64, reason: String): LinkCard =
        { url = url, title = None, description = None, imageUrl = None, siteName = None, fetchedAt = Timestamp.fromEpochMillis(now), error = Some(reason) }

}
