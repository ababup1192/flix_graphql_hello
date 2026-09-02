///
/// ../schema.graphql を読んで生成する。本体リポジトリのルートから make で呼ぶ。
///
/// - `make generate`: ../src/generated/GeneratedSchema.flix を書く（毎回上書き）
/// - `make scaffold [TYPE=Post] [DEFAULTS=no]`: ../src/resolvers/XResolvers.flix の雛形を書く（既にあれば触らない）
///
/// WhyNot: モードと型名をコマンドライン引数で受けないのは、`flix run` がプログラム引数を受け取れないため。
/// 環境変数 SCHEMAGEN_MODE / SCAFFOLD_TYPE / SCAFFOLD_DEFAULTS で受ける。
///
def main(): Unit \ {IO, Fs.FileRead, Fs.FileWrite, Sys.Env, Sys.Exit} =
    let sdlPath = "../schema.graphql";
    let result = forM (
        sdl      <- Fs.FileRead.read(sdlPath) |> Result.mapErr(error -> "${sdlPath} を読めません: ${error}");
        document <- SdlReader.read(sdl);
        messages <- match Sys.Env.getVar("SCHEMAGEN_MODE") {
            case Some("scaffold") => Fs.FileTest.runWithIO(() -> scaffoldFiles(document))
            case _                => generateFile(document, String.replace(src = "\r\n", dst = "\n", sdl))
        }
    ) yield messages;
    match result {
        case Err(message)  => { println(message); Sys.Exit.exit(1) }
        case Ok(messages)  => List.forEach(println, messages)
    }

///
/// GeneratedSchema.flix を書く。
///
def generateFile(document: SdlDocument, sdl: String): Result[String, List[String]] \ Fs.FileWrite =
    let outputPath = "../src/generated/GeneratedSchema.flix";
    forM (
        source <- Emit.render(document, sdl);
        _      <- Fs.FileWrite.write({ str = source + "\n" }, outputPath) |> Result.mapErr(error -> "${outputPath} を書けません: ${error}")
    ) yield "${outputPath} を書きました" :: Nil

///
/// 雛形を書く。SCAFFOLD_TYPE が空なら全型、SCAFFOLD_DEFAULTS が "no" なら既定リゾルバを使わず全フィールドを吐く。
///
def scaffoldFiles(document: SdlDocument): Result[String, List[String]] \ {Fs.FileWrite, Fs.FileTest, Sys.Env} =
    let directory = "../src/resolvers";
    let wanted = Sys.Env.getVar("SCAFFOLD_TYPE") |> Option.filter(name -> not String.isEmpty(name));
    let defaultsFlag = Sys.Env.getVar("SCAFFOLD_DEFAULTS") |> Option.getWithDefault("");
    let targets = document#objects |> List.filter(object -> wanted |> Option.map(name -> name == object#name) |> Option.getWithDefault(true));
    forM (
        _ <- Emit.validate(document);
        useDefaults <- match defaultsFlag {
            case ""    => Ok(true)
            case "no"  => Ok(false)
            case other => Err("DEFAULTS は no か空だけです（${other} は受け付けません）")
        };
        _ <- if (not Option.isEmpty(wanted) and List.isEmpty(targets)) Err("型 ${Option.getWithDefault("", wanted)} が schema.graphql にありません") else Ok(());
        _ <- Fs.FileWrite.mkDirs(directory) |> Result.mapErr(error -> "${directory} を作れません: ${error}");
        messages <- Result.traverse(object -> scaffoldOne(document, directory, useDefaults, object), targets)
    ) yield messages

///
/// 1 型の雛形。既にあれば書かずにその旨を返す。
///
def scaffoldOne(document: SdlDocument, directory: String, useDefaults: Bool, object: ObjectDef): Result[String, String] \ {Fs.FileWrite, Fs.FileTest} =
    let path = "${directory}/${Scaffold.fileName(object#name)}";
    forM (
        exists <- Fs.FileTest.exists(path) |> Result.mapErr(error -> "${path} を調べられません: ${error}");
        message <- if (exists) Ok("${path} は既にあるので触りません")
                   else Fs.FileWrite.write({ str = Scaffold.render(document, object, useDefaults) + "\n" }, path)
                        |> Result.mapErr(error -> "${path} を書けません: ${error}")
                        |> Result.map(_ -> "${path} を書きました")
    ) yield message
