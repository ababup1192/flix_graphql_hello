///
/// ../schema.graphql を読み、../src/generated/GeneratedSchema.flix を書く。
/// 本体リポジトリのルートから `make generate`（cd schemagen && ../bin/flix run）で呼ぶ。
///
def main(): Unit \ {IO, Fs.FileRead, Fs.FileWrite, Sys.Exit} =
    let sdlPath = "../schema.graphql";
    let outputPath = "../src/generated/GeneratedSchema.flix";
    let result = forM (
        sdl      <- Fs.FileRead.read(sdlPath) |> Result.mapErr(error -> "${sdlPath} を読めません: ${error}");
        document <- SdlReader.read(sdl);
        source   <- Emit.render(document, String.replace(src = "\r\n", dst = "\n", sdl));
        _        <- Fs.FileWrite.write({ str = source + "\n" }, outputPath) |> Result.mapErr(error -> "${outputPath} を書けません: ${error}")
    ) yield ();
    match result {
        case Err(message) => { println(message); Sys.Exit.exit(1) }
        case Ok(())       => println("${outputPath} を書きました")
    }
