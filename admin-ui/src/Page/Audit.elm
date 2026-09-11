module Page.Audit exposing (Model, Msg(..), init, update, urlOf, view)

{-| プロジェクト設定 › 監査ログ。誰が・いつ・何を変えたか。読むだけ。

絞り込み（誰が / 何を / 期間）は全部サーバの引数で、URL に持つ（一覧と同じ決め）。
行にも固定の URL（`?id=`）があり、その 1 行を人に渡せる。

時刻は手元のタイムゾーンで出し、展開した所に UTC の ISO 8601 を添える。
タイムゾーンは親が `Effect.Today` で引いて `ZoneKnown` で渡す。**それが来てから引く**
（期間の始まりと終わりを手元の 0 時で UTC に直すのに要る）。

-}

import Api
import Api.Admin.Enum.ActorKind as ActorKind
import Dict
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, href, title, type_)
import Html.Events exposing (onClick, onInput)
import Json.Decode as D
import Json.Encode as E
import Loaded exposing (Loaded)
import Model exposing (AuditRow, ContentTypeSummary, Slug)
import Page.Audit.Say as Say
import Queries
import Route
import Set exposing (Set)
import Time
import Ui
import Ui.DateRange
import Ui.DateTime as DateTime
import Ui.Icon as Icon


type alias Model =
    { project : Slug
    , zone : Maybe Time.Zone

    {- 今日。「過去 7 日間」の基準と、暦の初めの月に使う。 -}
    , today : Maybe { year : Int, month : Int, day : Int }
    , kind : String
    , action : String
    , since : String
    , until : String

    {- 期間を選ぶ暦。since / until はここから写す。 -}
    , range : Ui.DateRange.Model

    {- URL の `?id=` で指された行。一覧に無ければその旨を出す。 -}
    , wanted : Maybe String
    , rows : Loaded (List AuditRow)
    , opened : Set String
    , more : Bool
    , busy : Bool
    , errors : List String
    }


type Msg
    = ZoneKnown Time.Zone Int Int Int
    | GotRows (Result Api.Problem (List AuditRow))
    | GotMore (Result Api.Problem (List AuditRow))
    | KindChosen String
    | ActionChosen String
    | RangeMsg Ui.DateRange.Msg
    | EscapePressed
    | Toggled String
    | MoreRequested


{-| 1 ページの件数。返りがこれより少なければ「もっと見る」を消す。
-}
pageSize : Int
pageSize =
    50


init : Slug -> List ( String, String ) -> Model
init project params =
    let
        param : String -> String
        param key =
            params |> List.filter (\( k, _ ) -> k == key) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault ""

        wanted : Maybe String
        wanted =
            if String.isEmpty (param "id") then
                Nothing

            else
                Just (param "id")
    in
    { project = project
    , zone = Nothing
    , today = Nothing
    , kind = param "kind"
    , action = param "action"
    , since = param "since"
    , until = param "until"
    , range = Ui.DateRange.init { since = param "since", until = param "until" }
    , wanted = wanted
    , rows = Loaded.Loading
    , opened = wanted |> Maybe.map Set.singleton |> Maybe.withDefault Set.empty
    , more = False
    , busy = False
    , errors = []
    }


{-| 今の絞り込みで先頭から引く。
-}
load : Model -> List (Api.Call Msg)
load model =
    [ Api.call (\id -> Queries.auditEvents id model.project (queryOf model Nothing)) GotRows ]


queryOf : Model -> Maybe String -> Queries.AuditQuery
queryOf model after =
    let
        zone : Time.Zone
        zone =
            Maybe.withDefault Time.utc model.zone
    in
    { first = pageSize
    , after = after
    , actorKind = ActorKind.fromString model.kind
    , action = blankToNothing model.action
    , since = DateTime.dayToIso zone model.since
    , until = DateTime.dayAfterToIso zone model.until
    }


blankToNothing : String -> Maybe String
blankToNothing text =
    if String.isEmpty text then
        Nothing

    else
        Just text


{-| 今の絞り込みの URL。親がこれで URL を書き換える。
-}
urlOf : Model -> String
urlOf model =
    Route.toString (Route.Settings model.project (Route.Audit (paramsOf model)))


paramsOf : Model -> List ( String, String )
paramsOf model =
    [ ( "kind", model.kind )
    , ( "action", model.action )
    , ( "since", model.since )
    , ( "until", model.until )
    , ( "id", Maybe.withDefault "" model.wanted )
    ]
        |> List.filter (\( _, v ) -> not (String.isEmpty v))


update : Msg -> Model -> ( Model, List (Api.Call Msg) )
update msg model =
    case msg of
        ZoneKnown zone year month day ->
            let
                next : Model
                next =
                    { model
                        | zone = Just zone
                        , today = Just { year = year, month = month, day = day }
                        , range = Ui.DateRange.withToday { year = year, month = month, day = day } model.range
                    }
            in
            ( next, load next )

        GotRows result ->
            ( { model
                | rows = Loaded.fromResult (Result.map Just result)
                , more = Result.map (\rows -> List.length rows >= pageSize) result |> Result.withDefault False
              }
            , []
            )

        GotMore (Ok rows) ->
            ( { model
                | busy = False
                , rows = Loaded.map (\shown -> shown ++ rows) model.rows
                , more = List.length rows >= pageSize
              }
            , []
            )

        GotMore (Err problem) ->
            ( { model | busy = False, errors = [ (Api.problemToText problem).message ] }, [] )

        KindChosen kind ->
            refilter { model | kind = kind }

        ActionChosen action ->
            refilter { model | action = action }

        -- 開いている暦を 1 段閉じる
        EscapePressed ->
            ( { model | range = Ui.DateRange.close model.range }, [] )

        -- 暦を触るたびに引き直さない。期間が決まった（または外した）時だけ
        RangeMsg rangeMsg ->
            let
                range : Ui.DateRange.Model
                range =
                    Ui.DateRange.update rangeMsg model.range

                picked : { since : String, until : String }
                picked =
                    Ui.DateRange.dates range
            in
            if picked.since == model.since && picked.until == model.until then
                ( { model | range = range }, [] )

            else
                refilter { model | range = range, since = picked.since, until = picked.until }

        Toggled id ->
            ( { model
                | opened =
                    if Set.member id model.opened then
                        Set.remove id model.opened

                    else
                        Set.insert id model.opened
              }
            , []
            )

        MoreRequested ->
            case lastId model of
                Just id ->
                    ( { model | busy = True, errors = [] }
                    , [ Api.call (\requestId -> Queries.auditEvents requestId model.project (queryOf model (Just id))) GotMore ]
                    )

                Nothing ->
                    ( model, [] )


{-| 絞り込みを変えたら先頭から引き直す。**指された行は解く**（絞り込んだ一覧の物ではなくなる）。
-}
refilter : Model -> ( Model, List (Api.Call Msg) )
refilter model =
    let
        next : Model
        next =
            { model | wanted = Nothing, rows = Loaded.Loading, opened = Set.empty, more = False, errors = [] }
    in
    ( next, load next )


lastId : Model -> Maybe String
lastId model =
    Loaded.toMaybe model.rows |> Maybe.andThen (List.reverse >> List.head) |> Maybe.map .id



-- 画面


view : { canManage : Bool, types : List ContentTypeSummary } -> Model -> Html Msg
view args model =
    Ui.page []
        [ Ui.pageHeader { title = "監査ログ", icon = Nothing, meta = [], actions = [] }
        , Ui.note
            [ text ("無期限に残ります · 書き換え不可 · 時刻は" ++ zoneNote model) ]
        , if args.canManage then
            div [ class "flex flex-col gap-3" ]
                [ viewFilters model
                , Ui.errors model.errors
                , viewMissing model
                , viewRows (List.map .apiId args.types) model
                , viewMore model
                ]

          else
            Ui.messageCard "owner だけが見られます" []
        ]


zoneNote : Model -> String
zoneNote model =
    case model.zone of
        Just zone ->
            "ブラウザのタイムゾーン（" ++ DateTime.zoneAbbr zone "" ++ "）"

        Nothing ->
            "ブラウザのタイムゾーン"


kindOptions : List ( String, String )
kindOptions =
    ( "", "すべて" ) :: List.map (\kind -> ( ActorKind.toString kind, ActorKind.toString kind )) ActorKind.list


actionOptions : List ( String, String )
actionOptions =
    ( "", "すべて" )
        :: List.map (\prefix -> ( prefix, prefix ))
            [ "member.", "api_key.", "type.", "field.", "webhook.", "asset.", "entry.", "project." ]


viewFilters : Model -> Html Msg
viewFilters model =
    Ui.card [ class "flex flex-wrap items-end gap-4 p-4" ]
        [ Ui.field { label = "誰が", hint = Nothing, errors = [] }
            [ Ui.select [ onInput KindChosen ] kindOptions model.kind ]
        , Ui.field { label = "何を", hint = Nothing, errors = [] }
            [ Ui.select [ onInput ActionChosen ] (actionOptions ++ customAction model) model.action ]
        , Ui.field { label = "期間", hint = Nothing, errors = [] }
            [ Ui.DateRange.view RangeMsg model.range ]
        ]


{-| URL で来た前方一致が選択肢に無ければ、その値を選択肢に足す（選び直せるまで消えない）。
-}
customAction : Model -> List ( String, String )
customAction model =
    if String.isEmpty model.action || List.any (\( v, _ ) -> v == model.action) actionOptions then
        []

    else
        [ ( model.action, model.action ) ]


{-| `?id=` で指された行が一覧に無い時の断り。
-}
viewMissing : Model -> Html Msg
viewMissing model =
    case ( model.wanted, Loaded.toMaybe model.rows ) of
        ( Just id, Just rows ) ->
            if List.any (\row -> row.id == id) rows then
                text ""

            else
                Ui.callout Ui.toneWarn [] [ text ("この行（" ++ id ++ "）は表示範囲にありません。絞り込みを外すか「もっと見る」で探してください。") ]

        _ ->
            text ""


{-| 一覧。`existing` は今ある型の apiId で、消えた型・フィールド・entry にはリンクを付けない。
-}
viewRows : List String -> Model -> Html Msg
viewRows existing model =
    Loaded.view
        { loading = Ui.loadingCard
        , missing = Ui.table [ Ui.empty "記録がありません" ]
        , failed = Ui.failedCard
        , present =
            \rows ->
                if List.isEmpty rows then
                    Ui.table [ Ui.empty "この条件に当たる記録はありません" ]

                else
                    Ui.table
                        (Ui.headRowOf columns [ text "時刻", text "誰が", text "何を", text "" ]
                            :: List.concatMap (viewRow existing model) rows
                        )
        }
        model.rows


columns : String
columns =
    "grid-cols-[130px_minmax(0,220px)_minmax(0,1fr)_32px]"


viewRow : List String -> Model -> AuditRow -> List (Html Msg)
viewRow existing model row =
    let
        open : Bool
        open =
            Set.member row.id model.opened

        zone : Time.Zone
        zone =
            Maybe.withDefault Time.utc model.zone
    in
    Ui.rowOf columns
        [ span [ class "font-mono text-[12px] whitespace-nowrap", title row.createdAt ]
            [ text (DateTime.formatLocalShort zone row.createdAt ++ " " ++ DateTime.zoneAbbr zone row.createdAt) ]
        , div [ class "flex min-w-0 items-center gap-2" ]
            [ Ui.chip (kindTone row.actorKind) row.actorKind
            , span [ class "truncate", title row.actor ] [ text row.actor ]
            ]
        , viewWhat existing model zone row
        , Html.button
            [ class "flex h-7 w-7 cursor-pointer items-center justify-center rounded text-ink-soft hover:bg-well hover:text-ink"
            , type_ "button"
            , title
                (if open then
                    "閉じる"

                 else
                    "詳しく"
                )
            , onClick (Toggled row.id)
            ]
            [ span
                [ class
                    (if open then
                        "transition-transform"

                     else
                        "-rotate-90 transition-transform"
                    )
                ]
                [ Icon.view Icon.caret ]
            ]
        ]
        :: (if open then
                [ viewDetail model zone row ]

            else
                []
           )


{-| 何を。上に小さく action、下に人の文。
-}
viewWhat : List String -> Model -> Time.Zone -> AuditRow -> Html Msg
viewWhat existing model zone row =
    let
        pieces : Say.Sentence
        pieces =
            Say.sentence zone row
    in
    div [ class "flex min-w-0 flex-col leading-5" ]
        [ span [ class "font-mono text-[11px] text-ink-faint" ] [ text row.action ]
        , span [ class "text-ink", title (Say.toText pieces) ] (List.map (viewPiece existing model row) pieces)
        ]


viewPiece : List String -> Model -> AuditRow -> Say.Piece -> Html Msg
viewPiece existing model row piece =
    case piece of
        Say.Text label ->
            text label

        Say.Strong label ->
            Html.strong [ class "font-semibold" ] [ text label ]

        Say.TargetLink label ->
            case targetRoute existing model row of
                Just route ->
                    Ui.link [ href (Route.toString route), class "font-semibold" ] [ text label ]

                Nothing ->
                    Html.strong [ class "font-semibold", title "消えています" ] [ text label ]


{-| 誰がの印の色。人は薄く、鍵と PAT と SYSTEM は目に付く色（人でない物が一目で分かる）。
-}
kindTone : String -> String
kindTone kind =
    case kind of
        "USER" ->
            Ui.toneNeutral

        "SYSTEM" ->
            Ui.toneOk

        _ ->
            Ui.toneWarn


{-| 対象の画面。entry と型・フィールドは、その型が今もあればその画面へ飛べる。

WhyNot: 消した物にリンクを付けない。`type.deleted` の行から型の画面へ飛ぶと「この API はありません」で
終わるだけで、監査ログは消した後にこそ読まれる。消した物は `before` を開いて読む。

-}
targetRoute : List String -> Model -> AuditRow -> Maybe Route.Route
targetRoute existing model row =
    let
        ifTypeExists : String -> Route.Route -> Maybe Route.Route
        ifTypeExists typeApiId route =
            if List.member typeApiId existing then
                Just route

            else
                Nothing

        typeOfField : String
        typeOfField =
            String.split "." row.targetId |> List.head |> Maybe.withDefault row.targetId
    in
    case ( row.targetKind, typeApiIdOf row ) of
        ( "entry", Just typeApiId ) ->
            if row.action == "entry.deleted" then
                Nothing

            else
                ifTypeExists typeApiId (Route.Entry model.project typeApiId row.targetId)

        ( "type", _ ) ->
            ifTypeExists row.targetId (Route.TypeSchema model.project row.targetId)

        ( "field", _ ) ->
            ifTypeExists typeOfField (Route.TypeSchema model.project typeOfField)

        _ ->
            Nothing


{-| entry の行は detail に型の apiId を持つ。
-}
typeApiIdOf : AuditRow -> Maybe String
typeApiIdOf row =
    D.decodeValue (D.field "typeApiId" D.string) row.detail |> Result.toMaybe


{-| 開いた行。meta の行、action ごとの型紙、畳んだ JSON。
-}
viewDetail : Model -> Time.Zone -> AuditRow -> Html Msg
viewDetail model zone row =
    div [ class "flex flex-col gap-2 border-b border-edge bg-raised px-4 py-3 text-[12px] text-ink-soft last:border-b-0" ]
        [ div [ class "flex flex-wrap items-center gap-x-4 gap-y-1 font-mono" ]
            [ span [] [ text row.createdAt ]
            , span [] [ text ("actorId " ++ blankAs "—" row.actorId) ]
            , span [] [ text ("id " ++ row.id) ]
            , Ui.quietLink [ href (Route.toString (Route.Settings model.project (Route.Audit [ ( "id", row.id ) ]))), title "この行の URL" ] [ text "#" ]
            ]
        , viewSheet zone (Say.sheet row)
        , if row.action == "type.deleted" then
            div []
                [ Ui.ghostButton [ Html.Attributes.disabled True, class "border-dashed text-ink-faint", title "API の定義を書き戻す口が入ってから" ] [ text "この姿に戻す" ] ]

          else
            text ""
        , if hasNested row.detail then
            Html.details [ class "text-ink-soft" ]
                [ Html.summary [ class "cursor-pointer select-none hover:text-ink" ] [ text "JSON を見る" ]
                , Html.pre [ class "mt-2 overflow-x-auto rounded-md border border-edge bg-panel px-3 py-2 font-mono text-[11px] leading-5 whitespace-pre text-ink" ]
                    [ text (E.encode 2 row.detail) ]
                ]

          else
            text ""
        ]


{-| detail に入れ子（オブジェクトか配列）があるか。無ければ型紙が全部を出しているので、JSON の畳みを出さない
（`{"role": "writer"}` を「権限 投稿者」の下にもう 1 度出しても、増える情報が無い）。
-}
hasNested : D.Value -> Bool
hasNested value =
    D.decodeValue (D.dict D.value) value
        |> Result.map (Dict.values >> List.any isNested)
        |> Result.withDefault False


isNested : D.Value -> Bool
isNested value =
    D.decodeValue (D.oneOf [ D.dict D.value |> D.map (always True), D.list D.value |> D.map (always True) ]) value
        |> Result.withDefault False


viewSheet : Time.Zone -> Say.Sheet -> Html Msg
viewSheet zone sheet =
    case sheet of
        Say.Changes changes ->
            viewKv (List.map viewChange changes)

        Say.Order order ->
            viewKv
                (( "変更前", viewChips order.moved order.before )
                    :: (case order.after of
                            Just after ->
                                [ ( "今の並び", viewChips order.moved after ) ]

                            Nothing ->
                                []
                       )
                )

        Say.FieldTable rows ->
            viewFieldTable rows

        Say.Facts facts ->
            viewKv (List.map (\( key, value ) -> ( key, span [ title (factHint key) ] [ text (factText zone key value) ] )) facts)

        Say.Nothing_ ->
            text ""


{-| 予約の時刻だけは手元のタイムゾーンで出す。
-}
factText : Time.Zone -> String -> String -> String
factText zone key value =
    if key == "予約" then
        DateTime.formatLocal zone value ++ " " ++ DateTime.zoneAbbr zone value

    else
        value


{-| 説明が要る見出しだけ hover で補う。
-}
factHint : String -> String
factHint key =
    if key == "URL の照合値" then
        "URL の SHA-256 の先頭 12 桁。同じ URL を登録し直せば同じ値になります。URL そのものは残していません"

    else
        ""


viewKv : List ( String, Html Msg ) -> Html Msg
viewKv pairs =
    div [ class "grid max-w-2xl grid-cols-[max-content_minmax(0,1fr)] gap-x-5 gap-y-1 text-[13px] text-ink" ]
        (List.concatMap (\( key, value ) -> [ span [ class "text-ink-faint" ] [ text key ], div [ class "min-w-0" ] [ value ] ]) pairs)


{-| 変更前と、あれば変更後。両方ある時だけ前を消し線に。
-}
viewChange : Say.Change -> ( String, Html Msg )
viewChange change =
    ( change.key
    , case change.after of
        Just after ->
            span []
                [ span [ class "rounded-sm bg-[color:var(--color-bad-bg)] px-1 line-through" ] [ text change.before ]
                , span [ class "mx-1.5 text-ink-faint" ] [ text "→" ]
                , span [ class "rounded-sm bg-[color:var(--color-ok-bg)] px-1" ] [ text after ]
                ]

        Nothing ->
            span [ class "break-all" ] [ text change.before ]
    )


viewChips : List String -> List String -> Html Msg
viewChips moved apiIds =
    div [ class "flex flex-wrap items-center gap-1.5" ]
        (List.map
            (\apiId ->
                Ui.chip
                    (if List.member apiId moved then
                        Ui.toneWarn

                     else
                        Ui.toneNeutral
                    )
                    apiId
            )
            apiIds
        )


fieldColumns : String
fieldColumns =
    "grid-cols-[minmax(0,1fr)_minmax(0,1fr)_110px_40px_minmax(0,1fr)]"


viewFieldTable : List Say.FieldRow -> Html Msg
viewFieldTable rows =
    div [ class "max-w-3xl" ]
        [ Ui.table
            (Ui.headRowOf fieldColumns [ text "フィールド ID", text "表示名", text "種類", text "必須", text "設定" ]
                :: List.map
                    (\row ->
                        Ui.rowOf fieldColumns
                            [ span [ class "font-mono text-[12px]" ] [ text row.apiId ]
                            , span [ class "truncate", title row.name ] [ text row.name ]
                            , span [ class "font-mono text-[11px] text-ink-soft" ] [ text row.kind ]
                            , text
                                (if row.required then
                                    "○"

                                 else
                                    ""
                                )
                            , span [ class "text-ink-soft" ] [ text row.config ]
                            ]
                    )
                    rows
            )
        ]


blankAs : String -> String -> String
blankAs fallback text =
    if String.isEmpty text then
        fallback

    else
        text


viewMore : Model -> Html Msg
viewMore model =
    if model.more then
        div [ class "flex justify-center" ]
            [ Ui.ghostButton [ onClick MoreRequested, Html.Attributes.disabled model.busy ]
                [ text
                    (if model.busy then
                        "読んでいます…"

                     else
                        "もっと見る"
                    )
                ]
            ]

    else
        text ""
