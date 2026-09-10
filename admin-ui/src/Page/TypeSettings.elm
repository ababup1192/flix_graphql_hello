module Page.TypeSettings exposing (Model, Msg, init, load, update, view)

{-| API 設定（型の名前・プレビューの URL・パスの形・削除）。

**エンドポイント（apiId）は変えられない。** URL と API の名前になっていて、変えると
公開サイトが壊れるため、CMS 側に更新の口が無い。

-}

import Api
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Loaded exposing (Loaded)
import Model exposing (ContentTypeDetail, Slug)
import Queries
import Route
import Ui


type alias Model =
    { project : Slug
    , apiId : String
    , detail : Loaded ContentTypeDetail
    , name : String
    , previewUrl : String
    , linkPath : String
    , confirmDelete : Bool
    , deleted : Bool
    , errors : List String
    , busy : Bool
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


init : Slug -> String -> Model
init project apiId =
    { project = project
    , apiId = apiId
    , detail = Loaded.Loading
    , name = ""
    , previewUrl = ""
    , linkPath = ""
    , confirmDelete = False
    , deleted = False
    , errors = []
    , busy = False
    }


load : Slug -> String -> List (Api.Call Msg)
load slug apiId =
    [ Api.call (\id -> Queries.contentType id slug apiId) GotType ]


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
            ( { model | name = name }, [] )

        PreviewTyped url ->
            ( { model | previewUrl = url }, [] )

        LinkPathTyped path ->
            ( { model | linkPath = path }, [] )

        Saved ->
            case Loaded.toMaybe model.detail of
                Just detail ->
                    ( { model | busy = True, errors = [] }
                    , [ Api.call
                            (\id -> Queries.updateContentType id ctx.project { typeId = detail.id, name = model.name, previewUrl = model.previewUrl, linkPath = model.linkPath, icon = "" })
                            GotSaved
                      ]
                    )

                Nothing ->
                    ( model, [] )

        GotSaved (Ok _) ->
            ( { model | busy = False }, load ctx.project model.apiId )

        GotSaved (Err problem) ->
            ( failed problem model, [] )

        DeleteAsked ->
            ( { model | confirmDelete = True }, [] )

        DeleteCancelled ->
            ( { model | confirmDelete = False }, [] )

        DeleteConfirmed ->
            case Loaded.toMaybe model.detail of
                Just detail ->
                    ( { model | busy = True, confirmDelete = False }
                    , [ Api.call (\id -> Queries.deleteContentType id ctx.project detail.id) GotDeleted ]
                    )

                Nothing ->
                    ( model, [] )

        GotDeleted (Ok _) ->
            ( { model | busy = False, deleted = True }, [] )

        GotDeleted (Err problem) ->
            ( failed problem model, [] )


failed : Api.Problem -> Model -> Model
failed problem model =
    { model | busy = False, errors = [ (Api.problemToText problem).message ] }


view : { canManage : Bool } -> Model -> Html Msg
view args model =
    if model.deleted then
        Ui.messageCard "この API を消しました"
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
        [ Ui.heading "API 設定"
        , viewErrors model
        , Ui.card [ class "flex flex-col gap-4 p-4" ]
            [ Ui.field { label = "表示名", hint = Nothing, errors = [] }
                [ Ui.input [ value model.name, onInput NameTyped ] ]
            , Ui.field { label = "エンドポイント", hint = Just "後から変えられません", errors = [] }
                [ div [ class "rounded-md border border-edge bg-raised px-3 py-2 font-mono text-sm text-ink-soft" ]
                    [ text ("/" ++ detail.apiId) ]
                ]
            , Ui.field
                { label = "画面プレビューの URL"
                , hint = Just "公開サイト側の URL。{id} がコンテンツの id に置き換わります"
                , errors = []
                }
                [ Ui.input [ value model.previewUrl, onInput PreviewTyped, class "font-mono", placeholder "https://example.com/blog/{id}" ] ]
            , Ui.field
                { label = "パスの形"
                , hint = Just "本文からこの API のコンテンツへリンクした時に出る path。{slug} と {id} が使えます（{slug} は空なら id になります）。空にすると #entry:{id} のままになります"
                , errors = []
                }
                [ Ui.input [ value model.linkPath, onInput LinkPathTyped, class "font-mono", placeholder "/blog/{slug}" ] ]
            , if args.canManage then
                div [] [ Ui.button [ onClick Saved ] [ text (busyText model "保存") ] ]

              else
                Ui.note [ text "変えるには API を管理する権限が要ります。" ]
            ]
        , if args.canManage then
            viewDanger model detail

          else
            text ""
        ]


{-| 消す操作。**コンテンツが残っていれば CMS が断る**ので、そう伝えてから押させる。
-}
viewDanger : Model -> ContentTypeDetail -> Html Msg
viewDanger model detail =
    Ui.card [ class "flex flex-col gap-3 border-[color:var(--color-warn)] bg-[color:var(--color-warn-bg)] p-4" ]
        [ Ui.subheading "この API を消す"
        , Ui.note
            [ text ("フィールド " ++ String.fromInt (List.length detail.fields) ++ " 個の定義ごと消えます。コンテンツが 1 件でも残っていれば消せません（先にコンテンツを消してください）。") ]
        , if model.confirmDelete then
            div [ class "flex gap-2" ]
                [ Ui.button [ onClick DeleteConfirmed ] [ text (busyText model "消す") ]
                , Ui.ghostButton [ onClick DeleteCancelled ] [ text "やめる" ]
                ]

          else
            div [] [ Ui.dangerLink DeleteAsked "この API を消す…" ]
        ]


viewErrors : Model -> Html Msg
viewErrors model =
    if List.isEmpty model.errors then
        text ""

    else
        div [ class "flex flex-col gap-1" ]
            (List.map (\message -> span [ class "text-xs text-[color:var(--color-bad)]" ] [ text message ]) model.errors)


busyText : Model -> String -> String
busyText model label =
    if model.busy then
        "送っています…"

    else
        label
