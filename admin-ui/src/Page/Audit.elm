module Page.Audit exposing (Model, Msg(..), init, scrollTarget, update, urlOf, view)

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
import Ui.Reply as Reply exposing (Reply)
import Url.Builder


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

    {- 「この行のリンクをコピー」を押した行。返事を出し、親が数秒で下ろす。 -}
    , copied : Maybe String

    {- 今の絞り込みに当たる件数。一覧と同時に引く。 -}
    , count : Maybe Int

    {- 「エクスポート ▾」の面。 -}
    , exportMenu : Bool

    {- エクスポートの返事。ダウンロードはブラウザ任せなので、開始した旨を出し親が数秒で下ろす。 -}
    , exportReply : Reply
    , more : Bool
    , busy : Bool
    , errors : List String
    }


type Msg
    = ZoneKnown Time.Zone Int Int Int
    | GotRows (Result Api.Problem (List AuditRow))
    | GotMore (Result Api.Problem (List AuditRow))
    | GotCount (Result Api.Problem Int)
    | KindChosen String
    | ActionChosen String
    | RangeMsg Ui.DateRange.Msg
    | EscapePressed
    | Toggled String
    | CopyRequested { id : String, url : String }
    | CopyShown
    | ExportMenuToggled
    | ExportMenuClosed
    | ExportRequested { url : String }
    | ExportShown
    | MoreRequested


{-| 1 ページの件数。返りがこれより少なければ「もっと見る」を消す。
-}
pageSize : Int
pageSize =
    50


{-| エクスポートの上限。サーバの 413 と同じ数。超える時は項目を押せなくする。
-}
exportLimit : Int
exportLimit =
    100000


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
    , copied = Nothing
    , count = Nothing
    , exportMenu = False
    , exportReply = Reply.idle
    , more = False
    , busy = False
    , errors = []
    }


{-| 今の絞り込みで先頭から引く。
-}
load : Model -> List (Api.Call Msg)
load model =
    [ Api.call (\id -> Queries.auditEvents id model.project (queryOf model Nothing)) GotRows
    , Api.call (\id -> Queries.auditEventsCount id model.project (queryOf model Nothing)) GotCount
    ]


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

        -- 件数が引けなくても一覧は出す。件数の文を出さないだけ
        GotCount result ->
            ( { model | count = Result.toMaybe result }, [] )

        KindChosen kind ->
            refilter { model | kind = kind }

        ActionChosen action ->
            refilter { model | action = action }

        -- 開いている物（エクスポートの面か暦）を 1 段閉じる
        EscapePressed ->
            if model.exportMenu then
                ( { model | exportMenu = False }, [] )

            else
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

        -- クリップボードへ書くのは親（port の先）。ここは返事を出すだけ
        CopyRequested { id } ->
            ( { model | copied = Just id }, [] )

        CopyShown ->
            ( { model | copied = Nothing }, [] )

        ExportMenuToggled ->
            ( { model | exportMenu = not model.exportMenu, exportReply = Reply.idle }, [] )

        ExportMenuClosed ->
            ( { model | exportMenu = False }, [] )

        -- URL を開くのは親（port の先）。ここは面を閉じて返事を出すだけ
        ExportRequested _ ->
            ( { model | exportMenu = False, exportReply = Reply.done "エクスポートを開始しました" }, [] )

        ExportShown ->
            ( { model | exportReply = Reply.idle }, [] )

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
            { model | wanted = Nothing, rows = Loaded.Loading, count = Nothing, opened = Set.empty, more = False, errors = [] }
    in
    ( next, load next )


lastId : Model -> Maybe String
lastId model =
    Loaded.toMaybe model.rows |> Maybe.andThen (List.reverse >> List.head) |> Maybe.map .id


{-| エクスポートの URL。絞り込みは `auditEvents` に渡す物と同じ値。`format` は `csv` / `jsonl`。
-}
exportUrl : Model -> String -> String
exportUrl model format =
    let
        query : Queries.AuditQuery
        query =
            queryOf model Nothing

        param : String -> Maybe String -> Maybe Url.Builder.QueryParameter
        param key value =
            Maybe.map (Url.Builder.string key) value
    in
    Url.Builder.absolute [ "p", model.project, "admin", "audit." ++ format ]
        (List.filterMap identity
            [ param "actorKind" (Maybe.map ActorKind.toString query.actorKind)
            , param "action" query.action
            , param "since" query.since
            , param "until" query.until
            ]
        )


hasFilter : Model -> Bool
hasFilter model =
    not (List.all String.isEmpty [ model.kind, model.action, model.since, model.until ])


overLimit : Model -> Bool
overLimit model =
    Maybe.map (\count -> count > exportLimit) model.count |> Maybe.withDefault False


{-| 3 桁ごとにカンマ。
-}
withCommas : Int -> String
withCommas n =
    let
        digits : List Char
        digits =
            String.fromInt n |> String.toList |> List.reverse

        grouped : List Char -> List Char
        grouped chars =
            case chars of
                a :: b :: c :: rest ->
                    if List.isEmpty rest then
                        [ a, b, c ]

                    else
                        a :: b :: c :: ',' :: grouped rest

                short ->
                    short
    in
    grouped digits |> List.reverse |> String.fromList



-- 画面


view : { canManage : Bool, types : List ContentTypeSummary, origin : String } -> Model -> Html Msg
view args model =
    Ui.page []
        [ Ui.pageHeader { title = "監査ログ", icon = Nothing, meta = [], actions = [] }
        , Ui.note
            [ text ("無期限に残ります · 書き換え不可 · 時刻は" ++ zoneNote model) ]
        , if args.canManage then
            div [ class "flex flex-col gap-3" ]
                [ viewFilters model
                , viewCount model
                , Ui.errors model.errors
                , viewMissing model
                , viewRows { existing = List.map .apiId args.types, origin = args.origin } model
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
        , div [ class "ml-auto flex items-center gap-3" ]
            [ Reply.view model.exportReply
            , viewExport model
            ]
        ]


{-| 「エクスポート ▾」。押すと CSV / JSON の 2 項目。上限を超える時は項目を押せない。
-}
viewExport : Model -> Html Msg
viewExport model =
    div [ class "relative" ]
        [ Ui.ghostButton [ onClick ExportMenuToggled, type_ "button" ] [ text "エクスポート ▾" ]
        , if model.exportMenu then
            div [ class "absolute top-9 right-0 z-(--z-dropdown) flex w-56 flex-col rounded-lg border border-edge bg-panel py-1 shadow-lg" ]
                [ viewExportItem model "CSV でエクスポート" "csv"
                , viewExportItem model "JSON でエクスポート" "jsonl"
                ]

          else
            text ""
        , if model.exportMenu then
            Ui.dismissLayer ExportMenuClosed

          else
            text ""
        ]


viewExportItem : Model -> String -> String -> Html Msg
viewExportItem model label format =
    Html.button
        ([ class "flex w-full cursor-pointer items-center gap-2 px-3 py-2 text-left text-[13px] text-ink hover:bg-well disabled:cursor-default disabled:opacity-40"
         , type_ "button"
         , onClick (ExportRequested { url = exportUrl model format })
         ]
            ++ (if overLimit model then
                    [ Html.Attributes.disabled True, title (withCommas exportLimit ++ " 件まで。期間を分けてください") ]

                else
                    []
               )
        )
        [ text label ]


{-| 今の絞り込みに当たる件数。上限を超える時はその旨を薄く添える。
-}
viewCount : Model -> Html Msg
viewCount model =
    case model.count of
        Just count ->
            div [ class "flex flex-wrap items-center gap-2 px-1 text-[12px] text-ink-soft" ]
                [ span []
                    [ text
                        ((if hasFilter model then
                            "この条件に当たる "

                          else
                            ""
                         )
                            ++ withCommas count
                            ++ " 件"
                        )
                    ]
                , if overLimit model then
                    span [ class "text-ink-faint" ] [ text ("（" ++ withCommas exportLimit ++ " 件まで。超える時は期間を分けてください）") ]

                  else
                    text ""
                ]

        Nothing ->
            text ""


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


{-| 一覧に要る周りの値。`existing` は今ある型の apiId で、消えた型・フィールド・entry にはリンクを付けない。
`origin` は行の固定 URL をクリップボードに書く時の頭。
-}
type alias Surround =
    { existing : List String, origin : String }


viewRows : Surround -> Model -> Html Msg
viewRows surround model =
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
                            :: List.concatMap (viewRow surround model) rows
                        )
        }
        model.rows


columns : String
columns =
    "grid-cols-[130px_minmax(0,220px)_minmax(0,1fr)_32px]"


viewRow : Surround -> Model -> AuditRow -> List (Html Msg)
viewRow surround model row =
    let
        open : Bool
        open =
            Set.member row.id model.opened

        zone : Time.Zone
        zone =
            Maybe.withDefault Time.utc model.zone
    in
    div [ Html.Attributes.id (rowDomId row.id) ]
        [ Ui.rowOf columns
            [ span [ class "font-mono text-[12px] whitespace-nowrap", title row.createdAt ]
                [ text (DateTime.formatLocalShort zone row.createdAt ++ " " ++ DateTime.zoneAbbr zone row.createdAt) ]
            , div [ class "flex min-w-0 items-center gap-2" ]
                [ Ui.chip (kindTone row.actorKind) row.actorKind
                , span [ class "truncate", title row.actor ] [ text row.actor ]
                ]
            , viewWhat surround.existing model zone row
            , Ui.iconButton
                { title =
                    if open then
                        "閉じる"

                    else
                        "詳しく"
                , onClick = Toggled row.id
                }
                [ class
                    (if open then
                        "transition-transform"

                     else
                        "-rotate-90 transition-transform"
                    )
                ]
                Icon.caret
            ]
        ]
        :: (if open then
                [ viewDetail surround model zone row ]

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


{-| 開いた行。action ごとの型紙に「操作した人」と「時刻」を続け、下に機械の行（リンクのコピーと id）。

人が読む物（誰が・いつ・何を）を上の型紙にまとめ、機械の値（id）は薄く下に置く。
actorId や ISO 8601 を人の行と同じ大きさで並べると、読む物が増えるだけで誰も見ない。

-}
viewDetail : Surround -> Model -> Time.Zone -> AuditRow -> Html Msg
viewDetail surround model zone row =
    div [ class "flex flex-col gap-2 border-b border-edge bg-raised px-4 py-3 text-[12px] text-ink-soft last:border-b-0" ]
        [ viewSheet zone (Say.sheet row) (viewWho model row ++ [ ( "時刻", viewWhen zone row ) ])
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
        , viewMachine surround model row
        ]


{-| 「操作した人」。人か PAT なら、括弧にメンバーの id を添えてメンバーの画面へ飛べる。
API キーや SYSTEM の id はメンバーではないので文字のまま。id が無ければ括弧ごと出さない。
-}
viewWho : Model -> AuditRow -> List ( String, Html Msg )
viewWho model row =
    let
        memberLike : Bool
        memberLike =
            row.actorKind == "USER" || row.actorKind == "PAT"

        aside : List (Html Msg)
        aside =
            if String.isEmpty row.actorId then
                []

            else if memberLike then
                [ span [ class "text-ink-soft" ]
                    [ text "（メンバー "
                    , Ui.link [ href (Route.toString (Route.Settings model.project Route.Members)), class "font-mono" ] [ text row.actorId ]
                    , text "）"
                    ]
                ]

            else
                [ span [ class "text-ink-soft" ] [ text "（", span [ class "font-mono" ] [ text row.actorId ], text "）" ] ]
    in
    [ ( "操作した人", span [ class "break-all" ] (text row.actor :: aside) ) ]


{-| 「時刻」。手元のタイムゾーンで秒まで、括弧に UTC。
-}
viewWhen : Time.Zone -> AuditRow -> Html Msg
viewWhen zone row =
    span []
        [ text (DateTime.formatLocalSeconds zone row.createdAt ++ " " ++ DateTime.zoneAbbr zone row.createdAt)
        , span [ class "text-ink-soft" ] [ text ("（" ++ DateTime.utcSeconds row.createdAt ++ "）") ]
        ]


{-| 機械の行。固定 URL のコピーと、行の id。
-}
viewMachine : Surround -> Model -> AuditRow -> Html Msg
viewMachine surround model row =
    let
        url : String
        url =
            surround.origin ++ Route.toString (Route.Settings model.project (Route.Audit [ ( "id", row.id ) ]))
    in
    div [ class "flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px]" ]
        [ Ui.quietActionLink [ onClick (CopyRequested { id = row.id, url = url }), class "inline-flex items-center gap-1 text-[11px]" ]
            [ Icon.view Icon.copy, text "この行のリンクをコピー" ]
        , if model.copied == Just row.id then
            span [ class "text-[color:var(--color-ok)]" ] [ text "コピーしました" ]

          else
            text ""
        , span [ class "font-mono text-ink-faint" ] [ text ("id " ++ row.id) ]
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


{-| 型紙。`trailing` は型紙の kv の続きに置く行（操作した人・時刻）。
kv でない型紙（フィールドの表）の時は、表の下に kv として置く。
-}
viewSheet : Time.Zone -> Say.Sheet -> List ( String, Html Msg ) -> Html Msg
viewSheet zone sheet trailing =
    case sheet of
        Say.Changes changes ->
            viewKv (List.map viewChange changes ++ trailing)

        Say.Order order ->
            viewKv
                (( "変更前", viewChips order.moved order.before )
                    :: (case order.after of
                            Just after ->
                                [ ( "今の並び", viewChips order.moved after ) ]

                            Nothing ->
                                []
                       )
                    ++ trailing
                )

        Say.FieldTable rows ->
            div [ class "flex flex-col gap-2" ] [ viewFieldTable rows, viewKv trailing ]

        Say.Facts facts ->
            viewKv (List.map (\( key, value ) -> ( key, span [ title (factHint key) ] [ text (factText zone key value) ] )) facts ++ trailing)

        Say.Nothing_ ->
            viewKv trailing


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


viewMore : Model -> Html Msg
viewMore model =
    if model.more then
        div [ class "flex justify-center" ]
            [ Ui.ghostButton [ onClick MoreRequested, Html.Attributes.disabled model.busy ]
                [ text
                    (if model.busy then
                        "読み込み中…"

                     else
                        "もっと見る"
                    )
                ]
            ]

    else
        text ""


{-| 行の DOM の id。固定 URL（?id=）で開いた時にその行まで送るのに使う。
-}
rowDomId : String -> String
rowDomId id =
    "audit-" ++ id


{-| 固定 URL で指された行が一覧に入っていれば、その DOM の id。Main が読み込みの後に Effect.ScrollTo にする。
-}
scrollTarget : Model -> Maybe String
scrollTarget model =
    case ( model.wanted, Loaded.toMaybe model.rows ) of
        ( Just id, Just rows ) ->
            if List.any (\row -> row.id == id) rows then
                Just (rowDomId id)

            else
                Nothing

        _ ->
            Nothing
