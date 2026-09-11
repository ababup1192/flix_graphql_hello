module Page.Account exposing (Model, Msg(..), init, load, update, view)

{-| アカウント。組織の一覧と Personal Access Token。

PAT は CLI と MCP のための物で、**管理画面は自分の通信には使わない**。ここは発行の窓口だけ。

一覧と発行の見せ方は「API キーと Webhook」と揃えてある（同じ役割の物なので、画面ごとに
違う見え方にしない）。GitHub の Personal access tokens も、名前・権限・作成日・有効期限・
最後に使った日を並べ、失効はモーダルで確かめる。

-}

import Api
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, value)
import Html.Events exposing (onInput)
import Loaded exposing (Loaded)
import Model exposing (IssuedPat, PatRow, Person)
import Queries
import Time
import Ui
import Ui.Confirm
import Ui.DateTime
import Ui.Reply as Reply exposing (Reply)
import Ui.Secret


type alias Model =
    { person : Person
    , tokens : Loaded (List PatRow)
    , newName : String
    , write : Bool
    , reply : Reply
    , issued : Maybe IssuedPat
    , copied : Bool
    , confirmRevoke : Maybe PatRow
    , revoking : Reply
    , showRevoked : Bool
    , zone : Time.Zone
    , today : Maybe { year : Int, month : Int, day : Int }
    }


type Msg
    = GotTokens (Result Api.Problem (Maybe (List PatRow)))
    | NameTyped String
    | WriteToggled
    | Submitted
    | GotIssued (Result Api.Problem IssuedPat)
    | CopyRequested String
    | CopyShown
    | IssuedClosed
    | RevokeAsked PatRow
    | RevokeCancelled
    | RevokeConfirmed
    | GotRevoked (Result Api.Problem Bool)
    | RevokedToggled
    | TodayKnown Time.Zone Int Int Int
    | EscapePressed
    | Ignored


init : Person -> Model
init person =
    { person = person
    , tokens = Loaded.Loading
    , newName = ""
    , write = False
    , reply = Reply.idle
    , issued = Nothing
    , copied = False
    , confirmRevoke = Nothing
    , revoking = Reply.idle
    , showRevoked = False
    , zone = Time.utc
    , today = Nothing
    }


load : List (Api.Call Msg)
load =
    [ Api.call Queries.personalTokens GotTokens ]


update : Msg -> Model -> ( Model, List (Api.Call Msg) )
update msg model =
    case msg of
        GotTokens result ->
            ( { model | tokens = Loaded.fromResult result }, [] )

        NameTyped name ->
            ( { model | newName = name, reply = Reply.touched model.reply }, [] )

        WriteToggled ->
            ( { model | write = not model.write, reply = Reply.touched model.reply }, [] )

        Submitted ->
            ( { model | reply = Reply.sending }
            , [ Api.call (\id -> Queries.createPersonalToken id { name = model.newName, write = model.write }) GotIssued ]
            )

        GotIssued (Ok issued) ->
            ( { model | reply = Reply.idle, issued = Just issued, copied = False, newName = "" }, load )

        GotIssued (Err problem) ->
            ( { model | reply = Reply.failed problem }, [] )

        CopyRequested _ ->
            ( { model | copied = True }, [] )

        CopyShown ->
            ( { model | copied = False }, [] )

        IssuedClosed ->
            ( { model | issued = Nothing, copied = False }, [] )

        RevokeAsked row ->
            ( { model | confirmRevoke = Just row, revoking = Reply.idle }, [] )

        RevokeCancelled ->
            ( { model | confirmRevoke = Nothing }, [] )

        RevokeConfirmed ->
            case model.confirmRevoke of
                Just row ->
                    ( { model | revoking = Reply.sending }, [ Api.call (\id -> Queries.revokePersonalToken id row.id) GotRevoked ] )

                Nothing ->
                    ( model, [] )

        GotRevoked (Ok _) ->
            ( { model | revoking = Reply.idle, confirmRevoke = Nothing }, load )

        GotRevoked (Err problem) ->
            ( { model | revoking = Reply.failed problem }, [] )

        RevokedToggled ->
            ( { model | showRevoked = not model.showRevoked }, [] )

        TodayKnown zone year month day ->
            ( { model | zone = zone, today = Just { year = year, month = month, day = day } }, [] )

        EscapePressed ->
            ( { model | confirmRevoke = Nothing }, [] )

        Ignored ->
            ( model, [] )


view : Model -> Html Msg
view model =
    Ui.page [ class "mx-auto w-full max-w-3xl" ]
        [ Ui.pageHeader { title = "アカウント", icon = Nothing, meta = [], actions = [] }
        , Ui.card [ class "flex items-center gap-3 p-4 text-[13px]" ]
            [ Ui.avatar model.person.email
            , div [ class "flex flex-col" ]
                [ span [ class "font-semibold text-ink" ] [ text model.person.email ]
                , span [ class "text-xs text-ink-soft" ]
                    [ text ("組織 " ++ String.fromInt (List.length model.person.organizations) ++ " · プロジェクト " ++ String.fromInt (List.length model.person.projects)) ]
                ]
            ]
        , Ui.sectionTitle "Personal Access Token"
        , Ui.note [ text "CLI や MCP から自分の権限で API を使うためのトークンです。値は発行したときに 1 回だけ表示されます。" ]
        , case model.issued of
            Just issued ->
                Ui.Secret.view
                    { title = "「" ++ issued.name ++ "」を発行しました"
                    , value = issued.token
                    , copied = model.copied
                    , onCopy = CopyRequested issued.token
                    , onClose = IssuedClosed
                    }

            Nothing ->
                viewForm model
        , viewTokens model
        , case model.confirmRevoke of
            Just row ->
                Ui.Confirm.view
                    { title = "「" ++ row.name ++ "」を失効しますか"
                    , body = "このトークンを使っている CLI や MCP は、すぐに読み書きできなくなります。元には戻せません。"
                    , confirm = "失効"
                    , reply = model.revoking
                    , onConfirm = RevokeConfirmed
                    , onCancel = RevokeCancelled
                    , ignore = Ignored
                    }

            Nothing ->
                text ""
        ]


viewForm : Model -> Html Msg
viewForm model =
    Ui.card [ class "flex items-end gap-4 p-4" ]
        [ div [ class "flex-1" ]
            [ Ui.field { label = "名前", hint = Nothing, errors = Reply.errorsFor "name" model.reply }
                [ Ui.input [ value model.newName, onInput NameTyped, placeholder "手元の CLI" ] ]
            ]
        , Ui.checkbox { label = "書き込みを許可", checked = model.write, onToggle = WriteToggled }
        , Reply.addButton
            { label = "発行"
            , ready = not (String.isEmpty (String.trim model.newName))
            , reply = model.reply
            , onAdd = Submitted
            }
        ]


viewTokens : Model -> Html Msg
viewTokens model =
    Loaded.view
        { loading = Ui.loadingCard
        , missing = Ui.table [ Ui.empty "トークンがありません" ]
        , failed = Ui.failedCard
        , present = viewTable model
        }
        model.tokens


{-| 生きているトークンの表。失効した物は畳んでおく（API キーの一覧と同じ）。
-}
viewTable : Model -> List PatRow -> Html Msg
viewTable model rows =
    let
        active : List PatRow
        active =
            List.filter (\row -> row.revokedAt == Nothing) rows

        revoked : List PatRow
        revoked =
            List.filter (\row -> row.revokedAt /= Nothing) rows

        head : Html Msg
        head =
            Ui.headRowOf tokenColumns [ text "名前", text "権限", text "作成日", text "有効期限", text "最後に使った日", text "" ]

        toggle : Html Msg
        toggle =
            if List.isEmpty revoked then
                text ""

            else
                div [ class "border-t border-edge px-4 py-2" ]
                    [ Ui.quietActionLink [ Html.Events.onClick RevokedToggled ]
                        [ text
                            (if model.showRevoked then
                                "失効済み " ++ String.fromInt (List.length revoked) ++ " 件を隠す"

                             else
                                "失効済み " ++ String.fromInt (List.length revoked) ++ " 件を表示"
                            )
                        ]
                    ]

        shown : List PatRow
        shown =
            if model.showRevoked then
                revoked

            else
                []
    in
    if List.isEmpty active then
        Ui.table (Ui.empty "トークンがありません" :: toggle :: List.map (viewToken model) shown)

    else
        Ui.table (head :: List.map (viewToken model) active ++ toggle :: List.map (viewToken model) shown)


tokenColumns : String
tokenColumns =
    "grid-cols-[1fr_110px_100px_150px_110px_60px]"


viewToken : Model -> PatRow -> Html Msg
viewToken model row =
    let
        revoked : Bool
        revoked =
            row.revokedAt /= Nothing
    in
    Ui.rowOf
        (tokenColumns
            ++ (if revoked then
                    " opacity-60"

                else
                    ""
               )
        )
        [ div [ class "flex flex-col" ]
            [ span [ class "font-medium" ] [ text row.name ]
            , if revoked then
                span [ class "text-[11px] text-ink-faint" ]
                    [ text ("失効済み" ++ (row.revokedAt |> Maybe.map (\at -> " · " ++ Ui.DateTime.localDate model.zone at) |> Maybe.withDefault "")) ]

              else
                text ""
            ]
        , span [ class "text-ink-soft" ]
            [ text
                (if row.scope == "WRITE" then
                    "読み書き"

                 else
                    "読み取り"
                )
            ]
        , span [ class "font-mono text-[11px] text-ink-soft" ] [ text (Ui.DateTime.localDate model.zone row.createdAt) ]
        , viewExpiry model row
        , viewLastUsed model row
        , if revoked then
            text ""

          else
            div [ class "text-right" ] [ Ui.dangerLink (RevokeAsked row) "失効" ]
        ]


{-| 有効期限。PAT は必ず期限を持つ。切れていれば赤、7 日を切れば琥珀（API キーと同じ）。
-}
viewExpiry : Model -> PatRow -> Html Msg
viewExpiry model row =
    let
        day : String
        day =
            Ui.DateTime.localDate model.zone row.expiresAt
    in
    case model.today |> Maybe.andThen (\today -> Ui.DateTime.daysFromToday model.zone today row.expiresAt) of
        Just left ->
            if left < 0 then
                span [ class "font-mono text-[11px] text-[color:var(--color-bad)]", Html.Attributes.title day ] [ text "期限切れ" ]

            else if left <= 7 then
                span [ class "font-mono text-[11px] text-[color:var(--color-warn)]", Html.Attributes.title day ] [ text ("あと " ++ String.fromInt left ++ " 日") ]

            else
                span [ class "font-mono text-[11px] text-ink-soft" ] [ text day ]

        Nothing ->
            span [ class "font-mono text-[11px] text-ink-soft" ] [ text day ]


viewLastUsed : Model -> PatRow -> Html Msg
viewLastUsed model row =
    case row.lastUsedAt of
        Nothing ->
            span [ class "text-[11px] text-ink-faint" ] [ text "未使用" ]

        Just at ->
            let
                absolute : String
                absolute =
                    Ui.DateTime.formatLocal model.zone at
            in
            case Ui.DateTime.agoText model.zone model.today at of
                Just ago ->
                    span [ class "text-[11px] text-ink-soft", Html.Attributes.title absolute ] [ text ago ]

                Nothing ->
                    span [ class "font-mono text-[11px] text-ink-soft" ] [ text absolute ]
