///
/// schema.graphql と生成物の一致を確かめ、SQLite のカウンタを開き、エンジンを 1 回だけ組み立てて
/// 8080 番で GraphQL の HTTP サーバを起動する。起動に失敗したらメッセージを出して終了コード 1 で終わる。
///
def main(): Unit \ {IO, Chan, NonDet, Fs.FileRead, Sys.Exit} =
    let engine = forM (
        _        <- checkGenerated("schema.graphql");
        database <- SqliteCounter.open("counter.db");
        engine   <- Graphql.buildEngine(AppSchema.make(f -> SqliteCounter.runWithSqlite(database, f)))
    ) yield engine;
    match engine {
        case Err(message) => { println(message); Sys.Exit.exit(1) }
        case Ok(built)    => HttpServer.listen(8080, request -> Graphql.runWithEngine(built, () -> Server.handle(request)))
    }

///
/// 生成物が schema.graphql から、期待する版の生成器で作られた物か照合する。
/// テストでも同じ事を確かめるが、SDL だけ変えて起動しても古いスキーマで動いてしまうので、起動時にも止める。
///
def checkGenerated(sdlPath: String): Result[String, Unit] \ {IO, Fs.FileRead} =
    forM (
        sdl <- Fs.FileRead.read(sdlPath) |> Result.mapErr(error -> "${sdlPath} を読めません: ${error}");
        _   <- GeneratedCheck.check(sdl)
    ) yield ()
