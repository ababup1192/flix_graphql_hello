module Page.Keys exposing (Model, Msg(..), init, load, update, view)

{-| プロジェクト設定 › API キーと Webhook。

**生の値は発行の 1 回しか出ない。** 出したらその場でコピーさせ、閉じたら二度と出さない。
公開サイトがコンテンツ API を読むのも、AI から MCP で接続するのも、ここで発行した API キーを使う。

一覧の列は GitHub（PAT）・Stripe・Vercel と揃えてある: 名前、鍵の末尾、権限、作成日、有効期限、最後に使った日。
危ない操作（失効・削除）は確認を挟む。他社も挟んでいて、ここだけ 1 クリックにしない。

-}

import Api
import Api.Admin.Enum.ApiKeyScope as ApiKeyScope exposing (ApiKeyScope)
import Api.Admin.Enum.Role as Role
import Api.Admin.Enum.WebhookEvent as WebhookEvent
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, value)
import Html.Events exposing (onInput)
import Loaded exposing (Loaded)
import Model exposing (ApiKeyRow, IssuedKey, IssuedWebhook, Slug, WebhookRow)
import Queries
import Time
import Ui
import Ui.Confirm
import Ui.DateTime
import Ui.Reply as Reply exposing (Reply)
import Ui.Secret


type alias Model =
    { keys : Loaded (List ApiKeyRow)
    , hooks : Loaded (List WebhookRow)
    , newKeyName : String
    , newKeyScope : ApiKeyScope
    , keyReply : Reply
    , issued : Maybe IssuedKey
    , keyCopied : Bool
    , confirmRevoke : Maybe ApiKeyRow
    , revoking : Reply
    , newHookName : String
    , newHookUrl : String
    , hookReply : Reply
    , issuedHook : Maybe IssuedWebhook
    , hookCopied : Bool
    , confirmHookDelete : Maybe WebhookRow
    , deleting : Reply
    , zone : Time.Zone
    , today : Maybe { year : Int, month : Int, day : Int }
    , showRevoked : Bool
    }


type Msg
    = GotKeys (Result Api.Problem (List ApiKeyRow))
    | GotHooks (Result Api.Problem (List WebhookRow))
    | KeyNameTyped String
    | KeyScopeChosen String
    | KeySubmitted
    | GotIssued (Result Api.Problem IssuedKey)
    | KeyCopyRequested String
    | KeyCopyShown
    | IssuedClosed
    | HookCopyRequested String
    | HookCopyShown
    | IssuedHookClosed
    | RevokeAsked ApiKeyRow
    | RevokeCancelled
    | RevokeConfirmed
    | GotRevoked (Result Api.Problem String)
    | HookNameTyped String
    | HookUrlTyped String
    | HookSubmitted
    | GotHook (Result Api.Problem IssuedWebhook)
    | HookDeleteAsked WebhookRow
    | HookDeleteCancelled
    | HookDeleteConfirmed
    | GotHookDeleted (Result Api.Problem String)
    | EscapePressed
    | TodayKnown Time.Zone Int Int Int
    | RevokedToggled
    | Ignored


init : Model
init =
    { keys = Loaded.Loading
    , hooks = Loaded.Loading
    , newKeyName = ""
    , newKeyScope = ApiKeyScope.Read
    , keyReply = Reply.idle
    , issued = Nothing
    , keyCopied = False
    , confirmRevoke = Nothing
    , revoking = Reply.idle
    , newHookName = ""
    , newHookUrl = ""
    , hookReply = Reply.idle
    , issuedHook = Nothing
    , hookCopied = False
    , confirmHookDelete = Nothing
    , deleting = Reply.idle
    , zone = Time.utc
    , today = Nothing
    , showRevoked = False
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
            ( { model | newKeyName = name, keyReply = Reply.touched model.keyReply }, [] )

        KeyScopeChosen chosen ->
            ( { model | newKeyScope = scopeOf chosen, keyReply = Reply.touched model.keyReply }, [] )

        KeySubmitted ->
            ( { model | keyReply = Reply.sending }
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
            ( { model | keyReply = Reply.idle, issued = Just issued, keyCopied = False, newKeyName = "" }, load ctx.project )

        GotIssued (Err problem) ->
            ( { model | keyReply = Reply.failed problem }, [] )

        -- 親が port に流し、2 秒後に KeyCopyShown を返す。チェックはその間だけ（GitHub と同じ）
        KeyCopyRequested _ ->
            ( { model | keyCopied = True }, [] )

        KeyCopyShown ->
            ( { model | keyCopied = False }, [] )

        IssuedClosed ->
            ( { model | issued = Nothing, keyCopied = False }, [] )

        HookCopyRequested _ ->
            ( { model | hookCopied = True }, [] )

        HookCopyShown ->
            ( { model | hookCopied = False }, [] )

        IssuedHookClosed ->
            ( { model | issuedHook = Nothing, hookCopied = False }, [] )

        RevokeAsked row ->
            ( { model | confirmRevoke = Just row, revoking = Reply.idle }, [] )

        RevokeCancelled ->
            ( { model | confirmRevoke = Nothing }, [] )

        RevokeConfirmed ->
            case model.confirmRevoke of
                Just row ->
                    ( { model | revoking = Reply.sending }, [ Api.call (\id -> Queries.revokeApiKey id ctx.project row.id) GotRevoked ] )

                Nothing ->
                    ( model, [] )

        GotRevoked (Ok _) ->
            ( { model | revoking = Reply.idle, confirmRevoke = Nothing }, load ctx.project )

        GotRevoked (Err problem) ->
            ( { model | revoking = Reply.failed problem }, [] )

        HookNameTyped name ->
            ( { model | newHookName = name, hookReply = Reply.touched model.hookReply }, [] )

        HookUrlTyped url ->
            ( { model | newHookUrl = url, hookReply = Reply.touched model.hookReply }, [] )

        HookSubmitted ->
            ( { model | hookReply = Reply.sending }
            , [ Api.call
                    (\id ->
                        Queries.createWebhook id
                            ctx.project
                            { name = model.newHookName, url = model.newHookUrl, events = WebhookEvent.list }
                    )
                    GotHook
              ]
            )

        GotHook (Ok issued) ->
            ( { model
                | hookReply = Reply.idle
                , issuedHook = Just issued
                , hookCopied = False
                , newHookName = ""
                , newHookUrl = ""
                , hooks = Loaded.map (\hooks -> hooks ++ [ issued.webhook ]) model.hooks
              }
            , []
            )

        GotHook (Err problem) ->
            ( { model | hookReply = Reply.failed problem }, [] )

        HookDeleteAsked hook ->
            ( { model | confirmHookDelete = Just hook, deleting = Reply.idle }, [] )

        HookDeleteCancelled ->
            ( { model | confirmHookDelete = Nothing }, [] )

        HookDeleteConfirmed ->
            case model.confirmHookDelete of
                Just hook ->
                    ( { model | deleting = Reply.sending }, [ Api.call (\id -> Queries.deleteWebhook id ctx.project hook.id) GotHookDeleted ] )

                Nothing ->
                    ( model, [] )

        GotHookDeleted (Ok hookId) ->
            ( { model | deleting = Reply.idle, confirmHookDelete = Nothing, hooks = Loaded.map (List.filter (\hook -> hook.id /= hookId)) model.hooks }, [] )

        GotHookDeleted (Err problem) ->
            ( { model | deleting = Reply.failed problem }, [] )

        -- 開いている確認を 1 段閉じる
        EscapePressed ->
            ( { model | confirmRevoke = Nothing, confirmHookDelete = Nothing }, [] )

        TodayKnown zone year month day ->
            ( { model | zone = zone, today = Just { year = year, month = month, day = day } }, [] )

        RevokedToggled ->
            ( { model | showRevoked = not model.showRevoked }, [] )

        Ignored ->
            ( model, [] )


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
        , Ui.note [ text "API キーの値は発行したときに 1 回だけ表示されます。公開サイトからの取得と、MCP での接続に使います。" ]
        , case model.issued of
            Just issued ->
                Ui.Secret.view
                    { title = "「" ++ issued.name ++ "」を発行しました"
                    , value = issued.key
                    , copied = model.keyCopied
                    , onCopy = KeyCopyRequested issued.key
                    , onClose = IssuedClosed
                    }

            Nothing ->
                viewKeyForm model
        , viewKeys model
        , Ui.sectionTitle "Webhook"
        , Ui.note [ text "公開・公開終了・削除・スキーマの変更を、指定した URL に通知します。" ]
        , case model.issuedHook of
            Just issued ->
                Ui.Secret.view
                    { title = "「" ++ issued.webhook.name ++ "」を追加しました。署名の鍵です"
                    , value = issued.secret
                    , copied = model.hookCopied
                    , onCopy = HookCopyRequested issued.secret
                    , onClose = IssuedHookClosed
                    }

            Nothing ->
                viewHookForm model
        , viewHooks model
        , case model.confirmRevoke of
            Just row ->
                Ui.Confirm.view
                    { title = "「" ++ row.name ++ "」を失効しますか"
                    , body = "この API キーを使っているサイトやツールは、すぐに読み書きできなくなります。元には戻せません。"
                    , confirm = "失効"
                    , reply = model.revoking
                    , onConfirm = RevokeConfirmed
                    , onCancel = RevokeCancelled
                    , ignore = Ignored
                    }

            Nothing ->
                text ""
        , case model.confirmHookDelete of
            Just hook ->
                Ui.Confirm.view
                    { title = "「" ++ hook.name ++ "」を削除しますか"
                    , body = "この URL への通知が止まります。元には戻せません。"
                    , confirm = "削除"
                    , reply = model.deleting
                    , onConfirm = HookDeleteConfirmed
                    , onCancel = HookDeleteCancelled
                    , ignore = Ignored
                    }

            Nothing ->
                text ""
        ]


viewKeyForm : Model -> Html Msg
viewKeyForm model =
    Ui.card [ class "flex flex-col gap-3 p-4" ]
        [ div [ class "flex items-end gap-4" ]
            [ div [ class "flex-1" ]
                [ Ui.field { label = "名前", hint = Nothing, errors = Reply.errorsFor "name" model.keyReply }
                    [ Ui.input [ value model.newKeyName, onInput KeyNameTyped, placeholder "公開サイト" ] ]
                ]
            , div [ class "w-56" ]
                [ Ui.field { label = "権限", hint = Nothing, errors = Reply.errorsFor "scope" model.keyReply ++ Reply.errorsFor "role" model.keyReply }
                    [ Ui.select [ onInput KeyScopeChosen ] scopeOptions (ApiKeyScope.toString model.newKeyScope) ]
                ]
            , Reply.addButton { label = "発行", ready = not (String.isEmpty (String.trim model.newKeyName)), reply = model.keyReply, onAdd = KeySubmitted }
            ]
        ]


viewKeys : Model -> Html Msg
viewKeys model =
    Loaded.view
        { loading = Ui.loadingCard
        , missing = Ui.table [ Ui.empty "API キーがありません" ]
        , failed = Ui.failedCard
        , present = viewKeyTable model
        }
        model.keys


{-| 生きている鍵の表。失効した鍵は畳んでおく。

他社（GitHub / Stripe）は失効した鍵を一覧から消す。ここは行を残す（いつ誰が失効させたかを
監査で追える）ので、消さない代わりに畳む。放っておくと失効済みが一覧の大半になる。

-}
viewKeyTable : Model -> List ApiKeyRow -> Html Msg
viewKeyTable model rows =
    let
        active : List ApiKeyRow
        active =
            List.filter (\row -> row.revokedAt == Nothing) rows

        revoked : List ApiKeyRow
        revoked =
            List.filter (\row -> row.revokedAt /= Nothing) rows

        head : Html Msg
        head =
            Ui.headRowOf keyColumns [ text "名前", text "キー", text "権限", text "作成日", text "有効期限", text "最後に使った日", text "" ]

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

        shown : List ApiKeyRow
        shown =
            if model.showRevoked then
                revoked

            else
                []
    in
    if List.isEmpty active then
        Ui.table (Ui.empty "API キーがありません" :: toggle :: List.map (viewKey model) shown)

    else
        Ui.table (head :: List.map (viewKey model) active ++ toggle :: List.map (viewKey model) shown)


keyColumns : String
keyColumns =
    "grid-cols-[1fr_100px_180px_100px_150px_110px_60px]"


hookColumns : String
hookColumns =
    "grid-cols-[1fr_260px_80px_60px]"


{-| 鍵の 1 行。失効は確認のモーダルを経る。
-}
viewKey : Model -> ApiKeyRow -> Html Msg
viewKey model row =
    let
        revoked : Bool
        revoked =
            row.revokedAt /= Nothing

        faint : String
        faint =
            if revoked then
                " opacity-60"

            else
                ""
    in
    Ui.rowOf (keyColumns ++ faint)
        [ div [ class "flex flex-col" ]
            [ span [ class "font-medium" ] [ text row.name ]
            , if revoked then
                span [ class "text-[11px] text-ink-faint" ] [ text ("失効済み" ++ (row.revokedAt |> Maybe.map (\at -> " · " ++ dateOf model.zone at) |> Maybe.withDefault "")) ]

              else
                text ""
            ]
        , span [ class "font-mono text-[12px] text-ink-soft" ] [ text (hintOf row.keyHint) ]
        , span [ class "text-ink-soft" ] [ text (scopeText row.scope) ]
        , span [ class "font-mono text-[11px] text-ink-soft" ] [ text (dateOf model.zone row.createdAt) ]
        , viewExpiry model row
        , viewLastUsed model row
        , if revoked then
            text ""

          else
            div [ class "text-right" ] [ Ui.dangerLink (RevokeAsked row) "失効" ]
        ]


{-| 末尾 4 文字。古い鍵は持っていないので「…」だけ。
-}
hintOf : String -> String
hintOf hint =
    if String.isEmpty hint then
        "…"

    else
        "…" ++ hint


{-| 有効期限。無期限はそう書く。切れていれば赤で「期限切れ」、7 日を切れば琥珀で「あと N 日」
（GitHub と同じ。色を使うのは期限だけで、使われているかどうかには色を付けない）。
-}
viewExpiry : Model -> ApiKeyRow -> Html Msg
viewExpiry model row =
    case row.expiresAt of
        Nothing ->
            span [ class "text-[11px] text-ink-faint" ] [ text "無期限" ]

        Just at ->
            let
                day : String
                day =
                    dateOf model.zone at
            in
            case model.today |> Maybe.andThen (\today -> Ui.DateTime.daysFromToday model.zone today at) of
                Just left ->
                    if left < 0 then
                        span [ class "font-mono text-[11px] text-[color:var(--color-bad)]", Html.Attributes.title day ] [ text "期限切れ" ]

                    else if left <= 7 then
                        span [ class "font-mono text-[11px] text-[color:var(--color-warn)]", Html.Attributes.title day ] [ text ("あと " ++ String.fromInt left ++ " 日") ]

                    else
                        span [ class "font-mono text-[11px] text-ink-soft" ] [ text day ]

                Nothing ->
                    span [ class "font-mono text-[11px] text-ink-soft" ] [ text day ]


{-| 最後に使った日。読む人の問いは「まだ使われているか」なので相対で出し、絶対の日時はホバーに。
-}
viewLastUsed : Model -> ApiKeyRow -> Html Msg
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
            case model.today |> Maybe.andThen (\today -> Ui.DateTime.daysFromToday model.zone today at) of
                Just ago ->
                    span [ class "text-[11px] text-ink-soft", Html.Attributes.title absolute ] [ text (relative (negate ago)) ]

                Nothing ->
                    span [ class "font-mono text-[11px] text-ink-soft" ] [ text absolute ]


{-| 「今日」「昨日」「3 日前」「2 か月前」。GitHub の "within the last week" よりは細かく、日付よりは読みやすい所。
-}
relative : Int -> String
relative daysAgo =
    if daysAgo <= 0 then
        "今日"

    else if daysAgo == 1 then
        "昨日"

    else if daysAgo < 30 then
        String.fromInt daysAgo ++ " 日前"

    else if daysAgo < 365 then
        String.fromInt (daysAgo // 30) ++ " か月前"

    else
        String.fromInt (daysAgo // 365) ++ " 年前"


{-| ISO 8601 の日時を手元のタイムゾーンの日付（YYYY-MM-DD）に。
-}
dateOf : Time.Zone -> String -> String
dateOf zone iso =
    String.left 10 (Ui.DateTime.formatLocal zone iso)


viewHookForm : Model -> Html Msg
viewHookForm model =
    Ui.card [ class "flex items-end gap-4 p-4" ]
        [ div [ class "w-48" ]
            [ Ui.field { label = "名前", hint = Nothing, errors = Reply.errorsFor "name" model.hookReply }
                [ Ui.input [ value model.newHookName, onInput HookNameTyped, placeholder "サイトの再ビルド" ] ]
            ]
        , div [ class "flex-1" ]
            [ Ui.field { label = "URL", hint = Nothing, errors = Reply.errorsFor "url" model.hookReply }
                [ Ui.input [ value model.newHookUrl, onInput HookUrlTyped, placeholder "https://example.com/hook" ] ]
            ]
        , Reply.addButton
            { label = "追加"
            , ready = not (String.isEmpty (String.trim model.newHookName)) && not (String.isEmpty (String.trim model.newHookUrl))
            , reply = model.hookReply
            , onAdd = HookSubmitted
            }
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
                    Ui.table (Ui.headRowOf hookColumns [ text "名前 / URL", text "イベント", text "状態", text "" ] :: List.map viewHook rows)
        }
        model.hooks


viewHook : WebhookRow -> Html Msg
viewHook hook =
    Ui.rowOf hookColumns
        [ div [ class "flex min-w-0 flex-col" ]
            [ span [ class "font-medium" ] [ text hook.name ]
            , span [ class "truncate font-mono text-[11px] text-ink-faint" ] [ text hook.url ]
            ]
        , span [ class "text-[12px] text-ink-soft" ] [ text (hook.events |> List.map eventText |> String.join "・") ]
        , if hook.active then
            Ui.chip Ui.toneOk "有効"

          else
            Ui.chip Ui.toneNeutral "無効"
        , div [ class "text-right" ] [ Ui.dangerLink (HookDeleteAsked hook) "削除" ]
        ]


{-| イベントの言い方。GitHub は名前を並べる。「4 種類」では何が来るか分からない。
-}
eventText : String -> String
eventText event =
    case event of
        "ENTRY_PUBLISHED" ->
            "公開"

        "ENTRY_UNPUBLISHED" ->
            "公開終了"

        "ENTRY_DELETED" ->
            "削除"

        "SCHEMA_CHANGED" ->
            "スキーマの変更"

        other ->
            other
