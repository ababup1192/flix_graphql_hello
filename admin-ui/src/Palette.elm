module Palette exposing (Item, Model, Msg(..), init, inputId, isOpen, pickedItem, searchCalls, update, view)

{-| ⌘K の検索。API・メディア・設定へ飛ぶのと、**型を跨いだコンテンツの検索**。

CMS の `entries` は型の指定が必須なので、**型の数だけ query を投げる**（型が数個なら実用上は足りる）。
CMS に `searchEntries` が入れば 1 本になる（docs/design/admin-ui-spec.md 10.2）。

-}

import Api
import Dict exposing (Dict)
import EntryLabel
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, id, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Json.Decode as D
import Model exposing (ContentTypeSummary, EntryList, EntryRow, Slug)
import Queries
import Route exposing (Route)


type alias Model =
    { open : Bool
    , query : String
    , hits : Dict String (List Item)
    , picked : Int
    }


{-| 飛び先 1 つ。
-}
type alias Item =
    { label : String
    , hint : String
    , route : Route
    }


type Msg
    = Opened
    | Closed
    | Typed String
    | Moved Int
    | Chosen Item
    | Confirmed
    | GotHits String (Result Api.Problem EntryList)


init : Model
init =
    { open = False, query = "", hits = Dict.empty, picked = 0 }


{-| 開いているか。画面でキーを拾うかの判定に使う。
-}
isOpen : Model -> Bool
isOpen model =
    model.open


update : Msg -> Model -> Model
update msg model =
    case msg of
        Opened ->
            { model | open = True, picked = 0 }

        Closed ->
            { model | open = False, query = "", hits = Dict.empty, picked = 0 }

        Typed query ->
            { model | query = query, picked = 0, hits = Dict.empty }

        Moved step ->
            { model | picked = model.picked + step }

        Chosen _ ->
            { model | open = False, query = "", hits = Dict.empty, picked = 0 }

        Confirmed ->
            -- 飛び先は親が決める（親が pickedItem を見て PushRoute する）。
            model

        GotHits apiId (Ok page) ->
            { model | hits = Dict.insert apiId (List.map (entryItem apiId) page.nodes) model.hits }

        GotHits _ (Err _) ->
            model


entryItem : String -> EntryRow -> Item
entryItem apiId row =
    { label = EntryLabel.forRow row
    , hint = apiId
    , route = Route.Entry "" apiId row.id
    }


{-| 入力ごとに投げる検索。**型の数だけ**投げる。
-}
searchCalls : Slug -> List ContentTypeSummary -> String -> List (Api.Call Msg)
searchCalls project types query =
    -- **1 文字でも探す。** 日本語は 1 文字で絞れる事が多い（「煙」「案」）。
    -- 2 文字からにすると、和文の検索が効かなくなる。
    if String.isEmpty (String.trim query) then
        []

    else
        types
            |> List.map
                (\summary ->
                    Api.call
                        (\id ->
                            Queries.entries id
                                project
                                { typeId = summary.id, search = query, stage = "", conditions = [], ids = [], order = "", first = 5, skip = 0 }
                        )
                        (GotHits summary.apiId)
                )


{-| 出す候補。API とメディアと設定を先に、コンテンツを後に。
-}
results : Slug -> List ContentTypeSummary -> Model -> List Item
results project types model =
    let
        needle : String
        needle =
            String.toLower (String.trim model.query)

        {- 画面を探す時は別名も当てる。「PAT」で Personal Access Token に行けるように。 -}
        matches : { label : String, hint : String, route : Route, also : List String } -> Bool
        matches place =
            String.isEmpty needle
                || List.any (\word -> String.contains needle (String.toLower word)) (place.label :: place.also)

        {- 画面。`also` は探す時だけに使う別名（略語・英語・和名）で、一覧には出さない。 -}
        places : List { label : String, hint : String, route : Route, also : List String }
        places =
            (types
                |> List.map
                    (\summary ->
                        { label = summary.name
                        , hint = "API"
                        , route = Route.Entries project summary.apiId []
                        , also = [ summary.apiId ]
                        }
                    )
            )
                ++ [ { label = "メディア", hint = "画面", route = Route.Media project, also = [ "media", "asset", "画像", "ファイル" ] }
                   , { label = "メンバー", hint = "設定", route = Route.Settings project Route.Members, also = [ "member", "招待", "権限" ] }
                   , { label = "API キーと Webhook", hint = "設定", route = Route.Settings project Route.ApiKeys, also = [ "api key", "apikey", "webhook", "鍵" ] }
                   , { label = "監査ログ", hint = "設定", route = Route.Settings project (Route.Audit []), also = [ "audit", "log", "履歴" ] }
                   , { label = "プロジェクトと MCP", hint = "設定", route = Route.Settings project Route.ProjectSettings, also = [ "mcp", "project", "公開範囲" ] }
                   , { label = "アカウント", hint = "画面", route = Route.Account, also = [ "account", "自分", "プロフィール" ] }
                   , { label = "Personal Access Token", hint = "画面", route = Route.AccountTokens, also = [ "pat", "token", "トークン", "cli" ] }
                   ]

        entries : List Item
        entries =
            model.hits
                |> Dict.values
                |> List.concat
                |> List.map (\item -> { item | route = withProject project item.route })
    in
    (places |> List.filter matches |> List.map (\place -> { label = place.label, hint = place.hint, route = place.route })) ++ entries


{-| 今出ている候補（上限つき）。
-}
shown : Slug -> List ContentTypeSummary -> Model -> List Item
shown project types model =
    results project types model |> List.take 12


{-| 選んでいる位置。候補の数に丸める（下に行き過ぎたら最後、上は先頭）。
-}
pickedIndex : Slug -> List ContentTypeSummary -> Model -> Int
pickedIndex project types model =
    let
        count : Int
        count =
            List.length (shown project types model)
    in
    if count == 0 then
        0

    else
        clamp 0 (count - 1) model.picked


{-| Enter で選ばれた物。親が飛び先を決めるのに使う。
-}
pickedItem : Slug -> List ContentTypeSummary -> Model -> Maybe Item
pickedItem project types model =
    shown project types model |> List.drop (pickedIndex project types model) |> List.head


withProject : Slug -> Route -> Route
withProject project route =
    case route of
        Route.Entry _ apiId entryId ->
            Route.Entry project apiId entryId

        other ->
            other


{-| 入力の id。開いた時に focus を当てるのに使う。
-}
inputId : String
inputId =
    "palette-input"


view : Slug -> List ContentTypeSummary -> Model -> Html Msg
view project types model =
    if not model.open then
        text ""

    else
        let
            items : List Item
            items =
                shown project types model

            picked : Int
            picked =
                pickedIndex project types model
        in
        div
            [ class "fixed inset-0 z-(--z-dialog) flex items-start justify-center bg-black/30 pt-32"
            , onClick Closed
            ]
            [ div
                [ class "w-[560px] overflow-hidden rounded-xl border border-edge bg-panel shadow-2xl"
                , Html.Events.stopPropagationOn "click" (D.succeed ( Moved 0, True ))
                ]
                [ Html.input
                    [ id inputId
                    , class "w-full border-b border-edge bg-panel px-4 py-3 text-sm text-ink outline-none"
                    , placeholder "API・コンテンツ・メディア・設定を検索"
                    , value model.query
                    , onInput Typed
                    , Html.Attributes.autofocus True
                    ]
                    []
                , if List.isEmpty items then
                    div [ class "px-4 py-6 text-center text-[13px] text-ink-faint" ] [ text "見つかりません" ]

                  else
                    div [ class "max-h-80 overflow-auto py-1" ] (List.indexedMap (viewItem picked) items)
                ]
            ]


viewItem : Int -> Int -> Item -> Html Msg
viewItem picked index item =
    Html.button
        [ class
            ("flex w-full items-center gap-3 px-4 py-2.5 text-left text-[13px] "
                ++ (if index == picked then
                        "bg-well text-ink"

                    else
                        "text-ink"
                   )
            )
        , onClick (Chosen item)
        ]
        [ span [ class "truncate" ] [ text item.label ]
        , span [ class "ml-auto shrink-0 text-[11px] text-ink-faint" ] [ text item.hint ]
        ]
