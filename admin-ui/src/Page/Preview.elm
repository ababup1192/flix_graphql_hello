module Page.Preview exposing (Model, Msg(..), docsUrl, explorerUrl, init, load, update, view)

{-| API プレビュー。**この API に何を投げると何が返るか**を、実物で見せる。

**画面ではなく、右から出る引き出し。** microCMS の「API プレビュー」、Sanity の Inspect、
Directus の raw JSON と同じで、一覧と 1 件の画面から開く。専用のタブは作らない
（API を見るのは今見ている物を確かめる作業で、別の場所へ移る作業ではない）。

2 つの形を出す（人が API を使う時の 2 通り）。

  - **一覧**: `blogs(first: 10) { totalCount nodes { … } }`
  - **1 件**: `blog(id: "…") { … }`

query は**書き換えられる**。型から作った物はあくまで下書きで、
`OBJECT` や `BLOCKS` のように入れ子が要る種類は人が足せる。

**投げ先はコンテンツ API**（`/p/{slug}/graphql`）。管理 API ではない。
公開中の物だけが匿名で読めるので、既定は `stage` を付けない（= 公開中）。

**組む・調べるは別の場所**。query を組み立てるのは Explorer、フィールドや引数を調べるのは
リファレンス。ここは「実物を 1 回見る」だけに絞り、その 2 つへのリンクを置く。

-}

import Api
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, value)
import Html.Events exposing (onClick, onInput)
import Json.Decode as D
import Json.Encode as E
import Loaded exposing (Loaded)
import Model exposing (ContentTypeDetail, EntryList, EntryRow, FieldDef, Slug)
import Queries
import Ui
import Url


type alias Model =
    { project : Slug
    , apiId : String
    , contentType : Loaded ContentTypeDetail
    , entries : Loaded EntryList

    {- 開いた時に名指しされたコンテンツ。**最近の 20 件に居なくても選択欄に出す**ため、
       id で名指しして別に引く。
    -}
    , current : Maybe EntryRow
    , shape : Shape
    , entryId : String
    , draft : Bool
    , first : Int
    , document : String
    , edited : Bool
    , answer : Maybe Answer
    , sending : Bool
    }


{-| 何を見せるか。一覧と 1 件で query の形が変わる。
-}
type Shape
    = ListShape
    | OneShape


{-| 返ってきた物。**errors も含めて生のまま持つ**（プレビューは実物を見せる画面）。
-}
type alias Answer =
    { status : Int
    , body : String
    }


type Msg
    = GotType (Result Api.Problem (Maybe ContentTypeDetail))
    | GotEntries (Result Api.Problem EntryList)
    | GotCurrent (Result Api.Problem EntryList)
    | ShapeChosen Shape
    | EntryChosen String
    | DraftToggled
    | FirstChosen String
    | DocumentTyped String
    | ResetWanted
    | SendWanted
    | GotAnswer Api.Response
    | Closed
    | Ignored


{-| 開く。1 件から開いた時は `entryId` が来て、その 1 件の query から始まる。
-}
init : Slug -> String -> Maybe { entryId : String, draft : Bool } -> Model
init project apiId one =
    { project = project
    , apiId = apiId
    , contentType = Loaded.Loading
    , entries = Loaded.Loading
    , current = Nothing
    , shape =
        case one of
            Just _ ->
                OneShape

            Nothing ->
                ListShape
    , entryId = one |> Maybe.map .entryId |> Maybe.withDefault ""
    , draft = one |> Maybe.map .draft |> Maybe.withDefault False
    , first = 10
    , document = ""
    , edited = False
    , answer = Nothing
    , sending = False
    }


load : Slug -> String -> List (Api.Call Msg)
load slug apiId =
    [ Api.call (\id -> Queries.contentType id slug apiId) GotType ]


update : { project : Slug } -> Msg -> Model -> ( Model, List (Api.Call Msg) )
update ctx msg model =
    case msg of
        GotType result ->
            let
                next : Model
                next =
                    { model | contentType = Loaded.fromResult result }
            in
            ( rebuild next
            , case result of
                Ok (Just detail) ->
                    entriesCall ctx.project detail.id :: currentCall ctx.project detail.id model.entryId

                _ ->
                    []
            )

        GotEntries result ->
            let
                page : Maybe EntryList
                page =
                    Result.toMaybe result

                first : String
                first =
                    page |> Maybe.map .nodes |> Maybe.withDefault [] |> List.head |> Maybe.map .id |> Maybe.withDefault ""
            in
            ( rebuild
                { model
                    | entries = Loaded.fromResult (Result.map Just result)
                    , entryId =
                        if String.isEmpty model.entryId then
                            first

                        else
                            model.entryId
                }
            , []
            )

        GotCurrent result ->
            ( { model | current = result |> Result.toMaybe |> Maybe.map .nodes |> Maybe.withDefault [] |> List.head }, [] )

        ShapeChosen shape ->
            ( rebuild { model | shape = shape, answer = Nothing }, [] )

        EntryChosen entryId ->
            ( rebuild { model | entryId = entryId, answer = Nothing }, [] )

        DraftToggled ->
            ( rebuild { model | draft = not model.draft, answer = Nothing }, [] )

        FirstChosen typed ->
            ( rebuild { model | first = String.toInt typed |> Maybe.withDefault 10, answer = Nothing }, [] )

        DocumentTyped typed ->
            -- 人が書き換えたら、以後は型から作り直さない（書いた物を消さない）。
            ( { model | document = typed, edited = True }, [] )

        ResetWanted ->
            ( rebuild { model | edited = False }, [] )

        SendWanted ->
            ( { model | sending = True }
            , [ Api.preview
                    { kind = "apiPreview", project = ctx.project, document = model.document }
                    GotAnswer
              ]
            )

        Closed ->
            ( model, [] )

        Ignored ->
            ( model, [] )

        GotAnswer response ->
            ( { model
                | sending = False
                , answer = Just { status = response.status, body = E.encode 2 response.body }
              }
            , []
            )


{-| 型と今の選びから query を組み直す。**人が書き換えた後は触らない。**
-}
rebuild : Model -> Model
rebuild model =
    if model.edited then
        model

    else
        case Loaded.toMaybe model.contentType of
            Just detail ->
                { model | document = documentOf model detail }

            Nothing ->
                model


{-| 選択欄に出す「最近の」の数。
-}
entryPageSize : Int
entryPageSize =
    20


{-| 開いた時に名指しされた 1 件。**選択欄に必ず出す**ために id で引く。

WhyNot: 最近の 20 件に混ざるのを当てにしない。混ざらないと選択欄は先頭の物を
指したまま、query は名指しされた物、という食い違いになる。

-}
currentCall : Slug -> String -> String -> List (Api.Call Msg)
currentCall project typeId entryId =
    if String.isEmpty entryId then
        []

    else
        [ Api.call
            (\id ->
                Queries.entries id
                    project
                    { typeId = typeId, search = "", stage = "", conditions = [], ids = [ entryId ], order = "", first = 1, skip = 0 }
            )
            GotCurrent
        ]


entriesCall : Slug -> String -> Api.Call Msg
entriesCall project typeId =
    Api.call
        (\id ->
            Queries.entries id
                project
                { typeId = typeId, search = "", stage = "", conditions = [], ids = [], order = "", first = entryPageSize, skip = 0 }
        )
        GotEntries



-- query を組む


{-| 型の定義から query の文字を作る。

**フィールドの選び方は種類で決まる。** スカラーはそのまま、リッチテキストと参照は
入れ子が要る。入れ子の形が型から決まらない種類（`OBJECT` / `BLOCKS`）は出さず、
下に「足りない物」として名前を出す（人が書き足せる）。

-}
documentOf : Model -> ContentTypeDetail -> String
documentOf model detail =
    let
        body : String -> String
        body indent =
            selectionOf detail |> List.map (\line -> indent ++ line) |> String.join "\n"
    in
    case model.shape of
        ListShape ->
            String.join "\n"
                [ "query " ++ detail.apiId ++ " {"
                , "  " ++ detail.apiId ++ "(" ++ String.join ", " (listArgsOf model) ++ ") {"
                , "    totalCount"
                , "    nodes {"
                , body "      "
                , "    }"
                , "  }"
                , "}"
                ]

        OneShape ->
            String.join "\n"
                [ "query " ++ oneField detail ++ " {"
                , "  " ++ oneField detail ++ "(" ++ String.join ", " (oneArgsOf model) ++ ") {"
                , body "    "
                , "  }"
                , "}"
                ]


listArgsOf : Model -> List String
listArgsOf model =
    ("first: " ++ String.fromInt model.first)
        :: (if model.draft then
                [ "stage: DRAFT" ]

            else
                []
           )


oneArgsOf : Model -> List String
oneArgsOf model =
    ("id: \"" ++ model.entryId ++ "\"")
        :: (if model.draft then
                [ "stage: DRAFT" ]

            else
                []
           )


{-| 1 件を引くフィールドの名前。型名（`Blog`）の頭を小文字にした物。
-}
oneField : ContentTypeDetail -> String
oneField detail =
    case String.uncons detail.singular of
        Just ( head, rest ) ->
            String.fromChar (Char.toLower head) ++ rest

        Nothing ->
            detail.apiId


{-| すべての entry が持つフィールド。
-}
common : List String
common =
    [ "id", "stage", "publishedAt", "createdAt", "updatedAt" ]


selectionOf : ContentTypeDetail -> List String
selectionOf detail =
    common ++ List.filterMap fieldLine detail.fields


{-| フィールド 1 つの選び方。形が決まらない種類は出さない。
-}
fieldLine : FieldDef -> Maybe String
fieldLine field =
    case field.kind of
        "RICH_TEXT" ->
            Just (field.apiId ++ " { html text }")

        "REFERENCE" ->
            Just (field.apiId ++ " { id }")

        "OBJECT" ->
            Nothing

        "BLOCKS" ->
            Nothing

        "ASSET" ->
            Just (field.apiId ++ " { id url fileName mime width height alt }")

        _ ->
            Just field.apiId


{-| query に出せなかったフィールド。人が書き足す手がかりに出す。
-}
missingOf : ContentTypeDetail -> List FieldDef
missingOf detail =
    detail.fields |> List.filter (\field -> fieldLine field == Nothing)



-- 画面


{-| 右から出る引き出し。**画面は閉じない**（今見ていた一覧や編集の上に重ねる）。
-}
view : { publicOrigin : String } -> Model -> Html Msg
view env model =
    Ui.drawer
        { title = "API プレビュー"
        , meta = [ span [ class "font-mono text-[11px] text-ink-faint" ] [ text ("/" ++ model.apiId) ] ]
        , onClose = Closed
        , onIgnore = Ignored
        }
        [ Loaded.view
            { loading = Ui.loadingCard
            , missing = Ui.messageCard "この API はありません" []
            , failed = Ui.failedCard
            , present = viewPanel env model
            }
            model.contentType
        ]


viewPanel : { publicOrigin : String } -> Model -> ContentTypeDetail -> Html Msg
viewPanel env model detail =
    div [ class "flex flex-col gap-4" ]
        [ Ui.note [ text "この API で query を実行すると何が返るかを、実物で見せます。query は書き換えられます。" ]
        , viewControls model detail
        , viewLinks model
        , viewRequest model detail
        , viewAnswer model
        , viewCurl env model
        ]



-- 詳しく


{-| 組む時と調べる時の行き先。

WhyNot: ここに表を置き直さない。検索も補完も型を辿る事もできる Explorer と
リファレンスがあり、引き出しの中の表はその劣った写しになる。

-}
viewLinks : Model -> Html Msg
viewLinks model =
    div [ class "flex flex-wrap items-center gap-3 text-xs" ]
        [ span [ class "text-ink-faint" ] [ text "詳しく:" ]
        , outLink (explorerUrl model.project model.document) "Explorer（GraphiQL）で開く"
        , outLink (docsUrl model.project) "リファレンス"
        ]


outLink : String -> String -> Html Msg
outLink href label =
    Ui.quietLink
        [ Html.Attributes.href href
        , Html.Attributes.target "_blank"
        , Html.Attributes.rel "noopener"
        ]
        [ text label ]


{-| Explorer を今の query で開く URL。空の query は `?query=` ごと付けない
（Explorer が自前の下書きを出せる）。
-}
explorerUrl : Slug -> String -> String
explorerUrl project document =
    if String.isEmpty document then
        "/p/" ++ project ++ "/graphiql"

    else
        "/p/" ++ project ++ "/graphiql?query=" ++ Url.percentEncode document


docsUrl : Slug -> String
docsUrl project =
    "/p/" ++ project ++ "/docs"


viewControls : Model -> ContentTypeDetail -> Html Msg
viewControls model detail =
    div [ class "flex flex-wrap items-center gap-2" ]
        [ shapeButton model ListShape "一覧"
        , shapeButton model OneShape "1 件"
        , case model.shape of
            ListShape ->
                Ui.select [ onInput FirstChosen ]
                    [ ( "5", "5 件" ), ( "10", "10 件" ), ( "20", "20 件" ), ( "50", "50 件" ) ]
                    (String.fromInt model.first)

            OneShape ->
                Ui.select [ onInput EntryChosen ] (entryOptions model detail) model.entryId
        , case model.shape of
            OneShape ->
                viewEntryNote model

            ListShape ->
                text ""
        , Ui.checkbox { label = "下書きも読む（stage: DRAFT）", checked = model.draft, onToggle = DraftToggled }
        ]


{-| 選択欄に何が入っているかを言う。**全件ではない**ので、出していない数を出す。
-}
viewEntryNote : Model -> Html Msg
viewEntryNote model =
    let
        held : Int
        held =
            List.length (heldEntries model)

        rest : Int
        rest =
            (Loaded.toMaybe model.entries |> Maybe.map .totalCount |> Maybe.withDefault 0) - held
    in
    if rest > 0 then
        span [ class "text-xs text-ink-faint" ]
            [ text ("最近の " ++ String.fromInt entryPageSize ++ " 件から選べます。ほかに " ++ String.fromInt rest ++ " 件あり、コンテンツ一覧から開くとここに出ます。") ]

    else
        text ""


{-| 一覧か 1 件か。**押している方が塗られる**（GitHub の切り替えと同じ）。
-}
shapeButton : Model -> Shape -> String -> Html Msg
shapeButton model shape label =
    if model.shape == shape then
        Ui.button [ onClick (ShapeChosen shape) ] [ text label ]

    else
        Ui.ghostButton [ onClick (ShapeChosen shape) ] [ text label ]


entryOptions : Model -> ContentTypeDetail -> List ( String, String )
entryOptions model detail =
    List.map (\row -> ( row.id, titleOf detail row )) (heldEntries model)


{-| 選択欄に出す行。**開いた 1 件を先頭に**、その後ろに最近の分。
-}
heldEntries : Model -> List EntryRow
heldEntries model =
    let
        recent : List EntryRow
        recent =
            Loaded.toMaybe model.entries |> Maybe.map .nodes |> Maybe.withDefault []
    in
    case model.current of
        Just row ->
            row :: List.filter (\other -> other.id /= row.id) recent

        Nothing ->
            recent


titleOf : ContentTypeDetail -> EntryRow -> String
titleOf detail row =
    detail.fields
        |> List.filter (\field -> field.kind == "TEXT")
        |> List.head
        |> Maybe.andThen (\field -> D.decodeValue (D.field field.apiId D.string) row.fields |> Result.toMaybe)
        |> Maybe.andThen
            (\value ->
                if String.isEmpty value then
                    Nothing

                else
                    Just value
            )
        |> Maybe.withDefault ("（無題）" ++ String.right 6 row.id)


viewRequest : Model -> ContentTypeDetail -> Html Msg
viewRequest model detail =
    Ui.card [ class "flex flex-col gap-3 p-4" ]
        [ div [ class "flex items-center gap-2" ]
            [ Ui.subheading "実行する query"
            , div [ class "ml-auto flex items-center gap-2" ]
                [ if model.edited then
                    Ui.ghostButton [ onClick ResetWanted ] [ text "API スキーマから再作成" ]

                  else
                    text ""
                , Ui.button [ onClick SendWanted, Html.Attributes.disabled model.sending ]
                    [ text
                        (if model.sending then
                            "送信中…"

                         else
                            "送る"
                        )
                    ]
                ]
            ]
        , span [ class "font-mono text-[11px] text-ink-soft" ] [ text ("POST /p/" ++ model.project ++ "/graphql") ]
        , Html.textarea
            [ class "h-[26rem] w-full rounded-md border border-edge bg-well p-3 font-mono text-[12px] leading-5 text-ink"
            , value model.document
            , onInput DocumentTyped
            , Html.Attributes.spellcheck False
            ]
            []
        , case missingOf detail of
            [] ->
                text ""

            fields ->
                Ui.note
                    [ text
                        ("入れ子の形が型からは決まらないので出していないフィールド: "
                            ++ String.join "、" (List.map .name fields)
                            ++ "。query に書き足せます。"
                        )
                    ]
        ]


viewAnswer : Model -> Html Msg
viewAnswer model =
    Ui.card [ class "flex flex-col gap-3 p-4" ]
        [ div [ class "flex items-center gap-2" ]
            [ Ui.subheading "返ってくる JSON"
            , case model.answer of
                Just answer ->
                    Ui.chip (statusTone answer.status) ("HTTP " ++ String.fromInt answer.status)

                Nothing ->
                    text ""
            ]
        , case model.answer of
            Nothing ->
                div [ class "flex h-[26rem] items-center justify-center rounded-md border border-edge bg-well" ]
                    [ span [ class "text-xs text-ink-faint" ] [ text "「送る」を押すと、実際に返る JSON が出ます。" ] ]

            Just answer ->
                Html.pre
                    [ class "h-[26rem] overflow-auto rounded-md border border-edge bg-well p-3 font-mono text-[12px] leading-5 text-ink" ]
                    [ text answer.body ]
        ]


statusTone : Int -> String
statusTone status =
    if status == 0 then
        Ui.toneBad

    else if status < 300 then
        Ui.toneOk

    else
        Ui.toneWarn


{-| そのまま貼れる形。**API キーは出さない**（画面に出すと共有されて漏れる）。
公開中の物は鍵無しで読めるので、この形で通る。
-}
viewCurl : { publicOrigin : String } -> Model -> Html Msg
viewCurl env model =
    let
        origin : String
        origin =
            if String.isEmpty env.publicOrigin then
                "https://<あなたのドメイン>"

            else
                env.publicOrigin
    in
    Ui.card [ class "flex flex-col gap-2 p-4" ]
        [ Ui.subheading "手元から実行"
        , Ui.codeBlock []
            ("curl -X POST "
                ++ origin
                ++ "/p/"
                ++ model.project
                ++ "/graphql -H 'Content-Type: application/json' -d '"
                ++ E.encode 0 (E.object [ ( "query", E.string model.document ) ])
                ++ "'"
            )
        , if String.isEmpty env.publicOrigin then
            Ui.note [ text "サーバーの CMS_PUBLIC_ORIGIN を設定すると、実際の URL が出ます。" ]

          else
            text ""
        , Ui.note [ text "非公開のプロジェクトと下書きを読むには X-Api-Key が要ります。API キーは「API キー」の画面で発行します。" ]
        ]
