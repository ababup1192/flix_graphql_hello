module EditorPickerTest exposing (suite)

{-| Page.Editor の「メディアから選ぶ」（本文に入れる方）: 選ぶ → 決める → 本文への指示。

決定は `insert`（本文へ渡す指示）が立つかで見る。

-}

import Expect
import Model
import Page.Editor as Editor
import Test exposing (Test, describe, test)


ctx : { project : String, types : List Model.ContentTypeSummary }
ctx =
    { project = "default", types = [] }


{-| 本文のフィールドからピッカーを開いた所。
-}
opened : Editor.Model
opened =
    Editor.init "default" "blogs" (Just "e1")
        |> step (Editor.RichPickerOpened "body")


step : Editor.Msg -> Editor.Model -> Editor.Model
step msg model =
    Editor.update ctx msg model |> Tuple.first


{-| Msg を順に流し、本文への指示（無ければ Nothing）と、ピッカーがまだ開いているかを返す。
-}
run : List Editor.Msg -> ( Maybe (List String), Bool )
run msgs =
    List.foldl step opened msgs
        |> (\model -> ( Maybe.map .assetIds model.insert, model.richPicking /= Nothing ))


suite : Test
suite =
    describe "Page.Editor のメディアから選ぶ"
        (List.map
            (\( name, msgs, expected ) -> test name <| \_ -> run msgs |> Expect.equal expected)
            [ ( "0 枚では決めても入らず、開いたまま", [ Editor.RichInsertWanted ], ( Nothing, True ) )
            , ( "0 枚の Enter も入らない", [ Editor.EnterPressed ], ( Nothing, True ) )
            , ( "選んで Enter で入り、閉じる", [ Editor.AssetPicked "a1", Editor.AssetPicked "a2", Editor.EnterPressed ], ( Just [ "a1", "a2" ], False ) )
            , ( "ダブルクリックはその 1 枚だけを入れる", [ Editor.AssetPicked "a1", Editor.AssetConfirmed "a2" ], ( Just [ "a2" ], False ) )
            ]
        )
