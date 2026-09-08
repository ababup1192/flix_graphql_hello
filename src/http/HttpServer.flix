///
/// ソケットを開いて HTTP/1.1 のリクエストをハンドラに渡す最小サーバ。
/// GraphQL のことは知らず、HttpRequest -> HttpResponse の関数だけを受け取る。
///
/// 対応範囲と上限:
/// - 接続ごとにスレッド（Flix の spawn。virtual thread）を 1 本起こす
/// - 同時接続は maxConnections まで。超えた接続は handle を呼ばずに 503（Retry-After: 1）を返して閉じる。待ち行列は無い
/// - keep-alive: HTTP/1.1 で Connection: close が無ければ、1 接続で Http.maxRequestsPerConnection() 回まで順に受ける。
///   4xx / 5xx の後と HTTP/1.0 は閉じる。2 回目以降の待ちは idleTimeoutMs で切る
/// - pipelining（応答を待たずに次を送る）は保証しない
/// - Transfer-Encoding: chunked には対応せず、ボディは Content-Length ぶんだけ読む
/// - ヘッダは maxHeaderLines() 行まで、1 行は Http.maxHeaderLineBytes() バイトまで、
///   ボディは Http.maxBodyBytes() バイトまで
/// - 最初のリクエストの読み取りは readTimeoutMs、2 回目以降の待ちは idleTimeoutMs でタイムアウトする
///
mod HttpServer {
    import java.io.BufferedInputStream
    import java.io.ByteArrayOutputStream
    import java.io.InputStream
    import java.io.OutputStreamWriter
    import java.io.PrintWriter
    import java.lang.Exception
    import java.lang.System
    import java.lang.Throwable
    import java.net.InetAddress
    import java.net.ServerSocket
    import java.net.Socket
    import java.net.SocketTimeoutException
    import java.time.Instant
    import java.util.concurrent.Semaphore

    ///
    /// 受け付けるヘッダ行数の上限。超えたリクエストは 431 にする。
    ///
    pub def maxHeaderLines(): Int32 = 100

    ///
    /// 待ち受けの設定。
    ///
    /// - bind: Some なら、そのアドレスにだけ bind する（開発モードで外に開けないため）
    /// - port: 待ち受けるポート。0 なら空いているポートを OS が選ぶ（Listener の port で読める）
    /// - maxConnections: 同時に受ける接続の上限（CMS_MAX_CONNECTIONS）
    /// - readTimeoutMs: 最初のリクエストを読み切るまでの待ち（ミリ秒）
    /// - idleTimeoutMs: keep-alive で次のリクエストが来るまでの待ち（ミリ秒）
    ///
    pub type alias ListenConfig = { bind = Option[String], port = Int32, maxConnections = Int32, readTimeoutMs = Int32, idleTimeoutMs = Int32 }

    ///
    /// 本番の既定値。全部のアドレスで 8080、同時接続 256、最初の読み取り 10 秒、idle 15 秒。
    ///
    pub def defaultConfig(): ListenConfig =
        { bind = None, port = 8080, maxConnections = 256, readTimeoutMs = 10000, idleTimeoutMs = 15000 }

    ///
    /// bind 済みのサーバソケットと、接続数を数えるセマフォ。
    ///
    /// - server: bind 済みのソケット。close で accept ループが終わる
    /// - port: 実際に待ち受けているポート（config の port が 0 なら OS が選んだ物）
    /// - limiter: 空き枠。accept ごとに 1 つ借り、接続を閉じたら返す
    /// - config: 待ち受けの設定
    ///
    pub type alias Listener = { server = ServerSocket, port = Int32, limiter = Semaphore, config = ListenConfig }

    ///
    /// /health に出す混み具合。
    ///
    /// - active: 今つないでいる接続の数
    /// - max: 同時接続の上限
    ///
    pub type alias Connections = { active = Int32, max = Int32 }

    ///
    /// ソケットを bind して Listener を作る。まだ accept はしない。
    ///
    pub def open(config: ListenConfig): Listener \ IO =
        let server = match config#bind {
            case Some(address) => new ServerSocket(config#port, 50, InetAddress.getByName(address))
            case None          => new ServerSocket(config#port)
        };
        { server = server, port = server.getLocalPort(), limiter = new Semaphore(config#maxConnections), config = config }

    ///
    /// サーバソケットを閉じる。accept ループが抜け、新しい接続を受けなくなる（つないでいる接続はそのまま）。
    ///
    pub def close(listener: Listener): Unit \ IO =
        listener#server.close()

    ///
    /// 今つないでいる接続の数と上限。
    ///
    pub def connections(listener: Listener): Connections \ IO =
        { active = listener#config#maxConnections - listener#limiter.availablePermits(), max = listener#config#maxConnections }

    ///
    /// Listener で待ち受け、接続ごとにスレッドを起こして handle に渡す。戻らない。
    /// ログは 1 本のチャネルに集めて logger スレッドが順に表示する。
    ///
    /// WhyNot: handle のエフェクトを多相にしないのは、spawn に渡す式は IO 以外の
    /// algebraic effect を残せないため。Graphql などは呼び出し側が剥がしてから渡す。
    ///
    pub def listen(listener: Listener, handle: HttpRequest -> HttpResponse \ IO): Unit \ {IO, Chan, NonDet} =
        region rc {
            let (sender, receiver) = Channel.buffered(1024);
            spawn logger(receiver) @ rc;
            println("listening on http://${listener#config#bind |> Option.getWithDefault("0.0.0.0")}:${listener#port}/");
            acceptLoop(listener, sender, handle)
        }

    ///
    /// accept を繰り返し、空き枠があれば serve のスレッドを起こし、無ければ 503 を書いて閉じる。
    /// サーバソケットが閉じられたら戻る。
    ///
    /// WhyNot: 空きが無い時に accept しないで backlog に溜めないのは、クライアントが理由の読めないまま待たされ、
    /// 前段（Caddy）のタイムアウトで 502 になるため。503 と Retry-After なら「混んでいる」と伝わる。
    ///
    pub def acceptLoop(listener: Listener, log: Sender[String], handle: HttpRequest -> HttpResponse \ IO): Unit \ {IO, Chan} =
        region rc {
            def loop() = match accept(listener#server) {
                case None         => ()
                case Some(socket) =>
                    if (listener#limiter.tryAcquire()) {
                        spawn serveThenRelease(socket, listener#limiter, log, listener#config, handle) @ rc
                    } else {
                        reject(socket, log)
                    };
                    loop()
            };
            loop()
        }

    ///
    /// 接続を 1 つ受ける。サーバソケットが閉じられていれば None。
    ///
    def accept(server: ServerSocket): Option[Socket] \ IO =
        try {
            Some(server.accept())
        } catch {
            case _: Exception => None
        }

    ///
    /// 空き枠が無い接続に 503 と Retry-After: 1 を書いて閉じる。handle は呼ばない。
    ///
    def reject(socket: Socket, log: Sender[String]): Unit \ {IO, Chan} =
        try {
            let writer = new PrintWriter(new OutputStreamWriter(socket.getOutputStream(), "UTF-8"), true);
            Channel.send(logLine("-", "-", 503, 0i64), log);
            write(writer, Http.Connection.Close, { status = 503, headers = ("Retry-After", "1") :: Nil, body = "" }, log);
            socket.close()
        } catch {
            case e: Throwable =>
                report(e, log);
                socket.close()
        }

    ///
    /// Throwable をログに流す。JVM 自体が壊れている物（OutOfMemoryError）はログした上で再送出する。
    ///
    /// WhyNot: Exception でなく Throwable で受けるのは、Error（リゾルバの VerifyError、深い再帰の StackOverflowError）が
    /// Exception の catch を素通りし、スレッドが黙って死んでソケットも閉じないため。
    ///
    def report(error: Throwable, log: Sender[String]): Unit \ {IO, Chan} =
        Channel.send("error: ${JvmErrors.describe(error)}", log);
        if (JvmErrors.isFatal(error)) throw error else ()

    ///
    /// serve の後に必ず枠を返す。serve が例外で抜けても返す。
    ///
    def serveThenRelease(socket: Socket, limiter: Semaphore, log: Sender[String], config: ListenConfig, handle: HttpRequest -> HttpResponse \ IO): Unit \ {IO, Chan} =
        try {
            serve(socket, log, config, handle)
        } catch {
            case e: Throwable => report(e, log)
        };
        limiter.release()

    ///
    /// 接続 1 本ぶんの処理。リクエストを読み、handle に渡し、応答を書く。続けられる間は同じ接続で繰り返し、最後に閉じる。
    /// リクエストが読めなければ 400、ヘッダが多すぎる・長すぎれば 431、
    /// Content-Length が上限を超えていれば 413、handle が例外を投げれば 500 を返す。
    ///
    /// WhyNot: 例外を握りつぶさず catch してログへ流すのは、spawn したスレッドで例外が
    /// 起きても親には何も伝わらず、ソケットも閉じられないまま黙って消えるため。
    ///
    /// WhyNot: 書き出しを既定の文字コードに任せないのは、Content-Length を UTF-8 の
    /// バイト数で数えているので、エンコードも UTF-8 に固定しないと食い違うため。
    ///
    def serve(socket: Socket, log: Sender[String], config: ListenConfig, handle: HttpRequest -> HttpResponse \ IO): Unit \ {IO, Chan} =
        try {
            let writer = new PrintWriter(new OutputStreamWriter(socket.getOutputStream(), "UTF-8"), true);
            let input: InputStream = checked_cast(new BufferedInputStream(socket.getInputStream()));
            serveLoop(socket, input, writer, log, config, handle, 1);
            // WhyNot: close を serveLoop の try の中に置かないのは、応答を書き終えた後の close の失敗で catch に入り、閉じかけの
            // ソケットへ 500 をもう一度書いてしまうため
            socket.close()
        } catch {
            case e: Throwable =>
                report(e, log);
                socket.close()
        }

    ///
    /// 1 リクエストを処理し、続けられるなら次を待つ。served はこの接続で何回目か（1 から）。
    /// 次のリクエストが来る前に EOF かタイムアウトになれば黙って終わる。
    ///
    /// WhyNot: 読み取りにタイムアウトを付けるのは、ヘッダやボディを送り切らない遅い
    /// クライアントが 1 本のスレッドを永久に塞いでしまうため。keep-alive の待ちを別の値にするのは、
    /// 1 回目の「来ない」は短く切り、2 回目以降は少し待ちたいため。
    ///
    /// WhyNot: handle の例外を IOException に絞らず Throwable で受けるのは、handle の中で起きる RuntimeException も
    /// Error（VerifyError）も同じ理由で消えるため。writer を try の外で先に作るのは、catch の中から 500 を書き戻すため。
    ///
    def serveLoop(socket: Socket, input: InputStream, writer: PrintWriter, log: Sender[String], config: ListenConfig, handle: HttpRequest -> HttpResponse \ IO, served: Int32): Unit \ {IO, Chan} =
        socket.setSoTimeout(if (served == 1) config#readTimeoutMs else config#idleTimeoutMs);
        if (awaitRequest(input)) {
            let connection = try {
                let started = System.currentTimeMillis();
                let (method, path, response, next) = match readRequest(input) {
                    case Ok(request) =>
                        let response = handle(request);
                        (request#method, request#path, response, Http.shouldKeepAlive(request, response#status, served))
                    case Err(status) => ("-", "-", { status = status, headers = Nil, body = "" }, Http.Connection.Close)
                };
                Channel.send(logLine(method, path, response#status, System.currentTimeMillis() - started), log);
                write(writer, next, response, log);
                next
            } catch {
                case e: Throwable =>
                    report(e, log);
                    write(writer, Http.Connection.Close, { status = 500, headers = Nil, body = "" }, log);
                    Http.Connection.Close
            };
            match connection {
                case Http.Connection.KeepAlive => serveLoop(socket, input, writer, log, config, handle, served + 1)
                case Http.Connection.Close     => ()
            }
        } else
            ()

    ///
    /// 次のリクエストの先頭 1 バイトが来るまで待つ。来れば true（バイトは戻す）。EOF かタイムアウトなら false。
    ///
    /// WhyNot: readRequest に任せず先に 1 バイト覗くのは、クライアントが何も送らずに閉じた時に 400 を書いてログに残すのを避けるため。
    /// keep-alive では応答の後にクライアントが閉じるのが普通で、それはエラーではない。
    ///
    def awaitRequest(input: InputStream): Bool \ IO =
        try {
            input.mark(1);
            if (input.read() == -1)
                false
            else {
                input.reset();
                true
            }
        } catch {
            case _: SocketTimeoutException => false
        }

    ///
    /// レスポンスを書き出して flush する。
    ///
    /// WhyNot: 書き出しの失敗を例外で受けないのは、PrintWriter が IOException を
    /// 内部で握りつぶして checkError() に残す作りのため。書いたあとに checkError() を見て
    /// ログへ流す。
    ///
    def write(writer: PrintWriter, connection: Http.Connection, response: HttpResponse, log: Sender[String]): Unit \ {IO, Chan} =
        writer.print(Http.render(connection, response));
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
            |> Result.flatMap(match (method, path, version) ->
                readHeaderLines(input)
                    |> Result.map(lines -> (method, path, version, Http.parseHeaders(lines))))
            |> Result.flatMap(match (method, path, version, headers) ->
                Http.contentLength(headers)
                    |> Result.mapErr(statusOf)
                    |> Result.map(length -> { method = method, path = path, version = version, headers = headers, body = readBody(input, length) }))

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
