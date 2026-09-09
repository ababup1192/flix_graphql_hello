module Page.Keys exposing (Model, Msg, init, load, update, view)

{-| プロジェクト設定 › API キーと Webhook。

**生の値は発行の 1 回しか出ない。** 出したらその場でコピーさせ、閉じたら二度と出さない。
公開サイトがコンテンツ API を読むのも、AI から MCP で繋ぐのも、ここで発行した鍵を使う。

-}

import Api
import Api.Admin.Enum.ApiKeyScope as ApiKeyScope exposing (ApiKeyScope)
import Api.Admin.Enum.Role as Role
import Api.Admin.Enum.WebhookEvent as WebhookEvent
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Loaded exposing (Loaded)
import Model exposing (ApiKeyRow, IssuedKey, Slug, WebhookRow)
import Queries
import Ui


type alias Model =
    { keys : Loaded (List ApiKeyRow)
    , hooks : Loaded (List WebhookRow)
    , newKeyName : String
    , newKeyScope : ApiKeyScope
    , issued : Maybe IssuedKey
    , newHookName : String
    , newHookUrl : String
    , errors : List String
    , busy : Bool
    }


type Msg
    = GotKeys (Result Api.Problem (List ApiKeyRow))
    | GotHooks (Result Api.Problem (List WebhookRow))
    | KeyNameTyped String
    | KeyScopeChosen String
    | KeySubmitted
    | GotIssued (Result Api.Problem IssuedKey)
    | IssuedClosed
    | KeyRevoked String
    | GotRevoked (Result Api.Problem String)
    | HookNameTyped String
    | HookUrlTyped String
    | HookSubmitted
    | GotHook (Result Api.Problem WebhookRow)
    | HookDeleted String
    | GotHookDeleted (Result Api.Problem String)


init : Model
init =
    { keys = Loaded.Loading
    , hooks = Loaded.Loading
    , newKeyName = ""
    , newKeyScope = ApiKeyScope.Read
    , issued = Nothing
    , newHookName = ""
    , newHookUrl = ""
    , errors = []
    , busy = False
    }


load : Slug -> List (Api.Call Msg)
load slug =
    [ Api.call (\id -> Queries.apiKeys id slug) GotKeys
    , Api.call (\id -> Queries.webhooks id slug) GotHooks
    ]


update : { project : Slug } -> Msg -> Model -> ( Model, List (Api.Call Msg) )
update ctx msg model =
    case msg of
        GotKeys result ->
            ( { model | keys = Loaded.fromResult (Result.map Just result) }, [] )

        GotHooks result ->
            ( { model | hooks = Loaded.fromResult (Result.map Just result) }, [] )

        KeyNameTyped name ->
            ( { model | newKeyName = name }, [] )

        KeyScopeChosen chosen ->
            ( { model | newKeyScope = scopeOf chosen }, [] )

        KeySubmitted ->
            if String.isEmpty (String.trim model.newKeyName) then
                ( { model | errors = [ "キーの名前を入れてください" ] }, [] )

            else
                ( { model | busy = True, errors = [] }
                , [ Api.call
                        (\id ->
                            Queries.createApiKey id
                                ctx.project
                                { name = model.newKeyName
                                , scope = model.newKeyScope
                                , role =
                                    if model.newKeyScope == ApiKeyScope.Write then
                                        Just Role.Editor

                                    else
                                        Nothing
                                }
                        )
                        GotIssued
                  ]
                )

        GotIssued (Ok issued) ->
            ( { model | busy = False, issued = Just issued, newKeyName = "" }, load ctx.project )

        GotIssued (Err problem) ->
            ( failed problem model, [] )

        IssuedClosed ->
            ( { model | issued = Nothing }, [] )

        KeyRevoked keyId ->
            ( { model | busy = True }, [ Api.call (\id -> Queries.revokeApiKey id ctx.project keyId) GotRevoked ] )

        GotRevoked (Ok _) ->
            ( { model | busy = False }, load ctx.project )

        GotRevoked (Err problem) ->
            ( failed problem model, [] )

        HookNameTyped name ->
            ( { model | newHookName = name }, [] )

        HookUrlTyped url ->
            ( { model | newHookUrl = url }, [] )

        HookSubmitted ->
            if String.startsWith "http" model.newHookUrl then
                ( { model | busy = True, errors = [] }
                , [ Api.call
                        (\id ->
                            Queries.createWebhook id
                                ctx.project
                                { name = model.newHookName, url = model.newHookUrl, events = WebhookEvent.list }
                        )
                        GotHook
                  ]
                )

            else
                ( { model | errors = [ "送り先の URL を http から入れてください" ] }, [] )

        GotHook (Ok hook) ->
            ( { model
                | busy = False
                , newHookName = ""
                , newHookUrl = ""
                , hooks = Loaded.map (\hooks -> hooks ++ [ hook ]) model.hooks
              }
            , []
            )

        GotHook (Err problem) ->
            ( failed problem model, [] )

        HookDeleted hookId ->
            ( { model | busy = True }, [ Api.call (\id -> Queries.deleteWebhook id ctx.project hookId) GotHookDeleted ] )

        GotHookDeleted (Ok hookId) ->
            ( { model | busy = False, hooks = Loaded.map (List.filter (\hook -> hook.id /= hookId)) model.hooks }, [] )

        GotHookDeleted (Err problem) ->
            ( failed problem model, [] )


failed : Api.Problem -> Model -> Model
failed problem model =
    { model | busy = False, errors = [ (Api.problemToText problem).message ] }


scopeOptions : List ( String, String )
scopeOptions =
    [ ( "READ", "読み取り（公開中のみ）" )
    , ( "READ_DRAFT", "読み取り（下書きも）" )
    , ( "WRITE", "書き込み（編集者の範囲）" )
    ]


scopeOf : String -> ApiKeyScope
scopeOf value =
    ApiKeyScope.list
        |> List.filter (\scope -> ApiKeyScope.toString scope == value)
        |> List.head
        |> Maybe.withDefault ApiKeyScope.Read


scopeText : String -> String
scopeText value =
    scopeOptions |> List.filter (\( key, _ ) -> key == value) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault value


view : Model -> Html Msg
view model =
    Ui.page []
        [ Ui.pageHeader { title = "API キー", icon = Nothing, meta = [], actions = [] }
        , Ui.note [ text "キーの値は発行した時に 1 回だけ表示されます。公開サイトの読み取りと、AI から MCP で繋ぐのに使います。" ]
        , Ui.errors model.errors
        , case model.issued of
            Just issued ->
                viewIssued issued

            Nothing ->
                viewKeyForm model
        , viewKeys model
        , Ui.sectionTitle "Webhook"
        , Ui.note [ text "公開・公開終了・削除・スキーマの変更を、指定した URL に知らせます。" ]
        , viewHookForm model
        , viewHooks model
        ]


{-| 発行したキー。**閉じると二度と出ない**ので、そう伝える。
-}
viewIssued : IssuedKey -> Html Msg
viewIssued issued =
    Ui.callout Ui.toneWarn
        []
        [ Ui.subheading ("「" ++ issued.name ++ "」を発行しました")
        , Ui.note [ text "この値はこの画面を閉じると二度と出ません。今のうちに控えてください。" ]
        , Ui.codeBlock [ class "bg-panel" ] issued.key
        , div [] [ Ui.ghostButton [ onClick IssuedClosed ] [ text "控えました" ] ]
        ]


viewKeyForm : Model -> Html Msg
viewKeyForm model =
    Ui.card [ class "flex items-end gap-4 p-4" ]
        [ div [ class "flex-1" ]
            [ Ui.field { label = "キーの名前", hint = Nothing, errors = [] }
                [ Ui.input [ value model.newKeyName, onInput KeyNameTyped, placeholder "公開サイト" ] ]
            ]
        , div [ class "w-56" ]
            [ Ui.field { label = "用途", hint = Nothing, errors = [] }
                [ Ui.select [ onInput KeyScopeChosen ] scopeOptions (ApiKeyScope.toString model.newKeyScope) ]
            ]
        , Ui.button [ onClick KeySubmitted ] [ text (busyText model "発行") ]
        ]


busyText : Model -> String -> String
busyText model label =
    if model.busy then
        "送っています…"

    else
        label


viewKeys : Model -> Html Msg
viewKeys model =
    Loaded.view
        { loading = Ui.loadingCard
        , missing = Ui.table [ Ui.empty "キーがありません" ]
        , failed = Ui.failedCard
        , present =
            \rows ->
                if List.isEmpty rows then
                    Ui.table [ Ui.empty "キーがありません" ]

                else
                    Ui.table (Ui.headRowOf keyColumns [ text "名前", text "用途", text "最後に使った日", text "" ] :: List.map viewKey rows)
        }
        model.keys


keyColumns : String
keyColumns =
    "grid-cols-[1fr_200px_150px_80px]"


hookColumns : String
hookColumns =
    "grid-cols-[1fr_110px_90px_80px]"


viewKey : ApiKeyRow -> Html Msg
viewKey row =
    Ui.rowOf keyColumns
        [ div [ class "flex flex-col" ]
            [ span [ class "font-medium" ] [ text row.name ]
            , case row.revokedAt of
                Just _ ->
                    span [ class "text-[11px] text-ink-faint" ] [ text "失効済み" ]

                Nothing ->
                    text ""
            ]
        , span [ class "text-ink-soft" ] [ text (scopeText row.scope) ]
        , span [ class "font-mono text-[11px] text-ink-soft" ] [ text (row.lastUsedAt |> Maybe.map (String.left 16) |> Maybe.withDefault "—") ]
        , case row.revokedAt of
            Just _ ->
                text ""

            Nothing ->
                div [ class "text-right" ] [ Ui.dangerLink (KeyRevoked row.id) "失効" ]
        ]


viewHookForm : Model -> Html Msg
viewHookForm model =
    Ui.card [ class "flex items-end gap-4 p-4" ]
        [ div [ class "w-48" ]
            [ Ui.field { label = "名前", hint = Nothing, errors = [] }
                [ Ui.input [ value model.newHookName, onInput HookNameTyped, placeholder "サイトの再ビルド" ] ]
            ]
        , div [ class "flex-1" ]
            [ Ui.field { label = "送り先の URL", hint = Nothing, errors = [] }
                [ Ui.input [ value model.newHookUrl, onInput HookUrlTyped, placeholder "https://example.com/hook" ] ]
            ]
        , Ui.button [ onClick HookSubmitted ] [ text (busyText model "追加") ]
        ]


viewHooks : Model -> Html Msg
viewHooks model =
    Loaded.view
        { loading = Ui.loadingCard
        , missing = Ui.table [ Ui.empty "Webhook がありません" ]
        , failed = Ui.failedCard
        , present =
            \rows ->
                if List.isEmpty rows then
                    Ui.table [ Ui.empty "Webhook がありません" ]

                else
                    Ui.table (Ui.headRowOf hookColumns [ text "送り先", text "イベント", text "状態", text "" ] :: List.map viewHook rows)
        }
        model.hooks


viewHook : WebhookRow -> Html Msg
viewHook hook =
    Ui.rowOf hookColumns
        [ div [ class "flex min-w-0 flex-col" ]
            [ span [ class "font-medium" ] [ text hook.name ]
            , span [ class "truncate font-mono text-[11px] text-ink-faint" ] [ text hook.url ]
            ]
        , span [ class "text-ink-soft" ] [ text (String.fromInt (List.length hook.events) ++ " 種類") ]
        , if hook.active then
            Ui.chip Ui.toneOk "有効"

          else
            Ui.chip Ui.toneNeutral "停止中"
        , div [ class "text-right" ] [ Ui.dangerLink (HookDeleted hook.id) "削除" ]
        ]
