module Page.Media exposing (Model, Msg(..), init, inputId, load, takeUpload, update, view)

{-| メディア。

**アップロードは 3 手**: `createUploadUrl` で置き先をもらう → ブラウザが署名付き URL に PUT する
→ `confirmAsset` で置けた事を CMS に伝える。PUT は Elm がやらず、port の向こうの
TypeScript がやる（ファイルの中身を Elm に持ち込まない）。

-}

import Api
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, src, value)
import Html.Events exposing (on, onClick, onInput)
import Json.Decode as D
import Loaded exposing (Loaded)
import Model exposing (AssetList, AssetRow, Slug, Upload)
import Queries
import Ui
import Ui.Confirm
import Ui.Reply as Reply exposing (Reply)


{-| 選んだファイルの見出しだけ。**中身は持たない**（Elm の port は File を通せない。
中身は input 要素の中に置いたままで、PUT は TypeScript がやる）。
-}
type alias Picked =
    { fileName : String
    , mime : String
    , size : Int
    }


type alias Model =
    { assets : Loaded AssetList
    , picked : Maybe Picked
    , uploading : Maybe { fileName : String, assetId : String }
    , selected : Maybe AssetRow
    , alt : String
    , errors : List String

    {- 代替テキストの保存の返事と、削除の確認。 -}
    , altReply : Reply
    , confirmDelete : Maybe AssetRow
    , deleting : Reply
    , pending : Maybe Upload

    {- 継ぎ足しを頼んでいる間の印。二重に押せないようにする。 -}
    , loadingMore : Bool
    }


type Msg
    = GotAssets (Result Api.Problem AssetList)
    | MoreWanted
    | GotMore (Result Api.Problem AssetList)
    | FilePicked (Maybe Picked)
    | GotUploadUrl (Result Api.Problem Upload)
    | UploadFinished { assetId : String, ok : Bool }
    | GotConfirmed (Result Api.Problem AssetRow)
    | Selected AssetRow
    | AltTyped String
    | AltSaved
    | GotAltSaved (Result Api.Problem AssetRow)
    | DeleteAsked AssetRow
    | DeleteCancelled
    | DeleteConfirmed
    | GotDeleted (Result Api.Problem String)
    | EscapePressed
    | Ignored


init : Model
init =
    { assets = Loaded.Loading
    , picked = Nothing
    , uploading = Nothing
    , selected = Nothing
    , alt = ""
    , errors = []
    , altReply = Reply.idle
    , confirmDelete = Nothing
    , deleting = Reply.idle
    , pending = Nothing
    , loadingMore = False
    }


{-| 1 回に引く枚数。

WhyNot: 全部を 1 回で引かない。200 枚を一度に並べると、選ぶまでに要らない画像まで
全部落ちてくる。代わりに**総数を必ず出し**、足りなければ継ぎ足す。

-}
perPage : Int
perPage =
    60


load : Slug -> List (Api.Call Msg)
load slug =
    [ Api.call (\id -> Queries.assets id slug { first = perPage, skip = 0 }) GotAssets ]


update : { project : Slug } -> Msg -> Model -> ( Model, List (Api.Call Msg) )
update ctx msg model =
    case msg of
        GotAssets result ->
            ( { model | assets = Loaded.fromResult (Result.map Just result), loadingMore = False }, [] )

        MoreWanted ->
            ( { model | loadingMore = True }
            , [ Api.call (\id -> Queries.assets id ctx.project { first = perPage, skip = shownCount model }) GotMore ]
            )

        GotMore (Ok page) ->
            ( { model
                | loadingMore = False
                , assets = Loaded.map (\loaded -> { nodes = loaded.nodes ++ page.nodes, totalCount = page.totalCount }) model.assets
              }
            , []
            )

        GotMore (Err problem) ->
            ( failed problem { model | loadingMore = False }, [] )

        FilePicked (Just picked) ->
            ( { model | picked = Just picked, errors = [] }
            , [ Api.call
                    (\id ->
                        Queries.createUploadUrl id
                            ctx.project
                            { fileName = picked.fileName, mime = picked.mime, size = picked.size }
                    )
                    GotUploadUrl
              ]
            )

        FilePicked Nothing ->
            ( model, [] )

        GotUploadUrl (Ok upload) ->
            ( { model
                | uploading = Just { fileName = model.picked |> Maybe.map .fileName |> Maybe.withDefault "", assetId = upload.assetId }
                , pending = Just upload
              }
            , []
            )

        GotUploadUrl (Err problem) ->
            ( failed problem model, [] )

        UploadFinished result ->
            if result.ok then
                ( model, [ Api.call (\id -> Queries.confirmAsset id ctx.project result.assetId) GotConfirmed ] )

            else
                ( { model | uploading = Nothing, errors = [ "アップロードに失敗しました" ] }, [] )

        GotConfirmed (Ok _) ->
            ( { model | uploading = Nothing, picked = Nothing }, load ctx.project )

        GotConfirmed (Err problem) ->
            ( failed problem { model | uploading = Nothing }, [] )

        Selected asset ->
            ( { model | selected = Just asset, alt = asset.alt, altReply = Reply.idle }, [] )

        AltTyped alt ->
            ( { model | alt = alt, altReply = Reply.touched model.altReply }, [] )

        AltSaved ->
            case model.selected of
                Just asset ->
                    ( { model | altReply = Reply.sending }
                    , [ Api.call (\id -> Queries.updateAsset id ctx.project { assetId = asset.id, alt = model.alt }) GotAltSaved ]
                    )

                Nothing ->
                    ( model, [] )

        GotAltSaved (Ok asset) ->
            ( { model
                | selected = Just asset
                , altReply = Reply.done "保存しました"
                , assets = Loaded.map (\page -> { page | nodes = List.map (replace asset) page.nodes }) model.assets
              }
            , []
            )

        GotAltSaved (Err problem) ->
            ( { model | altReply = Reply.failed problem }, [] )

        DeleteAsked asset ->
            ( { model | confirmDelete = Just asset, deleting = Reply.idle }, [] )

        DeleteCancelled ->
            ( { model | confirmDelete = Nothing }, [] )

        DeleteConfirmed ->
            case model.confirmDelete of
                Just asset ->
                    ( { model | deleting = Reply.sending }, [ Api.call (\id -> Queries.deleteAsset id ctx.project asset.id) GotDeleted ] )

                Nothing ->
                    ( model, [] )

        EscapePressed ->
            ( { model | confirmDelete = Nothing }, [] )

        Ignored ->
            ( model, [] )

        GotDeleted (Ok assetId) ->
            ( { model
                | selected = Nothing
                , confirmDelete = Nothing
                , deleting = Reply.idle
                , assets =
                    Loaded.map
                        (\page ->
                            { nodes = List.filter (\asset -> asset.id /= assetId) page.nodes
                            , totalCount = max 0 (page.totalCount - 1)
                            }
                        )
                        model.assets
              }
            , []
            )

        GotDeleted (Err problem) ->
            ( { model | deleting = Reply.failed problem }, [] )


replace : AssetRow -> AssetRow -> AssetRow
replace updated current =
    if current.id == updated.id then
        updated

    else
        current


failed : Api.Problem -> Model -> Model
failed problem model =
    { model | errors = [ (Api.problemToText problem).message ] }


{-| 今この画面に出ている枚数。次に引き足す位置でもある。
-}
shownCount : Model -> Int
shownCount model =
    Loaded.toMaybe model.assets |> Maybe.map (\page -> List.length page.nodes) |> Maybe.withDefault 0


{-| ファイルを置く input の id。TypeScript がこの id で中身を取り、PUT する。
-}
inputId : String
inputId =
    "asset-file"


{-| 置き先が来ていれば 1 回だけ渡す。親がこれを port に流す。
-}
takeUpload : Model -> ( Model, Maybe Upload )
takeUpload model =
    ( { model | pending = Nothing }, model.pending )


view : Model -> Html Msg
view model =
    div [ class "flex gap-6" ]
        [ Ui.page [ class "min-w-0 flex-1" ]
            [ Ui.pageHeader { title = "メディア", icon = Nothing, meta = [], actions = [ viewPicker ] }
            , Ui.errors model.errors
            , case model.uploading of
                Just uploading ->
                    Ui.card [ class "flex items-center gap-3 p-4 text-[13px] text-ink" ]
                        [ Ui.spinner, text (uploading.fileName ++ " をアップロード中…") ]

                Nothing ->
                    text ""
            , viewGrid model
            ]
        , case model.selected of
            Just asset ->
                viewPanel model asset

            Nothing ->
                text ""
        , case model.confirmDelete of
            Just asset ->
                Ui.Confirm.view
                    { title = "「" ++ asset.fileName ++ "」を削除しますか"
                    , body = "このメディアを使っているコンテンツからは見えなくなります。元には戻せません。"
                    , confirm = "削除"
                    , reply = model.deleting
                    , onConfirm = DeleteConfirmed
                    , onCancel = DeleteCancelled
                    , ignore = Ignored
                    }

            Nothing ->
                text ""
        ]


{-| ファイルを選ぶ。中身は Elm に持ち込まず、port の向こうが PUT する。
-}
viewPicker : Html Msg
viewPicker =
    Html.label [ class "inline-flex h-8 cursor-pointer items-center rounded-md bg-accent px-3 text-[13px] font-semibold text-white hover:opacity-90" ]
        [ text "アップロード"
        , Html.input
            [ Html.Attributes.type_ "file"
            , Html.Attributes.id inputId
            , class "hidden"
            , on "change" (D.map FilePicked pickedDecoder)
            ]
            []
        ]


{-| 選んだファイルの見出しだけを読む（name / type / size は素の値なので Elm で扱える）。
-}
pickedDecoder : D.Decoder (Maybe Picked)
pickedDecoder =
    D.at [ "target", "files" ]
        (D.oneOf
            [ D.field "0"
                (D.map3 (\fileName mime size -> Just { fileName = fileName, mime = mime, size = size })
                    (D.field "name" D.string)
                    (D.field "type" D.string)
                    (D.field "size" D.int)
                )
            , D.succeed Nothing
            ]
        )


viewGrid : Model -> Html Msg
viewGrid model =
    Loaded.view
        { loading = Ui.loadingCard
        , missing = Ui.messageCard "メディアがありません" []
        , failed = Ui.failedCard
        , present =
            \page ->
                if List.isEmpty page.nodes then
                    Ui.messageCard "メディアがありません" [ Ui.note [ text "右上からアップロードしてください。" ] ]

                else
                    div [ class "flex flex-col gap-3" ]
                        [ div [ class "grid grid-cols-6 gap-3" ] (List.map viewThumb page.nodes)
                        , viewMore model page
                        ]
        }
        model.assets


{-| 何枚のうち何枚を出しているか。

WhyNot: 出した枚数だけで黙って打ち切らない。総数もページャも出さないと、
61 枚目から先に**画面から辿り着く手が無くなる**（実際に無くなった）。

-}
viewMore : Model -> AssetList -> Html Msg
viewMore model page =
    let
        shown : Int
        shown =
            List.length page.nodes
    in
    div [ class "flex items-center gap-3 text-xs text-ink-soft" ]
        [ text ("全 " ++ String.fromInt page.totalCount ++ " 枚のうち 1〜" ++ String.fromInt shown ++ " 枚")
        , if shown < page.totalCount then
            div [ class "ml-auto" ]
                [ Ui.ghostButton
                    [ onClick MoreWanted, Html.Attributes.disabled model.loadingMore ]
                    [ text
                        (if model.loadingMore then
                            "読んでいます…"

                         else
                            "もっと読む"
                        )
                    ]
                ]

          else
            text ""
        ]


viewThumb : AssetRow -> Html Msg
viewThumb asset =
    Ui.tile [ onClick (Selected asset) ]
        [ Ui.thumb "h-24" { url = asset.url, mime = asset.mime }
        , div [ class "flex flex-col items-start gap-1 border-t border-edge p-2" ]
            [ span [ class "w-full truncate text-[11px] font-medium text-ink" ] [ text asset.fileName ]
            , if asset.status == "PENDING" then
                Ui.chip Ui.toneWarn "アップロード中"

              else
                span [ class "text-[10px] text-ink-faint" ] [ text (sizeText asset.size) ]
            ]
        ]


sizeText : Int -> String
sizeText bytes =
    if bytes > 1024 * 1024 then
        String.fromInt (bytes // (1024 * 1024)) ++ " MB"

    else
        String.fromInt (bytes // 1024) ++ " KB"


{-| 選んだ 1 枚。**画面に貼り付いて付いてくる**（`sticky`）。

一覧の下の方を選ぶと、右の面は上に置かれたままなので**画面の外に出て見えない**
（実際に見えなかった）。

-}
viewPanel : Model -> AssetRow -> Html Msg
viewPanel model asset =
    div [ class "sticky top-0 z-(--z-sticky) flex max-h-screen w-72 shrink-0 flex-col gap-4 overflow-auto border-l border-edge py-6 pl-5" ]
        [ Ui.railTitle "選んだメディア"
        , if String.startsWith "image/" asset.mime then
            Html.img [ src asset.url, class "w-full rounded-md border border-edge bg-well object-contain" ] []

          else
            text ""
        , Ui.field { label = "代替テキスト（alt）", hint = Just "画像が出ない時と読み上げに使います", errors = [] }
            [ Ui.input [ value model.alt, onInput AltTyped ] ]
        , div [ class "flex items-center gap-2" ]
            [ Reply.saveButton { label = "保存", dirty = model.alt /= asset.alt, reply = model.altReply, onSave = AltSaved }
            , div [ class "ml-auto" ] [ Ui.dangerLink (DeleteAsked asset) "削除" ]
            ]
        , Ui.railSection "ファイル"
            []
            [ div [ class "flex flex-col gap-1 text-xs text-ink-soft" ]
                [ span [ class "font-mono break-all text-ink" ] [ text asset.fileName ]
                , span [] [ text (asset.mime ++ " · " ++ sizeText asset.size) ]
                , span [ class "font-mono break-all text-[10px] text-ink-faint" ] [ text asset.url ]
                ]
            ]
        ]
