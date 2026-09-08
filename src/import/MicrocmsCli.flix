///
/// `CMS_MODE=import-microcms CMS_IMPORT_DIR=import/microcms/schema` で起動した時の一発処理。
/// ディレクトリの *.json（microCMS の API スキーマの export。ファイル名が API のエンドポイント名）を読んで型を写し、
/// ダミーの entry を作って公開し、要約を出して終わる。
///
mod MicrocmsCli {

    ///
    /// 読んで写して積む。失敗は理由の文字列。
    ///
    pub def execute(dir: String, pool: Pool, deps: Deps, projectId: ProjectId, count: Int32): Result[String, String] \ {IO, Fs.FileRead} =
        forM (
            apis <- readApis(dir);
            outcome <- AppEnv.runWith(deps, Log.Fields.empty(), projectId, () ->
                    DbRunner.transact(pool, Some(projectId), Actor.System, () -> {
                        let types = MicrocmsImport.importSchema(apis);
                        let created = MicrocmsImport.seedDummy(apis, types, count);
                        (Map.size(types), created |> Map.valuesOf |> List.map(List.length) |> List.sum)
                    }))
                |> Result.mapErr(ApplicationFailure.describe)
        ) yield {
            let (types, entries) = outcome;
            "microCMS のスキーマ ${List.length(apis)} 件を写しました: 型 ${types}、ダミーの entry ${entries}（全部公開済み）"
        }

    ///
    /// dir の *.json を読む。ファイル名（拡張子を除く）が API のエンドポイント名。
    ///
    pub def readApis(dir: String): Result[String, List[MicrocmsSchema.Api]] \ {IO, Fs.FileRead} =
        let listed = run { Fs.DirList.list(dir) } with Fs.DirList.runWithIO;
        listed
            |> Result.mapErr(error -> "${dir} を読めません: ${error}")
            |> Result.flatMap(names -> names
                |> List.filter(name -> String.endsWith(suffix = ".json", name))
                |> List.sort
                |> Result.traverse(name ->
                    Fs.FileRead.read("${dir}/${name}")
                        |> Result.mapErr(error -> "${dir}/${name} を読めません: ${error}")
                        |> Result.flatMap(MicrocmsSchema.parse(String.dropRight(5, name)))))

}
