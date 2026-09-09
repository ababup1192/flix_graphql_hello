module FilterTest exposing (suite)

{-| 絞り込みの条件。URL との往復と、種類ごとに出す演算子。
-}

import Expect
import Filter
import Model exposing (ContentTypeDetail, FieldDef)
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Filter"
        [ describe "URL との往復"
            [ test "条件が無ければ空" <|
                \_ -> Filter.encode [] |> Expect.equal ""
            , test "空を読むと条件が無い" <|
                \_ -> Filter.decode "" |> Expect.equal []
            , test "1 つの条件が往復する" <|
                \_ ->
                    let
                        conditions : List Filter.Condition
                        conditions =
                            [ { apiId = "title", op = "CONTAINS", value = "移行" } ]
                    in
                    Filter.encode conditions |> Filter.decode |> Expect.equal conditions
            , test "区切りの文字が値に入っていても往復する" <|
                \_ ->
                    let
                        conditions : List Filter.Condition
                        conditions =
                            [ { apiId = "title", op = "CONTAINS", value = "a:b~c,d" }
                            , { apiId = "updatedAt", op = "GTE", value = "2026-01-01" }
                            ]
                    in
                    Filter.encode conditions |> Filter.decode |> Expect.equal conditions
            , test "壊れた文字列は捨てる" <|
                \_ -> Filter.decode "title,:EQ:x,a:B:c" |> Expect.equal [ { apiId = "a", op = "B", value = "c" } ]
            ]
        , describe "種類ごとの演算子"
            [ test "テキストは部分一致から始める" <|
                \_ ->
                    Filter.opsFor (field "TEXT" False)
                        |> List.map Tuple.first
                        |> Expect.equal [ "CONTAINS", "EQ", "STARTS_WITH", "IS_NULL" ]
            , test "複数の物は「含む」だけ（CMS が他を断る）" <|
                \_ ->
                    Filter.opsFor (field "REFERENCE" True)
                        |> List.map Tuple.first
                        |> Expect.equal [ "ARRAY_CONTAINS", "IS_NULL" ]
            , test "日時は範囲で絞れる" <|
                \_ ->
                    Filter.opsFor (field "DATE" False)
                        |> List.map Tuple.first
                        |> Expect.equal [ "GTE", "LTE", "EQ", "IS_NULL" ]
            , test "日付だけの物も日時と同じ" <|
                \_ ->
                    Filter.opsFor (field "DATE_ONLY" False)
                        |> List.map Tuple.first
                        |> Expect.equal [ "GTE", "LTE", "EQ", "IS_NULL" ]
            , test "リッチエディタは未入力だけ（本文は検索窓に任せる）" <|
                \_ ->
                    Filter.opsFor (field "RICH_TEXT" False)
                        |> List.map Tuple.first
                        |> Expect.equal [ "IS_NULL" ]
            ]
        , describe "演算子の言葉"
            [ test "値の後ろに置いて文が終わる" <|
                \_ ->
                    [ "CONTAINS", "EQ", "STARTS_WITH", "IS_NULL" ]
                        |> List.map Filter.opText
                        |> Expect.equal [ "を含む", "と一致する", "で始まる", "未入力" ]
            , test "日時は大小を前後で言う" <|
                \_ ->
                    Filter.opsFor (field "DATE" False)
                        |> List.map Tuple.second
                        |> Expect.equal [ "以降", "以前", "と一致する", "未入力" ]
            , test "数は大小のまま言う" <|
                \_ ->
                    Filter.opsFor (field "NUMBER" False)
                        |> List.map Tuple.second
                        |> Expect.equal [ "と一致する", "以上", "以下", "より大きい", "より小さい", "未入力" ]
            , test "真偽は「である」" <|
                \_ -> Filter.opTextFor (field "BOOLEAN" False) "EQ" |> Expect.equal "である"
            ]
        , describe "どの型も持つ日時"
            [ test "更新日時・作成日時・公開日時が項目の後ろに付く" <|
                \_ ->
                    Filter.filterable (detailOf [ field "TEXT" False ])
                        |> List.map .apiId
                        |> Expect.equal [ "title", "updatedAt", "createdAt", "publishedAt" ]
            , test "大小しか出さない（DateTimeFilter が等値と未入力を持たない）" <|
                \_ ->
                    Filter.opsFor (field "SYSTEM_DATE" False)
                        |> List.map Tuple.first
                        |> Expect.equal [ "GTE", "LTE", "GT", "LT" ]
            , test "where の直下で受ける物か分かる" <|
                \_ ->
                    [ "updatedAt", "createdAt", "publishedAt", "title" ]
                        |> List.map Filter.isSystem
                        |> Expect.equal [ True, True, True, False ]
            , test "日付で入れさせる" <|
                \_ -> Filter.inputFor (field "SYSTEM_DATE" False) "GTE" |> Expect.equal Filter.DateInput
            ]
        , describe "値の入れ方"
            [ test "未入力は値を取らない" <|
                \_ -> Filter.inputFor (field "TEXT" False) "IS_NULL" |> Expect.equal Filter.NoInput
            , test "参照は参照先の型を持って返る" <|
                \_ ->
                    Filter.inputFor { blank | kind = "REFERENCE", targetTypeId = Just "7" } "EQ"
                        |> Expect.equal (Filter.EntryInput "7")
            , test "真偽は はい / いいえ" <|
                \_ -> Filter.inputFor (field "BOOLEAN" False) "EQ" |> Expect.equal Filter.BoolInput
            ]
        , describe "出せる項目"
            [ test "入れ子の形が決まらない物は出さない" <|
                \_ ->
                    Filter.filterable (detailOf [ field "TEXT" False, field "OBJECT" False, field "BLOCKS" True ])
                        |> List.filter (\f -> not (Filter.isSystem f.apiId))
                        |> List.map .kind
                        |> Expect.equal [ "TEXT" ]
            ]
        ]


detailOf : List FieldDef -> ContentTypeDetail
detailOf fields =
    { id = "1"
    , apiId = "blogs"
    , name = "ブログ"
    , kind = "COLLECTION"
    , previewUrl = ""
    , singular = "Blog"
    , icon = "list"
    , fields = fields
    }


field : String -> Bool -> FieldDef
field kind many =
    { blank | kind = kind, many = many }


blank : FieldDef
blank =
    { id = "1"
    , apiId = "title"
    , name = "タイトル"
    , kind = "TEXT"
    , many = False
    , required = False
    , unique = False
    , localized = False
    , targetTypeId = Nothing
    , config = { maxLength = Nothing, sourceField = Nothing, min = Nothing, max = Nothing, integer = Nothing, options = [] }
    }
