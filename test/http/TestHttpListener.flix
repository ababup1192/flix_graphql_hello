///
/// HttpServer: 本物の socket で、同時接続の上限（503）と keep-alive を確かめる。
/// ポートは 0 で開き、OS が選んだポート（Listener の port）につなぐ。accept ループは別スレッドで起こし、最後にサーバソケットを閉じて止める。
///
mod TestHttpListener {
    import java.io.BufferedInputStream
    import java.io.InputStream
    import java.io.OutputStream
    import java.lang.Thread
    import java.net.Socket
    import java.lang.VerifyError
    import java.nio.charset.StandardCharsets

    ///
    /// テスト用の待ち受け。127.0.0.1 の空きポート、最初の読み取り 2 秒、idle は 1 秒。
    ///
    def config(maxConnections: Int32): HttpServer.ListenConfig =
        { bind = Some("127.0.0.1"), port = 0, maxConnections = maxConnections, readTimeoutMs = 2000, idleTimeoutMs = 1000 }

    ///
    /// パスを JSON 文字列にして返すハンドラ。
    ///
    def echoPath(request: HttpRequest): HttpResponse =
        { status = 200, headers = Nil, body = "\"${request#path}\"" }

    ///
    /// 必ず例外を投げるハンドラ（範囲外の substring）。
    ///
    def explode(request: HttpRequest): HttpResponse =
        let path: String = request#path;
        { status = 200, headers = Nil, body = path.substring(100, 200) }

    ///
    /// 必ず Error（Exception でない Throwable。リゾルバの VerifyError と同じ）を投げるハンドラ。
    ///
    def explodeWithError(_request: HttpRequest): HttpResponse \ IO =
        throw new VerifyError("stack map")

    ///
    /// サーバを立てて body を回し、終わったら止める。Served は onServed に流す。
    ///
    def withServerObserved(listenConfig: HttpServer.ListenConfig, onServed: HttpServer.Served -> Unit \ IO, handle: HttpRequest -> HttpResponse \ IO, body: HttpServer.Listener -> a \ IO): a \ IO =
        region rc {
            let listener = HttpServer.open(listenConfig);
            spawn HttpServer.acceptLoop(listener, onServed, handle) @ rc;
            let result = body(listener);
            HttpServer.close(listener);
            result
        }

    ///
    /// サーバを立てて body を回し、終わったら止める。Served は見ない。
    ///
    def withServer(listenConfig: HttpServer.ListenConfig, handle: HttpRequest -> HttpResponse \ IO, body: HttpServer.Listener -> a \ IO): a \ IO =
        withServerObserved(listenConfig, _ -> (), handle, body)

    ///
    /// Served を比べられる形に: (method, path, status, requestBytes, responseBytes, failure のクラス名)。
    ///
    def servedTuple(served: HttpServer.Served): (String, String, Int32, Int64, Int64, Option[String]) \ IO =
        (served#method, served#path, served#status, served#requestBytes, served#responseBytes,
         served#failure |> Option.map(error -> error.getClass().getName()))

    ///
    /// Served を Static の Ref に積む関数（spawn の中から呼ばれる）。
    ///
    def collectServed(sink: Ref[List[HttpServer.Served], Static], served: HttpServer.Served): Unit \ IO =
        Ref.put(served :: Ref.get(sink), sink)

    ///
    /// 積んだ Served が count 個になるまで待つ（最長 2 秒）。古い順に返す。
    ///
    def awaitServed(sink: Ref[List[HttpServer.Served], Static], count: Int32): List[HttpServer.Served] \ IO =
        def loop(remaining) =
            if (List.length(Ref.get(sink)) >= count or remaining <= 0) Ref.get(sink) |> List.reverse
            else { Thread.sleep(20i64); loop(remaining - 1) };
        loop(100)

    ///
    /// クライアント側の socket。
    ///
    /// - socket: つないだ socket
    /// - input: サーバからの応答を読む口
    /// - output: リクエストを書く口
    ///
    type alias Client = { socket = Socket, input = InputStream, output = OutputStream }

    ///
    /// サーバにつなぐ。読み取りは 3 秒で諦める。
    ///
    def connect(listener: HttpServer.Listener): Client \ IO =
        let socket = new Socket("127.0.0.1", listener#port);
        socket.setSoTimeout(3000);
        { socket = socket, input = checked_cast(new BufferedInputStream(socket.getInputStream())), output = socket.getOutputStream() }

    ///
    /// リクエストのテキストをそのまま送る。
    ///
    def send(client: Client, text: String): Unit \ IO =
        client#output.write(text.getBytes(StandardCharsets.UTF_8));
        client#output.flush()

    ///
    /// 応答を 1 つ読む: (ステータスコード, ヘッダ, ボディ)。ボディは Content-Length ぶん。
    ///
    def readResponse(client: Client): (Int32, List[(String, String)], String) \ IO =
        let statusLine = HttpServer.readLine(client#input) |> Result.getWithDefault("");
        let status = String.splitOn(substr = " ", statusLine) |> List.drop(1) |> List.head |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(-1);
        let headers = HttpServer.readHeaderLines(client#input) |> Result.getWithDefault(Nil) |> Http.parseHeaders;
        let length = Http.contentLength(headers) |> Result.getWithDefault(0);
        (status, headers, HttpServer.readBody(client#input, length))

    ///
    /// GET を送って応答を読む: (ステータスコード, Connection ヘッダ, ボディ)。
    ///
    def get(client: Client, path: String, extraHeaders: String): (Int32, Option[String], String) \ IO =
        send(client, "GET ${path} HTTP/1.1\r\nHost: x\r\n${extraHeaders}\r\n");
        let (status, headers, body) = readResponse(client);
        (status, Http.findHeader("Connection", headers), body)

    ///
    /// サーバが閉じるまで待ち、EOF（-1）が読めたか。
    ///
    def isClosed(client: Client): Bool \ IO =
        client#input.read() == -1

    ///
    /// つないでいる数が expected になるまで待つ（最長 2 秒）。なったら true。
    ///
    def waitForActive(listener: HttpServer.Listener, expected: Int32): Bool \ IO =
        def loop(remaining) =
            if (HttpServer.connections(listener)#active == expected) true
            else if (remaining <= 0) false
            else { Thread.sleep(20i64); loop(remaining - 1) };
        loop(100)

    // ---- spawn ----

    /// Flix の spawn は virtual thread で起きる（接続ごとに 1 本起こしても platform thread を食わない）。
    @Test
    def testSpawnIsVirtualThread(): Unit \ {Assert, IO, Chan, NonDet} =
        let isVirtual = region rc {
            let (sender, receiver) = Channel.buffered(1);
            spawn Channel.send(Thread.currentThread().isVirtual(), sender) @ rc;
            Channel.recv(receiver)
        };
        Assert.assertTrue(isVirtual)

    // ---- 同時接続の上限 ----

    /// 上限 2 で 3 本目は 503 と Retry-After: 1（handle は呼ばれない）。1 本目が閉じれば次の接続は通る。
    ///
    ///   a ──┐
    ///   b ──┤ 枠 2 つ
    ///   c ──┘ → 503
    ///   a を閉じる → d → 200
    ///
    @Test
    def testMaxConnectionsRejectsWith503(): Unit \ {Assert, IO} =
        let outcome = withServer(config(2), request -> echoPath(request), listener -> {
            let a = connect(listener);
            let b = connect(listener);
            let twoActive = waitForActive(listener, 2);
            let c = connect(listener);
            let (rejectedStatus, rejectedHeaders, _) = readResponse(c);
            let rejectedClosed = isClosed(c);
            a#socket.close();
            let oneActive = waitForActive(listener, 1);
            let d = connect(listener);
            let (servedStatus, _, servedBody) = get(d, "/after", "");
            b#socket.close();
            c#socket.close();
            d#socket.close();
            (twoActive, rejectedStatus, Http.findHeader("Retry-After", rejectedHeaders), rejectedClosed, oneActive, servedStatus, servedBody)
        });
        Assert.assertEq(expected = (true, 503, Some("1"), true, true, 200, "\"/after\""), outcome)

    /// handle が例外を投げた接続でも枠が返る。上限 1 で 500 の後に、次の接続も 503 ではなく 500 になる。
    @Test
    def testMaxConnectionsReleasedAfterHandlerException(): Unit \ {Assert, IO} =
        let outcome = withServer(config(1), request -> explode(request), listener -> {
            let first = connect(listener);
            let (firstStatus, firstConnection, _) = get(first, "/boom", "");
            first#socket.close();
            let released = waitForActive(listener, 0);
            let second = connect(listener);
            let (secondStatus, _, _) = get(second, "/boom", "");
            second#socket.close();
            (firstStatus, firstConnection, released, secondStatus)
        });
        Assert.assertEq(expected = (500, Some("close"), true, 500), outcome)

    /// handle が Error（VerifyError）を投げても 500 が返って接続が閉じ、枠が返る。上限 1 で次の接続も 503 ではなく 500 になる。
    @Test
    def testMaxConnectionsReleasedAfterHandlerError(): Unit \ {Assert, IO} =
        let outcome = withServer(config(1), request -> explodeWithError(request), listener -> {
            let first = connect(listener);
            let (firstStatus, firstConnection, _) = get(first, "/boom", "");
            let closedAfter = isClosed(first);
            first#socket.close();
            let released = waitForActive(listener, 0);
            let second = connect(listener);
            let (secondStatus, _, _) = get(second, "/boom", "");
            second#socket.close();
            (firstStatus, firstConnection, closedAfter, released, secondStatus)
        });
        Assert.assertEq(expected = (500, Some("close"), true, true, 500), outcome)

    // ---- keep-alive ----

    /// 1 本の socket で 3 リクエストを順に送ると、3 応答が順に返り、どれも Connection: keep-alive。
    @Test
    def testKeepAliveServesRequestsInOrder(): Unit \ {Assert, IO} =
        let outcome = withServer(config(4), request -> echoPath(request), listener -> {
            let client = connect(listener);
            let responses = List#{"/one", "/two", "/three"} |> List.map(path -> get(client, path, ""));
            client#socket.close();
            responses
        });
        Assert.assertEq(
            expected = List#{(200, Some("keep-alive"), "\"/one\""), (200, Some("keep-alive"), "\"/two\""), (200, Some("keep-alive"), "\"/three\"")},
            outcome)

    /// Connection: close を付けた要求には Connection: close で応え、その後サーバが閉じる。
    @Test
    def testKeepAliveStopsOnConnectionClose(): Unit \ {Assert, IO} =
        let outcome = withServer(config(4), request -> echoPath(request), listener -> {
            let client = connect(listener);
            let (status, connection, _) = get(client, "/last", "Connection: close\r\n");
            let closed = isClosed(client);
            client#socket.close();
            (status, connection, closed)
        });
        Assert.assertEq(expected = (200, Some("close"), true), outcome)

    /// HTTP/1.0 は 1 回で閉じる。
    @Test
    def testKeepAliveNotForHttp10(): Unit \ {Assert, IO} =
        let outcome = withServer(config(4), request -> echoPath(request), listener -> {
            let client = connect(listener);
            send(client, "GET /old HTTP/1.0\r\nHost: x\r\n\r\n");
            let (status, headers, _) = readResponse(client);
            let closed = isClosed(client);
            client#socket.close();
            (status, Http.findHeader("Connection", headers), closed)
        });
        Assert.assertEq(expected = (200, Some("close"), true), outcome)

    /// 400 の後は閉じる（ストリームの位置が信用できない）。
    @Test
    def testKeepAliveStopsAfterBadRequest(): Unit \ {Assert, IO} =
        let outcome = withServer(config(4), request -> echoPath(request), listener -> {
            let client = connect(listener);
            send(client, "nonsense\r\n\r\n");
            let (status, headers, _) = readResponse(client);
            let closed = isClosed(client);
            client#socket.close();
            (status, Http.findHeader("Connection", headers), closed)
        });
        Assert.assertEq(expected = (400, Some("close"), true), outcome)

    /// idle（次のリクエストが来ない）が続くとサーバが閉じる。idle を 200 ミリ秒にして待つ。
    @Test
    def testKeepAliveClosesAfterIdleTimeout(): Unit \ {Assert, IO} =
        let outcome = withServer({ idleTimeoutMs = 200 | config(4) }, request -> echoPath(request), listener -> {
            let client = connect(listener);
            let (status, connection, _) = get(client, "/first", "");
            let closed = isClosed(client);
            client#socket.close();
            (status, connection, closed)
        });
        Assert.assertEq(expected = (200, Some("keep-alive"), true), outcome)

    /// 1 接続で 100 回まで。100 回目の応答は Connection: close で、その前の 99 回は keep-alive。
    @Test
    def testKeepAliveStopsAtMaxRequests(): Unit \ {Assert, IO} =
        let outcome = withServer(config(4), request -> echoPath(request), listener -> {
            let client = connect(listener);
            let connections = List.range(0, Http.maxRequestsPerConnection()) |> List.map(_ -> get(client, "/n", "") |> (match (_, connection, _) -> connection));
            let closed = isClosed(client);
            client#socket.close();
            (List.count(connection -> connection == Some("keep-alive"), connections), List.last(connections), closed)
        });
        Assert.assertEq(expected = (Http.maxRequestsPerConnection() - 1, Some(Some("close")), true), outcome)

    // ---- onServed ----

    /// 200 の Served: method と path（クエリは落ちる）、ボディのバイト数、failure 無し。
    @Test
    def testServedForOk(): Unit \ {Assert, IO} =
        let sink = Ref.fresh(Static, Nil);
        let served = withServerObserved(config(4), served -> collectServed(sink, served), request -> echoPath(request), listener -> {
            let client = connect(listener);
            send(client, "POST /echo?token=secret HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n日");
            discard readResponse(client);
            client#socket.close();
            awaitServed(sink, 1)
        });
        Assert.assertEq(expected = List#{("POST", "/echo", 200, 3i64, 20i64, None)}, served |> List.map(servedTuple))

    /// 読めないリクエストの Served: method / path は "-"、status は 400、failure 無し。
    @Test
    def testServedForBadRequest(): Unit \ {Assert, IO} =
        let sink = Ref.fresh(Static, Nil);
        let served = withServerObserved(config(4), served -> collectServed(sink, served), request -> echoPath(request), listener -> {
            let client = connect(listener);
            send(client, "nonsense\r\n\r\n");
            discard readResponse(client);
            client#socket.close();
            awaitServed(sink, 1)
        });
        Assert.assertEq(expected = List#{("-", "-", 400, 0i64, 0i64, None)}, served |> List.map(servedTuple))

    /// handle が Error（VerifyError）を投げた Served: method / path は残り、status は 500、failure にその例外。
    @Test
    def testServedForHandlerError(): Unit \ {Assert, IO} =
        let sink = Ref.fresh(Static, Nil);
        let served = withServerObserved(config(4), served -> collectServed(sink, served), request -> explodeWithError(request), listener -> {
            let client = connect(listener);
            discard get(client, "/boom", "");
            client#socket.close();
            awaitServed(sink, 1)
        });
        Assert.assertEq(expected = List#{("GET", "/boom", 500, 0i64, 0i64, Some("java.lang.VerifyError"))}, served |> List.map(servedTuple))

    /// 上限を超えた接続の Served: 503、method / path は "-"。
    @Test
    def testServedForRejected(): Unit \ {Assert, IO} =
        let sink = Ref.fresh(Static, Nil);
        let served = withServerObserved(config(1), served -> collectServed(sink, served), request -> echoPath(request), listener -> {
            let a = connect(listener);
            discard waitForActive(listener, 1);
            let b = connect(listener);
            discard readResponse(b);
            a#socket.close();
            b#socket.close();
            awaitServed(sink, 1)
        });
        Assert.assertEq(expected = List#{("-", "-", 503, 0i64, 0i64, None)}, served |> List.map(servedTuple))

}
