///
/// ソケットを開いて HTTP/1.1 のリクエストを 1 本ずつハンドラに渡す最小サーバ。
/// GraphQL のことは知らず、HttpRequest -> HttpResponse の関数だけを受け取る。
///
/// 対応範囲と上限:
/// - 接続ごとにスレッドを 1 本起こす。スレッド数に上限は無い（接続が増えた分だけ増える）
/// - keep-alive には対応せず、1 接続で 1 リクエストを処理して閉じる
/// - Transfer-Encoding: chunked には対応せず、ボディは Content-Length ぶんだけ読む
/// - ヘッダは maxHeaderLines() 行まで、1 行は Http.maxHeaderLineBytes() バイトまで、
///   ボディは Http.maxBodyBytes() バイトまで
/// - 読み取りは 10 秒でタイムアウトする
///
mod HttpServer {
    import java.io.BufferedInputStream
    import java.io.ByteArrayOutputStream
    import java.io.InputStream
    import java.io.OutputStreamWriter
    import java.io.PrintWriter
    import java.lang.Exception
    import java.lang.System
    import java.net.InetAddress
    import java.net.ServerSocket
    import java.time.Instant
    import java.net.Socket

    ///
    /// 受け付けるヘッダ行数の上限。超えたリクエストは 431 にする。
    ///
    pub def maxHeaderLines(): Int32 = 100

    ///
    /// 指定ポートで待ち受け、接続ごとにスレッドを起こして handle に渡す。戻らない。
    /// ログは 1 本のチャネルに集めて logger スレッドが順に表示する。bind が Some なら、そのアドレスにだけ bind する（開発モードで外に開けないため）。
    ///
    /// WhyNot: handle のエフェクトを多相にしないのは、spawn に渡す式は IO 以外の
    /// algebraic effect を残せないため。Graphql などは呼び出し側が剥がしてから渡す。
    ///
    pub def listen(bind: Option[String], port: Int32, handle: HttpRequest -> HttpResponse \ IO): Unit \ {IO, Chan, NonDet} =
        region rc {
            let (sender, receiver) = Channel.buffered(1024);
            spawn logger(receiver) @ rc;
            let server = match bind {
                case Some(address) => new ServerSocket(port, 50, InetAddress.getByName(address))
                case None          => new ServerSocket(port)
            };
            println("listening on http://${bind |> Option.getWithDefault("0.0.0.0")}:${port}/");
            def accept() = {
                let socket = server.accept();
                spawn serve(socket, sender, handle) @ rc;
                accept()
            };
            accept()
        }

    ///
    /// 接続 1 本ぶんの処理。HTTP リクエストを 1 つ読み、handle に渡し、返して閉じる。
    /// リクエストが読めなければ 400、ヘッダが多すぎる・長すぎれば 431、
    /// Content-Length が上限を超えていれば 413、handle が例外を投げれば 500 を返す。
    ///
    /// WhyNot: 例外を握りつぶさず catch してログへ流すのは、spawn したスレッドで例外が
    /// 起きても親には何も伝わらず、ソケットも閉じられないまま黙って消えるため。
    /// IOException に絞らず Exception で受けるのは、handle の中で起きる RuntimeException も
    /// 同じ理由で消えるため。
    ///
    /// WhyNot: writer を try の外で先に作るのは、handle が例外を投げたときに catch の中から
    /// 500 を書き戻すため。writer を作れないときはソケットを閉じるしかない。
    ///
    /// WhyNot: 書き出しを既定の文字コードに任せないのは、Content-Length を UTF-8 の
    /// バイト数で数えているので、エンコードも UTF-8 に固定しないと食い違うため。
    ///
    /// WhyNot: 読み取りにタイムアウトを付けるのは、ヘッダやボディを送り切らない遅い
    /// クライアントが 1 本のスレッドを永久に塞いでしまうため。
    ///
    def serve(socket: Socket, log: Sender[String], handle: HttpRequest -> HttpResponse \ IO): Unit \ {IO, Chan} =
        try {
            socket.setSoTimeout(10000);
            let writer = new PrintWriter(new OutputStreamWriter(socket.getOutputStream(), "UTF-8"), true);
            try {
                let input: InputStream = checked_cast(new BufferedInputStream(socket.getInputStream()));
                let started = System.currentTimeMillis();
                let (method, path, response) = match readRequest(input) {
                    case Ok(request) => (request#method, request#path, handle(request))
                    case Err(status) => ("-", "-", { status = status, headers = Nil, body = "" })
                };
                Channel.send(logLine(method, path, response#status, System.currentTimeMillis() - started), log);
                write(writer, response, log)
            } catch {
                case e: Exception =>
                    Channel.send("error: ${e.getMessage()}", log);
                    write(writer, { status = 500, headers = Nil, body = "" }, log)
            };
            // WhyNot: close を try の中に置かないのは、応答を書き終えた後の close の失敗で catch に入り、閉じかけの
            // ソケットへ 500 をもう一度書いてしまうため
            socket.close()
        } catch {
            case e: Exception =>
                Channel.send("error: ${e.getMessage()}", log);
                socket.close()
        }

    ///
    /// レスポンスを書き出して flush する。
    ///
    /// WhyNot: 書き出しの失敗を例外で受けないのは、PrintWriter が IOException を
    /// 内部で握りつぶして checkError() に残す作りのため。書いたあとに checkError() を見て
    /// ログへ流す。
    ///
    def write(writer: PrintWriter, response: HttpResponse, log: Sender[String]): Unit \ {IO, Chan} =
        writer.print(Http.render(response));
        writer.flush();
        if (writer.checkError())
            Channel.send("error: write failed", log)
        else
            ()

    ///
    /// リクエスト 1 本のログ。1 行 1 JSON（time / method / path / status / ms）。ログ基盤（Loki 等）が `| json` で引ける形。
    ///
    /// WhyNot: パスをそのまま出さないのは、改行などの制御文字が入っていると偽のログ行を作れてしまうため（log injection）。
    /// JSON の escape で改行は割れないが、端末のエスケープシーケンスは通るので制御文字ごと落とす。
    /// クエリ文字列を落とすのは、プレビューのトークンや GET の query がログ基盤に残らないようにするため。
    ///
    pub def logLine(method: String, path: String, status: Int32, elapsedMs: Int64): String \ IO =
        JsonValue.toJsonString(Value.Obj(Map#{
            "time" => Value.Str(Instant.now().toString()),
            "method" => Value.Str(method),
            "path" => Value.Str(path |> withoutQuery |> String.replaceMatches(regex = "\\p{Cntrl}", to = "")),
            "status" => Value.Int(status),
            "ms" => Value.Int(Int64.clampToInt32(min = 0, max = Int32.maxValue(), elapsedMs))
        }))

    /// `?` より後ろを落とす。
    def withoutQuery(path: String): String =
        String.splitOn(substr = "?", path) |> List.head |> Option.getWithDefault(path)

    ///
    /// リクエスト行・ヘッダ・ボディを読んで HttpRequest にする。
    /// 読めないときは返すべきステータスコードを Err に入れる。
    /// リクエスト行が長すぎれば Err(431)、解析できなければ Err(400)。
    /// Content-Length が読めなかったときはボディを読まずに返す。
    ///
    pub def readRequest(input: InputStream): Result[Int32, HttpRequest] \ IO =
        readLine(input)
            |> Result.flatMap(requestLine -> Http.parseRequestLine(requestLine) |> Option.toOk(400))
            |> Result.flatMap(match (method, path) ->
                readHeaderLines(input)
                    |> Result.map(lines -> (method, path, Http.parseHeaders(lines))))
            |> Result.flatMap(match (method, path, headers) ->
                Http.contentLength(headers)
                    |> Result.mapErr(statusOf)
                    |> Result.map(length -> { method = method, path = path, headers = headers, body = readBody(input, length) }))

    ///
    /// Content-Length の失敗をステータスコードにする。
    ///
    def statusOf(error: Http.HeaderError): Int32 = match error {
        case Http.HeaderError.Malformed(_) => 400
        case Http.HeaderError.TooLarge(_)  => 413
    }

    ///
    /// 空行（または EOF）が来るまでヘッダ行を読む。
    /// maxHeaderLines() を超えて空行が来なければそこで読むのをやめて Err(431)。
    /// 1 行が Http.maxHeaderLineBytes() を超えても Err(431)（RFC 6585 はヘッダ全体の大きさを対象にする）。
    ///
    pub def readHeaderLines(input: InputStream): Result[Int32, List[String]] \ IO =
        def loop(count, acc) =
            readLine(input) |> Result.flatMap(line ->
                if (line == "")
                    Ok(List.reverse(acc))
                else if (count >= maxHeaderLines())
                    Err(431)
                else
                    loop(count + 1, line :: acc));
        loop(0, Nil)

    ///
    /// 1 行を "\n" まで読み、末尾の "\r" を落として UTF-8 として返す。EOF なら空文字列。
    /// 改行が来る前に Http.maxHeaderLineBytes() を超えたら Err(431)。
    ///
    /// WhyNot: Reader（文字単位）ではなく InputStream（バイト単位）で読むのは、
    /// ボディを Content-Length のバイト数ちょうどで読むには同じストリームから
    /// バイトで読む必要があり、Reader を挟むと先読みでボディの一部を持って行かれるため。
    ///
    pub def readLine(input: InputStream): Result[Int32, String] \ IO =
        let out = new ByteArrayOutputStream();
        def loop() = match input.read() {
            case -1   => Ok(out.toString("UTF-8"))
            case 10   => Ok(out.toString("UTF-8"))
            case code =>
                if (out.size() >= Http.maxHeaderLineBytes())
                    Err(431)
                else {
                    out.write(code);
                    loop()
                }
        };
        loop() |> Result.map(line -> String.stripSuffix(substr = "\r", line) |> Option.getWithDefault(line))

    ///
    /// ボディを読むときの 1 回分のバッファ長。確保する長さと 1 回に読む長さは同じでないと読み過ぎる。
    ///
    def readBufferBytes(): Int32 = 8192

    ///
    /// ボディを byteCount バイトぶん読んで UTF-8 として返す。EOF が先に来たらそこまでを返す。
    ///
    /// WhyNot: 文字単位で読んで UTF-8 バイト数を引き算しないのは、絵文字のような
    /// サロゲートペアは 1 文字が 2 単位に割れて数え間違え、ソケットが
    /// タイムアウトまで残りを待ち続けるため。
    ///
    pub def readBody(input: InputStream, byteCount: Int32): String \ IO =
        region rc {
            let out = new ByteArrayOutputStream();
            let buffer = Array.repeat(rc, readBufferBytes(), 0i8);
            def loop(remaining) = {
                if (remaining <= 0)
                    ()
                else
                    match input.read(buffer, 0, Int32.min(remaining, readBufferBytes())) {
                        case -1    => ()
                        case count =>
                            out.write(buffer, 0, count);
                            loop(remaining - count)
                    }
            };
            loop(byteCount);
            out.toString("UTF-8")
        }

    ///
    /// ログを 1 本のチャネルに集約して順に表示する。
    ///
    def logger(receiver: Receiver[String]): Unit \ {IO, Chan, NonDet} =
        def loop() = { println(Channel.recv(receiver)); loop() };
        loop()

}
