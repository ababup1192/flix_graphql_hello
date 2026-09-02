///
/// スキーマファイルを読み、SQLite のカウンタを開き、エンジンを 1 回だけ組み立てて
/// 8080 番で GraphQL の HTTP サーバを起動する。起動に失敗したらメッセージを出して終了コード 1 で終わる。
///
def main(): Unit \ {IO, Chan, NonDet, Fs.FileRead, Sys.Exit} =
    let engine = forM (
        sdl       <- Fs.FileRead.read("src/schema.graphql") |> Result.mapErr(error -> "スキーマファイルを読めません: ${error}");
        database  <- SqliteCounter.open("counter.db");
        resolvers <- Graphql.mergeResolvers(CalcResolvers.resolvers() :: Counter.resolvers(database) :: Nil);
        engine    <- Graphql.buildEngine({ sdl = sdl, resolvers = resolvers })
    ) yield engine;
    match engine {
        case Err(message) => { println(message); Sys.Exit.exit(1) }
        case Ok(built)    => HttpServer.listen(8080, request -> Graphql.runWithEngine(built, () -> Server.handle(request)))
    }
