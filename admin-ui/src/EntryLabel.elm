module EntryLabel exposing (byField, forRow)

{-| コンテンツ 1 件を人に見せる時の見出し。

**CMS に `titleField` がまだ無い**（docs/design/admin-ui-spec.md 10.2）。入るまで、
どの値を見出しにするかの決め方をここが持つ。参照のチップ・ボードのカード・一覧・
⌘K の候補が同じ決め方を使う（画面ごとに書くと、同じコンテンツが場所によって
違う名前で出る）。

Html を作らない。テストできる。

-}

import Dict exposing (Dict)
import Json.Decode as D
import Model exposing (EntryRow, FieldDef)


{-| 型が分かる時。**最初のテキストのフィールド**を使う。

中身から適当に拾うと、参照の id（`author` の値）が先に来て id が並ぶ（実際に並んだ）。

-}
byField : List FieldDef -> EntryRow -> String
byField fields row =
    fields
        |> List.filter (\field -> field.kind == "TEXT")
        |> List.head
        |> Maybe.andThen
            (\field ->
                D.decodeValue (D.field field.apiId D.string) row.fields
                    |> Result.toMaybe
                    |> Maybe.andThen nonEmpty
            )
        |> Maybe.withDefault ("（無題）" ++ String.right 6 row.id)


{-| 型が分からない時（参照先の一覧など）。中身の最初の短い文字列を使う。
-}
forRow : EntryRow -> String
forRow row =
    D.decodeValue (D.dict D.value) row.fields
        |> Result.withDefault Dict.empty
        |> preferNamed
        |> List.filterMap (D.decodeValue D.string >> Result.toMaybe)
        |> List.filter (\value -> not (String.isEmpty value) && String.length value < 120 && not (looksLikeId value))
        |> List.head
        |> Maybe.withDefault row.id


{-| 見出しらしいキーを先に見る。Dict は名前順に並ぶので、これが無いと
`author` のような早い名前が勝つ。

**`name` を `title` より先に見る。** 著者のように両方持つ型では `title` が肩書で、
名前ではない（実際に著者が「テクニカルライター」と出た）。`title` しか無い型
（ブログ）はそのまま `title` が選ばれる。

-}
preferNamed : Dict String D.Value -> List D.Value
preferNamed values =
    let
        named : List D.Value
        named =
            [ "name", "title", "label" ] |> List.filterMap (\key -> Dict.get key values)
    in
    named ++ Dict.values values


{-| 参照の値のような id は見出しにしない（12 桁の 16 進）。
-}
looksLikeId : String -> Bool
looksLikeId value =
    String.length value == 12 && String.all Char.isHexDigit value


nonEmpty : String -> Maybe String
nonEmpty value =
    if String.isEmpty value then
        Nothing

    else
        Just value
