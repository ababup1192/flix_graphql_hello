module FieldValue exposing (Value(..), blank, decode, encode, idsOf, toDocJson, toText)

{-| フィールドの値。**種類ごとに JSON の形が違う。**

全部を文字列で送ると CMS が正しく断る（richText は doc のオブジェクト、select は選択肢の 1 つ）。
画面の入力（全部文字列）と CMS の JSON の間の写しを、ここが 1 か所で持つ。

Html を作らない。テストできる。

-}

import Json.Decode as D
import Json.Encode as E
import Model exposing (FieldDef)


{-| 画面が持つ値。入力は文字列で受け、送る時に種類の形にする。
-}
type Value
    = Text String
    | Number String
    | Bool Bool
    | Choice String
    | Date String
    | Rich String
    | Choices (List String)
    | Ref String
    | Refs (List String)
    | Raw D.Value


{-| 複数なら前者、1 件なら後者。REFERENCE と ASSET が同じ形を取る
（どちらも「他の物の id」で、複数にできる）。
-}
manyOr : FieldDef -> Value -> Value -> Value
manyOr field asMany asOne =
    if field.many then
        asMany

    else
        asOne


{-| 空の値。新規作成の時の初期値。
-}
blank : FieldDef -> Value
blank field =
    case field.kind of
        "NUMBER" ->
            Number ""

        "BOOLEAN" ->
            Bool False

        "SELECT" ->
            if field.many then
                Choices []

            else
                Choice ""

        "REFERENCE" ->
            manyOr field (Refs []) (Ref "")

        "ASSET" ->
            manyOr field (Refs []) (Ref "")

        "DATE" ->
            Date ""

        "DATE_ONLY" ->
            Date ""

        "RICH_TEXT" ->
            Rich ""

        _ ->
            Text ""


{-| CMS に送る形にする。

  - richText は `{ type: "doc", content: [段落…] }`。空行で段落を分ける
  - 数値は数として送る（文字列だと断られる）
  - 空の値は `null` で送り、CMS 側でキーを消してもらう

-}
encode : Value -> E.Value
encode value =
    case value of
        Text "" ->
            E.null

        Text text ->
            E.string text

        Number "" ->
            E.null

        Number text ->
            String.toFloat text |> Maybe.map E.float |> Maybe.withDefault E.null

        Bool yes ->
            E.bool yes

        Choice "" ->
            E.null

        Choice choice ->
            E.string choice

        Choices [] ->
            E.null

        Choices choices ->
            E.list E.string choices

        Ref "" ->
            E.null

        Ref entryId ->
            E.string entryId

        Refs [] ->
            E.null

        Refs ids ->
            E.list E.string ids

        Date "" ->
            E.null

        Date text ->
            E.string text

        Rich "" ->
            E.null

        Rich raw ->
            -- doc の JSON をそのまま持っている。読めない物は空の doc にする（値を捨てない）。
            D.decodeString D.value raw |> Result.withDefault emptyDoc

        Raw raw ->
            raw


emptyDoc : E.Value
emptyDoc =
    E.object [ ( "type", E.string "doc" ), ( "content", E.list identity [] ) ]


{-| CMS から来た JSON を画面の値にする。読めない形は `Raw` で持ち、そのまま送り返す
（画面が知らない種類の値を壊さない）。
-}
decode : FieldDef -> D.Value -> Value
decode field raw =
    case field.kind of
        "NUMBER" ->
            D.decodeValue D.float raw
                |> Result.map (String.fromFloat >> Number)
                |> Result.withDefault (Number "")

        "BOOLEAN" ->
            D.decodeValue D.bool raw |> Result.map Bool |> Result.withDefault (Bool False)

        "SELECT" ->
            if field.many then
                D.decodeValue (D.list D.string) raw |> Result.map Choices |> Result.withDefault (Choices [])

            else
                D.decodeValue D.string raw |> Result.map Choice |> Result.withDefault (Choice "")

        "REFERENCE" ->
            decodeRefs field raw

        "ASSET" ->
            decodeRefs field raw

        "DATE" ->
            D.decodeValue D.string raw |> Result.map Date |> Result.withDefault (Date "")

        "DATE_ONLY" ->
            D.decodeValue D.string raw |> Result.map Date |> Result.withDefault (Date "")

        "RICH_TEXT" ->
            -- doc は編集器がそのまま扱うので、JSON の文字列で持つ。
            Rich (E.encode 0 raw)

        "TEXT" ->
            D.decodeValue D.string raw |> Result.map Text |> Result.withDefault (Raw raw)

        "TEXT_AREA" ->
            D.decodeValue D.string raw |> Result.map Text |> Result.withDefault (Raw raw)

        "SLUG" ->
            D.decodeValue D.string raw |> Result.map Text |> Result.withDefault (Raw raw)

        _ ->
            Raw raw


{-| 参照とメディアの値。**複数と 1 件で JSON の形が違う**（配列か文字列か）。
-}
decodeRefs : FieldDef -> D.Value -> Value
decodeRefs field raw =
    if field.many then
        D.decodeValue (D.list D.string) raw |> Result.map Refs |> Result.withDefault (Refs [])

    else
        D.decodeValue D.string raw |> Result.map Ref |> Result.withDefault (Ref "")


{-| 参照とメディアの今の中身。複数と 1 件を同じ形で読む。
-}
idsOf : Value -> List String
idsOf value =
    case value of
        Ref "" ->
            []

        Ref one ->
            [ one ]

        Refs ids ->
            ids

        _ ->
            []


{-| 編集器に渡す doc の JSON。空なら空の doc を渡す（属性が空だと編集器が黙る）。
-}
toDocJson : Value -> String
toDocJson value =
    case value of
        Rich "" ->
            E.encode 0 emptyDoc

        Rich raw ->
            raw

        _ ->
            E.encode 0 emptyDoc


{-| 入力欄に出す文字列。
-}
toText : Value -> String
toText value =
    case value of
        Text text ->
            text

        Number text ->
            text

        Bool _ ->
            ""

        Choice choice ->
            choice

        Choices choices ->
            String.join ", " choices

        Ref entryId ->
            entryId

        Refs ids ->
            String.join ", " ids

        Date text ->
            text

        Rich text ->
            text

        Raw _ ->
            ""
