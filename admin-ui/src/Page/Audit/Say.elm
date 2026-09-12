module Page.Audit.Say exposing
    ( Change
    , FieldRow
    , Piece(..)
    , Sentence
    , Sheet(..)
    , orderWith
    , sentence
    , sheet
    , toText
    )

{-| 監査の行を人の文にする。Html は作らない（描くのは `Page.Audit`）。

畳んだ行は 1 文（`sentence`）、開いた行は action ごとの型紙（`sheet`）。
action は CMS の `Audit.rowOf` の 24 種で、全部に文を持つ。知らない action は action と対象をそのまま出す。

名前は detail に入っている物だけを使う。detail に無ければ id のまま出し、**嘘の名前を作らない**。
detail は変更前（`before`）しか持たないので、`Changes` は「変わった」ではなく「変更前」として出す
（`project.visibility_changed` だけが `before` と `after` を両方持つ）。

-}

import Array exposing (Array)
import Json.Decode as D
import Json.Encode as E
import Model exposing (AuditRow)
import Time
import Ui.Bytes
import Ui.DateTime as DateTime


{-| 畳んだ行の文。`TargetLink` は対象（型・entry）への手掛かりで、リンクにするかは描く側が決める。
-}
type Piece
    = Text String
    | Strong String
    | TargetLink String


type alias Sentence =
    List Piece


{-| 開いた行の型紙。
-}
type Sheet
    = Changes (List Change)
    | Order { before : List String, after : Maybe (List String), moved : List String }
    | FieldTable (List FieldRow)
    | Facts (List ( String, String ))
    | Nothing_


{-| 1 つのキーの変更前と、あれば変更後。
-}
type alias Change =
    { key : String, before : String, after : Maybe String }


{-| 消えたフィールド 1 本。子は apiId を `親.子` にして同じ表に並べる。
-}
type alias FieldRow =
    { apiId : String, name : String, kind : String, required : Bool, config : String }



-- 文


sentence : Time.Zone -> AuditRow -> Sentence
sentence zone row =
    let
        detail : D.Value
        detail =
            row.detail

        ( typeOfField, fieldName ) =
            splitField row.targetId
    in
    case row.action of
        "member.invited" ->
            Strong row.targetId
                :: (case string [ "role" ] detail of
                        Just role ->
                            [ Text " を招待した（権限: ", Strong (roleText role), Text "）" ]

                        Nothing ->
                            [ Text " を招待した" ]
                   )

        "member.role_changed" ->
            Strong row.targetId
                :: (case string [ "role" ] detail of
                        Just role ->
                            [ Text " の権限を ", Strong (roleText role), Text " にした" ]

                        Nothing ->
                            [ Text " の権限を変更した" ]
                   )

        "member.removed" ->
            [ Text "メンバー ", Strong row.targetId, Text " を外した" ]

        "invitation.cancelled" ->
            [ Text "招待 ", Strong row.targetId, Text " を取り消した" ]

        "api_key.created" ->
            [ Text "API キー ", Strong (Maybe.withDefault row.targetId (string [ "name" ] detail)), Text " を発行した" ]

        "api_key.revoked" ->
            [ Text "API キー ", Strong row.targetId, Text " を失効した" ]

        "type.created" ->
            [ Text "API ", TargetLink row.targetId, Text " を作成した" ]

        "type.updated" ->
            [ Text "API ", TargetLink row.targetId, Text " を変更した" ]

        "type.deleted" ->
            [ Text "API ", TargetLink row.targetId ]
                ++ verb (Maybe.map (\n -> String.fromInt n ++ " フィールド") (count [ "before", "fields" ] detail)) "を削除した"
                ++ (case int [ "purgedEntries" ] detail of
                        Just purged ->
                            if purged > 0 then
                                [ Text ("。削除済みのコンテンツ " ++ String.fromInt purged ++ " 件も消えた") ]

                            else
                                []

                        Nothing ->
                            []
                   )

        "field.added" ->
            [ TargetLink typeOfField, Text " に ", Strong fieldName, Text " を追加した" ]

        "field.updated" ->
            [ TargetLink typeOfField, Text " の ", Strong fieldName, Text " を変更した" ]

        "field.removed" ->
            [ TargetLink typeOfField, Text " の ", Strong fieldName, Text " を削除した" ]

        "fields.reordered" ->
            [ Text "API ", TargetLink row.targetId, Text " のフィールドを並べ替えた" ]

        "project.visibility_changed" ->
            case ( string [ "before" ] detail, string [ "after" ] detail ) of
                ( Just before, Just after ) ->
                    [ Text "公開範囲を ", Strong (visibilityText before), Text " → ", Strong (visibilityText after), Text " にした" ]

                _ ->
                    [ Text "公開範囲を変更した" ]

        "webhook.created" ->
            webhook [] row "を作成した"

        "webhook.updated" ->
            webhook [ "before" ] row "を変更した"

        "webhook.deleted" ->
            webhook [ "before" ] row "を削除した"

        "webhook.redelivered" ->
            [ Text "Webhook の配信 ", Strong row.targetId, Text " を再送した" ]

        "asset.confirmed" ->
            asset [] row "をアップロードした"

        "asset.deleted" ->
            [ Text "メディア ", Strong row.targetId, Text " を削除した" ]

        "audit.exported" ->
            [ Text "監査ログを "
            , Strong (String.toUpper row.targetId)
            , Text " でエクスポートした"
            ]
                ++ (case int [ "count" ] detail of
                        Just n ->
                            [ Text ("（" ++ String.fromInt n ++ " 件）") ]

                        Nothing ->
                            []
                   )

        "entry.unpublished" ->
            entry row ++ [ Text " の公開を終えた" ] ++ paren (version detail)

        "entry.deleted" ->
            entry row ++ [ Text " を削除した" ] ++ paren (version detail)

        "entry.published" ->
            entry row
                ++ [ Text " を予約どおり公開した" ]
                ++ paren
                    (joinSome "、"
                        [ version detail
                        , string [ "scheduledFor" ] detail |> Maybe.map (\at -> "予約は " ++ DateTime.formatLocal zone at ++ " " ++ DateTime.zoneAbbr zone at)
                        ]
                    )

        _ ->
            [ Text row.action, Text "（", Text (row.targetKind ++ " " ++ row.targetId), Text "）" ]


{-| 文を平文に（title 属性とテスト用）。
-}
toText : Sentence -> String
toText pieces =
    pieces
        |> List.map
            (\piece ->
                case piece of
                    Text text ->
                        text

                    Strong text ->
                        text

                    TargetLink text ->
                        text
            )
        |> String.concat


{-| `Webhook 名前（host）を…`。名前が無ければ公開 id。
-}
webhook : List String -> AuditRow -> String -> Sentence
webhook path row did =
    [ Text "Webhook ", Strong (Maybe.withDefault row.targetId (string (path ++ [ "name" ]) row.detail)) ]
        ++ verb (string (path ++ [ "url", "host" ]) row.detail) did


{-| `メディア id（mime、大きさ）を…`。
-}
asset : List String -> AuditRow -> String -> Sentence
asset path row did =
    [ Text "メディア ", Strong row.targetId ]
        ++ verb (joinSome "、" [ string (path ++ [ "mime" ]) row.detail, int (path ++ [ "size" ]) row.detail |> Maybe.map Ui.Bytes.human ]) did


{-| 括弧の補足と述語。補足が無ければ対象との間に空白を、あれば全角の括弧のまま続ける。
-}
verb : Maybe String -> String -> Sentence
verb inner did =
    case inner of
        Just _ ->
            paren inner ++ [ Text did ]

        Nothing ->
            [ Text (" " ++ did) ]


{-| `API 型 のコンテンツ id`。API が detail に無ければコンテンツだけ。
-}
entry : AuditRow -> Sentence
entry row =
    (case string [ "typeApiId" ] row.detail of
        Just typeApiId ->
            [ Text "API ", Strong typeApiId, Text " のコンテンツ " ]

        Nothing ->
            [ Text "コンテンツ " ]
    )
        ++ [ TargetLink row.targetId ]


version : D.Value -> Maybe String
version detail =
    int [ "version" ] detail |> Maybe.map (\n -> "v" ++ String.fromInt n)


{-| 全角の括弧で包む。中身が無ければ何も出さない。
-}
paren : Maybe String -> Sentence
paren inner =
    case inner of
        Just text ->
            [ Text ("（" ++ text ++ "）") ]

        Nothing ->
            []


joinSome : String -> List (Maybe String) -> Maybe String
joinSome sep parts =
    case List.filterMap identity parts of
        [] ->
            Nothing

        some ->
            Just (String.join sep some)


{-| `型.フィールド` を分ける。点が無ければ全部を型として扱う。
-}
splitField : String -> ( String, String )
splitField targetId =
    case String.split "." targetId of
        typeApiId :: rest ->
            ( typeApiId, String.join "." rest )

        [] ->
            ( targetId, "" )



-- 型紙


sheet : AuditRow -> Sheet
sheet row =
    let
        detail : D.Value
        detail =
            row.detail
    in
    case row.action of
        "member.invited" ->
            facts [ ( "権限", string [ "role" ] detail |> Maybe.map roleText ) ]

        "member.role_changed" ->
            facts [ ( "権限", string [ "role" ] detail |> Maybe.map roleText ) ]

        "api_key.created" ->
            facts [ ( "名前", string [ "name" ] detail ) ]

        "type.updated" ->
            Changes (changesOf [ "before" ] typeKeys detail)

        "type.deleted" ->
            FieldTable (fieldRows "" (D.decodeValue (D.at [ "before", "fields" ] (D.list D.value)) detail |> Result.withDefault []))

        "field.updated" ->
            Changes (changesOf [ "before" ] fieldKeys detail)

        "field.removed" ->
            FieldTable (fieldRows "" (D.decodeValue (D.field "before" D.value) detail |> Result.toMaybe |> Maybe.map List.singleton |> Maybe.withDefault []))

        "fields.reordered" ->
            Order
                { before = D.decodeValue (D.at [ "before", "fields" ] (D.list D.string)) detail |> Result.withDefault []
                , after = Nothing
                , moved = []
                }

        "project.visibility_changed" ->
            case ( string [ "before" ] detail, string [ "after" ] detail ) of
                ( Just before, Just after ) ->
                    Changes [ { key = "公開範囲", before = visibilityText before, after = Just (visibilityText after) } ]

                _ ->
                    Nothing_

        "webhook.created" ->
            webhookFacts [] detail

        "webhook.updated" ->
            webhookFacts [ "before" ] detail

        "webhook.deleted" ->
            webhookFacts [ "before" ] detail

        "asset.confirmed" ->
            assetFacts [] detail

        "asset.deleted" ->
            assetFacts [ "before" ] detail

        "audit.exported" ->
            facts
                [ ( "形式", string [ "format" ] detail |> Maybe.map String.toUpper )
                , ( "件数", int [ "count" ] detail |> Maybe.map String.fromInt )
                , ( "誰が", string [ "actorKind" ] detail |> Maybe.map String.toUpper )
                , ( "何を", string [ "action" ] detail )
                , ( "期間", Maybe.map2 (\a b -> a ++ " 〜 " ++ b) (string [ "since" ] detail) (string [ "until" ] detail) )
                ]

        "entry.unpublished" ->
            entryFacts detail

        "entry.deleted" ->
            entryFacts detail

        "entry.published" ->
            entryFacts detail

        _ ->
            Nothing_


{-| 並び替えの型紙に今の並びを足す。動いた物は、前後で共通の並び（最長共通部分列）に入らない物。
今の型のフィールドの並びが手に入る画面が呼ぶ。他の型紙はそのまま返す。
-}
orderWith : List String -> Sheet -> Sheet
orderWith now sheet_ =
    case sheet_ of
        Order order ->
            let
                kept : List String
                kept =
                    lcs order.before now
            in
            Order { order | after = Just now, moved = List.filter (\apiId -> not (List.member apiId kept)) now }

        other ->
            other


typeKeys : List String
typeKeys =
    [ "name", "kind", "singular", "plural", "icon", "previewUrl", "linkPath" ]


fieldKeys : List String
fieldKeys =
    [ "name", "kind", "required", "unique", "many", "localized", "target", "config" ]


{-| `path` の下の object から、`keys` の順に、ある物だけを取る。
-}
changesOf : List String -> List String -> D.Value -> List Change
changesOf path keys detail =
    keys
        |> List.filterMap
            (\key ->
                D.decodeValue (D.at (path ++ [ key ]) D.value) detail
                    |> Result.toMaybe
                    |> Maybe.map (\value -> { key = key, before = valueText value, after = Nothing })
            )


{-| 値を人が読む形に。真偽は はい / いいえ、無ければ —、入れ子は JSON のまま。
-}
valueText : D.Value -> String
valueText value =
    D.decodeValue
        (D.oneOf
            [ D.string
            , D.map boolText D.bool
            , D.map String.fromFloat D.float
            , D.null "—"
            , D.map (E.encode 0) D.value
            ]
        )
        value
        |> Result.withDefault ""


boolText : Bool -> String
boolText flag =
    if flag then
        "はい"

    else
        "いいえ"


{-| 変更前のフィールドの JSON（`SchemaSnapshot.ofField`）を表の行に。子は `親.子` で続ける。
-}
fieldRows : String -> List D.Value -> List FieldRow
fieldRows prefix fields =
    fields
        |> List.concatMap
            (\field ->
                let
                    apiId : String
                    apiId =
                        prefix ++ Maybe.withDefault "" (string [ "apiId" ] field)

                    row : FieldRow
                    row =
                        { apiId = apiId
                        , name = Maybe.withDefault "" (string [ "name" ] field)
                        , kind = Maybe.withDefault "" (string [ "kind" ] field) |> upperSnake
                        , required = bool [ "required" ] field |> Maybe.withDefault False
                        , config = configText field
                        }

                    children : List D.Value
                    children =
                        D.decodeValue (D.field "children" (D.list D.value)) field |> Result.withDefault []
                in
                row :: fieldRows (apiId ++ ".") children
            )


{-| config と印を 1 行に（`max 120` / `unique` / `→ authors`）。
-}
configText : D.Value -> String
configText field =
    [ int [ "config", "maxLength" ] field |> Maybe.map (\n -> "max " ++ String.fromInt n)
    , string [ "config", "sourceField" ] field |> Maybe.map (\source -> "source " ++ source)
    , float [ "config", "min" ] field |> Maybe.map (\n -> "min " ++ String.fromFloat n)
    , float [ "config", "max" ] field |> Maybe.map (\n -> "max " ++ String.fromFloat n)
    , bool [ "config", "integer" ] field |> Maybe.andThen (flagText "integer")
    , D.decodeValue (D.at [ "config", "options" ] (D.list D.string)) field |> Result.toMaybe |> Maybe.map (String.join " / ")
    , string [ "target" ] field |> Maybe.map (\target -> "→ " ++ target)
    , bool [ "unique" ] field |> Maybe.andThen (flagText "unique")
    , bool [ "many" ] field |> Maybe.andThen (flagText "many")
    , bool [ "localized" ] field |> Maybe.andThen (flagText "localized")
    ]
        |> List.filterMap identity
        |> String.join ", "


flagText : String -> Bool -> Maybe String
flagText label flag =
    if flag then
        Just label

    else
        Nothing


{-| CMS が DB に書く綴り（`richText`）を管理 API の綴り（`RICH_TEXT`）に。
-}
upperSnake : String -> String
upperSnake camel =
    camel
        |> String.toList
        |> List.concatMap
            (\char ->
                if Char.isUpper char then
                    [ '_', char ]

                else
                    [ Char.toUpper char ]
            )
        |> String.fromList


webhookFacts : List String -> D.Value -> Sheet
webhookFacts path detail =
    facts
        [ ( "名前", string (path ++ [ "name" ]) detail )
        , ( "URL", joinSome " " [ string (path ++ [ "url", "host" ]) detail, string (path ++ [ "url", "pathHint" ]) detail ] )
        , ( "URL の照合値", string (path ++ [ "url", "urlHash" ]) detail )
        , ( "イベント", D.decodeValue (D.at (path ++ [ "events" ]) (D.list D.string)) detail |> Result.toMaybe |> Maybe.map (List.map eventText >> String.join "・") )
        , ( "状態", bool (path ++ [ "active" ]) detail |> Maybe.map activeText )
        ]


assetFacts : List String -> D.Value -> Sheet
assetFacts path detail =
    facts
        [ ( "mime", string (path ++ [ "mime" ]) detail )
        , ( "大きさ", int (path ++ [ "size" ]) detail |> Maybe.map Ui.Bytes.human )
        , ( "寸法", Maybe.map2 (\w h -> String.fromInt w ++ " × " ++ String.fromInt h) (int (path ++ [ "width" ]) detail) (int (path ++ [ "height" ]) detail) )
        ]


entryFacts : D.Value -> Sheet
entryFacts detail =
    facts
        [ ( "API", string [ "typeApiId" ] detail )
        , ( "バージョン", int [ "version" ] detail |> Maybe.map (\n -> "v" ++ String.fromInt n) )
        , ( "予約", string [ "scheduledFor" ] detail )
        ]


{-| 権限の言い方。Members の画面と同じ（管理者 / 編集者 / 投稿者 / 閲覧者）。知らない値はそのまま。
-}
roleText : String -> String
roleText role =
    case String.toUpper role of
        "OWNER" ->
            "管理者"

        "EDITOR" ->
            "編集者"

        "WRITER" ->
            "投稿者"

        "VIEWER" ->
            "閲覧者"

        _ ->
            role


{-| イベントの言い方。「API キーと Webhook」の画面と同じ。監査は `entry.published` の綴りで持つ。
-}
eventText : String -> String
eventText event =
    case event of
        "entry.published" ->
            "公開"

        "entry.unpublished" ->
            "公開終了"

        "entry.deleted" ->
            "削除"

        "schema.changed" ->
            "スキーマの変更"

        other ->
            other


activeText : Bool -> String
activeText active =
    if active then
        "有効"

    else
        "無効"


{-| 値のある物だけを並べる。1 つも無ければ型紙無し。
-}
facts : List ( String, Maybe String ) -> Sheet
facts pairs =
    case List.filterMap (\( key, value ) -> Maybe.map (Tuple.pair key) value) pairs of
        [] ->
            Nothing_

        some ->
            Facts some



-- JSON を引く


string : List String -> D.Value -> Maybe String
string path value =
    D.decodeValue (D.at path D.string) value |> Result.toMaybe


int : List String -> D.Value -> Maybe Int
int path value =
    D.decodeValue (D.at path D.int) value |> Result.toMaybe


float : List String -> D.Value -> Maybe Float
float path value =
    D.decodeValue (D.at path D.float) value |> Result.toMaybe


bool : List String -> D.Value -> Maybe Bool
bool path value =
    D.decodeValue (D.at path D.bool) value |> Result.toMaybe


count : List String -> D.Value -> Maybe Int
count path value =
    D.decodeValue (D.at path (D.list D.value)) value |> Result.toMaybe |> Maybe.map List.length



-- 最長共通部分列


{-| 2 つの並びの最長共通部分列。並び替えで動かなかった物を知るのに使う。
-}
lcs : List String -> List String -> List String
lcs before after =
    let
        xs : Array String
        xs =
            Array.fromList before

        ys : Array String
        ys =
            Array.fromList after

        m : Int
        m =
            Array.length ys

        nextRow : String -> Array Int -> Array Int
        nextRow x prev =
            List.foldl
                (\j row ->
                    Array.push
                        (if Array.get (j - 1) ys == Just x then
                            cell (j - 1) prev + 1

                         else
                            max (cell j prev) (cell (j - 1) row)
                        )
                        row
                )
                (Array.fromList [ 0 ])
                (List.range 1 m)

        table : Array (Array Int)
        table =
            List.foldl
                (\x rows ->
                    case rows of
                        last :: _ ->
                            nextRow x last :: rows

                        [] ->
                            rows
                )
                [ Array.repeat (m + 1) 0 ]
                before
                |> List.reverse
                |> Array.fromList

        at : Int -> Int -> Int
        at i j =
            Array.get i table |> Maybe.map (cell j) |> Maybe.withDefault 0

        walk : Int -> Int -> List String -> List String
        walk i j acc =
            if i == 0 || j == 0 then
                acc

            else
                case ( Array.get (i - 1) xs, Array.get (j - 1) ys ) of
                    ( Just x, Just y ) ->
                        if x == y then
                            walk (i - 1) (j - 1) (x :: acc)

                        else if at (i - 1) j >= at i (j - 1) then
                            walk (i - 1) j acc

                        else
                            walk i (j - 1) acc

                    _ ->
                        acc
    in
    walk (Array.length xs) m []


cell : Int -> Array Int -> Int
cell index row =
    Array.get index row |> Maybe.withDefault 0


{-| 公開範囲の値。プロジェクト設定の chip と同じ語（公開 / 非公開）。
-}
visibilityText : String -> String
visibilityText value =
    case String.toLower value of
        "public" ->
            "公開"

        "private" ->
            "非公開"

        _ ->
            value
