module EditorAutosaveTest exposing (suite)

{-| Page.Editor の自動保存: 入力 → 待ち → 保存 → 保存中に入力 → 再保存。

待ちのタイマーは親（Main）が `Effect.Autosave` で出すので、ここでは「待ちが明けた」を
`AutosaveDue 番号` として直に流し、保存の状態と飛んだ呼び出しの数で確かめる。

-}

import Api
import Expect
import FieldValue
import Json.Encode as E
import Model
import Page.Editor as Editor
import Test exposing (Test, describe, test)


ctx : { project : String, types : List Model.ContentTypeSummary }
ctx =
    { project = "default", types = [] }


detail : Model.ContentTypeDetail
detail =
    { id = "t1", apiId = "blogs", name = "ブログ", kind = "LIST", previewUrl = "", linkPath = "", singular = "", icon = "", fields = [] }


row : Model.EntryRow
row =
    { id = "e1", version = 1, stage = "DRAFT", fields = E.object [], updatedAt = "2026-09-11T00:00:00Z", path = Nothing }


{-| 型と中身が届いた直後の、保存済みのエディタ。
-}
opened : Editor.Model
opened =
    Editor.init "default" "blogs" (Just "e1")
        |> step (Editor.GotType (Ok (Just detail)))
        |> Tuple.first
        |> step (Editor.GotEntry (Ok (Just row)))
        |> Tuple.first


typed : Editor.Msg
typed =
    Editor.FieldTyped "title" (FieldValue.Text "a")


step : Editor.Msg -> Editor.Model -> ( Editor.Model, Int )
step msg model =
    Editor.update ctx msg model |> Tuple.mapSecond List.length


{-| Msg を順に流し、最後の状態と**最後の Msg で飛んだ呼び出しの数**を返す。
-}
run : List Editor.Msg -> ( Editor.SaveState, Int )
run msgs =
    List.foldl (\msg ( model, _ ) -> step msg model) ( opened, 0 ) msgs
        |> Tuple.mapFirst .save


suite : Test
suite =
    describe "Page.Editor の自動保存" [ transitions, newEntry ]


transitions : Test
transitions =
    describe "状態の遷移"
        (List.map
            (\( name, msgs, expected ) -> test name <| \_ -> run msgs |> Expect.equal expected)
            [ ( "入力すると未保存になり、まだ何も飛ばない", [ typed ], ( Editor.Dirty, 0 ) )
            , ( "待ちが明けると 1 本だけ飛ぶ", [ typed, Editor.AutosaveDue 1 ], ( Editor.Saving { queued = False }, 1 ) )
            , ( "待っている間に打ち直すと、古い番号の待ちは捨てる", [ typed, typed, Editor.AutosaveDue 1 ], ( Editor.Dirty, 0 ) )
            , ( "打ち直した後の番号の待ちで飛ぶ", [ typed, typed, Editor.AutosaveDue 1, Editor.AutosaveDue 2 ], ( Editor.Saving { queued = False }, 1 ) )
            , ( "保存中の入力は 1 件だけ持ち、重ねて飛ばさない", [ typed, Editor.AutosaveDue 1, typed ], ( Editor.Saving { queued = True }, 0 ) )
            , ( "保存中の入力の待ちが明けても飛ばさない", [ typed, Editor.AutosaveDue 1, typed, Editor.AutosaveDue 2 ], ( Editor.Saving { queued = True }, 0 ) )
            , ( "保存が終わると、持っていた 1 件をもう一度飛ばす", [ typed, Editor.AutosaveDue 1, typed, Editor.GotSaved (Ok row) ], ( Editor.Saving { queued = False }, 1 ) )
            , ( "入力が無ければ保存済みに戻る", [ typed, Editor.AutosaveDue 1, Editor.GotSaved (Ok row) ], ( Editor.Saved, 0 ) )
            , ( "何も打っていない待ちは何もしない", [ Editor.AutosaveDue 0 ], ( Editor.Saved, 0 ) )
            , ( "届かなかった失敗は表示に残る", [ typed, Editor.AutosaveDue 1, Editor.GotSaved (Err Api.Unreachable) ], ( Editor.SaveFailed "サーバに届きませんでした", 0 ) )
            , ( "失敗の後の入力で未保存に戻り、次の待ちで再度飛ぶ", [ typed, Editor.AutosaveDue 1, Editor.GotSaved (Err Api.Unreachable), typed, Editor.AutosaveDue 2 ], ( Editor.Saving { queued = False }, 1 ) )
            , ( "⌘S で先に保存した後の待ちは飛ばさない", [ typed, Editor.SaveWanted, Editor.GotSaved (Ok row), Editor.AutosaveDue 1 ], ( Editor.Saved, 0 ) )
            ]
        )


{-| 新しいコンテンツは自動で作らない（最初の保存は人が押す）。
-}
newEntry : Test
newEntry =
    test "新しいコンテンツは待ちが明けても飛ばさない" <|
        \_ ->
            Editor.init "default" "blogs" Nothing
                |> step (Editor.GotType (Ok (Just detail)))
                |> Tuple.first
                |> step typed
                |> Tuple.first
                |> step (Editor.AutosaveDue 1)
                |> Tuple.mapFirst .save
                |> Expect.equal ( Editor.Dirty, 0 )
