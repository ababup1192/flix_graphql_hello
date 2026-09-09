module FieldValueTest exposing (suite)

{-| FieldValue — 種類ごとの JSON の形。CMS が断る形にしない事を見張る。
-}

import Expect
import FieldValue exposing (Value(..))
import Json.Decode as D
import Json.Encode as E
import Model
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "FieldValue"
        [ test "richText は編集器が作った doc をそのまま送る" <|
            \_ ->
                Rich "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\"}]}"
                    |> FieldValue.encode
                    |> E.encode 0
                    |> Expect.equal "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\"}]}"
        , test "壊れた richText は空の doc にする（値を捨てない）" <|
            \_ ->
                Rich "これは JSON ではない"
                    |> FieldValue.encode
                    |> E.encode 0
                    |> Expect.equal "{\"type\":\"doc\",\"content\":[]}"
        , test "数値は数として送る（文字列だと CMS が断る）" <|
            \_ ->
                [ Number "1.5", Number "3", Number "" ]
                    |> List.map (FieldValue.encode >> E.encode 0)
                    |> Expect.equal [ "1.5", "3", "null" ]
        , test "空の値は null で送る" <|
            \_ ->
                [ Text "", Choice "", Date "", Rich "" ]
                    |> List.map (FieldValue.encode >> E.encode 0)
                    |> Expect.equal [ "null", "null", "null", "null" ]
        , test "doc は往復しても形が変わらない" <|
            \_ ->
                let
                    doc : String
                    doc =
                        "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\"}]}"
                in
                Rich doc
                    |> FieldValue.encode
                    |> FieldValue.decode (sample "RICH_TEXT")
                    |> Expect.equal (Rich doc)
        , test "真偽と選択は往復する" <|
            \_ ->
                [ ( sample "BOOLEAN", Bool True ), ( sample "SELECT", Choice "TECH" ) ]
                    |> List.map (\( field, value ) -> FieldValue.decode field (FieldValue.encode value))
                    |> Expect.equal [ Bool True, Choice "TECH" ]
        , test "知らない形は Raw で持ち、そのまま送り返す" <|
            \_ ->
                let
                    raw : D.Value
                    raw =
                        E.object [ ( "unexpected", E.int 1 ) ]
                in
                FieldValue.decode (sample "TEXT") raw
                    |> FieldValue.encode
                    |> E.encode 0
                    |> Expect.equal "{\"unexpected\":1}"
        ]


sample : String -> Model.FieldDef
sample kind =
    { id = "f1"
    , apiId = "x"
    , name = "X"
    , kind = kind
    , many = False
    , required = False
    , unique = False
    , localized = False
    , targetTypeId = Nothing
    , config = { maxLength = Nothing, sourceField = Nothing, min = Nothing, max = Nothing, integer = Nothing, options = [] }
    }
