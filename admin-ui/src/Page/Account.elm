module Page.Account exposing (Model, Msg, init, load, update, view)

{-| 自分（アカウント）。組織の一覧と Personal Access Token。

PAT は CLI と MCP のための物で、**管理画面は自分の通信には使わない**。ここは発行の窓口だけ。

-}

import Api
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Loaded exposing (Loaded)
import Model exposing (IssuedPat, PatRow, Person)
import Queries
import Ui


type alias Model =
    { person : Person
    , tokens : Loaded (List PatRow)
    , newName : String
    , write : Bool
    , issued : Maybe IssuedPat
    , errors : List String
    , busy : Bool
    }


type Msg
    = GotTokens (Result Api.Problem (Maybe (List PatRow)))
    | NameTyped String
    | WriteToggled
    | Submitted
    | GotIssued (Result Api.Problem IssuedPat)
    | IssuedClosed
    | Revoked String
    | GotRevoked (Result Api.Problem Bool)


init : Person -> Model
init person =
    { person = person, tokens = Loaded.Loading, newName = "", write = False, issued = Nothing, errors = [], busy = False }


load : List (Api.Call Msg)
load =
    [ Api.call Queries.personalTokens GotTokens ]


update : Msg -> Model -> ( Model, List (Api.Call Msg) )
update msg model =
    case msg of
        GotTokens result ->
            ( { model | tokens = Loaded.fromResult result }, [] )

        NameTyped name ->
            ( { model | newName = name }, [] )

        WriteToggled ->
            ( { model | write = not model.write }, [] )

        Submitted ->
            if String.isEmpty (String.trim model.newName) then
                ( { model | errors = [ "名前を入れてください" ] }, [] )

            else
                ( { model | busy = True, errors = [] }
                , [ Api.call (\id -> Queries.createPersonalToken id { name = model.newName, write = model.write }) GotIssued ]
                )

        GotIssued (Ok issued) ->
            ( { model | busy = False, issued = Just issued, newName = "" }, load )

        GotIssued (Err problem) ->
            ( { model | busy = False, errors = [ (Api.problemToText problem).message ] }, [] )

        IssuedClosed ->
            ( { model | issued = Nothing }, [] )

        Revoked tokenId ->
            ( { model | busy = True }, [ Api.call (\id -> Queries.revokePersonalToken id tokenId) GotRevoked ] )

        GotRevoked (Ok _) ->
            ( { model | busy = False }, load )

        GotRevoked (Err problem) ->
            ( { model | busy = False, errors = [ (Api.problemToText problem).message ] }, [] )


view : Model -> Html Msg
view model =
    Ui.page [ class "mx-auto w-full max-w-3xl" ]
        [ Ui.pageHeader { title = "自分", icon = Nothing, meta = [], actions = [] }
        , Ui.card [ class "flex items-center gap-3 p-4 text-[13px]" ]
            [ Ui.avatar model.person.email
            , div [ class "flex flex-col" ]
                [ span [ class "font-semibold text-ink" ] [ text model.person.email ]
                , span [ class "text-xs text-ink-soft" ]
                    [ text ("組織 " ++ String.fromInt (List.length model.person.organizations) ++ " · プロジェクト " ++ String.fromInt (List.length model.person.projects)) ]
                ]
            ]
        , Ui.sectionTitle "Personal Access Token"
        , Ui.note [ text "CLI と MCP から自分の権限で叩くための鍵です。値は発行した時に 1 回だけ表示されます。" ]
        , Ui.errors model.errors
        , case model.issued of
            Just issued ->
                Ui.callout Ui.toneWarn
                    []
                    [ Ui.subheading ("「" ++ issued.name ++ "」を発行しました")
                    , Ui.note [ text "この値はこの画面を閉じると二度と出ません。今のうちに控えてください。" ]
                    , Ui.codeBlock [ class "bg-panel" ] issued.token
                    , div [] [ Ui.ghostButton [ onClick IssuedClosed ] [ text "控えました" ] ]
                    ]

            Nothing ->
                Ui.card [ class "flex items-end gap-4 p-4" ]
                    [ div [ class "flex-1" ]
                        [ Ui.field { label = "名前", hint = Nothing, errors = [] }
                            [ Ui.input [ value model.newName, onInput NameTyped, placeholder "手元の CLI" ] ]
                        ]
                    , Ui.checkbox { label = "書き込みも許す", checked = model.write, onToggle = WriteToggled }
                    , Ui.button [ onClick Submitted ]
                        [ text
                            (if model.busy then
                                "送っています…"

                             else
                                "発行"
                            )
                        ]
                    ]
        , viewTokens model
        ]


viewTokens : Model -> Html Msg
viewTokens model =
    Loaded.view
        { loading = Ui.loadingCard
        , missing = Ui.table [ Ui.empty "トークンがありません" ]
        , failed = Ui.failedCard
        , present =
            \rows ->
                if List.isEmpty rows then
                    Ui.table [ Ui.empty "トークンがありません" ]

                else
                    Ui.table (Ui.headRowOf tokenColumns [ text "名前", text "範囲", text "期限", text "" ] :: List.map viewToken rows)
        }
        model.tokens


{-| トークンの表の列。右端は「失効」だけなので狭く取る。
-}
tokenColumns : String
tokenColumns =
    "grid-cols-[1fr_120px_120px_80px]"


viewToken : PatRow -> Html Msg
viewToken row =
    Ui.rowOf tokenColumns
        [ div [ class "flex flex-col" ]
            [ span [ class "font-medium" ] [ text row.name ]
            , case row.revokedAt of
                Just _ ->
                    span [ class "text-[11px] text-ink-faint" ] [ text "失効済み" ]

                Nothing ->
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
        , span [ class "font-mono text-[11px] text-ink-soft" ] [ text (String.left 10 row.expiresAt) ]
        , case row.revokedAt of
            Just _ ->
                text ""

            Nothing ->
                div [ class "text-right" ] [ Ui.dangerLink (Revoked row.id) "失効" ]
        ]
