module Filter exposing
    ( Condition
    , Input(..)
    , decode
    , encode
    , filterable
    , inputFor
    , isSystem
    , needsValue
    , opText
    , opTextFor
    , opsFor
    )

{-| 一覧の絞り込みの条件。

**フィールドの名前ではなく種類で決める。** 以前は `tags` という apiId のフィールドだけを
特別扱いして固定のセレクトを出していた。`categories` や `relatedPosts` と名付けた型では
絞り込みが 1 つも出ず、参照が 3 本ある型でも 1 本しか絞れなかった。
調べた 9 社に「特定の名前のフィールド」を見る例は 1 つも無い。

条件は**いくつでも足せる**。CMS の `EntryWhere.fields` は元から配列で受けるのに、
画面が常に 1 要素しか入れていなかった。

**更新日時・作成日時・公開日時は 1 つの入れ物に混ぜて持つ。** CMS はこの 3 つを
`fields` の中ではなく `EntryWhere` の直下（`DateTimeFilter`）で受けるが、分けて持つ必要は
無い。3 つとも `Naming.reservedFieldApiIds` にあり、**型のフィールドには付けられない名前**
なので `apiId` がぶつからない。分かれるのは CMS に写す所（`Queries.whereOf`）だけで、
URL・チップ・画面はどれも 1 種類の条件として扱える。

**`DateTimeFilter` は大小しか持たない**（gt / gte / lt / lte）。`EQ` と `IS_NULL` を
この 3 つに出すと、選べるのに CMS へ写せない条件になる。だから種類を `DATE` と分けている。

Html を作らない。テストできる。

-}

import Model exposing (ContentTypeDetail, FieldDef)
import Url


{-| 条件 1 つ。`apiId` は型のフィールドか、下の `systemFields` の物。
-}
type alias Condition =
    { apiId : String
    , op : String
    , value : String
    }


{-| 値をどう入れさせるか。**種類で決まる。**
-}
type Input
    = TextInput
    | NumberInput
    | DateInput
    | BoolInput
    | ChoiceInput (List String)
    | EntryInput String
    | NoInput



-- URL


{-| URL の 1 つの query に畳む。

区切りは `,` と `:`。**どちらも percent encode が必ず変える文字**なので、値の中に
そのまま出てこない。`~` は encode されずに残るので区切りに使えない（実際に往復が壊れた）。
apiId は lowerCamel、演算子は大文字と `_` だけなので、こちらにも出てこない。

-}
encode : List Condition -> String
encode conditions =
    conditions
        |> List.map (\c -> c.apiId ++ ":" ++ c.op ++ ":" ++ Url.percentEncode c.value)
        |> String.join ","


decode : String -> List Condition
decode raw =
    if String.isEmpty raw then
        []

    else
        raw
            |> String.split ","
            |> List.filterMap
                (\part ->
                    case String.split ":" part of
                        [ apiId, op, value ] ->
                            if String.isEmpty apiId || String.isEmpty op then
                                Nothing

                            else
                                Just { apiId = apiId, op = op, value = Url.percentDecode value |> Maybe.withDefault value }

                        _ ->
                            Nothing
                )



-- 種類ごとの決め


{-| その種類で使える演算子。**CMS が実際に受ける物だけ**を出す
（`EntryFilterSql` が SQL に落とせる組。落ちない物は INVALID で断られる）。

複数の値を持つフィールドは `ARRAY_CONTAINS` しか通らない。

-}
opsFor : FieldDef -> List ( String, String )
opsFor field =
    if field.many then
        [ ( "ARRAY_CONTAINS", opText "ARRAY_CONTAINS" ), ( "IS_NULL", opText "IS_NULL" ) ]

    else
        case field.kind of
            "TEXT" ->
                textOps

            "TEXT_AREA" ->
                textOps

            "SLUG" ->
                textOps

            "NUMBER" ->
                [ ( "EQ", opText "EQ" )
                , ( "GTE", opText "GTE" )
                , ( "LTE", opText "LTE" )
                , ( "GT", opText "GT" )
                , ( "LT", opText "LT" )
                , ( "IS_NULL", opText "IS_NULL" )
                ]

            "DATE" ->
                dateOps

            "DATE_ONLY" ->
                dateOps

            "SYSTEM_DATE" ->
                -- `DateTimeFilter` は大小しか持たない。等値と未入力は写せない。
                [ ( "GTE", dateText "GTE" )
                , ( "LTE", dateText "LTE" )
                , ( "GT", dateText "GT" )
                , ( "LT", dateText "LT" )
                ]

            "BOOLEAN" ->
                [ ( "EQ", "である" ), ( "IS_NULL", opText "IS_NULL" ) ]

            "SELECT" ->
                [ ( "EQ", opText "EQ" ), ( "IS_NULL", opText "IS_NULL" ) ]

            "REFERENCE" ->
                [ ( "EQ", opText "EQ" ), ( "IS_NULL", opText "IS_NULL" ) ]

            "ASSET" ->
                [ ( "IS_NULL", opText "IS_NULL" ) ]

            "RICH_TEXT" ->
                -- 本文の中は検索窓に任せる（`Query.entries` の `search`）。
                [ ( "IS_NULL", opText "IS_NULL" ) ]

            _ ->
                [ ( "IS_NULL", opText "IS_NULL" ) ]


textOps : List ( String, String )
textOps =
    [ ( "CONTAINS", opText "CONTAINS" )
    , ( "EQ", opText "EQ" )
    , ( "STARTS_WITH", opText "STARTS_WITH" )
    , ( "IS_NULL", opText "IS_NULL" )
    ]


dateOps : List ( String, String )
dateOps =
    [ ( "GTE", dateText "GTE" )
    , ( "LTE", dateText "LTE" )
    , ( "EQ", dateText "EQ" )
    , ( "IS_NULL", opText "IS_NULL" )
    ]


{-| その項目での演算子の言葉。**種類で言い方が変わる**（日時は「以降」、数は「以上」）。
チップは必ずこちらを使う。
-}
opTextFor : FieldDef -> String -> String
opTextFor field op =
    opsFor field
        |> List.filter (\( key, _ ) -> key == op)
        |> List.head
        |> Maybe.map Tuple.second
        |> Maybe.withDefault (opText op)


{-| 演算子の言葉。**値の後ろに置いて文が終わる述語**にする（言い回しは microCMS の
管理画面に合わせた）。だからチップは「項目 → 値 → 演算子」の順に描く。

「タイトル 移行 を含む」「読了目安 5 以上」「公開日 2026-08-10 以降」「本文 未入力」。

-}
opText : String -> String
opText op =
    case op of
        "EQ" ->
            "と一致する"

        "CONTAINS" ->
            "を含む"

        "STARTS_WITH" ->
            "で始まる"

        "ARRAY_CONTAINS" ->
            "を含む"

        "GT" ->
            "より大きい"

        "GTE" ->
            "以上"

        "LT" ->
            "より小さい"

        "LTE" ->
            "以下"

        "IS_NULL" ->
            "未入力"

        "IN" ->
            "のいずれか"

        other ->
            other


{-| 日時での言い方。大小を「大きい / 小さい」ではなく前後で言う。
-}
dateText : String -> String
dateText op =
    case op of
        "GTE" ->
            "以降"

        "LTE" ->
            "以前"

        "GT" ->
            "より後"

        "LT" ->
            "より前"

        other ->
            opText other


{-| 値の入れ方。参照は**参照先の型 id**を持って返す（候補を引くのに要る）。
-}
inputFor : FieldDef -> String -> Input
inputFor field op =
    if not (needsValue op) then
        NoInput

    else
        case field.kind of
            "NUMBER" ->
                NumberInput

            "DATE" ->
                DateInput

            "DATE_ONLY" ->
                DateInput

            "SYSTEM_DATE" ->
                DateInput

            "BOOLEAN" ->
                BoolInput

            "SELECT" ->
                ChoiceInput field.config.options

            "REFERENCE" ->
                field.targetTypeId |> Maybe.map EntryInput |> Maybe.withDefault TextInput

            _ ->
                TextInput


{-| 値が要るか。「未入力」だけは値を取らない。
-}
needsValue : String -> Bool
needsValue op =
    op /= "IS_NULL"


{-| 絞り込みに出せる項目。型のフィールド ＋ どの型も持つ日時。

**入れ子の形が決まらない物は出さない**（OBJECT / BLOCKS。調べた各社も component / union を
外している）。

-}
filterable : ContentTypeDetail -> List FieldDef
filterable detail =
    (detail.fields |> List.filter (\field -> not (List.member field.kind [ "OBJECT", "BLOCKS" ])))
        ++ systemFields


{-| どの型も持つ日時。CMS の受け口が違うので、種類を `DATE` と分けてある。
-}
systemFields : List FieldDef
systemFields =
    [ systemField "updatedAt" "更新日時"
    , systemField "createdAt" "作成日時"
    , systemField "publishedAt" "公開日時"
    ]


systemField : String -> String -> FieldDef
systemField apiId name =
    { id = apiId
    , apiId = apiId
    , name = name
    , kind = "SYSTEM_DATE"
    , many = False
    , required = False
    , unique = False
    , localized = False
    , targetTypeId = Nothing
    , config = { maxLength = Nothing, sourceField = Nothing, min = Nothing, max = Nothing, integer = Nothing, options = [] }
    }


{-| `EntryWhere` の直下で受ける物か。`Queries` がここで振り分ける。
-}
isSystem : String -> Bool
isSystem apiId =
    List.any (\field -> field.apiId == apiId) systemFields
