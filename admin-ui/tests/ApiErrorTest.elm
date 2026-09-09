module ApiErrorTest exposing (suite)

{-| Api.Error — violation の path の読み方と、失敗の分類。
-}

import Api.Error as Error exposing (Code(..), Seg(..))
import Expect
import Json.Decode as D
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Api.Error"
        [ test "path の 3 つの規則を 1 つの形に正規化する" <|
            \_ ->
                [ "fields.title"
                , "fields.hero.headline"
                , "fields.sections[0].headline"
                , "fields.body.content[2].marks[0]"
                , "b1.fields.title"
                , "references"
                , "config.options"
                ]
                    |> List.map Error.parsePath
                    |> Expect.equal
                        [ { entryId = Nothing, segments = [ Key "fields", Key "title" ] }
                        , { entryId = Nothing, segments = [ Key "fields", Key "hero", Key "headline" ] }
                        , { entryId = Nothing, segments = [ Key "fields", Key "sections", Index 0, Key "headline" ] }
                        , { entryId = Nothing, segments = [ Key "fields", Key "body", Key "content", Index 2, Key "marks", Index 0 ] }
                        , { entryId = Just "b1", segments = [ Key "fields", Key "title" ] }
                        , { entryId = Nothing, segments = [ Key "references" ] }
                        , { entryId = Nothing, segments = [ Key "config", Key "options" ] }
                        ]
        , test "正規化した path を元の文字列に戻せる" <|
            \_ ->
                [ "fields.title", "fields.sections[0].headline", "b1.fields.title", "references" ]
                    |> List.map (Error.parsePath >> Error.pathToString)
                    |> Expect.equal [ "fields.title", "fields.sections[0].headline", "b1.fields.title", "references" ]
        , test "フォームの項目に付く違反だけを選ぶ" <|
            \_ ->
                [ "fields.title", "fields.body.content[2]", "fields.slug", "references" ]
                    |> List.map (\raw -> { path = Error.parsePath raw, raw = raw, message = "" })
                    |> Error.violationsFor "title"
                    |> List.map .raw
                    |> Expect.equal [ "fields.title" ]
        , test "violations は field キーでも path キーでも読める" <|
            \_ ->
                """
                { "message": "だめ"
                , "extensions":
                  { "code": "INVALID"
                  , "violations": [ { "field": "fields.title", "message": "必須です" } ]
                  }
                }
                """
                    |> D.decodeString Error.decoder
                    |> Result.map (\err -> ( err.code, List.map .raw err.violations ))
                    |> Expect.equal (Ok ( Invalid, [ "fields.title" ] ))
        , test "知らない code は Unknown に落ちる" <|
            \_ ->
                [ "INVALID", "CONFLICT", "UNAUTHENTICATED", "SOMETHING_NEW" ]
                    |> List.map Error.codeOf
                    |> Expect.equal [ Invalid, Conflict, Unauthenticated, Unknown "SOMETHING_NEW" ]
        , test "ログインし直しが要るのは 2 つだけ" <|
            \_ ->
                [ Unauthenticated, RequiresLogin, Forbidden, Invalid, Internal ]
                    |> List.map (\code -> Error.isAuthProblem (sample code))
                    |> Expect.equal [ True, True, False, False, False ]
        , test "CONFLICT は期待した版と実際の版を持つ" <|
            \_ ->
                """
                { "message": "競合"
                , "extensions": { "code": "CONFLICT", "entity": "Entry", "id": "e1", "expectedVersion": 4, "actualVersion": 5 }
                }
                """
                    |> D.decodeString Error.decoder
                    |> Result.map (\err -> ( err.entity, err.expectedVersion, err.actualVersion ))
                    |> Expect.equal (Ok ( Just "Entry", Just 4, Just 5 ))
        ]


sample : Code -> Error.ApiError
sample code =
    { message = ""
    , code = code
    , path = []
    , violations = []
    , entity = Nothing
    , entityId = Nothing
    , requestId = Nothing
    , expectedVersion = Nothing
    , actualVersion = Nothing
    }
