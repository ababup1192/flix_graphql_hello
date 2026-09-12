module ApiShape exposing
    ( Argument
    , Filter
    , Operator
    , Order
    , Returned
    , Shape
    , decoder
    , insertOrderBy
    , insertWhere
    , placeholder
    , query
    , splitLeaf
    )

{-| コンテンツ API の「この API の形」。**何で絞れるか・何の順に並ぶか・何が返るか**を、
introspection から表の行にする。

description はサーバが埋めている途中なので、**無い前提で読む**（null は空欄）。

-}

import Json.Decode as D


{-| 型 1 つの表。
-}
type alias Shape =
    { filters : List Filter
    , orders : List Order
    , returns : List Returned
    , arguments : List Argument
    }


{-| 絞り込みの 1 行。フィールド名と、そのフィールドに掛けられる演算子。
-}
type alias Filter =
    { field : String
    , operators : List Operator
    }


type alias Operator =
    { operator : String
    , leaf : String
    , typeText : String
    , description : String
    }


type alias Order =
    { name : String
    , description : String
    }


{-| 返るフィールド 1 つ。`children` は RichText / Asset を 1 段だけ開いた物。
-}
type alias Returned =
    { name : String
    , typeText : String
    , description : String
    , children : List Child
    }


{-| 1 段だけ開いた中のフィールド。**それ以上は開かない**（RichText の中の links の中、までは見せない）。
-}
type alias Child =
    { name : String
    , typeText : String
    , description : String
    }


type alias Argument =
    { name : String
    , typeText : String
    , description : String
    , defaultValue : String
    }



-- introspection


{-| 型 1 つ分の introspection。`singular` は `Blog`、`apiId` は `blogs`。
-}
query : { singular : String, apiId : String } -> String
query names =
    String.join "\n"
        [ "query apiShape {"
        , "  where: __type(name: \"" ++ names.singular ++ "Where\") { inputFields { name description type { ...T } } }"
        , "  orderBy: __type(name: \"" ++ names.singular ++ "OrderBy\") { enumValues { name description } }"
        , "  entry: __type(name: \"" ++ names.singular ++ "\") { fields { name description type { ...T } } }"
        , "  richText: __type(name: \"RichText\") { fields { name description type { ...T } } }"
        , "  asset: __type(name: \"Asset\") { fields { name description type { ...T } } }"
        , "  root: __type(name: \"Query\") { fields { name args { name description defaultValue type { ...T } } } }"
        , "}"
        , "fragment T on __Type { kind name ofType { kind name ofType { kind name ofType { kind name } } } }"
        ]


{-| 応答の全体（`data` から）を読む。`apiId` は引数を引く root field の名前。
-}
decoder : String -> D.Decoder Shape
decoder apiId =
    D.field "data"
        (D.map4 Shape
            (D.field "where" (nullable (D.field "inputFields" (D.list leafDecoder))) |> D.map fold)
            (D.field "orderBy" (nullable (D.field "enumValues" (D.list orderDecoder))))
            (D.map3 returns
                (D.field "entry" (nullable (D.field "fields" (D.list returnedDecoder))))
                (D.field "richText" (nullable (D.field "fields" (D.list childDecoder))))
                (D.field "asset" (nullable (D.field "fields" (D.list childDecoder))))
            )
            (D.field "root" (nullable (D.field "fields" (D.list rootFieldDecoder))) |> D.map (argumentsOf apiId))
        )


{-| `__type` は無い型なら null。**無くても表を出す**（サーバの型名の付け方が変わっても壊れない）。
-}
nullable : D.Decoder (List a) -> D.Decoder (List a)
nullable inner =
    D.oneOf [ D.null [], inner ]


text : String -> D.Decoder String
text name =
    D.oneOf [ D.field name D.string, D.succeed "" ]


leafDecoder : D.Decoder ( String, Operator )
leafDecoder =
    D.map3
        (\name typeText description ->
            let
                ( field, operator ) =
                    splitLeaf name
            in
            ( field, { operator = operator, leaf = name, typeText = typeText, description = description } )
        )
        (D.field "name" D.string)
        (D.field "type" typeDecoder)
        (text "description")


orderDecoder : D.Decoder Order
orderDecoder =
    D.map2 Order (D.field "name" D.string) (text "description")


returnedDecoder : D.Decoder Returned
returnedDecoder =
    D.map3 (\name typeText description -> Returned name typeText description [])
        (D.field "name" D.string)
        (D.field "type" typeDecoder)
        (text "description")


childDecoder : D.Decoder Child
childDecoder =
    D.map3 Child
        (D.field "name" D.string)
        (D.field "type" typeDecoder)
        (text "description")


rootFieldDecoder : D.Decoder ( String, List Argument )
rootFieldDecoder =
    D.map2 Tuple.pair
        (D.field "name" D.string)
        (D.field "args" (D.list argumentDecoder))


argumentDecoder : D.Decoder Argument
argumentDecoder =
    D.map4 Argument
        (D.field "name" D.string)
        (D.field "type" typeDecoder)
        (text "description")
        (text "defaultValue")


{-| `ofType` の入れ子を SDL の綴り（`[String!]!`）にする。
-}
typeDecoder : D.Decoder String
typeDecoder =
    D.map3
        (\kind name inner ->
            case ( kind, inner ) of
                ( "NON_NULL", Just of_ ) ->
                    of_ ++ "!"

                ( "LIST", Just of_ ) ->
                    "[" ++ of_ ++ "]"

                _ ->
                    name
        )
        (D.field "kind" D.string)
        (text "name")
        (D.oneOf [ D.field "ofType" (D.lazy (\_ -> D.map Just typeDecoder)), D.succeed Nothing ])



-- 表の行にする


{-| 同じフィールドの演算子を 1 行に畳む。**出てきた順を保つ**（id が先、フィールドは定義の順）。
-}
fold : List ( String, Operator ) -> List Filter
fold leaves =
    List.foldl
        (\( field, operator ) acc ->
            if List.any (\group -> group.field == field) acc then
                List.map
                    (\group ->
                        if group.field == field then
                            { group | operators = group.operators ++ [ operator ] }

                        else
                            group
                    )
                    acc

            else
                acc ++ [ { field = field, operators = [ operator ] } ]
        )
        []
        leaves


{-| `title_contains` → `( "title", "contains" )`。参照の `author_id_eq` は `( "author", "id_eq" )`。

WhyNot: 最後の `_` で切らない。フィールド名にも `_` が入るので、演算子の一覧と突き合わせる。

-}
splitLeaf : String -> ( String, String )
splitLeaf name =
    let
        matching : Maybe String
        matching =
            operators |> List.filter (\op -> String.endsWith ("_" ++ op) name) |> List.head
    in
    case matching of
        Just op ->
            ( String.dropRight (String.length op + 1) name, op )

        Nothing ->
            ( name, "" )


{-| 長い物を先に置く（`id_eq` は `eq` より先に当てる）。
-}
operators : List String
operators =
    [ "id_eq", "id_in", "isNull", "startsWith", "contains", "eq", "in", "gte", "gt", "lte", "lt" ]


{-| 返る物。RichText / Asset のフィールドはその型の中身を 1 段だけ持たせる。
-}
returns : List Returned -> List Child -> List Child -> List Returned
returns entry richText asset =
    List.map
        (\field ->
            case baseName field.typeText of
                "RichText" ->
                    { field | children = richText }

                "Asset" ->
                    { field | children = asset }

                _ ->
                    field
        )
        entry


{-| `[Asset!]!` → `Asset`。
-}
baseName : String -> String
baseName typeText =
    String.filter (\c -> c /= '[' && c /= ']' && c /= '!') typeText


argumentsOf : String -> List ( String, List Argument ) -> List Argument
argumentsOf apiId fields =
    fields
        |> List.filter (\( name, _ ) -> name == apiId)
        |> List.head
        |> Maybe.map Tuple.second
        |> Maybe.withDefault []



-- query に差し込む


{-| 演算子の値の仮の形。型で決める（文字列は `""`、配列は `[]`）。
-}
placeholder : String -> String
placeholder typeText =
    if String.startsWith "[" typeText then
        "[]"

    else
        case baseName typeText of
            "Int" ->
                "0"

            "Float" ->
                "0"

            "Boolean" ->
                "true"

            _ ->
                "\"\""


{-| `where: { … }` の頭に葉を 1 つ足す。無ければ where ごと、root field の引数の頭に足す。
-}
insertWhere : String -> String -> String -> String
insertWhere apiId leaf document =
    case indexOf "where: {" document of
        Just at ->
            let
                head : Int
                head =
                    at + 8
            in
            String.left head document ++ " " ++ leaf ++ "," ++ String.dropLeft head document

        Nothing ->
            insertArgument apiId ("where: { " ++ leaf ++ " }") document


{-| `orderBy: X` を置く。既にあれば値を置き換える。
-}
insertOrderBy : String -> String -> String -> String
insertOrderBy apiId value document =
    case indexOf "orderBy: " document of
        Just at ->
            let
                from : Int
                from =
                    at + 9

                rest : String
                rest =
                    String.dropLeft from document

                end : Int
                end =
                    rest |> String.toList |> takeWhileCount (\c -> c /= ',' && c /= ')' && c /= '\n')
            in
            String.left from document ++ value ++ String.dropLeft end rest

        Nothing ->
            insertArgument apiId ("orderBy: " ++ value) document


{-| root field の引数の頭に 1 つ足す。`blogs(` が無ければ `blogs {` を `blogs(…) {` にする。
どちらも無ければ触らない（1 件の query に一覧の引数は付かない）。

WhyNot: 文書の頭から探さない。操作名（`query blogs {`）が root field と同じ綴りで先に当たる。

-}
insertArgument : String -> String -> String -> String
insertArgument apiId argument document =
    let
        opening : Int
        opening =
            indexOf "{" document |> Maybe.map ((+) 1) |> Maybe.withDefault 0

        body : String
        body =
            String.dropLeft opening document

        put : Int -> String -> String
        put head inserted =
            String.left opening document ++ String.left head body ++ inserted ++ String.dropLeft head body
    in
    case indexOf (apiId ++ "(") body of
        Just at ->
            put (at + String.length apiId + 1) (argument ++ ", ")

        Nothing ->
            case indexOf (apiId ++ " {") body of
                Just at ->
                    put (at + String.length apiId) ("(" ++ argument ++ ")")

                Nothing ->
                    document


indexOf : String -> String -> Maybe Int
indexOf needle haystack =
    String.indexes needle haystack |> List.head


takeWhileCount : (Char -> Bool) -> List Char -> Int
takeWhileCount keep chars =
    case chars of
        c :: rest ->
            if keep c then
                1 + takeWhileCount keep rest

            else
                0

        [] ->
            0
