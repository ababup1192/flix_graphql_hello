///
/// SDL を読んで生成する。本体リポジトリのルートから make で呼ぶ。
///
/// - `make generate`: SDL ごとに ../src/generated/graphql/<Module>Schema.flix を書く（毎回上書き）
/// - `make scaffold [TYPE=Post] [DEFAULTS=no]`: リゾルバの雛形を書く（既にあれば触らない）
///
/// どの SDL をどこへ書くかは環境変数で受ける。
/// - SCHEMAGEN_SDL: SDL のパス（既定 ../schema.graphql）
/// - SCHEMAGEN_MODULE: 生成物のモジュール名（既定 Generated）。出力先は ../src/generated/graphql/<Module>Schema.flix
/// - SCHEMAGEN_EFF: 雛形が使う効果の別名（既定 AppEff）
/// - SCAFFOLD_DIR: 雛形の置き場所（既定 ../src/sample/resolvers）
///
/// WhyNot: モードと型名をコマンドライン引数で受けないのは、`flix run` がプログラム引数を受け取れないため。
/// 環境変数 SCHEMAGEN_MODE / SCAFFOLD_TYPE / SCAFFOLD_DEFAULTS で受ける。
///
def main(): Unit \ {IO, Fs.FileRead, Fs.FileWrite, Sys.Env, Sys.Exit} =
    let target = targetFromEnv();
    let result = forM (
        sdl      <- Fs.FileRead.read(target#sdlPath) |> Result.mapErr(error -> "${target#sdlPath} を読めません: ${error}");
        document <- SdlReader.read(sdl);
        messages <- match Sys.Env.getVar("SCHEMAGEN_MODE") {
            case Some("scaffold") => Fs.FileTest.runWithIO(() -> scaffoldFiles(target, document))
            case _                => generateFile(target, document, String.replace(src = "\r\n", dst = "\n", sdl))
        }
    ) yield messages;
    match result {
        case Err(message)  => { println(message); Sys.Exit.exit(1) }
        case Ok(messages)  => List.forEach(println, messages)
    }

///
/// 生成の対象。
///
/// - sdlPath: 読む SDL
/// - moduleName: 生成物のモジュール名
/// - outputPath: 生成物の書き先
/// - effName: 雛形のリゾルバが使う効果の別名
/// - scaffoldDir: 雛形の置き場所
///
type alias Target = { sdlPath = String, moduleName = String, outputPath = String, effName = String, scaffoldDir = String }

///
/// 環境変数から対象を組む。既定は schema.graphql → Generated。
///
def targetFromEnv(): Target \ Sys.Env =
    let moduleName = Sys.Env.getVar("SCHEMAGEN_MODULE") |> Option.getWithDefault("Generated");
    {
        sdlPath     = Sys.Env.getVar("SCHEMAGEN_SDL") |> Option.getWithDefault("../schema.graphql"),
        moduleName  = moduleName,
        outputPath  = "../src/generated/graphql/${moduleName}Schema.flix",
        effName     = Sys.Env.getVar("SCHEMAGEN_EFF") |> Option.getWithDefault("AppEff"),
        scaffoldDir = Sys.Env.getVar("SCAFFOLD_DIR") |> Option.getWithDefault("../src/sample/resolvers")
    }

///
/// 生成物を書く。
///
def generateFile(target: Target, document: SdlDocument, sdl: String): Result[String, List[String]] \ Fs.FileWrite =
    forM (
        source <- Emit.render(target#moduleName, document, sdl);
        _      <- Fs.FileWrite.write({ str = source + "\n" }, target#outputPath) |> Result.mapErr(error -> "${target#outputPath} を書けません: ${error}")
    ) yield "${target#outputPath} を書きました" :: Nil

///
/// 雛形を書く。SCAFFOLD_TYPE が空なら全型、SCAFFOLD_DEFAULTS が "no" なら既定リゾルバを使わず全フィールドを吐く。
///
def scaffoldFiles(target: Target, document: SdlDocument): Result[String, List[String]] \ {Fs.FileWrite, Fs.FileTest, Sys.Env} =
    let directory = target#scaffoldDir;
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
        _ <- if (not Option.isEmpty(wanted) and List.isEmpty(targets)) Err("型 ${Option.getWithDefault("", wanted)} が ${target#sdlPath} にありません") else Ok(());
        _ <- Fs.FileWrite.mkDirs(directory) |> Result.mapErr(error -> "${directory} を作れません: ${error}");
        messages <- Result.traverse(object -> scaffoldOne(target, document, directory, useDefaults, object), targets)
    ) yield messages

///
/// 1 型の雛形。既にあれば書かずにその旨を返す。
///
def scaffoldOne(target: Target, document: SdlDocument, directory: String, useDefaults: Bool, object: ObjectDef): Result[String, String] \ {Fs.FileWrite, Fs.FileTest} =
    let path = "${directory}/${Scaffold.fileName(object#name)}";
    let names = { moduleName = target#moduleName, effName = target#effName };
    forM (
        exists <- Fs.FileTest.exists(path) |> Result.mapErr(error -> "${path} を調べられません: ${error}");
        message <- if (exists) Ok("${path} は既にあるので触りません")
                   else Fs.FileWrite.write({ str = Scaffold.render(names, document, object, useDefaults) + "\n" }, path)
                        |> Result.mapErr(error -> "${path} を書けません: ${error}")
                        |> Result.map(_ -> "${path} を書きました")
    ) yield message
