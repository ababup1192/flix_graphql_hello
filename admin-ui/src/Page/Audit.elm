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
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, href, title, type_, value)
import Html.Events exposing (onClick, onInput)
import Json.Decode as D
import Json.Encode as E
import Loaded exposing (Loaded)
import Model exposing (AuditRow, ContentTypeSummary, Slug)
import Queries
import Route
import Set exposing (Set)
import Time
import Ui
import Ui.DateTime as DateTime


type alias Model =
    { project : Slug
    , zone : Maybe Time.Zone
    , kind : String
    , action : String
    , since : String
    , until : String

    {- URL の `?id=` で指された行。一覧に無ければその旨を出す。 -}
    , wanted : Maybe String
    , rows : Loaded (List AuditRow)
    , opened : Set String
    , more : Bool
    , busy : Bool
    , errors : List String
    }


type Msg
    = ZoneKnown Time.Zone
    | GotRows (Result Api.Problem (List AuditRow))
    | GotMore (Result Api.Problem (List AuditRow))
    | KindChosen String
    | ActionChosen String
    | SinceTyped String
    | UntilTyped String
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
    , kind = param "kind"
    , action = param "action"
    , since = param "since"
    , until = param "until"
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
        ZoneKnown zone ->
            let
                next : Model
                next =
                    { model | zone = Just zone }
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

        SinceTyped date ->
            refilter { model | since = date }

        UntilTyped date ->
            refilter { model | until = date }

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
            [ div [ class "flex items-center gap-2" ]
                [ Ui.input [ type_ "date", value model.since, onInput SinceTyped ]
                , span [ class "text-ink-faint" ] [ text "〜" ]
                , Ui.input [ type_ "date", value model.until, onInput UntilTyped ]
                ]
            ]
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
                        (Ui.headRowOf columns [ text "時刻", text "誰が", text "何を", text "対象", text "" ]
                            :: List.concatMap (viewRow existing model) rows
                        )
        }
        model.rows


columns : String
columns =
    "grid-cols-[130px_minmax(0,1fr)_minmax(0,230px)_minmax(0,1fr)_32px]"


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
        , span [ class "min-w-0 truncate font-mono text-[12px]", title row.action ] [ text row.action ]
        , viewTarget existing model row
        , Html.button
            [ class "flex h-6 w-6 cursor-pointer items-center justify-center rounded text-ink-soft hover:bg-well hover:text-ink"
            , type_ "button"
            , title
                (if open then
                    "閉じる"

                 else
                    "詳しく"
                )
            , onClick (Toggled row.id)
            ]
            [ text
                (if open then
                    "▾"

                 else
                    "▸"
                )
            ]
        ]
        :: (if open then
                [ viewDetail model row ]

            else
                []
           )


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


{-| 対象。entry と型・フィールドは、その型が今もあればその画面へ飛べる。

WhyNot: 消した物にリンクを付けない。`type.deleted` の行から型の画面へ飛ぶと「この API はありません」で
終わるだけで、監査ログは消した後にこそ読まれる。消した物は `before` を開いて読む。

-}
viewTarget : List String -> Model -> AuditRow -> Html Msg
viewTarget existing model row =
    let
        label : String
        label =
            row.targetKind ++ " " ++ row.targetId

        plain : String -> Html Msg
        plain hint =
            span [ class "truncate", title hint ] [ text label ]

        link : Route.Route -> Html Msg
        link route =
            Ui.titleLink [ href (Route.toString route), class "truncate", title label ] [ text label ]

        linkIfTypeExists : String -> Route.Route -> Html Msg
        linkIfTypeExists typeApiId route =
            if List.member typeApiId existing then
                link route

            else
                plain (label ++ "（型 " ++ typeApiId ++ " は消えています）")

        typeOfField : String
        typeOfField =
            String.split "." row.targetId |> List.head |> Maybe.withDefault row.targetId
    in
    case ( row.targetKind, typeApiIdOf row ) of
        ( "entry", Just typeApiId ) ->
            if row.action == "entry.deleted" then
                plain (label ++ "（消えています）")

            else
                linkIfTypeExists typeApiId (Route.Entry model.project typeApiId row.targetId)

        ( "type", _ ) ->
            linkIfTypeExists row.targetId (Route.TypeSchema model.project row.targetId)

        ( "field", _ ) ->
            linkIfTypeExists typeOfField (Route.TypeSchema model.project typeOfField)

        _ ->
            plain label


{-| entry の行は detail に型の apiId を持つ。
-}
typeApiIdOf : AuditRow -> Maybe String
typeApiIdOf row =
    D.decodeValue (D.field "typeApiId" D.string) row.detail |> Result.toMaybe


viewDetail : Model -> AuditRow -> Html Msg
viewDetail model row =
    div [ class "flex flex-col gap-2 border-b border-edge bg-raised px-4 py-3 text-[12px] text-ink-soft last:border-b-0" ]
        [ div [ class "flex flex-wrap items-center gap-x-4 gap-y-1 font-mono" ]
            [ span [] [ text row.createdAt ]
            , span [] [ text ("actorId " ++ blankAs "—" row.actorId) ]
            , span [] [ text ("id " ++ row.id) ]
            , Ui.quietLink [ href (Route.toString (Route.Settings model.project (Route.Audit [ ( "id", row.id ) ]))), title "この行の URL" ] [ text "#" ]
            ]
        , Html.pre [ class "overflow-x-auto rounded-md border border-edge bg-panel px-3 py-2 font-mono text-[11px] leading-5 whitespace-pre text-ink" ]
            [ text (E.encode 2 row.detail) ]
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
