module Page.Entries exposing (Model, Msg(..), init, load, typedAt, update, urlOf, view)

{-| コンテンツの一覧。

一覧の 1 列目は型の最初のテキストのフィールドで代表する（CMS に `titleField` がまだ無い）。
入るまでは `EntryLabel` が決め方を持つ。

**絞り込みは条件を足していく形**（`Filter`）。項目 → 演算子 → 値を 1 行に並べ、足した物は
チップになって 1 つずつ外せる。調べた 9 社のうち 6 社がこの形で、固定のセレクトだけなのは
1 社しか無い（しかもそこは「高度な検索」が積み残っている）。

**並び替えは表の見出しと右のセレクトの両方から**。見出しは押せる列だけがボタンで、
セレクトは**見出しに出ていない物**（狭い画面で畳まれる更新日時、列に無い公開日時と
フィールド）のために残す。

-}

import Api
import Dict exposing (Dict)
import EntryLabel
import Filter exposing (Condition)
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Loaded exposing (Loaded)
import Model exposing (ContentTypeDetail, EntryList, EntryRow, FieldDef, Slug)
import Queries
import Route
import Ui
import Ui.DateTime
import Ui.Icon as Icon


type alias Model =
    { project : Slug
    , apiId : String
    , contentType : Loaded ContentTypeDetail
    , entries : Loaded EntryList
    , query : Query

    {- 足そうとしている条件。開いている間だけ持つ。 -}
    , adding : Maybe Condition

    {- 日付の値を選ぶ暦。開いている間だけ持つ。 -}
    , datePick : Maybe Ui.DateTime.Model
    , today : Maybe { year : Int, month : Int, day : Int }

    {- 参照の値を人に見せる文字（entry id → 見出し）。
       **必要な id だけ引く**（前は参照先を 100 件先読みしていて、101 件目が絞れなかった）。
    -}
    , labels : Dict String String

    {- 参照の候補。打つたびに引き直す。 -}
    , candidates : List ( String, String )

    {- 打った文字に当たるコンテンツの件数。**出した数より多ければ**
       「ほかに N 件」と断るのに使う。
    -}
    , candidateTotal : Int
    , candidateQuery : String

    {- 検索を打った回数。**最後の 1 回だけ引く**（Elm はタイマーを取り消せないので、
       番号が今と同じ物だけを通す）。
    -}
    , typedAt : Int
    }


{-| 一覧の状態。**URL に持つ**（戻っても残り、絞り込んだ一覧を人に渡せる）。
-}
type alias Query =
    { search : String
    , stage : String
    , conditions : List Condition
    , order : String
    , page : Int
    }


perPage : Int
perPage =
    50


type Msg
    = GotType (Result Api.Problem (Maybe ContentTypeDetail))
    | GotEntries (Result Api.Problem EntryList)
    | SearchTyped String
    | SearchFired Int
    | StageChosen String
    | OrderChosen String
    | SortChosen String
    | PageMoved Int
    | FilterOpened
    | FilterClosed
    | FilterFieldChosen String
    | FilterOpChosen String
    | FilterValueTyped String
    | DatePickOpened
    | DatePickMsg Ui.DateTime.Msg
    | DatePickClosed
    | TodayKnown Int Int Int
    | FilterAdded
    | FilterRemoved Int
    | FiltersCleared
    | CandidateTyped String
    | GotCandidates (Result Api.Problem EntryList)
    | GotLabels (Result Api.Problem EntryList)
    | ApiPreviewWanted


init : Slug -> String -> List ( String, String ) -> Model
init project apiId params =
    { project = project
    , apiId = apiId
    , contentType = Loaded.Loading
    , entries = Loaded.Loading
    , query = queryOf params
    , adding = Nothing
    , datePick = Nothing
    , today = Nothing
    , labels = Dict.empty
    , candidates = []
    , candidateTotal = 0
    , candidateQuery = ""
    , typedAt = 0
    }


{-| URL の query を一覧の状態にする。
-}
queryOf : List ( String, String ) -> Query
queryOf params =
    let
        get : String -> String
        get key =
            params |> List.filter (\( k, _ ) -> k == key) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault ""
    in
    { search = get "q"
    , stage = get "where"
    , conditions = Filter.decode (get "f")
    , order = get "order"
    , page = get "page" |> String.toInt |> Maybe.withDefault 1
    }


{-| 一覧の状態を URL の query にする。既定の値は書かない（URL を短く保つ）。
-}
paramsOf : Query -> List ( String, String )
paramsOf query =
    [ ( "q", query.search )
    , ( "where", query.stage )
    , ( "f", Filter.encode query.conditions )
    , ( "order", query.order )
    , ( "page"
      , if query.page > 1 then
            String.fromInt query.page

        else
            ""
      )
    ]
        |> List.filter (\( _, value ) -> not (String.isEmpty value))


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
            ( next
            , case result of
                Ok (Just detail) ->
                    entriesCall ctx.project detail.id model.query :: labelCalls ctx next

                _ ->
                    []
            )

        GotEntries result ->
            ( { model | entries = Loaded.fromResult (Result.map Just result) }, [] )

        GotLabels (Ok page) ->
            ( { model | labels = Dict.union (labelsOf page) model.labels }, [] )

        GotLabels (Err _) ->
            ( model, [] )

        GotCandidates (Ok page) ->
            ( { model
                | candidates = List.map (\row -> ( row.id, EntryLabel.forRow row )) page.nodes
                , candidateTotal = page.totalCount
                , labels = Dict.union (labelsOf page) model.labels
              }
            , []
            )

        GotCandidates (Err _) ->
            ( { model | candidates = [], candidateTotal = 0 }, [] )

        SearchTyped search ->
            -- **打つ度には問い合わせない。** 一覧を空にして描き直すと、画面がちらつき
            -- 入力欄の焦点が外れる（実際に外れた）。文字だけ持って、少し待ってから引く
            -- （待つのは親。ページに時間の effect を持たせるとテストから見えなくなる）。
            ( { model
                | query = setQuery model.query (\query -> { query | search = search, page = 1 })
                , typedAt = model.typedAt + 1
              }
            , []
            )

        SearchFired at ->
            -- **最後に打った 1 回だけ引く。** 番号が進んでいれば、まだ打っている途中。
            case ( at == model.typedAt, Loaded.toMaybe model.contentType ) of
                ( True, Just detail ) ->
                    ( model, [ entriesCall ctx.project detail.id model.query ] )

                _ ->
                    ( model, [] )

        StageChosen stage ->
            refine ctx model (\query -> { query | stage = stage, page = 1 })

        OrderChosen order ->
            refine ctx model (\query -> { query | order = normalizeOrder order, page = 1 })

        SortChosen key ->
            -- **2 段階。** 同じ見出しをもう一度押すと逆になり、別の見出しは昇順から始まる。
            let
                ( active, direction ) =
                    sortOf model.query

                next : String
                next =
                    if active == key && direction == "asc" then
                        key ++ ":desc"

                    else
                        key ++ ":asc"
            in
            refine ctx model (\query -> { query | order = normalizeOrder next, page = 1 })

        PageMoved step ->
            refine ctx model (\query -> { query | page = max 1 (query.page + step) })

        FilterOpened ->
            case List.head (fieldsOf model) of
                Just field ->
                    startAdding ctx model field

                Nothing ->
                    ( model, [] )

        FilterClosed ->
            ( { model | adding = Nothing, candidates = [], candidateTotal = 0, candidateQuery = "" }, [] )

        FilterFieldChosen apiId ->
            case fieldsOf model |> List.filter (\field -> field.apiId == apiId) |> List.head of
                Just field ->
                    startAdding ctx model field

                Nothing ->
                    ( model, [] )

        FilterOpChosen op ->
            -- **演算子を変えると値の入れ方も変わる**ので、値は捨てる。
            ( { model | adding = model.adding |> Maybe.map (\draft -> { draft | op = op, value = "" }) }, [] )

        DatePickOpened ->
            ( { model
                | datePick =
                    Just
                        (Ui.DateTime.atDate
                            (Maybe.withDefault { year = 2026, month = 1, day = 1 } model.today)
                            (model.adding |> Maybe.map .value |> Maybe.withDefault "")
                        )
              }
            , []
            )

        -- 日を押したらその場で値にして閉じる（「この日付にする」をもう 1 回押させない）
        DatePickMsg pickMsg ->
            case model.datePick of
                Just picked ->
                    let
                        next : Ui.DateTime.Model
                        next =
                            Ui.DateTime.update pickMsg picked
                    in
                    if Ui.DateTime.isDayChosen pickMsg then
                        ( { model
                            | datePick = Nothing
                            , adding = model.adding |> Maybe.map (\draft -> { draft | value = Ui.DateTime.toIsoDate next })
                          }
                        , []
                        )

                    else
                        ( { model | datePick = Just next }, [] )

                Nothing ->
                    ( model, [] )

        DatePickClosed ->
            ( { model | datePick = Nothing }, [] )

        TodayKnown year month day ->
            ( { model | today = Just { year = year, month = month, day = day } }, [] )

        FilterValueTyped typed ->
            ( { model | adding = model.adding |> Maybe.map (\draft -> { draft | value = typed }) }, [] )

        FilterAdded ->
            case model.adding of
                Just draft ->
                    if Filter.needsValue draft.op && String.isEmpty draft.value then
                        ( model, [] )

                    else
                        refine ctx
                            { model | adding = Nothing, candidates = [], candidateTotal = 0, candidateQuery = "" }
                            (\query -> { query | conditions = query.conditions ++ [ draft ], page = 1 })

                Nothing ->
                    ( model, [] )

        FilterRemoved at ->
            refine ctx
                model
                (\query ->
                    { query
                        | conditions =
                            query.conditions
                                |> List.indexedMap Tuple.pair
                                |> List.filter (\( i, _ ) -> i /= at)
                                |> List.map Tuple.second
                        , page = 1
                    }
                )

        FiltersCleared ->
            refine ctx model (\query -> { query | conditions = [], page = 1 })

        CandidateTyped typed ->
            ( { model | candidateQuery = typed }, candidateCalls ctx model typed )

        ApiPreviewWanted ->
            -- 開けるのは親（引き出しはページの外に重なる）。
            ( model, [] )


{-| 条件を作り始める。参照なら候補を引いておく（何も打たなくても一覧が出る）。
-}
startAdding : { project : Slug } -> Model -> FieldDef -> ( Model, List (Api.Call Msg) )
startAdding ctx model field =
    let
        op : String
        op =
            Filter.opsFor field |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault "EQ"

        next : Model
        next =
            { model | adding = Just { apiId = field.apiId, op = op, value = "" }, candidates = [], candidateTotal = 0, candidateQuery = "" }
    in
    ( next, candidateCalls ctx next "" )


{-| 1 度に出す候補の数。**残りは打って絞る**ので、出し切らなくて良い。
-}
candidatePageSize : Int
candidatePageSize =
    20


{-| 参照の候補を引く。**打つたびに引き直す**（先読みした固定の一覧は、参照先が増えると
静かに壊れる。101 件目が絞り込めない）。
-}
candidateCalls : { project : Slug } -> Model -> String -> List (Api.Call Msg)
candidateCalls ctx model search =
    case model.adding |> Maybe.andThen (inputOf model) of
        Just (Filter.EntryInput typeId) ->
            [ Api.call
                (\id ->
                    Queries.entries id
                        ctx.project
                        { typeId = typeId, search = search, stage = "", conditions = [], ids = [], order = "", first = candidatePageSize, skip = 0 }
                )
                GotCandidates
            ]

        _ ->
            []


{-| 今 URL に載っている参照の条件について、見出しを引く。**要る id だけ**。
-}
labelCalls : { project : Slug } -> Model -> List (Api.Call Msg)
labelCalls ctx model =
    let
        wanted : List ( String, String )
        wanted =
            model.query.conditions
                |> List.filterMap
                    (\condition ->
                        case fieldOf model condition.apiId |> Maybe.andThen .targetTypeId of
                            Just typeId ->
                                if Dict.member condition.value model.labels then
                                    Nothing

                                else
                                    Just ( typeId, condition.value )

                            Nothing ->
                                Nothing
                    )
    in
    wanted
        |> List.map Tuple.first
        |> unique
        |> List.map
            (\typeId ->
                Api.call
                    (\id ->
                        Queries.entries id
                            ctx.project
                            { typeId = typeId
                            , search = ""
                            , stage = ""
                            , conditions = []
                            , ids = wanted |> List.filter (\( t, _ ) -> t == typeId) |> List.map Tuple.second
                            , order = ""
                            , first = 50
                            , skip = 0
                            }
                    )
                    GotLabels
            )


unique : List String -> List String
unique values =
    List.foldl
        (\value kept ->
            if List.member value kept then
                kept

            else
                kept ++ [ value ]
        )
        []
        values


labelsOf : EntryList -> Dict String String
labelsOf page =
    page.nodes |> List.map (\row -> ( row.id, EntryLabel.forRow row )) |> Dict.fromList


setQuery : Query -> (Query -> Query) -> Query
setQuery query change =
    change query


{-| 絞り込みを変える。**URL も同時に変える**ので、戻る・共有・再読み込みで同じ物が出る。
-}
refine : { project : Slug } -> Model -> (Query -> Query) -> ( Model, List (Api.Call Msg) )
refine ctx model change =
    let
        query : Query
        query =
            change model.query

        next : Model
        next =
            -- **前の結果を消さない。** 空にすると 1 回ごとに読み込みの箱が出て、
            -- 画面がちらつく。新しい結果が来たら差し替わる。
            { model | query = query }
    in
    case Loaded.toMaybe model.contentType of
        Just detail ->
            ( next, entriesCall ctx.project detail.id query :: labelCalls ctx next )

        Nothing ->
            ( { model | query = query }, [] )


entriesCall : Slug -> String -> Query -> Api.Call Msg
entriesCall project typeId query =
    Api.call
        (\id ->
            Queries.entries id
                project
                { typeId = typeId
                , search = query.search
                , stage = query.stage
                , conditions = query.conditions
                , ids = []
                , order = query.order
                , first = perPage
                , skip = (query.page - 1) * perPage
                }
        )
        GotEntries


{-| 検索を打った回数。親が「待ってから引く」を組むのに使う。
-}
typedAt : Model -> Int
typedAt model =
    model.typedAt


{-| 今の一覧の URL。親がこれで URL を書き換える（戻る・共有・再読み込みで同じ物が出る）。
-}
urlOf : Model -> String
urlOf model =
    Route.toString (Route.Entries model.project model.apiId (paramsOf model.query))



-- 絞り込みの下ごしらえ


{-| 絞り込みに出せる項目。型のフィールド ＋ どの entry も持つ日時。
-}
fieldsOf : Model -> List FieldDef
fieldsOf model =
    case Loaded.toMaybe model.contentType of
        Just detail ->
            Filter.filterable detail

        Nothing ->
            []


fieldOf : Model -> String -> Maybe FieldDef
fieldOf model apiId =
    fieldsOf model |> List.filter (\field -> field.apiId == apiId) |> List.head


inputOf : Model -> Condition -> Maybe Filter.Input
inputOf model condition =
    fieldOf model condition.apiId |> Maybe.map (\field -> Filter.inputFor field condition.op)



-- 画面


view : Model -> Html Msg
view model =
    Loaded.view
        { loading = Ui.loadingCard
        , missing = Ui.messageCard "この API はありません" [ Ui.note [ text "左の一覧から選び直してください。" ] ]
        , failed = Ui.failedCard
        , present = viewList model
        }
        model.contentType


viewList : Model -> ContentTypeDetail -> Html Msg
viewList model detail =
    div [ class "flex flex-col gap-4 py-6" ]
        -- **題は 1 行に切る。** 長い名前で折り返すと、右の操作が縦につぶれる
        -- （実際に「ボード」が 2 行、「+ 追加」が縦書きになった）。全部はホバーで読める。
        [ div [ class "flex items-center gap-3" ]
            [ div [ class "flex min-w-0 items-center gap-3" ]
                [ Html.h1
                    [ class "truncate text-xl font-semibold text-ink", Html.Attributes.title detail.name ]
                    [ text detail.name ]
                , span
                    [ class "shrink-0 rounded border border-edge px-1.5 py-0.5 font-mono text-[11px] whitespace-nowrap text-ink-soft" ]
                    [ text ("/" ++ detail.apiId) ]
                ]
            , div [ class "ml-auto flex shrink-0 items-center gap-2" ]
                [ Ui.ghostButton [ onClick ApiPreviewWanted ] [ text "API" ]
                , Ui.plainLink [ Html.Attributes.href (Route.toString (Route.Board model.project detail.apiId)) ]
                    [ Ui.ghostButton [] [ text "ボード" ] ]
                , Ui.plainLink [ Html.Attributes.href (Route.toString (Route.NewEntry model.project detail.apiId)) ]
                    [ Ui.button [ class "whitespace-nowrap" ] [ text "+ 追加" ] ]
                ]
            ]

        -- **絞り込みと並び替えを 2 つの塊に分ける。** 1 つの折り返す行に混ぜると、
        -- 並び替えが次の行に落ちた時に横いっぱいに伸びる（実際に伸びた）。
        , div [ class "flex flex-wrap items-center justify-between gap-2" ]
            [ div [ class "flex flex-wrap items-center gap-2" ]
                [ Ui.input
                    [ value model.query.search
                    , onInput SearchTyped
                    , placeholder "中身を検索"
                    , class "w-64"
                    ]
                , Ui.select [ onInput StageChosen ] stageOptions model.query.stage
                , Ui.ghostButton [ onClick FilterOpened ] [ text "+ 絞り込み" ]
                ]
            , Ui.select [ onInput OrderChosen, class "max-w-56" ] (orderOptions detail) model.query.order
            ]
        , viewChips model
        , case model.adding of
            Just draft ->
                viewAdding model draft

            Nothing ->
                text ""
        , Loaded.view
            { loading = Ui.loadingCard
            , missing = Ui.table [ Ui.empty "コンテンツがありません" ]
            , failed = Ui.failedCard
            , present = viewRows model detail
            }
            model.entries
        ]


{-| 今かかっている条件。**1 つずつ外せる。**
-}
viewChips : Model -> Html Msg
viewChips model =
    if List.isEmpty model.query.conditions then
        text ""

    else
        div [ class "flex flex-wrap items-center gap-1.5" ]
            (List.indexedMap (viewChip model) model.query.conditions
                ++ [ Ui.quietActionLink [ class "px-1.5", onClick FiltersCleared ] [ text "条件をすべて外す" ] ]
            )


{-| 条件 1 つ。**項目 → 値 → 演算子**の順に描く。演算子は値の後ろに置いて文が終わる
言葉なので（`Filter.opText`）、この順でだけ「タイトル 移行 を含む」と読める。
-}
viewChip : Model -> Int -> Condition -> Html Msg
viewChip model at condition =
    Html.button
        [ class "flex items-center gap-1.5 rounded-full border border-edge bg-well px-2.5 py-1 text-[11px] text-ink hover:border-[color:var(--color-bad)]"
        , Html.Attributes.type_ "button"
        , Html.Attributes.title "押すとこの条件を外す"
        , onClick (FilterRemoved at)
        ]
        [ span [ class "font-medium" ] [ text (fieldName model condition.apiId) ]
        , if Filter.needsValue condition.op then
            span [ class "font-medium" ] [ text (valueText model condition) ]

          else
            text ""
        , span [ class "text-ink-soft" ]
            [ text
                (fieldOf model condition.apiId
                    |> Maybe.map (\field -> Filter.opTextFor field condition.op)
                    |> Maybe.withDefault (Filter.opText condition.op)
                )
            ]
        , span [ class "text-ink-faint" ] [ text "×" ]
        ]


fieldName : Model -> String -> String
fieldName model apiId =
    fieldOf model apiId |> Maybe.map .name |> Maybe.withDefault apiId


{-| チップに出す値。**参照は id ではなく見出し**（引けていなければ id のまま）。
-}
valueText : Model -> Condition -> String
valueText model condition =
    case Dict.get condition.value model.labels of
        Just label ->
            label

        Nothing ->
            if condition.value == "true" then
                "はい"

            else if condition.value == "false" then
                "いいえ"

            else
                condition.value


{-| 条件を作る所。**項目 → 演算子 → 値を 1 行に並べ、ラベルは置かない。**

WhyNot: 「項目」「条件」「値」の見出しを上に重ねない。3 つ並ぶと絞り込みの行だけで
高さが 2 倍になり、狭い画面では見出しと入力が食い違う所に折り返す（実際にずれた）。
調べた各社（Notion / Strapi / Sanity / Airtable）もラベルを持たず、読み上げ用の
`aria-label` だけを付けている。

-}
viewAdding : Model -> Condition -> Html Msg
viewAdding model draft =
    let
        field : Maybe FieldDef
        field =
            fieldOf model draft.apiId

        ready : Bool
        ready =
            not (Filter.needsValue draft.op) || not (String.isEmpty draft.value)
    in
    -- **中身の幅に収める。** 横いっぱいに伸ばすと、3 つの入力が左端に寄って
    -- 右に何も無い帯が残る。
    Ui.card [ class "flex w-fit max-w-full flex-wrap items-start gap-2 p-3" ]
        [ Ui.select [ onInput FilterFieldChosen, ariaLabel "絞り込む項目" ]
            (fieldsOf model |> List.map (\f -> ( f.apiId, f.name )))
            draft.apiId
        , Ui.select [ onInput FilterOpChosen, ariaLabel "条件" ]
            (field |> Maybe.map Filter.opsFor |> Maybe.withDefault [])
            draft.op
        , case field |> Maybe.map (\f -> Filter.inputFor f draft.op) of
            Just Filter.NoInput ->
                text ""

            Just input ->
                viewValueInput model draft input

            Nothing ->
                text ""
        , div [ class "flex items-center gap-2" ]
            [ Ui.button
                [ onClick FilterAdded
                , Html.Attributes.disabled (not ready)
                , class "disabled:cursor-not-allowed disabled:opacity-50"
                ]
                [ text "絞り込む" ]
            , Ui.ghostButton [ onClick FilterClosed ] [ text "閉じる" ]
            ]
        ]


ariaLabel : String -> Html.Attribute msg
ariaLabel =
    Html.Attributes.attribute "aria-label"


{-| 値の入れ方は**フィールドの種類で決まる**。参照だけは候補を検索して選ぶ（id を打たせない）。
-}
viewValueInput : Model -> Condition -> Filter.Input -> Html Msg
viewValueInput model draft input =
    case input of
        Filter.TextInput ->
            Ui.input [ value draft.value, onInput FilterValueTyped, ariaLabel "値", class "w-56" ]

        Filter.NumberInput ->
            Ui.input [ value draft.value, onInput FilterValueTyped, ariaLabel "値", Html.Attributes.type_ "number", class "w-32" ]

        Filter.DateInput ->
            viewDatePick model draft

        Filter.BoolInput ->
            Ui.select [ onInput FilterValueTyped, ariaLabel "値" ] [ ( "", "選んでください" ), ( "true", "はい" ), ( "false", "いいえ" ) ] draft.value

        Filter.ChoiceInput options ->
            Ui.select [ onInput FilterValueTyped, ariaLabel "値" ]
                (( "", "選んでください" ) :: List.map (\option -> ( option, option )) options)
                draft.value

        Filter.EntryInput _ ->
            viewEntryPicker model draft

        Filter.NoInput ->
            text ""


{-| 日付の値。**押すと暦が開く。** `<input type="date">` は使わない（並びも暦もブラウザの
言語で決まり、文字で打ちたい場面がほとんど無い）。日を押したらその場で値になる。
-}
viewDatePick : Model -> Condition -> Html Msg
viewDatePick model draft =
    div [ class "relative" ]
        [ Ui.ghostButton [ onClick DatePickOpened, class "w-44 justify-between" ]
            [ span []
                [ text
                    (if String.isEmpty draft.value then
                        "日付を選ぶ"

                     else
                        draft.value
                    )
                ]
            , Icon.view Icon.calendar
            ]
        , case model.datePick of
            Just picked ->
                div [ class "absolute top-9 left-0 z-(--z-dropdown)" ] [ Html.map DatePickMsg (Ui.DateTime.viewDate picked) ]

            Nothing ->
                text ""
        , case model.datePick of
            Just _ ->
                Ui.dismissLayer DatePickClosed

            Nothing ->
                text ""
        ]


{-| 参照の候補。**打つたびに引き直す**ので、参照先がいくつあっても選べる。
-}
viewEntryPicker : Model -> Condition -> Html Msg
viewEntryPicker model draft =
    div [ class "flex flex-col gap-1.5" ]
        [ Ui.input
            [ value model.candidateQuery
            , onInput CandidateTyped
            , placeholder "名前で探す"
            , class "w-56"
            ]
        , div [ class "flex max-h-40 w-56 flex-col overflow-auto rounded-md border border-edge bg-panel" ]
            (if List.isEmpty model.candidates then
                [ span [ class "px-2 py-2 text-xs text-ink-faint" ] [ text "候補がありません" ] ]

             else
                List.map (viewCandidate draft) model.candidates ++ viewCandidateRest model
            )
        ]


{-| 出し切れなかった分の断り。

WhyNot: 出した分だけで終わらせない。1 度に引くのは 20 件なので、21 件目以降は
黙って落ちる。**ここからは絞って辿り着く**ので、その旨を添える。

-}
viewCandidateRest : Model -> List (Html Msg)
viewCandidateRest model =
    let
        rest : Int
        rest =
            model.candidateTotal - List.length model.candidates
    in
    if rest > 0 then
        [ span [ class "border-t border-edge px-2 py-2 text-[11px] text-ink-faint" ]
            [ text ("ほかに " ++ String.fromInt rest ++ " 件あります。打つと絞り込めます。") ]
        ]

    else
        []


viewCandidate : Condition -> ( String, String ) -> Html Msg
viewCandidate draft ( entryId, label ) =
    Html.button
        [ class
            ("truncate px-2 py-1.5 text-left text-[13px] hover:bg-raised "
                ++ (if draft.value == entryId then
                        "bg-well font-semibold text-ink"

                    else
                        "text-ink-soft"
                   )
            )
        , onClick (FilterValueTyped entryId)
        ]
        [ text label ]


viewRows : Model -> ContentTypeDetail -> EntryList -> Html Msg
viewRows model detail page =
    if List.isEmpty page.nodes then
        Ui.table [ Ui.empty "コンテンツがありません" ]

    else
        div [ class "flex flex-col gap-2" ]
            [ Ui.table
                (Ui.headRow
                    [ sortHead model (titleKey detail) "タイトル"

                    -- **公開状態では並べ替えない。** `stage` は `EntryOrderBy` の組み込みの
                    -- キーに無く、フィールドとして読まれて全部 NULL になる。断られないまま
                    -- 何も起きないので、押せる形にしない。
                    , text "公開状態"
                    , sortHead model (Just "updatedAt") "更新日時"
                    , text ""
                    ]
                    :: List.map (viewRow model detail) page.nodes
                )
            , viewPager model page
            ]


{-| 押して並べ替えられる見出し。**矢印は並べている列にだけ出し**、他はホバーで薄く出す
（Material / Carbon / Fluent が揃ってこの形。常に出す物は 1 つも無かった）。

同じ見出しをもう一度押すと逆になる 2 段階で、**最初は昇順**（Primer の
"unsorted columns sort in ascending order on first click"）。

-}
sortHead : Model -> Maybe String -> String -> Html Msg
sortHead model key label =
    case key of
        Nothing ->
            text label

        Just sortKey ->
            let
                ( active, direction ) =
                    sortOf model.query

                on : Bool
                on =
                    active == sortKey

                ascNext : Bool
                ascNext =
                    not (on && direction == "asc")
            in
            Html.button
                [ class "group flex min-w-0 items-center gap-1 text-left hover:text-ink"
                , Html.Attributes.type_ "button"
                , Html.Attributes.title
                    (label
                        ++ (if ascNext then
                                "を昇順で並べ替え"

                            else
                                "を降順で並べ替え"
                           )
                    )
                , ariaLabel
                    (label
                        ++ (if on then
                                "（並べ替え中）"

                            else
                                ""
                           )
                    )
                , onClick (SortChosen sortKey)
                ]
                [ span [ class "truncate" ] [ text label ]
                , span
                    [ class
                        ("text-[10px] "
                            ++ (if on then
                                    "text-ink"

                                else
                                    "text-ink-faint opacity-0 group-hover:opacity-100"
                               )
                        )
                    , Html.Attributes.attribute "aria-hidden" "true"
                    ]
                    [ text
                        (if on && direction == "desc" then
                            "↓"

                         else
                            "↑"
                        )
                    ]
                ]


{-| 1 列目（タイトル）が何で並ぶか。`EntryLabel.byField` と同じ**最初のテキスト**を使う
（別の物で並べると、見えている文字と並びが噛み合わない）。テキストが 1 つも無い型は
押せない見出しにする。
-}
titleKey : ContentTypeDetail -> Maybe String
titleKey detail =
    detail.fields |> List.filter (\field -> field.kind == "TEXT") |> List.head |> Maybe.map .apiId


{-| 今の並び。空は CMS の既定と同じ意味なので、そこに開いて見出しの矢印を出す。
-}
sortOf : Query -> ( String, String )
sortOf query =
    case String.split ":" query.order of
        [ key, direction ] ->
            if String.isEmpty key then
                defaultSort

            else
                ( key, direction )

        _ ->
            defaultSort


defaultSort : ( String, String )
defaultSort =
    ( "updatedAt", "desc" )


{-| 既定と同じ並びは URL に書かない。**書くとセレクトの選択と食い違う**
（同じ並びを空と `updatedAt:desc` の 2 通りで表す事になる）。
-}
normalizeOrder : String -> String
normalizeOrder order =
    if order == "updatedAt:desc" then
        ""

    else
        order


{-| 公開状態の絞り込み。値は CMS の ContentStage に合わせる。
-}
stageOptions : List ( String, String )
stageOptions =
    [ ( "", "すべての状態" ), ( "DRAFT", "下書き" ), ( "PUBLISHED", "公開中" ), ( "CHANGED", "公開中 · 下書きあり" ) ]


{-| 並び替え。**見出しを押せない列**（狭い画面で畳まれる更新日時、列に出ていない
公開日時やフィールド）はここからしか選べないので、見出しと併せて残す。

言葉は「項目名 ＋ の ＋ 向き」で、**間に空白を入れない**。向きは種類で言い分ける。

-}
orderOptions : ContentTypeDetail -> List ( String, String )
orderOptions detail =
    [ ( "", "更新日時の新しい順" )
    , ( "updatedAt:asc", "更新日時の古い順" )
    , ( "publishedAt:desc", "公開日時の新しい順" )
    , ( "publishedAt:asc", "公開日時の古い順" )
    , ( "createdAt:desc", "作成日時の新しい順" )
    , ( "createdAt:asc", "作成日時の古い順" )
    ]
        ++ (detail.fields
                |> List.filter (\field -> not field.many && List.member field.kind [ "TEXT", "TEXT_AREA", "SLUG", "NUMBER", "DATE", "DATE_ONLY" ])
                |> List.concatMap
                    (\field ->
                        [ ( field.apiId ++ ":asc", field.name ++ orderWord field.kind True )
                        , ( field.apiId ++ ":desc", field.name ++ orderWord field.kind False )
                        ]
                    )
           )


{-| 向きの言葉。**種類で言い分ける**（日時は新しい / 古い、数は大きい / 小さい、
文字は昇順 / 降順。Excel の日本語がこの分け方）。
-}
orderWord : String -> Bool -> String
orderWord kind ascending =
    case ( List.member kind [ "DATE", "DATE_ONLY" ], kind == "NUMBER", ascending ) of
        ( True, _, True ) ->
            "の古い順"

        ( True, _, False ) ->
            "の新しい順"

        ( _, True, True ) ->
            "の小さい順"

        ( _, True, False ) ->
            "の大きい順"

        ( _, _, True ) ->
            "の昇順"

        ( _, _, False ) ->
            "の降順"


viewPager : Model -> Model.EntryList -> Html Msg
viewPager model page =
    let
        shown : Int
        shown =
            List.length page.nodes

        from : Int
        from =
            (model.query.page - 1) * perPage + 1
    in
    div [ class "flex items-center gap-3 text-xs text-ink-soft" ]
        [ text ("全 " ++ String.fromInt page.totalCount ++ " 件のうち " ++ String.fromInt from ++ "〜" ++ String.fromInt (from + shown - 1) ++ " 件")
        , div [ class "ml-auto flex gap-2" ]
            [ if model.query.page > 1 then
                Ui.ghostButton [ onClick (PageMoved -1) ] [ text "前へ" ]

              else
                text ""
            , if from + shown - 1 < page.totalCount then
                Ui.ghostButton [ onClick (PageMoved 1) ] [ text "次へ" ]

              else
                text ""
            ]
        ]


viewRow : Model -> ContentTypeDetail -> EntryRow -> Html Msg
viewRow model detail row =
    Ui.row
        [ Ui.titleLink
            [ Html.Attributes.href (Route.toString (Route.Entry model.project detail.apiId row.id))
            , class "flex w-full min-w-0 items-center gap-2 font-medium"
            ]
            [ span [ class "text-ink-faint" ] [ Icon.view Icon.entry ]
            , span [ class "truncate" ] [ text (EntryLabel.byField detail.fields row) ]
            ]
        , stageChip row.stage
        , span [ class "font-mono text-[11px] text-ink-soft" ] [ text (String.replace "T" " " (String.left 16 row.updatedAt)) ]
        , text ""
        ]


stageChip : String -> Html msg
stageChip stage =
    case stage of
        "PUBLISHED" ->
            Ui.chip Ui.toneOk "公開中"

        "CHANGED" ->
            Ui.chip Ui.toneWarn "公開中 · 下書きあり"

        _ ->
            Ui.chip Ui.toneNeutral "下書き"
