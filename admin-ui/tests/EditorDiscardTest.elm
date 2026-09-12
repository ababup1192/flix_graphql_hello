module EditorDiscardTest exposing (suite)

{-| Page.Editor の「下書きを捨てる」: 履歴から、公開で積まれた最新のバージョンを選ぶ。
-}

import Expect
import Model
import Page.Editor as Editor
import Test exposing (Test, describe, test)


version : Int -> String -> Model.EntryVersion
version number reason =
    { id = "v" ++ String.fromInt number, version = number, reason = reason, author = "a", createdAt = "2026-09-12T00:00:00Z" }


suite : Test
suite =
    describe "latestPublished"
        [ test "PUBLISH が複数あれば version が最大の物" <|
            \_ ->
                [ version 3 "PUBLISH", version 5 "SAVE", version 7 "PUBLISH", version 1 "PUBLISH" ]
                    |> Editor.latestPublished
                    |> Expect.equal (Just (version 7 "PUBLISH"))
        , test "PUBLISH が無ければ Nothing" <|
            \_ ->
                [ version 3 "SAVE", version 5 "RESTORE" ]
                    |> Editor.latestPublished
                    |> Expect.equal Nothing
        , test "空なら Nothing" <|
            \_ ->
                Editor.latestPublished []
                    |> Expect.equal Nothing
        ]
