module Page.Project exposing (Model, Msg, init, update, view)

{-| プロジェクト設定 › プロジェクトと、AI からつなぐ（MCP）。

公開範囲は 2 つ。`public` は鍵なしで公開中を読める。`private` は API キーか役割が要る。

-}

import Api
import Html exposing (Html, div, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)
import Model exposing (Project, Slug)
import Queries
import Ui


type alias Model =
    { project : Project
    , visibility : String
    , busy : Bool
    , errors : List String
    }


type Msg
    = VisibilityToggled
    | GotVisibility (Result Api.Problem String)


init : Project -> Model
init project =
    { project = project, visibility = project.visibility, busy = False, errors = [] }


update : { project : Slug } -> Msg -> Model -> ( Model, List (Api.Call Msg) )
update ctx msg model =
    case msg of
        VisibilityToggled ->
            ( { model | busy = True, errors = [] }
            , [ Api.call (\id -> Queries.updateProjectVisibility id ctx.project (model.visibility /= "PUBLIC")) GotVisibility ]
            )

        GotVisibility (Ok visibility) ->
            ( { model | busy = False, visibility = visibility }, [] )

        GotVisibility (Err problem) ->
            ( { model | busy = False, errors = [ (Api.problemToText problem).message ] }, [] )


view : { origin : String } -> Model -> Html Msg
view args model =
    Ui.page [ class "max-w-2xl" ]
        [ Ui.pageHeader { title = "プロジェクト", icon = Nothing, meta = [], actions = [] }
        , Ui.card [ class "flex flex-col gap-4 p-4" ]
            [ Ui.subheading "公開範囲"
            , Ui.note
                [ text
                    (if model.visibility == "PUBLIC" then
                        "公開中のコンテンツは API キーなしで読めます。公開サイトから直接読む時はこれです。"

                     else
                        "コンテンツ API に API キーか役割が要ります。社内向けや準備中のサイトはこれです。"
                    )
                ]
            , div [ class "flex items-center gap-3" ]
                [ if model.visibility == "PUBLIC" then
                    Ui.chip Ui.toneOk "公開"

                  else
                    Ui.chip Ui.toneNeutral "非公開"
                , Ui.ghostButton [ onClick VisibilityToggled ]
                    [ text
                        (if model.busy then
                            "変更中…"

                         else if model.visibility == "PUBLIC" then
                            "非公開に変更"

                         else
                            "公開に変更"
                        )
                    ]
                ]
            , Ui.errors model.errors
            ]
        , Ui.sectionTitle "AI からつなぐ（MCP）"
        , Ui.note [ text "Claude Code などの AI から、管理画面と同じ物を読み書きできます。見える範囲と権限は API キーと同じで、管理画面だけの隠し API はありません。" ]
        , Ui.card [ class "flex flex-col gap-4 p-4" ]
            [ Ui.field { label = "つなぎ先の URL", hint = Nothing, errors = [] }
                [ Ui.codeBlock [] (mcpUrl { project = model.project, origin = args.origin }) ]
            , Ui.field { label = "つなぐコマンド", hint = Just "API キーは「API キーと Webhook」で発行します", errors = [] }
                [ Ui.codeBlock [ class "text-[11px]" ]
                    ("claude mcp add --transport http cms " ++ mcpUrl { project = model.project, origin = args.origin } ++ " --header \"X-Api-Key: <発行した API キー>\"")
                ]
            , div [ class "flex flex-wrap gap-1.5" ]
                (List.map (\label -> Ui.chip Ui.toneNeutral label)
                    [ "API の一覧と定義の取得"
                    , "コンテンツの検索"
                    , "コンテンツ 1 件の取得（本文は Markdown）"
                    , "コンテンツの作成・修正・削除"
                    , "公開前の確認と公開"
                    ]
                )
            ]
        ]


mcpUrl : { project : Project, origin : String } -> String
mcpUrl args =
    args.origin ++ "/p/" ++ args.project.slug ++ "/mcp"
