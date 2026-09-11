module Page.Board exposing (Model, Msg, init, load, update, view)

{-| ボード。コンテンツを列に分けて並べる。

**列は公開状態**（下書き / 公開中・下書きあり / 公開中）。CMS にワークフローの status が入れば
そちらを列にする（docs/design/admin-ui-spec.md 2 章）。

**ドラッグで列を移せる。** 移す事は「公開する / 公開を終える」なので、
落とした時に何が起きるかを出す確認を挟む（黙って公開しない）。

-}

import Api
import Dict
import EntryLabel
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class)
import Html.Events exposing (on, onClick, preventDefaultOn)
import Json.Decode as D
import Loaded exposing (Loaded)
import Model exposing (ContentTypeDetail, EntryList, EntryRow, Slug)
import Queries
import Route
import Ui
import Ui.Icon as Icon


type alias Model =
    { project : Slug
    , apiId : String
    , contentType : Loaded ContentTypeDetail
    , entries : Loaded EntryList
    , dragging : Maybe EntryRow
    , asking : Maybe { row : EntryRow, title : String, from : String, to : String }
    , busy : Bool
    , errors : List String

    {- タグの見出し。**タグはコンテンツなので、中身は id の並び**。
       そのまま出すと 12 桁の 16 進が並ぶ（実際に並んだ）ので、名前に引き直す。
    -}
    , tagLabels : Dict.Dict String String
    }


type Msg
    = GotType (Result Api.Problem (Maybe ContentTypeDetail))
    | GotEntries Int (Result Api.Problem EntryList)
    | Grabbed EntryRow
    | Dropped String
    | Released
    | Hovered
    | Confirmed
    | Cancelled
    | GotMoved (Result Api.Problem EntryRow)
    | GotTagLabels (Result Api.Problem EntryList)


{-| 列。値は CMS の ContentStage。

見た目は GitHub Projects に寄せる: 状態を表す丸、名前、件数のバッジ、その下に 1 行の説明。

-}
type alias Column =
    { stage : String
    , name : String
    , hint : String
    , tone : String

    {- ここへ落とせるか。

       WhyNot: 3 列とも落とせる、にしない。「公開中 · 下書きあり」は公開済みの物の
       下書きを保存すると入る**導かれた状態**で、人が盤の上で作れる状態ではない。
       落とせるままにすると、差の無い公開が走って版だけ 1 つ積まれ、カードは
       「公開中」に戻る。
    -}
    , droppable : Bool
    }


columns : List Column
columns =
    [ { stage = "DRAFT", name = "下書き", hint = "まだ公開していません", tone = "text-ink-faint", droppable = True }
    , { stage = "CHANGED", name = "公開中 · 下書きあり", hint = "公開中の内容と差があります。下書きを保存すると入ります", tone = "text-[color:var(--color-warn)]", droppable = False }
    , { stage = "PUBLISHED", name = "公開中", hint = "公開サイトから見えます", tone = "text-[color:var(--color-ok)]", droppable = True }
    ]


init : Slug -> String -> Model
init project apiId =
    { project = project
    , apiId = apiId
    , contentType = Loaded.Loading
    , entries = Loaded.Loading
    , dragging = Nothing
    , asking = Nothing
    , busy = False
    , errors = []
    , tagLabels = Dict.empty
    }


load : Slug -> String -> List (Api.Call Msg)
load slug apiId =
    [ Api.call (\id -> Queries.contentType id slug apiId) GotType ]


update : { project : Slug } -> Msg -> Model -> ( Model, List (Api.Call Msg) )
update ctx msg model =
    case msg of
        GotType result ->
            ( { model | contentType = Loaded.fromResult result }
            , case result of
                Ok (Just detail) ->
                    [ entriesCall ctx.project detail.id 0 ]

                _ ->
                    []
            )

        GotTagLabels (Ok page) ->
            ( { model | tagLabels = Dict.union (Dict.fromList (List.map (\row -> ( row.id, EntryLabel.forRow row )) page.nodes)) model.tagLabels }, [] )

        GotTagLabels (Err _) ->
            ( model, [] )

        GotEntries skip (Ok page) ->
            let
                rows : List EntryRow
                rows =
                    (if skip == 0 then
                        []

                     else
                        heldRows model
                    )
                        ++ page.nodes
            in
            ( { model | entries = Loaded.Present { page | nodes = rows } }
            , (if List.isEmpty page.nodes || List.length rows >= min page.totalCount boardLimit then
                []

               else
                case Loaded.toMaybe model.contentType of
                    Just detail ->
                        [ entriesCall model.project detail.id (List.length rows) ]

                    Nothing ->
                        []
              )
                ++ (case Loaded.toMaybe model.contentType of
                        Just detail ->
                            tagLabelCalls ctx model detail page.nodes

                        Nothing ->
                            []
                   )
            )

        GotEntries _ (Err problem) ->
            ( { model | entries = Loaded.Failed (Api.problemToText problem).message }, [] )

        Grabbed row ->
            ( { model | dragging = Just row }, [] )

        Released ->
            ( { model | dragging = Nothing }, [] )

        Hovered ->
            -- **掴んでいる状態を消さない。** dragover は「ここに落とせる」と言うためだけの物で、
            -- ここで解除すると drop の時に何を掴んでいたか分からなくなる（実際に分からなくなった）。
            ( model, [] )

        Dropped to ->
            case model.dragging of
                Just row ->
                    if row.stage == to then
                        ( { model | dragging = Nothing }, [] )

                    else
                        ( { model
                            | dragging = Nothing
                            , asking =
                                Just
                                    { row = row
                                    , title =
                                        Loaded.toMaybe model.contentType
                                            |> Maybe.map (\detail -> EntryLabel.byField detail.fields row)
                                            |> Maybe.withDefault row.id
                                    , from = row.stage
                                    , to = to
                                    }
                          }
                        , []
                        )

                Nothing ->
                    ( model, [] )

        Cancelled ->
            ( { model | asking = Nothing }, [] )

        Confirmed ->
            case model.asking of
                Just ask ->
                    ( { model | asking = Nothing, busy = True }
                    , [ if ask.to == "DRAFT" then
                            Api.call (\id -> Queries.unpublishEntry id ctx.project ask.row.id) GotMoved

                        else
                            Api.call
                                (\id -> Queries.publishEntry id ctx.project { entryId = ask.row.id, withDependencies = True })
                                GotMoved
                      ]
                    )

                Nothing ->
                    ( model, [] )

        GotMoved (Ok _) ->
            ( { model | busy = False }
            , case Loaded.toMaybe model.contentType of
                Just detail ->
                    [ entriesCall ctx.project detail.id 0 ]

                Nothing ->
                    []
            )

        GotMoved (Err problem) ->
            ( { model | busy = False, errors = [ (Api.problemToText problem).message ] }, [] )


{-| タグがコンテンツ（REFERENCE）なら、名前を引く。

WhyNot: タグの型を頭から 100 件引いて当てにしない。101 個目のタグが付いた
カードは、名前を引けず 12 桁の id を出す。**カードに載っている id だけ**を
名指しして引く。

-}
tagLabelCalls : { project : Slug } -> Model -> ContentTypeDetail -> List EntryRow -> List (Api.Call Msg)
tagLabelCalls ctx model detail rows =
    let
        wanted : List String
        wanted =
            rows
                |> List.concatMap tagIdsOf
                |> List.filter (\entryId -> not (Dict.member entryId model.tagLabels))
                |> unique
    in
    detail.fields
        |> List.filter (\field -> field.apiId == "tags" && field.kind == "REFERENCE")
        |> List.filterMap .targetTypeId
        |> List.concatMap
            (\typeId ->
                Queries.chunkIds wanted
                    |> List.map
                        (\ids ->
                            Api.call
                                (\id ->
                                    Queries.entries id
                                        ctx.project
                                        { typeId = typeId, search = "", stage = "", conditions = [], ids = ids, order = "", first = List.length ids, skip = 0 }
                                )
                                GotTagLabels
                        )
            )


unique : List String -> List String
unique values =
    List.foldl
        (\value kept ->
            if List.member value kept then
                kept

            else
                kept ++ [ value ]
        )
        []
        values


{-| 1 回に引く件数と、盤に並べる上限。
-}
boardPageSize : Int
boardPageSize =
    100


boardLimit : Int
boardLimit =
    500


{-| 今持っているコンテンツ。続きを足す時と、件数を数える時に使う。
-}
heldRows : Model -> List EntryRow
heldRows model =
    Loaded.toMaybe model.entries |> Maybe.map .nodes |> Maybe.withDefault []


{-| **1 本だけ引いて画面で列に分ける。**

CMS の絞り込みは DRAFT と PUBLISHED しか持たない（「公開中・下書きあり」は無い）。
列ごとに引くと、その列だけ絞り込みが効かず全件が出る（実際に出た）。

WhyNot: 1 回引いて終わりにしない。列のバッジは引いた分を数えた数なので、
引き残すとその数が実際と食い違う。上限までは続きを引き、それでも余る時は
盤の上に「ほかに N 件」と出す。

-}
entriesCall : Slug -> String -> Int -> Api.Call Msg
entriesCall project typeId skip =
    Api.call
        (\id ->
            Queries.entries id
                project
                { typeId = typeId, search = "", stage = "", conditions = [], ids = [], order = "", first = boardPageSize, skip = skip }
        )
        (GotEntries skip)


view : Model -> Html Msg
view model =
    Loaded.view
        { loading = Ui.loadingCard
        , missing = Ui.messageCard "この API はありません" []
        , failed = \message -> Ui.messageCard "読み込めませんでした" [ span [ class "text-xs text-[color:var(--color-bad)]" ] [ text message ] ]
        , present = viewBoard model
        }
        model.contentType


viewBoard : Model -> ContentTypeDetail -> Html Msg
viewBoard model detail =
    div [ class "flex flex-col gap-4 py-6" ]
        [ div [ class "flex items-center gap-3" ]
            [ Ui.heading detail.name
            , span [ class "font-mono text-xs text-ink-faint" ] [ text ("/" ++ detail.apiId) ]
            , div [ class "ml-auto" ]
                [ Ui.plainLink [ Html.Attributes.href (Route.toString (Route.Entries model.project detail.apiId [])) ]
                    [ Ui.ghostButton [] [ text "一覧" ] ]
                ]
            ]
        , if List.isEmpty model.errors then
            text ""

          else
            div [ class "flex flex-col gap-1" ]
                (List.map (\message -> span [ class "text-xs text-[color:var(--color-bad)]" ] [ text message ]) model.errors)
        , viewRestNote model detail
        , div [ class "grid grid-cols-3 items-start gap-4" ] (List.map (viewColumn model detail) columns)
        , case model.asking of
            Just ask ->
                viewConfirm model ask

            Nothing ->
                text ""
        ]


{-| 盤に載り切らなかった分の断り。

WhyNot: 列のバッジだけで済ませない。バッジは盤に載っている分の数なので、
載り切らない時は「これで全部」と読めてしまう。

-}
viewRestNote : Model -> ContentTypeDetail -> Html Msg
viewRestNote model detail =
    case model.entries of
        Loaded.Present page ->
            let
                rest : Int
                rest =
                    page.totalCount - List.length page.nodes
            in
            if rest > 0 then
                span [ class "text-xs text-ink-soft" ]
                    [ text ("新しい順に " ++ String.fromInt (List.length page.nodes) ++ " 件を並べています。ほかに " ++ String.fromInt rest ++ " 件あり、")
                    , Ui.plainLink [ Html.Attributes.href (Route.toString (Route.Entries model.project detail.apiId [])) ] [ text "一覧" ]
                    , text "から探せます。"
                    ]

            else
                text ""

        _ ->
            text ""


{-| 列を移す = 公開状態を変える。**何が起きるかを言葉で出してから実行する。**
-}
viewConfirm : Model -> { row : EntryRow, title : String, from : String, to : String } -> Html Msg
viewConfirm model ask =
    div [ class "fixed inset-0 z-(--z-dialog) flex items-center justify-center bg-black/30" ]
        [ Ui.card [ class "flex w-[420px] flex-col gap-3 p-5" ]
            [ Ui.subheading
                (if ask.to == "DRAFT" then
                    "このコンテンツの公開を終えますか"

                 else if ask.from == "CHANGED" then
                    -- **もう公開されている物は「公開しますか」ではない。**
                    -- 変わるのは公開サイトに出る内容で、見える・見えないは変わらない。
                    "下書きの内容を公開しますか"

                 else
                    "このコンテンツを公開しますか"
                )
            , span [ class "text-[13px] font-medium text-ink" ] [ text ask.title ]
            , Ui.note
                [ text
                    (if ask.to == "DRAFT" then
                        "公開サイトから見えなくなります。下書きは残ります。"

                     else if ask.from == "CHANGED" then
                        "公開サイトに出ている内容が、下書きの内容に入れ替わります。未公開の参照先があれば一緒に公開されます。"

                     else
                        "公開サイトから見えるようになります。未公開の参照先があれば一緒に公開されます。"
                    )
                ]
            , div [ class "flex gap-2" ]
                [ Ui.button [ onClick Confirmed ]
                    [ text
                        (if model.busy then
                            "送っています…"

                         else if ask.to == "DRAFT" then
                            "公開を終える"

                         else if ask.from == "CHANGED" then
                            -- エディタの公開の確認と同じ語にする。
                            "変更を公開する"

                         else
                            "公開する"
                        )
                    ]
                , Ui.ghostButton [ onClick Cancelled ] [ text "やめる" ]
                ]
            ]
        ]


viewColumn : Model -> ContentTypeDetail -> Column -> Html Msg
viewColumn model detail column =
    let
        rows : List EntryRow
        rows =
            heldRows model |> List.filter (\row -> row.stage == column.stage)

        count : String
        count =
            case model.entries of
                Loaded.Present _ ->
                    String.fromInt (List.length rows)

                _ ->
                    "—"
    in
    div
        (class
            ("flex min-w-0 flex-col gap-2 rounded-md border p-3 "
                ++ (if model.dragging == Nothing then
                        "border-edge bg-raised"

                    else if column.droppable then
                        "border-accent bg-raised"

                    else
                        -- **落とせない列は掴んでいる間だけ薄くする。** 枠を光らせると、
                        -- 落とせる先と見分けが付かない。
                        "border-edge bg-raised opacity-50"
                   )
            )
            :: (if column.droppable then
                    [ preventDefaultOn "dragover" (D.succeed ( Hovered, True ))
                    , preventDefaultOn "drop" (D.succeed ( Dropped column.stage, True ))
                    ]

                else
                    []
               )
        )
        [ div [ class "flex items-center gap-2" ]
            [ span [ class column.tone ] [ Icon.view Icon.stage ]
            , span [ class "text-sm font-semibold text-ink" ] [ text column.name ]
            , span [ class "rounded-full bg-well px-2 py-0.5 text-[11px] font-medium text-ink-soft" ] [ text count ]
            ]
        , span [ class "pb-1 text-xs text-ink-soft" ] [ text column.hint ]
        , case model.entries of
            Loaded.Loading ->
                div [ class "flex justify-center p-4" ] [ Ui.spinner ]

            Loaded.Failed message ->
                span [ class "px-1 text-xs text-[color:var(--color-bad)]" ] [ text message ]

            _ ->
                if List.isEmpty rows then
                    span [ class "px-1 py-3 text-center text-xs text-ink-faint" ] [ text "なし" ]

                else
                    div [ class "flex flex-col gap-2" ] (List.map (viewCard model detail) rows)
        ]


viewCard : Model -> ContentTypeDetail -> EntryRow -> Html Msg
viewCard model detail row =
    let
        title : String
        title =
            EntryLabel.byField detail.fields row

        tags : List String
        tags =
            tagsOf model row
    in
    div
        [ class "cursor-grab rounded-md border border-edge bg-panel p-3 hover:border-ink-faint"
        , Html.Attributes.draggable "true"
        , on "dragstart" (D.succeed (Grabbed row))
        , on "dragend" (D.succeed Released)
        ]
        [ div [ class "flex items-center gap-1.5 text-[11px] text-ink-soft" ]
            [ span [ class "text-ink-faint" ] [ Icon.view Icon.entry ]
            , span [ class "font-mono truncate" ] [ text (detail.apiId ++ " #" ++ String.right 6 row.id) ]
            ]

        {- WhyNot: 題を伸ばし放題にしない。空白の無い英語の題は枠を突き抜けて隣の列に被り、
           長い日本語の題はカード 1 枚を 400px まで縦に伸ばす（実際にどちらも起きた）。
           全文は `title` 属性で読める。
        -}
        , Ui.titleLink
            [ Html.Attributes.href (Route.toString (Route.Entry model.project detail.apiId row.id))
            , Html.Attributes.title title
            , class "mt-1 line-clamp-2 text-sm leading-6 break-words"
            ]
            [ text title ]
        , div [ class "mt-2 flex flex-wrap gap-1" ]
            (List.map viewTag (List.take tagLimit tags)
                ++ (if List.length tags > tagLimit then
                        [ viewTag ("他 " ++ String.fromInt (List.length tags - tagLimit) ++ " 件") ]

                    else
                        []
                   )
            )
        ]


{-| カードに出すタグの数。

WhyNot: 超えた分を黙って捨てない。3 個で切ったまま何も出さないと、
タグが 20 個ある物と 3 個の物が同じに見える（実際に見えた）。

-}
tagLimit : Int
tagLimit =
    3


{-| タグ。GitHub のラベルのように、丸く縁のある小さな印にする。
-}
viewTag : String -> Html Msg
viewTag label =
    span [ class "max-w-40 truncate rounded-full border border-edge px-2 py-0.5 text-[10px] font-medium text-ink-soft" ] [ text label ]


tagsOf : Model -> EntryRow -> List String
tagsOf model row =
    tagIdsOf row |> List.map (\value -> Dict.get value model.tagLabels |> Maybe.withDefault value)


tagIdsOf : EntryRow -> List String
tagIdsOf row =
    D.decodeValue (D.field "tags" (D.list D.string)) row.fields |> Result.withDefault []
