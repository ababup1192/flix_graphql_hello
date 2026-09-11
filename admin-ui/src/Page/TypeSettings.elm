module Page.TypeSettings exposing (Model, Msg(..), init, load, unsaved, update, view)

{-| API 設定（API 名・画面プレビューの URL・リンクのパス・削除）。

**エンドポイント（apiId）は変えられない。** URL と API の名前になっていて、変えると
公開サイトが壊れるため、CMS 側に更新の口が無い。

返事（送信中 / 保存しました / 失敗の理由）と未保存の印は `Ui.Reply` に任せる。
この画面が「反応の決まり」を最初に当てた所で、他のフォームも同じ形にしていく。

-}

import Api
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, value)
import Html.Events exposing (onInput)
import Loaded exposing (Loaded)
import Model exposing (ContentTypeDetail, Slug)
import Queries
import Route
import Ui
import Ui.Confirm
import Ui.Reply as Reply exposing (Reply)


type alias Model =
    { project : Slug
    , apiId : String
    , detail : Loaded ContentTypeDetail
    , name : String
    , previewUrl : String
    , linkPath : String
    , dirty : Bool
    , reply : Reply
    , confirmDelete : Bool
    , deleting : Reply
    , deleted : Bool
    }


type Msg
    = GotType (Result Api.Problem (Maybe ContentTypeDetail))
    | NameTyped String
    | PreviewTyped String
    | LinkPathTyped String
    | Saved
    | GotSaved (Result Api.Problem Model.ContentTypeSummary)
    | DeleteAsked
    | DeleteCancelled
    | DeleteConfirmed
    | GotDeleted (Result Api.Problem String)
    | EscapePressed
    | Ignored


init : Slug -> String -> Model
init project apiId =
    { project = project
    , apiId = apiId
    , detail = Loaded.Loading
    , name = ""
    , previewUrl = ""
    , linkPath = ""
    , dirty = False
    , reply = Reply.idle
    , confirmDelete = False
    , deleting = Reply.idle
    , deleted = False
    }


load : Slug -> String -> List (Api.Call Msg)
load slug apiId =
    [ Api.call (\id -> Queries.contentType id slug apiId) GotType ]


{-| 離れる前に止めるか。
-}
unsaved : Model -> Bool
unsaved model =
    model.dirty


update : { project : Slug } -> Msg -> Model -> ( Model, List (Api.Call Msg) )
update ctx msg model =
    case msg of
        GotType result ->
            let
                loaded : Loaded ContentTypeDetail
                loaded =
                    Loaded.fromResult result
            in
            ( case Loaded.toMaybe loaded of
                Just detail ->
                    { model | detail = loaded, name = detail.name, previewUrl = detail.previewUrl, linkPath = detail.linkPath }

                Nothing ->
                    { model | detail = loaded }
            , []
            )

        NameTyped name ->
            ( edited { model | name = name }, [] )

        PreviewTyped url ->
            ( edited { model | previewUrl = url }, [] )

        LinkPathTyped path ->
            ( edited { model | linkPath = path }, [] )

        Saved ->
            case Loaded.toMaybe model.detail of
                Just detail ->
                    ( { model | reply = Reply.sending }
                    , [ Api.call
                            (\id -> Queries.updateContentType id ctx.project { typeId = detail.id, name = model.name, previewUrl = model.previewUrl, linkPath = model.linkPath, icon = "" })
                            GotSaved
                      ]
                    )

                Nothing ->
                    ( model, [] )

        -- 読み直さない。応答までの間に打った文字が、読み直しで元に戻る
        GotSaved (Ok summary) ->
            ( { model
                | reply = Reply.done "保存しました"
                , dirty = False
                , detail = Loaded.map (\detail -> { detail | name = summary.name }) model.detail
              }
            , []
            )

        GotSaved (Err problem) ->
            ( { model | reply = Reply.failed problem }, [] )

        DeleteAsked ->
            ( { model | confirmDelete = True, deleting = Reply.idle }, [] )

        DeleteCancelled ->
            ( { model | confirmDelete = False }, [] )

        DeleteConfirmed ->
            case Loaded.toMaybe model.detail of
                Just detail ->
                    ( { model | deleting = Reply.sending }
                    , [ Api.call (\id -> Queries.deleteContentType id ctx.project detail.id) GotDeleted ]
                    )

                Nothing ->
                    ( model, [] )

        GotDeleted (Ok _) ->
            ( { model | deleting = Reply.idle, confirmDelete = False, deleted = True }, [] )

        GotDeleted (Err problem) ->
            ( { model | deleting = Reply.failed problem }, [] )

        -- 開いている物を 1 段閉じる。今のところ削除の確認だけ
        EscapePressed ->
            ( { model | confirmDelete = False }, [] )

        Ignored ->
            ( model, [] )


{-| 入力を触った。未保存にし、前の返事を下ろす。
-}
edited : Model -> Model
edited model =
    { model | dirty = True, reply = Reply.touched model.reply }


view : { canManage : Bool } -> Model -> Html Msg
view args model =
    if model.deleted then
        Ui.messageCard "API を削除しました"
            [ Ui.link [ Html.Attributes.href (Route.toString Route.Projects) ] [ text "プロジェクトへ戻る" ] ]

    else
        Loaded.view
            { loading = Ui.loadingCard
            , missing = Ui.messageCard "この API はありません" []
            , failed = \message -> Ui.messageCard "読み込めませんでした" [ span [ class "text-xs text-[color:var(--color-bad)]" ] [ text message ] ]
            , present = viewSettings args model
            }
            model.detail


viewSettings : { canManage : Bool } -> Model -> ContentTypeDetail -> Html Msg
viewSettings args model detail =
    div [ class "flex max-w-2xl flex-col gap-5 py-6" ]
        [ div [ class "flex items-center gap-3" ] [ Ui.heading "API 設定", Reply.unsavedChip model.dirty ]
        , Ui.card [ class "flex flex-col gap-4 p-4" ]
            [ Ui.field { label = "API 名", hint = Nothing, errors = Reply.errorsFor "name" model.reply }
                [ Ui.input [ value model.name, onInput NameTyped ] ]
            , Ui.field { label = "エンドポイント", hint = Just "後から変更できません", errors = [] }
                [ div [ class "rounded-md border border-edge bg-raised px-3 py-2 font-mono text-sm text-ink-soft" ]
                    [ text ("/" ++ detail.apiId) ]
                ]
            , Ui.field
                { label = "画面プレビューの URL"
                , hint = Just "公開サイトの URL。{id} はコンテンツ ID に置き換わります"
                , errors = Reply.errorsFor "previewUrl" model.reply
                }
                [ Ui.input [ value model.previewUrl, onInput PreviewTyped, class "font-mono", placeholder "https://example.com/blog/{id}" ] ]
            , Ui.field
                { label = "リンクのパス"
                , hint = Just "本文からこの API のコンテンツにリンクしたときのパス。{slug} と {id} が使えます（{slug} が空なら {id} になります）。空のままだと #entry:{id} になります"
                , errors = Reply.errorsFor "linkPath" model.reply
                }
                [ Ui.input [ value model.linkPath, onInput LinkPathTyped, class "font-mono", placeholder "/blog/{slug}" ] ]
            , if args.canManage then
                Reply.saveButton { label = "保存", dirty = model.dirty, reply = model.reply, onSave = Saved }

              else
                Ui.note [ text "変更するには API を管理する権限が必要です。" ]
            ]
        , if args.canManage then
            viewDanger model detail

          else
            text ""
        ]


{-| 削除。**コンテンツが残っていれば CMS が断る**ので、そう伝えてから押させる。
-}
viewDanger : Model -> ContentTypeDetail -> Html Msg
viewDanger model detail =
    Ui.card [ class "flex flex-col gap-3 border-[color:var(--color-warn)] bg-[color:var(--color-warn-bg)] p-4" ]
        [ Ui.subheading "この API を削除"
        , Ui.note
            [ text (String.fromInt (List.length detail.fields) ++ " 個のフィールドの定義も一緒に削除されます。コンテンツが 1 件でも残っている場合は削除できません。先にコンテンツを削除してください。") ]
        , div [] [ Ui.dangerLink DeleteAsked "この API を削除…" ]
        , if model.confirmDelete then
            Ui.Confirm.view
                { title = "「" ++ detail.name ++ "」を削除しますか"
                , details = []
                , body = String.fromInt (List.length detail.fields) ++ " 個のフィールドの定義も一緒に削除されます。元には戻せません。"
                , confirm = "削除"
                , reply = model.deleting
                , onConfirm = DeleteConfirmed
                , onCancel = DeleteCancelled
                , ignore = Ignored
                }

          else
            text ""
        ]
