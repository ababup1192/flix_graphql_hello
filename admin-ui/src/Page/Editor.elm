module Page.Editor exposing (Model, Msg(..), init, load, previewOf, richInputId, takeRichUpload, title, unsaved, update, view)

{-| コンテンツの編集。

**保存は人が押す。** 上の帯に「下書き保存」と「公開する」を並べ、押した時だけ書く
（Strapi / Payload / WordPress と同じ）。自動保存にすると、書きかけの下書きが
勝手に版になり、公開前の確認を挟む余地が無くなる。

**公開は下書き保存の後**。公開を押した時に未保存が残っていれば、先に保存してから
公開前の確認を開く（人に 2 回押させない）。

保存は常に 1 本だけ飛ばし、飛んでいる間の入力は 1 件だけ持つ
（重ねると古い版で自分に競合を起こす）。応答の `version` で必ず更新する。

`CONFLICT` は相手が先に保存した合図。相手の下書きを取り直して見せ、
「乗せて保存」か「捨てる」を人に選ばせる。自動で混ぜない。

-}

import Api
import Api.Error
import Dict exposing (Dict)
import EntryLabel
import FieldValue exposing (Value)
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Json.Decode as D
import Json.Encode as E
import Loaded exposing (Loaded)
import Model exposing (ContentTypeDetail, EntryRow, FieldDef, Slug)
import Queries
import Route
import Time
import Ui
import Ui.DateTime
import Ui.Icon as Icon


type alias Model =
    { project : Slug
    , apiId : String
    , entryId : Maybe String
    , contentType : Loaded ContentTypeDetail
    , values : Dict String Value
    , version : Int
    , save : SaveState
    , conflict : Maybe EntryRow
    , errors : List ( String, String )
    , stage : String
    , report : Maybe Model.PublishReport
    , publishing : Bool
    , history : Loaded (List Model.EntryVersion)
    , schedules : List Model.ScheduleRow
    , scheduler : Maybe Ui.DateTime.Model

    {- DATE のフィールドごとの、選んでいる途中の日時。

       WhyNot: 予約と同じ 1 つの `scheduler` に相乗りしない。DATE は 1 つの entry に
       いくつでもあるので、共有すると別のフィールドの月送りが混ざる。

       WhyNot: 「空かどうか」をここに持たない。空は `values` の `Date ""` が表す
       （ここは暦の見え方だけを持つ）。
    -}
    , dates : Dict String Ui.DateTime.Model
    , dateOpen : Maybe String
    , today : Maybe { year : Int, month : Int, day : Int }
    , zone : Time.Zone
    , schedulingOpen : Bool
    , entryMissing : Bool
    , picking : Maybe String
    , assets : Loaded Model.AssetList

    {- 本文に入れるためにメディアを選んでいる所（値は入れ先のフィールドの apiId）。
       フィールドの `picking` と分ける。**本文は複数選べる**（2 枚以上で横並びになる）。
    -}
    , richPicking : Maybe String
    , richPicked : List String

    {- 本文に入れる指示。`seq` で 1 回だけ入れる（属性は同じ値のまま描き直される）。 -}
    , insert : Maybe { seq : Int, apiId : String, assetIds : List String }
    , insertSeq : Int

    {- 貼り付けで上げている途中の物。asset の id から仮の見た目の token に戻す。 -}
    , uploads : Dict String { token : String, apiId : String }
    , pendingUpload : Maybe Model.Upload
    , resolved : List { apiId : String, token : String, assetId : String }

    {- 上げ終わったメディア。一覧を引き直さずに URL を本文へ渡す。 -}
    , newAssets : List Model.AssetRow
    , row : Maybe EntryRow
    , touched : Bool

    {- 参照の候補。**打つ度に引き直す**（先読みした 100 件では 101 件目が永遠に出ない）。
       まだ引いていないフィールドは鍵ごと無い。
    -}
    , refs : Dict String (List ( String, String ))

    {- フィールドごとに、打った文字に当たるコンテンツの件数。**出した数より多ければ**
       「ほかに N 件」と断るのに使う。
    -}
    , refTotals : Dict String Int
    , refQuery : Dict String String
    , refOpen : Maybe String

    {- 選んである物の見出し。**検索の結果に居なくても出す**ために、id で引いた分と
       選んだ時の分をここに貯める。
    -}
    , refLabels : Dict String String
    , asking : Asking

    {- 公開・取り下げが断られた理由。確認の中に出す。 -}
    , actionError : Maybe String
    , pendingPublish : Bool

    {- このコンテンツを参照している物。**削除と取り下げを止める理由**でもある。 -}
    , referrers : Loaded (List Model.Referrer)
    , referrersOpen : Bool

    {- レールは先頭だけ出す。全部はここを開いて見せる。 -}
    , historyOpen : Bool

    {- 本文を画面いっぱいに広げている項目の apiId。**1 つだけ。** -}
    , expanded : Maybe String
    , schedulesOpen : Bool

    {- 本文からリンクを張る時の候補。型をまたいで探す。 -}
    , linkCandidates : List Model.LinkCandidate

    {- 探した文字に当たるコンテンツの件数（型をまたいだ合計）と、何回引いたか。
       「もっと見る」で次を引くのに要る。
    -}
    , linkTotal : Int
    , linkPage : Int
    , linkQuery : String
    , linkedEntries : List Model.LinkCandidate
    }


{-| 保存の状態。**飛んでいる間の入力は 1 件だけ持つ。**
-}
type SaveState
    = Saved
    | Dirty
    | Saving { queued : Bool }
    | Conflicted
    | SaveFailed String


{-| 今どの確認を出しているか。

**公開も取り下げも確認を挟む。** 取り下げは公開サイトから物が消える操作で、
公開と同じだけ重い。ボードでは聞いてエディタでは聞かない、では一貫しない。

-}
type Asking
    = NotAsking
    | AskingPublish
    | AskingUnpublish
    | AskingRestore Model.EntryVersion


type Msg
    = GotType (Result Api.Problem (Maybe ContentTypeDetail))
    | GotEntry (Result Api.Problem (Maybe EntryRow))
    | FieldTyped String Value
    | SaveWanted
    | GotSaved (Result Api.Problem EntryRow)
    | GotTheirs (Result Api.Problem (Maybe EntryRow))
    | KeepMine
    | TakeTheirs
    | Ignored
    | ApiPreviewWanted
    | PublishOpened
    | UnpublishOpened
    | PublishClosed
    | CheckWanted
    | GotReport (Result Api.Problem Model.PublishReport)
    | PublishWanted
    | UnpublishWanted
    | GotPublished (Result Api.Problem EntryRow)
    | GotHistory (Result Api.Problem (Maybe (List Model.EntryVersion)))
    | GotReferrers (Result Api.Problem (List Model.Referrer))
    | LinkSearched String
    | LinkMoreAsked
    | GotLinkCandidates TypeMark (Result Api.Problem Model.EntryList)
    | LinkResolveAsked (List String)
    | GotLinkedEntries TypeMark (Result Api.Problem Model.EntryList)
    | GotSchedules (Result Api.Problem (List Model.ScheduleRow))
    | GotRefs String String (Result Api.Problem Model.EntryList)
    | GotRefLabels (Result Api.Problem Model.EntryList)
    | RefOpened String
    | RefClosed
    | RefSearched String String
    | RefPicked String String
    | RefDropped String String
    | DateOpened String
    | DateClosed
    | DateMsg String Ui.DateTime.Msg
    | DateApplied String
    | DateCleared String
    | PickerOpened String
    | PickerClosed
    | GotAssets (Result Api.Problem Model.AssetList)
    | AssetPicked String
    | ScheduleOpened
    | TodayKnown Time.Zone Int Int Int
    | SchedulerMsg Ui.DateTime.Msg
    | ScheduleSubmitted
    | GotScheduled (Result Api.Problem Model.ScheduleRow)
    | ScheduleCancelled String
    | GotScheduleCancelled (Result Api.Problem String)
    | ReferrersOpened
    | ReferrersClosed
    | HistoryToggled Bool
    | ExpandToggled (Maybe String)
    | RestoreOpened Model.EntryVersion
    | RestoreWanted
    | GotVersionSaved (Result Api.Problem String)
    | GotRestored (Result Api.Problem EntryRow)
    | SchedulesToggled Bool
    | RichPickerOpened String
    | RichInsertWanted
    | RichUploadStarted String { token : String, fileName : String, mime : String, size : Int }
    | GotRichUploadUrl String String (Result Api.Problem Model.Upload)
    | RichUploadFinished { assetId : String, ok : Bool }
    | GotRichConfirmed String (Result Api.Problem Model.AssetRow)


init : Slug -> String -> Maybe String -> Model
init project apiId entryId =
    { project = project
    , apiId = apiId
    , entryId = entryId
    , contentType = Loaded.Loading
    , values = Dict.empty
    , version = 0
    , save = Saved
    , conflict = Nothing
    , errors = []
    , stage = "DRAFT"
    , report = Nothing
    , publishing = False
    , history = Loaded.Loading
    , schedules = []
    , scheduler = Nothing
    , dates = Dict.empty
    , dateOpen = Nothing
    , today = Nothing
    , zone = Time.utc
    , schedulingOpen = False
    , entryMissing = False
    , picking = Nothing
    , assets = Loaded.Loading
    , row = Nothing
    , touched = False
    , refs = Dict.empty
    , refTotals = Dict.empty
    , refQuery = Dict.empty
    , refOpen = Nothing
    , refLabels = Dict.empty
    , asking = NotAsking
    , actionError = Nothing
    , pendingPublish = False
    , referrers = Loaded.Loading
    , referrersOpen = False
    , historyOpen = False
    , expanded = Nothing
    , schedulesOpen = False
    , linkCandidates = []
    , linkTotal = 0
    , linkPage = 0
    , linkQuery = ""
    , linkedEntries = []
    , richPicking = Nothing
    , richPicked = []
    , insert = Nothing
    , insertSeq = 0
    , uploads = Dict.empty
    , pendingUpload = Nothing
    , resolved = []
    , newAssets = []
    }


load : Slug -> String -> Maybe String -> List (Api.Call Msg)
load slug apiId entryId =
    Api.call (\id -> Queries.contentType id slug apiId) GotType
        :: (case entryId of
                Just chosen ->
                    [ Api.call (\id -> Queries.entry id slug chosen) GotEntry
                    , Api.call (\id -> Queries.referrers id slug chosen) GotReferrers
                    , Api.call (\id -> Queries.versions id slug chosen) GotHistory
                    , Api.call (\id -> Queries.schedules id slug (Just chosen)) GotSchedules
                    ]

                Nothing ->
                    []
           )


update : { project : Slug, types : List Model.ContentTypeSummary } -> Msg -> Model -> ( Model, List (Api.Call Msg) )
update ctx msg model =
    case msg of
        GotType result ->
            let
                next : Model
                next =
                    sync { model | contentType = Loaded.fromResult result }
            in
            ( next, refLabelCalls { project = ctx.project } next ++ assetCalls { project = ctx.project } next )

        PickerOpened apiId ->
            ( { model | picking = Just apiId }
            , case model.assets of
                Loaded.Present _ ->
                    []

                _ ->
                    [ Api.call (\id -> Queries.assets id ctx.project { first = 60, skip = 0 }) GotAssets ]
            )

        RichPickerOpened apiId ->
            ( { model | richPicking = Just apiId, richPicked = [] }
            , case model.assets of
                Loaded.Present _ ->
                    []

                _ ->
                    [ Api.call (\id -> Queries.assets id ctx.project { first = 60, skip = 0 }) GotAssets ]
            )

        RichInsertWanted ->
            case model.richPicking of
                Just apiId ->
                    ( { model
                        | richPicking = Nothing
                        , richPicked = []
                        , insertSeq = model.insertSeq + 1
                        , insert = Just { seq = model.insertSeq + 1, apiId = apiId, assetIds = model.richPicked }
                      }
                    , []
                    )

                Nothing ->
                    ( model, [] )

        RichUploadStarted apiId started ->
            ( model
            , [ Api.call
                    (\id ->
                        Queries.createUploadUrl id
                            ctx.project
                            { fileName = started.fileName, mime = started.mime, size = started.size }
                    )
                    (GotRichUploadUrl apiId started.token)
              ]
            )

        GotRichUploadUrl apiId token (Ok upload) ->
            ( { model
                | pendingUpload = Just upload
                , uploads = Dict.insert upload.assetId { token = token, apiId = apiId } model.uploads
              }
            , []
            )

        GotRichUploadUrl apiId token (Err _) ->
            ( giveUp apiId token model, [] )

        RichUploadFinished finished ->
            case Dict.get finished.assetId model.uploads of
                Just found ->
                    if finished.ok then
                        ( model, [ Api.call (\id -> Queries.confirmAsset id ctx.project finished.assetId) (GotRichConfirmed finished.assetId) ] )

                    else
                        ( giveUp found.apiId found.token { model | uploads = Dict.remove finished.assetId model.uploads }, [] )

                Nothing ->
                    ( model, [] )

        GotRichConfirmed assetId (Ok asset) ->
            case Dict.get assetId model.uploads of
                Just found ->
                    ( { model
                        | uploads = Dict.remove assetId model.uploads
                        , newAssets = asset :: model.newAssets
                        , resolved = model.resolved ++ [ { apiId = found.apiId, token = found.token, assetId = asset.id } ]
                      }
                    , []
                    )

                Nothing ->
                    ( model, [] )

        GotRichConfirmed assetId (Err _) ->
            case Dict.get assetId model.uploads of
                Just found ->
                    ( giveUp found.apiId found.token { model | uploads = Dict.remove assetId model.uploads }, [] )

                Nothing ->
                    ( model, [] )

        HistoryToggled open ->
            ( { model | historyOpen = open }, [] )

        ExpandToggled apiId ->
            ( { model | expanded = apiId }, [] )

        RestoreOpened version ->
            ( { model | asking = AskingRestore version, actionError = Nothing }, [] )

        RestoreWanted ->
            -- **戻す前に、今の下書きを版として積む。** 積まないと、戻した瞬間に
            -- 今書いていた物がどこにも残らない（戻すのを取り消せない）。
            case model.entryId of
                Just entryId ->
                    ( { model | publishing = True, actionError = Nothing }
                    , [ Api.call (\id -> Queries.saveVersion id ctx.project entryId) GotVersionSaved ]
                    )

                Nothing ->
                    ( model, [] )

        GotVersionSaved (Ok _) ->
            case ( model.entryId, model.asking ) of
                ( Just entryId, AskingRestore version ) ->
                    ( model
                    , [ Api.call
                            (\id ->
                                Queries.restoreVersion id
                                    ctx.project
                                    { entryId = entryId, versionId = version.id, expectedVersion = model.version }
                            )
                            GotRestored
                      ]
                    )

                _ ->
                    ( { model | publishing = False }, [] )

        GotVersionSaved (Err problem) ->
            ( { model | publishing = False, actionError = Just (Api.problemToText problem).message }, [] )

        GotRestored (Ok row) ->
            let
                next : Model
                next =
                    sync
                        { model
                            | row = Just row
                            , version = row.version
                            , stage = row.stage
                            , save = Saved
                            , touched = False
                            , publishing = False
                            , asking = NotAsking
                            , actionError = Nothing
                            , report = Nothing
                        }
            in
            ( next
            , refLabelCalls { project = ctx.project } next
                ++ assetCalls { project = ctx.project } next
                ++ (case model.entryId of
                        Just entryId ->
                            [ Api.call (\id -> Queries.versions id ctx.project entryId) GotHistory ]

                        Nothing ->
                            []
                   )
            )

        GotRestored (Err problem) ->
            ( { model | publishing = False, actionError = Just (Api.problemToText problem).message }, [] )

        SchedulesToggled open ->
            ( { model | schedulesOpen = open }, [] )

        PickerClosed ->
            ( { model | picking = Nothing, richPicking = Nothing, richPicked = [] }, [] )

        GotAssets (Ok page) ->
            let
                next : Model
                next =
                    { model | assets = Loaded.Present (mergeAssets model page) }
            in
            ( next, assetCalls { project = ctx.project } next )

        GotAssets (Err problem) ->
            ( { model | assets = Loaded.fromResult (Err problem) }, [] )

        AssetPicked assetId ->
            case model.richPicking of
                Just _ ->
                    ( { model | richPicked = togglePicked assetId model.richPicked }, [] )

                Nothing ->
                    pickForField assetId model

        GotRefs apiId asked (Ok page) ->
            -- **今 打ってある文字への答だけを採る。** 先に投げた検索が後から返る事があり、
            -- そのまま入れると絞った候補が広い方に戻る（実際に戻った）。
            if Dict.get apiId model.refQuery |> Maybe.withDefault "" |> (/=) asked then
                ( model, [] )

            else
                ( { model
                    | refs = Dict.insert apiId (labelsOf page) model.refs
                    , refTotals = Dict.insert apiId page.totalCount model.refTotals
                    , refLabels = Dict.union (Dict.fromList (labelsOf page)) model.refLabels
                  }
                , []
                )

        GotRefs apiId _ (Err _) ->
            ( { model | refs = Dict.insert apiId [] model.refs, refTotals = Dict.insert apiId 0 model.refTotals }, [] )

        GotRefLabels (Ok page) ->
            ( { model | refLabels = Dict.union (Dict.fromList (labelsOf page)) model.refLabels }, [] )

        GotRefLabels (Err _) ->
            ( model, [] )

        RefOpened apiId ->
            -- **開く度に引き直す。** 前に絞った結果が残っていると、閉じて開いただけで
            -- 候補が減ったまま出る。
            ( { model | refOpen = Just apiId }
            , refSearchCalls { project = ctx.project } model apiId (Dict.get apiId model.refQuery |> Maybe.withDefault "")
            )

        RefClosed ->
            ( { model | refOpen = Nothing }, [] )

        RefSearched apiId typed ->
            ( { model | refQuery = Dict.insert apiId typed model.refQuery, refOpen = Just apiId }
            , refSearchCalls { project = ctx.project } model apiId typed
            )

        RefPicked apiId entryId ->
            ( pickRef apiId entryId model, [] )

        RefDropped apiId entryId ->
            ( dropRef apiId entryId model, [] )

        DateOpened apiId ->
            ( { model | dateOpen = Just apiId, dates = Dict.insert apiId (dateModelOf model apiId) model.dates }, [] )

        DateClosed ->
            ( { model | dateOpen = Nothing }, [] )

        DateMsg apiId inner ->
            -- **暦を動かしただけでは値を書かない。** 書くと、まだ何も選んでいない
            -- 任意の DATE が月送りだけで埋まる。
            ( { model | dates = Dict.update apiId (Maybe.map (Ui.DateTime.update inner)) model.dates }, [] )

        DateApplied apiId ->
            case Dict.get apiId model.dates of
                Just picked ->
                    let
                        -- **日付だけの欄は UTC に直さない。** 直すと時差の分だけ日がずれる。
                        chosen : String
                        chosen =
                            if dateOnly model apiId then
                                Ui.DateTime.toIsoDate picked

                            else
                                Ui.DateTime.toIso model.zone picked
                    in
                    ( setField apiId (FieldValue.Date chosen) { model | dateOpen = Nothing }, [] )

                Nothing ->
                    ( model, [] )

        DateCleared apiId ->
            ( setField apiId (FieldValue.Date "") { model | dateOpen = Nothing }, [] )

        GotEntry (Ok (Just row)) ->
            let
                next : Model
                next =
                    sync { model | row = Just row, version = row.version, stage = row.stage, save = Saved }
            in
            -- **中身が来てから、指しているメディアを追う。** 型だけの時点では
            -- どの id が要るか分からない。
            ( next, refLabelCalls { project = ctx.project } next ++ assetCalls { project = ctx.project } next )

        GotEntry (Ok Nothing) ->
            -- **型の状態と混ぜない。** 型は後から返るので、混ぜると上書きされて空のフォームが出る。
            ( { model | entryMissing = True }, [] )

        GotEntry (Err problem) ->
            ( { model | save = SaveFailed (Api.problemToText problem).message }, [] )

        FieldTyped apiId typed ->
            ( setField apiId typed model, [] )

        SaveWanted ->
            save { project = ctx.project } model

        GotSaved (Ok row) ->
            let
                saved : Model
                saved =
                    { model | version = row.version, entryId = Just row.id, stage = row.stage, errors = [], conflict = Nothing, report = Nothing }

                queued : Bool
                queued =
                    case model.save of
                        Saving state ->
                            state.queued

                        _ ->
                            False
            in
            if queued then
                save { project = ctx.project } { saved | save = Dirty }

            else if saved.pendingPublish then
                -- 保存できたので、押された時の狙い（公開）へ進む。
                publish { project = ctx.project } CheckWanted { saved | save = Saved, pendingPublish = False, asking = AskingPublish }

            else
                ( { saved | save = Saved }, [] )

        GotSaved (Err (Api.Failed errors)) ->
            case List.filter (\err -> err.code == Api.Error.Conflict) errors of
                _ :: _ ->
                    ( { model | save = Conflicted }
                    , case model.entryId of
                        Just entryId ->
                            [ Api.call (\id -> Queries.entry id ctx.project entryId) GotTheirs ]

                        Nothing ->
                            []
                    )

                [] ->
                    ( { model | save = SaveFailed "", pendingPublish = False, errors = violationsOf errors }, [] )

        GotSaved (Err problem) ->
            ( { model | save = SaveFailed (Api.problemToText problem).message, pendingPublish = False }, [] )

        GotTheirs result ->
            ( { model | conflict = Result.withDefault Nothing result }, [] )

        Ignored ->
            ( model, [] )

        ApiPreviewWanted ->
            -- 開けるのは親（引き出しはページの外に重なる）。ここでは何もしない。
            ( model, [] )

        PublishOpened ->
            -- **未保存があれば先に保存してから確認を開く。**
            -- 公開されるのは保存済みの下書きなので、ここを飛ばすと
            -- 「押したのに古い内容が公開された」が起きる。
            if unsaved model || model.entryId == Nothing then
                save { project = ctx.project } { model | pendingPublish = True }

            else
                publish { project = ctx.project } CheckWanted { model | asking = AskingPublish }

        UnpublishOpened ->
            ( { model | asking = AskingUnpublish, actionError = Nothing }, [] )

        PublishClosed ->
            ( { model | asking = NotAsking, pendingPublish = False, report = Nothing, actionError = Nothing }, [] )

        CheckWanted ->
            publish { project = ctx.project } msg model

        PublishWanted ->
            publish { project = ctx.project } msg model

        UnpublishWanted ->
            publish { project = ctx.project } msg model

        GotReport result ->
            ( { model | publishing = False, report = Result.toMaybe result }, [] )

        GotPublished (Ok row) ->
            -- **履歴を引き直す。** 公開も取り下げも版が動くので、開いた時のままだと古い物が残る。
            ( { model | publishing = False, asking = NotAsking, actionError = Nothing, stage = row.stage, version = row.version, report = Nothing }
            , case model.entryId of
                Just entryId ->
                    [ Api.call (\id -> Queries.versions id ctx.project entryId) GotHistory ]

                Nothing ->
                    []
            )

        GotPublished (Err problem) ->
            -- **断られた理由は確認の中に出す。** 上の帯に出しても、確認が上に重なって
            -- 見えない（実際に、押しても何も起きないように見えた）。
            ( { model | publishing = False, actionError = Just (Api.problemToText problem).message }, [] )

        GotHistory result ->
            ( { model | history = Loaded.fromResult result }, [] )

        GotReferrers result ->
            ( { model | referrers = Loaded.fromResult (Result.map Just result) }, [] )

        ReferrersOpened ->
            ( { model | referrersOpen = True }, [] )

        ReferrersClosed ->
            ( { model | referrersOpen = False }, [] )

        LinkSearched query ->
            -- **型ごとに 1 本ずつ投げる**（CMS の一覧は型の中しか探せない）。⌘K と同じやり方。
            -- 一度に全部は引かない。足りなければ「もっと見る」で次を引く。
            ( { model | linkCandidates = [], linkTotal = 0, linkPage = 0, linkQuery = query }
            , linkFetch ctx query 0
            )

        LinkMoreAsked ->
            -- 面が出しているのは引いた分だけなので、続きは引き直して後ろに足す。
            ( { model | linkPage = model.linkPage + 1 }
            , linkFetch ctx model.linkQuery (model.linkPage + 1)
            )

        GotLinkCandidates mark (Ok page) ->
            ( { model
                | linkCandidates =
                    model.linkCandidates
                        ++ List.map (\row -> { id = row.id, title = EntryLabel.forRow row, typeName = mark.name, typeIcon = mark.icon, stage = row.stage, path = row.path }) page.nodes

                -- 件数は最初の 1 回で数える（2 回目からは同じ数が返り、足すと二重になる）。
                , linkTotal =
                    if model.linkPage == 0 then
                        model.linkTotal + page.totalCount

                    else
                        model.linkTotal
              }
            , []
            )

        GotLinkCandidates _ (Err _) ->
            ( model, [] )

        LinkResolveAsked ids ->
            -- **本文が指しているコンテンツを引き直す。** 面とツールチップで「今どこを
            -- 指しているか」を出すのに要る。id が消えていれば返らないので、そのまま
            -- 「見つかりません」になる。
            if List.isEmpty ids then
                ( { model | linkedEntries = [] }, [] )

            else
                ( { model | linkedEntries = [] }
                , ctx.types
                    |> List.map
                        (\summary ->
                            Api.call
                                (\id ->
                                    Queries.entries id
                                        ctx.project
                                        { typeId = summary.id, search = "", stage = "", conditions = [], ids = ids, order = "", first = List.length ids, skip = 0 }
                                )
                                (GotLinkedEntries (markOf summary))
                        )
                )

        GotLinkedEntries mark (Ok page) ->
            ( { model
                | linkedEntries =
                    model.linkedEntries
                        ++ List.map (\row -> { id = row.id, title = EntryLabel.forRow row, typeName = mark.name, typeIcon = mark.icon, stage = row.stage, path = row.path }) page.nodes
              }
            , []
            )

        GotLinkedEntries _ (Err _) ->
            ( model, [] )

        GotSchedules result ->
            ( { model | schedules = Result.withDefault [] result }, [] )

        ScheduleOpened ->
            -- 開けるのは親（今日が何日かは Effect.Today でしか分からない）。
            ( { model | schedulingOpen = not model.schedulingOpen }, [] )

        TodayKnown zone year month day ->
            ( { model
                | zone = zone
                , today = Just { year = year, month = month, day = day }
                , scheduler = Just (Ui.DateTime.init { year = year, month = month, day = day })
              }
            , []
            )

        SchedulerMsg inner ->
            ( { model | scheduler = Maybe.map (Ui.DateTime.update inner) model.scheduler }, [] )

        ScheduleSubmitted ->
            case ( model.entryId, model.scheduler ) of
                ( Just entryId, Just scheduler ) ->
                    ( { model | publishing = True }
                    , [ Api.call
                            (\id -> Queries.schedulePublish id ctx.project { entryId = entryId, at = Ui.DateTime.toIso model.zone scheduler })
                            GotScheduled
                      ]
                    )

                _ ->
                    ( model, [] )

        GotScheduled (Ok schedule) ->
            -- CMS は同じ entry の未実行の予約を 1 件に保つ（置き換える）ので、引き直す。
            ( { model | publishing = False, schedulingOpen = False, schedules = [ schedule ] }
            , scheduleCalls ctx.project model
            )

        GotScheduled (Err problem) ->
            ( { model | publishing = False, save = SaveFailed (Api.problemToText problem).message }, [] )

        ScheduleCancelled scheduleId ->
            ( model, [ Api.call (\id -> Queries.cancelSchedule id ctx.project scheduleId) GotScheduleCancelled ] )

        GotScheduleCancelled (Ok scheduleId) ->
            ( { model | schedules = List.filter (\schedule -> schedule.id /= scheduleId) model.schedules }
            , scheduleCalls ctx.project model
            )

        GotScheduleCancelled (Err _) ->
            ( model, [] )

        KeepMine ->
            case model.conflict of
                Just theirs ->
                    save { project = ctx.project } { model | version = theirs.version, conflict = Nothing, save = Dirty }

                Nothing ->
                    ( model, [] )

        TakeTheirs ->
            case model.conflict of
                Just theirs ->
                    ( sync { model | row = Just theirs, touched = False, version = theirs.version, conflict = Nothing, save = Saved }, [] )

                Nothing ->
                    ( model, [] )


{-| メディアのフィールドに選んだ物を入れる。
-}
pickForField : String -> Model -> ( Model, List (Api.Call Msg) )
pickForField assetId model =
    case model.picking of
        Just apiId ->
            ( { model
                | picking = Nothing
                , touched = True
                , save = markDirty model.save
                , values = Dict.insert apiId (pickedAsset model apiId assetId) model.values
              }
            , []
            )

        Nothing ->
            ( model, [] )


togglePicked : String -> List String -> List String
togglePicked assetId chosen =
    if List.member assetId chosen then
        List.filter (\id -> id /= assetId) chosen

    else
        chosen ++ [ assetId ]


{-| 上げられなかった事を本文に返す。**仮の見た目を残さない**（残ると保存もできないまま消えない）。
-}
giveUp : String -> String -> Model -> Model
giveUp apiId token model =
    { model | resolved = model.resolved ++ [ { apiId = apiId, token = token, assetId = "" } ] }


{-| 本文に貼られた画像を置く input の id。TypeScript がこの id で中身を取り、PUT する。
-}
richInputId : String
richInputId =
    "rich-paste-file"


{-| 置き先が来ていれば 1 回だけ渡す。親がこれを port に流す（メディアの画面と同じ形）。
-}
takeRichUpload : Model -> ( Model, Maybe Model.Upload )
takeRichUpload model =
    ( { model | pendingUpload = Nothing }, model.pendingUpload )


{-| 予約を引き直す。**足さない**（CMS が持っている物が正）。
-}
scheduleCalls : Slug -> Model -> List (Api.Call Msg)
scheduleCalls project model =
    case model.entryId of
        Just entryId ->
            [ Api.call (\id -> Queries.schedules id project (Just entryId)) GotSchedules ]

        Nothing ->
            []


{-| メディアを選んだ後の値。**複数のフィールドは足す**（差し替えない）。
-}
pickedAsset : Model -> String -> String -> Value
pickedAsset model apiId assetId =
    let
        many : Bool
        many =
            Loaded.toMaybe model.contentType
                |> Maybe.map .fields
                |> Maybe.withDefault []
                |> List.filter (\field -> field.apiId == apiId)
                |> List.head
                |> Maybe.map .many
                |> Maybe.withDefault False
    in
    if many then
        let
            chosen : List String
            chosen =
                Dict.get apiId model.values |> Maybe.map FieldValue.idsOf |> Maybe.withDefault []
        in
        FieldValue.Refs
            (if List.member assetId chosen then
                chosen

             else
                chosen ++ [ assetId ]
            )

    else
        FieldValue.Ref assetId


{-| 公開前の確認 → 公開 → 公開終了。**確認は書き込まない。**

確認の結果が出てから公開のボタンに変える（モックの「公開は 2 クリック」）。

-}
publish : { project : Slug } -> Msg -> Model -> ( Model, List (Api.Call Msg) )
publish ctx msg model =
    case ( msg, model.entryId ) of
        ( CheckWanted, Just entryId ) ->
            ( { model | publishing = True, report = Nothing }
            , [ Api.call (\id -> Queries.publishCheck id ctx.project entryId) GotReport ]
            )

        ( PublishWanted, Just entryId ) ->
            ( { model | publishing = True }
            , [ Api.call (\id -> Queries.publishEntry id ctx.project { entryId = entryId, withDependencies = True }) GotPublished ]
            )

        ( UnpublishWanted, Just entryId ) ->
            ( { model | publishing = True }
            , [ Api.call (\id -> Queries.unpublishEntry id ctx.project entryId) GotPublished ]
            )

        _ ->
            ( model, [] )


{-| API プレビューの引き出しに渡す物。**公開中でなければ下書きを見る**
（公開の query では下書きは返らない）。
-}
previewOf : Model -> Maybe { entryId : String, draft : Bool }
previewOf model =
    model.entryId |> Maybe.map (\entryId -> { entryId = entryId, draft = model.stage /= "PUBLISHED" })


{-| まだ書いていない入力があるか。

上の帯の出しわけと、画面を離れる時の警告（`Main` が port で外に出す）が同じ判断を使う。

-}
unsaved : Model -> Bool
unsaved model =
    model.save /= Saved


{-| 保存を 1 本だけ飛ばす。飛んでいる間は queued に印を付けるだけ。
-}
save : { project : Slug } -> Model -> ( Model, List (Api.Call Msg) )
save ctx model =
    case ( model.save, Loaded.toMaybe model.contentType ) of
        ( Saving state, _ ) ->
            ( { model | save = Saving { state | queued = True } }, [] )

        ( _, Just detail ) ->
            case model.entryId of
                Just entryId ->
                    ( { model | save = Saving { queued = False } }
                    , [ Api.call
                            (\id ->
                                Queries.updateEntry id
                                    ctx.project
                                    { entryId = entryId, fields = encodeValues model, expectedVersion = model.version }
                            )
                            GotSaved
                      ]
                    )

                Nothing ->
                    ( { model | save = Saving { queued = False } }
                    , [ Api.call
                            (\id -> Queries.createEntry id ctx.project { typeId = detail.id, fields = encodeValues model })
                            GotSaved
                      ]
                    )

        _ ->
            ( model, [] )


markDirty : SaveState -> SaveState
markDirty state =
    case state of
        Saving inner ->
            Saving { inner | queued = True }

        _ ->
            Dirty


{-| 画面の値を CMS に送る形にする。種類ごとの写しは `FieldValue` が持つ。
-}
encodeValues : Model -> E.Value
encodeValues model =
    model.values
        |> Dict.toList
        |> List.map (\( apiId, value ) -> ( apiId, FieldValue.encode value ))
        |> E.object


{-| 違反をフォームの項目に写す（`fields.title` → `title`）。
-}
violationsOf : List Api.Error.ApiError -> List ( String, String )
violationsOf errors =
    errors
        |> List.concatMap .violations
        |> List.filterMap
            (\violation ->
                case violation.path.segments of
                    (Api.Error.Key "fields") :: (Api.Error.Key apiId) :: _ ->
                        Just ( apiId, violation.message )

                    _ ->
                        Nothing
            )


{-| 1 回に引くメディアの数。
-}
assetPageSize : Int
assetPageSize =
    60


{-| これ以上は追わない。**入れた物が消されていると、いつまでも見つからない。**
-}
assetPageLimit : Int
assetPageLimit =
    600


{-| メディアの一覧を引く。**開いた時に引く**（ピッカーを開いた時だけだと、既に入っている
画像が id の文字のまま出る。実際に出た）。

WhyNot: 1 ページで打ち切らない。CMS の一覧は新しい順なので、古いメディアを入れてある
entry では、そのメディアが 1 ページ目に居らず、サムネイルの代わりに id が出る
（メディアが 265 件ある手元で実際に出た）。**入っている id が全部見つかるまで次のページを追う。**

-}
assetCalls : { project : Slug } -> Model -> List (Api.Call Msg)
assetCalls ctx model =
    let
        held : List Model.AssetRow
        held =
            Loaded.toMaybe model.assets |> Maybe.map .nodes |> Maybe.withDefault []

        total : Int
        total =
            Loaded.toMaybe model.assets |> Maybe.map .totalCount |> Maybe.withDefault 0

        missing : Bool
        missing =
            wantedAssetIds model |> List.any (\assetId -> not (List.any (\asset -> asset.id == assetId) held))
    in
    if not (usesAssets model) then
        []

    else if List.isEmpty held then
        [ Api.call (\id -> Queries.assets id ctx.project { first = assetPageSize, skip = 0 }) GotAssets ]

    else if missing && List.length held < min total assetPageLimit then
        [ Api.call (\id -> Queries.assets id ctx.project { first = assetPageSize, skip = List.length held }) GotAssets ]

    else
        []


{-| メディアの id を持つフィールドがあるか。本文の画像も asset の id を持ち、
URL はこの一覧からしか引けない。
-}
usesAssets : Model -> Bool
usesAssets model =
    fieldsOf model |> List.any (\field -> field.kind == "ASSET" || field.kind == "RICH_TEXT")


{-| この entry が指しているメディアの id。フィールドの値と、本文に埋まっている物の両方。
-}
wantedAssetIds : Model -> List String
wantedAssetIds model =
    fieldsOf model
        |> List.concatMap
            (\field ->
                case ( field.kind, Dict.get field.apiId model.values ) of
                    ( "ASSET", Just value ) ->
                        FieldValue.idsOf value

                    ( "RICH_TEXT", Just value ) ->
                        D.decodeString docAssetIds (FieldValue.toDocJson value) |> Result.withDefault []

                    _ ->
                        []
            )
        |> unique


{-| 本文の doc に埋まっているメディアの id（`attrs.assetId`）。
-}
docAssetIds : D.Decoder (List String)
docAssetIds =
    D.map2 (++)
        (D.oneOf [ D.at [ "attrs", "assetId" ] D.string |> D.map List.singleton, D.succeed [] ])
        (D.oneOf [ D.field "content" (D.list (D.lazy (\_ -> docAssetIds))) |> D.map List.concat, D.succeed [] ])


{-| 引いた頁を足す。**入れ替えない**（前の頁に居たメディアが消えると id に戻る）。
-}
mergeAssets : Model -> Model.AssetList -> Model.AssetList
mergeAssets model page =
    case Loaded.toMaybe model.assets of
        Just held ->
            { nodes =
                held.nodes
                    ++ List.filter (\asset -> not (List.any (\kept -> kept.id == asset.id) held.nodes)) page.nodes
            , totalCount = page.totalCount
            }

        Nothing ->
            page


{-| 候補として 1 度に見せる数。**多い型でも、打って絞る方で辿り着く。**
-}
refPageSize : Int
refPageSize =
    20


{-| 参照の候補を引く。**id を手で打たせない。**

WhyNot: 開く前に先読みしない。前は開いた時点で 100 件を取って手元で絞っていて、
101 件目以降は画面から選ぶ手段が無かった。**打つ度に CMS へ投げ直す。**

-}
refSearchCalls : { project : Slug } -> Model -> String -> String -> List (Api.Call Msg)
refSearchCalls ctx model apiId search =
    case targetTypeOf model apiId of
        Just typeId ->
            [ refCall ctx typeId search (GotRefs apiId search) ]

        Nothing ->
            []


refCall : { project : Slug } -> String -> String -> (Result Api.Problem Model.EntryList -> Msg) -> Api.Call Msg
refCall ctx typeId search toMsg =
    Api.call
        (\id ->
            Queries.entries id
                ctx.project
                { typeId = typeId, search = search, stage = "", conditions = [], ids = [], order = "", first = refPageSize, skip = 0 }
        )
        toMsg


{-| 今 入っている参照の見出しを引く。**選んである物は検索の結果に居なくても出す**ので、
id で名指しして引く。
-}
refLabelCalls : { project : Slug } -> Model -> List (Api.Call Msg)
refLabelCalls ctx model =
    case ( Loaded.toMaybe model.contentType, model.row ) of
        ( Just _, Just _ ) ->
            let
                wanted : List ( String, String )
                wanted =
                    referenceFields model
                        |> List.concatMap
                            (\( apiId, typeId ) ->
                                chosenOf model apiId |> List.map (\entryId -> ( typeId, entryId ))
                            )
            in
            wanted
                |> List.map Tuple.first
                |> unique
                |> List.concatMap
                    (\typeId ->
                        wanted
                            |> List.filter (\( t, _ ) -> t == typeId)
                            |> List.map Tuple.second
                            |> Queries.chunkIds
                            |> List.map (refLabelCall ctx typeId)
                    )

        _ ->
            []


{-| 名指しした id の分だけ引く。**頼んだ数をそのまま first にする**ので、
引けなかった物は出ない。
-}
refLabelCall : { project : Slug } -> String -> List String -> Api.Call Msg
refLabelCall ctx typeId ids =
    Api.call
        (\id ->
            Queries.entries id
                ctx.project
                { typeId = typeId
                , search = ""
                , stage = ""
                , conditions = []
                , ids = ids
                , order = ""
                , first = List.length ids
                , skip = 0
                }
        )
        GotRefLabels


{-| 参照のフィールドの `( apiId, 参照先の型 id )`。
-}
referenceFields : Model -> List ( String, String )
referenceFields model =
    fieldsOf model
        |> List.filter (\field -> field.kind == "REFERENCE")
        |> List.filterMap (\field -> Maybe.map (\typeId -> ( field.apiId, typeId )) field.targetTypeId)


fieldsOf : Model -> List FieldDef
fieldsOf model =
    Loaded.toMaybe model.contentType |> Maybe.map .fields |> Maybe.withDefault []


fieldDefOf : Model -> String -> Maybe FieldDef
fieldDefOf model apiId =
    fieldsOf model |> List.filter (\field -> field.apiId == apiId) |> List.head


targetTypeOf : Model -> String -> Maybe String
targetTypeOf model apiId =
    fieldDefOf model apiId |> Maybe.andThen .targetTypeId


chosenOf : Model -> String -> List String
chosenOf model apiId =
    Dict.get apiId model.values |> Maybe.map FieldValue.idsOf |> Maybe.withDefault []


labelsOf : Model.EntryList -> List ( String, String )
labelsOf page =
    List.map (\row -> ( row.id, EntryLabel.forRow row )) page.nodes


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


{-| 候補を 1 つ選ぶ。複数なら足す（もう入っていれば外す）、1 件なら差し替える。
-}
pickRef : String -> String -> Model -> Model
pickRef apiId entryId model =
    let
        chosen : List String
        chosen =
            chosenOf model apiId

        remembered : Model
        remembered =
            { model
                | refLabels =
                    case Dict.get apiId model.refs |> Maybe.withDefault [] |> List.filter (\( id, _ ) -> id == entryId) |> List.head of
                        Just ( _, label ) ->
                            Dict.insert entryId label model.refLabels

                        Nothing ->
                            model.refLabels
            }
    in
    if manyOf model apiId then
        if List.member entryId chosen then
            setField apiId (FieldValue.Refs (List.filter (\id -> id /= entryId) chosen)) remembered

        else
            setField apiId (FieldValue.Refs (chosen ++ [ entryId ])) remembered

    else
        setField apiId
            (FieldValue.Ref entryId)
            { remembered | refOpen = Nothing, refQuery = Dict.insert apiId "" model.refQuery }


{-| 選んである物を外す。
-}
dropRef : String -> String -> Model -> Model
dropRef apiId entryId model =
    if manyOf model apiId then
        setField apiId (FieldValue.Refs (List.filter (\id -> id /= entryId) (chosenOf model apiId))) model

    else
        setField apiId (FieldValue.Ref "") model


manyOf : Model -> String -> Bool
manyOf model apiId =
    fieldDefOf model apiId |> Maybe.map .many |> Maybe.withDefault False


{-| 暦が開く時の日時。今の値があればそこから、無ければ「これから」の既定から。

WhyNot: 読めない値でも暦を出す事をやめない。ミリ秒付き・オフセット付きのような
canonical でない値が既に入っていても、選び直せなくなるより出た方が直せる。

-}
dateModelOf : Model -> String -> Ui.DateTime.Model
dateModelOf model apiId =
    let
        started : Ui.DateTime.Model
        started =
            Ui.DateTime.init (Maybe.withDefault { year = 2000, month = 1, day = 1 } model.today)

        local : String
        local =
            if dateOnly model apiId then
                -- 日付だけの値は時刻を持たない。**タイムゾーンを当てない**（日がずれる）。
                valueTextOf model apiId

            else
                Ui.DateTime.formatLocal model.zone (valueTextOf model apiId)
    in
    case ( sliceInt 0 4 local, sliceInt 5 7 local, sliceInt 8 10 local ) of
        ( Just year, Just month, Just day ) ->
            { year = year
            , month = month
            , day = day
            , hour = sliceInt 11 13 local |> Maybe.withDefault 9
            , minute = sliceInt 14 16 local |> Maybe.withDefault 0
            , shownYear = year
            , shownMonth = month
            , today = started.today
            , picked = True
            }

        _ ->
            started


dateOnly : Model -> String -> Bool
dateOnly model apiId =
    fieldDefOf model apiId |> Maybe.map (\field -> field.kind == "DATE_ONLY") |> Maybe.withDefault False


valueTextOf : Model -> String -> String
valueTextOf model apiId =
    Dict.get apiId model.values |> Maybe.map FieldValue.toText |> Maybe.withDefault ""


sliceInt : Int -> Int -> String -> Maybe Int
sliceInt from to text =
    String.toInt (String.slice from to text)


{-| 1 つのフィールドの値を書く。**書いたら未保存にする**（保存は人が押す）。
-}
setField : String -> Value -> Model -> Model
setField apiId typed model =
    { model
        | touched = True
        , values = Dict.insert apiId typed model.values
        , save = markDirty model.save
        , errors = List.filter (\( key, _ ) -> key /= apiId) model.errors
    }


{-| 型と中身が揃ったら、画面の値を組み直す。

**どちらが先に返るか決まらない**ので、両方が来た時にまとめて畳む。
型が来る前に中身を畳むと、種類が分からず全部が空になる（実際に起きた）。
人が触った後は上書きしない。

-}
sync : Model -> Model
sync model =
    case ( Loaded.toMaybe model.contentType, model.touched ) of
        ( Just detail, False ) ->
            { model
                | values =
                    detail.fields
                        |> List.map
                            (\field ->
                                ( field.apiId
                                , model.row
                                    |> Maybe.andThen (fieldOf field)
                                    |> Maybe.withDefault (FieldValue.blank field)
                                )
                            )
                        |> Dict.fromList
            }

        _ ->
            model


fieldOf : FieldDef -> EntryRow -> Maybe Value
fieldOf field row =
    D.decodeValue (D.dict D.value) row.fields
        |> Result.withDefault Dict.empty
        |> Dict.get field.apiId
        |> Maybe.map (FieldValue.decode field)


{-| 今のコンテンツの見出し。パンくずに出す。最初のテキストのフィールドを使う。
-}
title : Model -> String
title model =
    Loaded.toMaybe model.contentType
        |> Maybe.map .fields
        |> Maybe.withDefault []
        |> List.filter (\field -> field.kind == "TEXT")
        |> List.head
        |> Maybe.andThen (\field -> Dict.get field.apiId model.values)
        |> Maybe.map FieldValue.toText
        |> Maybe.andThen
            (\value ->
                if String.isEmpty value then
                    Nothing

                else
                    Just value
            )
        |> Maybe.withDefault "（無題）"


view : { types : List Model.ContentTypeSummary } -> Model -> Html Msg
view args model =
    if model.entryMissing then
        Ui.messageCard "このコンテンツはありません"
            [ Ui.note [ text "消されたか、URL が違います。一覧から選び直してください。" ] ]

    else
        Loaded.view
            { loading = Ui.loadingCard
            , missing = Ui.messageCard "このコンテンツはありません" [ Ui.note [ text "消されたか、URL が違います。" ] ]
            , failed = \message -> Ui.messageCard "読み込めませんでした" [ span [ class "text-xs text-[color:var(--color-bad)]" ] [ text message ] ]
            , present = viewForm args model
            }
            model.contentType


viewForm : { types : List Model.ContentTypeSummary } -> Model -> ContentTypeDetail -> Html Msg
viewForm args model detail =
    div [ class "flex flex-col" ]
        [ viewActionBar model detail
        , div [ class "flex gap-8 py-6" ]
            [ div [ class "flex min-w-0 flex-1 flex-col gap-5" ]
                [ case model.conflict of
                    Just theirs ->
                        viewConflict theirs

                    Nothing ->
                        text ""
                , div [ class "flex flex-col gap-5" ] (List.map (viewField args model) detail.fields)
                ]
            , viewRail args model
            , viewPicker model

            -- 本文に貼られた画像の置き場。**中身は Elm に持ち込まない**
            -- （エディタが `DataTransfer` でここに移し、PUT は TypeScript がやる）。
            , Html.input
                [ Html.Attributes.type_ "file"
                , Html.Attributes.id richInputId
                , Html.Attributes.accept "image/*"
                , class "hidden"
                ]
                []
            ]
        , viewReferrerDrawer args model
        , viewHistoryDrawer model
        , viewScheduleDrawer model
        , case model.asking of
            AskingPublish ->
                viewPublishDialog model

            AskingUnpublish ->
                viewUnpublishDialog model

            AskingRestore version ->
                viewRestoreDialog model version

            NotAsking ->
                text ""
        ]


{-| 上の帯。**保存と公開だけを置く。**

Strapi / Payload / WordPress と同じ形にした。左に今の状態（下書き・公開中）と保存の様子、
右に「下書き保存」と「公開する」を並べる。画面を送っても付いてくるので、
長いフォームでも保存が画面の外に出ない。

WhyNot: トグル 1 つで公開を切り替えない。CMS の公開は公開前の確認
（必須の未入力、未公開の参照先）を挟むので、押した瞬間に状態が変わる形だと
確認を出す場所が無くなる。

-}
viewActionBar : Model -> ContentTypeDetail -> Html Msg
viewActionBar model detail =
    div [ class "sticky top-0 z-(--z-sticky) -mx-6 flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-edge bg-panel px-6 py-3" ]
        -- **題は 1 行に切る。** 幅を止めないと、長い題が折り返して帯が縦に伸びる
        -- （画面を送ると付いてくる帯なので、本文の見える高さがそのぶん減る）。
        [ div [ class "flex min-w-0 max-w-[36ch] flex-col" ]
            [ span [ class "truncate text-[15px] font-semibold text-ink", Html.Attributes.title (title model) ] [ text (title model) ]
            , span [ class "truncate font-mono text-[11px] text-ink-faint" ] [ text ("/" ++ detail.apiId) ]
            ]
        , stageChip model.stage
        , span [ class "text-xs text-ink-soft" ] [ text (saveText model.save) ]
        , div [ class "ml-auto flex items-center gap-2" ]
            [ case model.entryId of
                Just _ ->
                    -- **API を見る所は、今見ている物のすぐ横**（Sanity の Inspect と同じ）。
                    Ui.ghostButton [ onClick ApiPreviewWanted ] [ text "API" ]

                Nothing ->
                    text ""
            , Ui.ghostButton
                [ onClick SaveWanted
                , Html.Attributes.disabled (not (unsaved model))
                , Html.Attributes.title "Command + S"
                ]
                [ text "下書き保存" ]
            , Ui.button
                [ onClick PublishOpened
                , Html.Attributes.disabled (nothingToPublish model || model.publishing)
                ]
                [ text (publishText model (publishLabel model)) ]
            ]
        ]


{-| 公開する物が無い状態。公開中で、下書きに変更が無い（押しても何も変わらない）。
-}
nothingToPublish : Model -> Bool
nothingToPublish model =
    model.stage == "PUBLISHED" && not (unsaved model)


{-| 公開前の確認。**確認は書き込まない。**

未保存は `PublishOpened` が先に片付けているので、ここに来た時点で公開される内容は
今フォームに出ている物と同じ。

-}
viewPublishDialog : Model -> Html Msg
viewPublishDialog model =
    Ui.overlay PublishClosed
        [ class "items-center" ]
        [ Ui.card
            [ class "flex w-[440px] flex-col gap-3 p-5", keepOpen ]
            [ Ui.subheading (publishLabel model)
            , span [ class "truncate text-[13px] font-medium text-ink", Html.Attributes.title (title model) ] [ text (title model) ]
            , case model.report of
                Just report ->
                    viewReport model report

                Nothing ->
                    Ui.note [ text "公開前の確認をしています…" ]
            , case model.report of
                Just report ->
                    if report.ok then
                        Ui.note
                            [ text
                                (if model.stage == "DRAFT" then
                                    "公開すると、公開サイトから見えるようになります。"

                                 else
                                    -- **もう公開されている物に「見えるようになります」と言わない。**
                                    -- 変わるのは公開サイトに出る内容の方。
                                    "公開サイトに出ている内容が、今の下書きの内容に入れ替わります。"
                                )
                            ]

                    else
                        Ui.note [ text "直してから、もう一度確認してください。" ]

                Nothing ->
                    text ""
            , viewActionError model
            , div [ class "flex gap-2" ]
                [ viewPublishConfirm model
                , Ui.ghostButton [ onClick PublishClosed ] [ text "やめる" ]
                ]
            ]
        ]


{-| 断られた理由。**確認の中に出す**（上の帯に出しても確認の下に隠れる）。
-}
viewActionError : Model -> Html Msg
viewActionError model =
    case model.actionError of
        Just message ->
            Ui.callout Ui.toneBad [ class "gap-1 p-3 text-xs" ] [ text message ]

        Nothing ->
            text ""


{-| 覆いの中。**押しても閉じない**（覆いそのものを押した時だけ閉じる）。
-}
keepOpen : Html.Attribute Msg
keepOpen =
    Html.Events.stopPropagationOn "click" (D.succeed ( Ignored, True ))


{-| 戻すの確認。

**今の下書きも版に残る事を書く。** 書かないと「戻すと今書いている物が消える」と読めて、
押せない（実際に、公開を終える確認と同じ重さに見えた）。

-}
viewRestoreDialog : Model -> Model.EntryVersion -> Html Msg
viewRestoreDialog model version =
    Ui.overlay PublishClosed
        [ class "items-center" ]
        [ Ui.card
            [ class "flex w-[440px] flex-col gap-3 p-5", keepOpen ]
            [ Ui.subheading ("v" ++ String.fromInt version.version ++ " の内容に戻しますか")
            , span [ class "text-[13px] text-ink-soft" ]
                [ text (byText version ++ "（" ++ Ui.DateTime.formatLocal model.zone version.createdAt ++ "）") ]
            , Ui.note [ text "今の下書きもバージョンとして残るので、戻した後でここから元に戻せます。公開中の内容は変わりません。" ]
            , viewActionError model
            , div [ class "flex gap-2" ]
                [ Ui.button [ onClick RestoreWanted, Html.Attributes.disabled model.publishing ]
                    [ text (publishText model "戻す") ]
                , Ui.ghostButton [ onClick PublishClosed ] [ text "やめる" ]
                ]
            ]
        ]


{-| 取り下げの確認。**何が起きるかを言葉で出してから実行する**（ボードと同じ文言）。
-}
viewUnpublishDialog : Model -> Html Msg
viewUnpublishDialog model =
    Ui.overlay PublishClosed
        [ class "items-center" ]
        [ Ui.card
            [ class "flex w-[440px] flex-col gap-3 p-5", keepOpen ]
            [ Ui.subheading "このコンテンツの公開を終えますか"
            , span [ class "truncate text-[13px] font-medium text-ink", Html.Attributes.title (title model) ] [ text (title model) ]
            , Ui.note [ text "公開サイトから見えなくなります。下書きは残るので、また公開できます。" ]
            , viewActionError model
            , div [ class "flex gap-2" ]
                [ Ui.button [ onClick UnpublishWanted, Html.Attributes.disabled model.publishing ]
                    [ text (publishText model "公開を終える") ]
                , Ui.ghostButton [ onClick PublishClosed ] [ text "やめる" ]
                ]
            ]
        ]


viewPublishConfirm : Model -> Html Msg
viewPublishConfirm model =
    case model.report of
        Just report ->
            if report.ok then
                Ui.button [ onClick PublishWanted ] [ text (publishText model (publishLabel model)) ]

            else
                Ui.ghostButton [ onClick CheckWanted ] [ text "もう一度確認" ]

        Nothing ->
            Ui.button [ Html.Attributes.disabled True ] [ text (publishLabel model) ]


{-| 右のレール。公開に関わる操作をここに集める（モックの 6.1）。
-}
viewRail : { types : List Model.ContentTypeSummary } -> Model -> Html Msg
viewRail args model =
    div [ class "flex w-64 shrink-0 flex-col gap-4 border-l border-edge pl-5" ]
        [ span [ class "text-[11px] font-semibold tracking-wide text-ink-soft" ] [ text "公開" ]
        , stageChip model.stage
        , case model.entryId of
            Nothing ->
                Ui.note [ text "保存すると公開できます。" ]

            Just _ ->
                div [ class "flex flex-col gap-3" ]
                    [ if nothingToPublish model then
                        Ui.note [ text "公開中の内容と同じです。書き換えると公開できます。" ]

                      else
                        Ui.note [ text "公開は上の帯の「公開する」から。" ]
                    , if model.stage == "DRAFT" then
                        text ""

                      else
                        Ui.dangerLink UnpublishOpened "公開を終える"
                    ]
        , viewReferrers args model
        , viewSchedules model
        , viewHistory model
        ]


{-| このコンテンツを参照している物。

**公開中の参照があると、公開を終える事も削除する事もできない**（CMS が断る）。
出さないと、押して初めて理由を知る事になる。持っているのは Contentful / Sanity /
microCMS の 3 社だけで、この CMS は 3 社と同じ「止める」振る舞いなのに理由が
見えていなかった。

**下書きと公開を分ける。** 取り下げを止めるのは公開側の参照だけ、削除は両方が理由なので、
畳むと「なぜ止まったか」が説明できない。

-}
viewReferrers : { types : List Model.ContentTypeSummary } -> Model -> Html Msg
viewReferrers args model =
    case ( model.entryId, Loaded.toMaybe model.referrers ) of
        ( Just _, Just found ) ->
            if List.isEmpty found then
                text ""

            else
                let
                    rest : Int
                    rest =
                        List.length found - List.length (List.concatMap (railRows found) referrerStages)
                in
                Ui.railSection ("参照されています（" ++ String.fromInt (List.length found) ++ "）")
                    []
                    (List.map (viewReferrerGroup args model (Just railLimit) found) referrerStages
                        ++ [ if rest > 0 then
                                Ui.actionLink [ class "self-start", onClick ReferrersOpened ]
                                    [ text ("他 " ++ String.fromInt rest ++ " 件") ]

                             else
                                text ""
                           , if List.any (\referrer -> referrer.stage == "PUBLISHED") found then
                                Ui.note [ text "公開中の参照があるうちは、公開を終える事も削除する事もできません。" ]

                             else
                                text ""
                           ]
                    )

        _ ->
            text ""


{-| レールに出す件数。**残りは引き出しで全部見せる**ので、ここは目安が付く数で足りる。
-}
railLimit : Int
railLimit =
    3


referrerStages : List ( String, String )
referrerStages =
    [ ( "PUBLISHED", "公開中の参照" ), ( "DRAFT", "下書きの参照" ) ]


railRows : List Model.Referrer -> ( String, String ) -> List Model.Referrer
railRows found ( stage, _ ) =
    found |> List.filter (\referrer -> referrer.stage == stage) |> List.take railLimit


{-| 参照元の全部。レールは高さが決まっているので、多い時はここで見せる。
-}
viewReferrerDrawer : { types : List Model.ContentTypeSummary } -> Model -> Html Msg
viewReferrerDrawer args model =
    case ( model.referrersOpen, Loaded.toMaybe model.referrers ) of
        ( True, Just found ) ->
            Ui.drawer
                { title = "参照されています"
                , meta = [ span [ class "text-[11px] text-ink-faint" ] [ text (String.fromInt (List.length found) ++ " 件") ] ]
                , onClose = ReferrersClosed
                , onIgnore = Ignored
                }
                (List.map (viewReferrerGroup args model Nothing found) referrerStages)

        _ ->
            text ""


{-| 公開中と下書きで分けた一覧。`limit` を渡すとそこで切る（レール）。
-}
viewReferrerGroup : { types : List Model.ContentTypeSummary } -> Model -> Maybe Int -> List Model.Referrer -> ( String, String ) -> Html Msg
viewReferrerGroup args model limit found ( stage, heading ) =
    let
        all : List Model.Referrer
        all =
            found |> List.filter (\referrer -> referrer.stage == stage)

        rows : List Model.Referrer
        rows =
            case limit of
                Just count ->
                    List.take count all

                Nothing ->
                    all
    in
    if List.isEmpty all then
        text ""

    else
        div [ class "flex flex-col gap-1" ]
            (span [ class "text-[11px] text-ink-faint" ]
                [ text (heading ++ "（" ++ String.fromInt (List.length all) ++ "）") ]
                :: List.map (viewReferrer args model (limit == Nothing)) rows
            )


{-| 参照元 1 件。**どのフィールド経由か**まで出す（本文中のリンクの事もある）。

WhyNot: レールでは `via` を並べない。見出しの幅が削られ、長い見出しが余計に切れる。
代わりにマウスを乗せた時に出す。

-}
viewReferrer : { types : List Model.ContentTypeSummary } -> Model -> Bool -> Model.Referrer -> Html Msg
viewReferrer args model wide referrer =
    div [ class "flex min-w-0 items-baseline gap-2" ]
        [ Ui.link
            [ Html.Attributes.href (Route.toString (Route.Entry model.project (apiIdOfType args model referrer.typeId) referrer.entryId))
            , Html.Attributes.title (referrer.title ++ "（" ++ referrer.via ++ "）")
            , class
                (if wide then
                    "min-w-0 flex-1 text-xs"

                 else
                    "min-w-0 flex-1 truncate text-xs"
                )
            ]
            [ text referrer.title ]
        , if wide then
            span [ class "shrink-0 font-mono text-[10px] text-ink-faint" ] [ text referrer.via ]

          else
            text ""
        ]


{-| 参照元の型の apiId。URL を組むのに要る。分からなければ今の型で開く
（型が違えば「ありません」が出るので、黙って壊れない）。
-}
apiIdOfType : { types : List Model.ContentTypeSummary } -> Model -> String -> String
apiIdOfType args model typeId =
    args.types
        |> List.filter (\summary -> summary.id == typeId)
        |> List.head
        |> Maybe.map .apiId
        |> Maybe.withDefault model.apiId


{-| 予約。時刻を過ぎても実行されていない物は「遅延」と出す。

公開の予約は entry ごとに 1 件で、入れ直すと前の物が置き換わる。**その事を押す前に出す。**

-}
viewSchedules : Model -> Html Msg
viewSchedules model =
    case model.entryId of
        Nothing ->
            text ""

        Just _ ->
            div [ class "flex flex-col gap-2 border-t border-edge pt-4" ]
                [ div [ class "flex items-center" ]
                    [ span [ class "text-[11px] font-semibold tracking-wide text-ink-soft" ] [ text "予約" ]
                    , Ui.actionLink [ class "ml-auto", onClick ScheduleOpened ] [ text (scheduleOpenLabel model) ]
                    ]
                , case ( model.schedulingOpen, model.scheduler ) of
                    ( True, Just scheduler ) ->
                        div [ class "flex flex-col gap-2" ]
                            [ Html.map SchedulerMsg (Ui.DateTime.view model.zone scheduler)
                            , if hasPendingSchedule model then
                                span [ class "text-[11px] text-ink-soft" ] [ text "今の予約は取り消され、この時刻に置き換わります。" ]

                              else
                                text ""
                            , Ui.button
                                [ class "cursor-pointer justify-center", onClick ScheduleSubmitted ]
                                [ text (publishText model (scheduleSubmitLabel model)) ]
                            ]

                    _ ->
                        text ""
                , div [ class "flex flex-col gap-1" ]
                    (model.schedules |> List.filter liveSchedule |> List.map (viewSchedule model.zone))

                -- **終わった予約も何件あるかは出す。** 出さないと、レールが
                -- 実行待ちの 1 件しか見せていない事に気付けない（実際に気付けなかった）。
                , case List.length (List.filter (liveSchedule >> not) model.schedules) of
                    0 ->
                        text ""

                    rest ->
                        Ui.actionLink [ class "self-start", onClick (SchedulesToggled True) ]
                            [ text ("終わった予約 " ++ String.fromInt rest ++ " 件") ]
                ]


{-| 予約の全部（実行済み・失敗・取り消しも）。レールは実行待ちだけを出す。
-}
viewScheduleDrawer : Model -> Html Msg
viewScheduleDrawer model =
    if model.schedulesOpen then
        Ui.drawer
            { title = "予約"
            , meta = [ span [ class "text-[11px] text-ink-faint" ] [ text (String.fromInt (List.length model.schedules) ++ " 件") ] ]
            , onClose = SchedulesToggled False
            , onIgnore = Ignored
            }
            [ div [ class "flex flex-col gap-1" ] (List.map (viewSchedule model.zone) model.schedules) ]

    else
        text ""


{-| これから起きる物として出す予約。

WhyNot: 取り消した物と終わった物を並べない。CMS は入れ直す度に前の予約を取り消して
残すので、並べると「予約が増えた」ように見える（実際にそう見えた）。失敗だけは
気付けないと困るので残す。

-}
liveSchedule : Model.ScheduleRow -> Bool
liveSchedule schedule =
    schedule.status == "PENDING" || schedule.status == "FAILED"


{-| 未実行の公開の予約があるか。
-}
hasPendingSchedule : Model -> Bool
hasPendingSchedule model =
    List.any (\schedule -> schedule.status == "PENDING") model.schedules


scheduleOpenLabel : Model -> String
scheduleOpenLabel model =
    if model.schedulingOpen then
        "閉じる"

    else if hasPendingSchedule model then
        "予約を変える"

    else
        "予約する"


scheduleSubmitLabel : Model -> String
scheduleSubmitLabel model =
    if hasPendingSchedule model then
        "この時刻に変える"

    else
        "この時刻に公開"


viewSchedule : Time.Zone -> Model.ScheduleRow -> Html Msg
viewSchedule zone schedule =
    div [ class "flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-ink-soft" ]
        [ span [ class "font-mono text-[11px]" ] [ text (Ui.DateTime.formatLocal zone schedule.runAt) ]
        , if schedule.overdue then
            Ui.chip Ui.toneBad "遅延"

          else
            text (scheduleStatusText schedule.status)
        , if schedule.status == "PENDING" then
            Html.button
                [ class "ml-auto cursor-pointer text-[color:var(--color-bad)]", onClick (ScheduleCancelled schedule.id) ]
                [ text "取り消す" ]

          else
            text ""
        ]


scheduleStatusText : String -> String
scheduleStatusText status =
    case status of
        "PENDING" ->
            "実行待ち"

        "DONE" ->
            "完了"

        "FAILED" ->
            "失敗"

        "CANCELLED" ->
            "取り消し"

        other ->
            other


{-| バージョン履歴。積まれるのは「下書きを保存した時」と「公開した時」の 2 つで、
1 つの一覧に混ざる。**行ごとにどちらかが分かる**ようにする。

WhyNot: 見出しを「変更履歴」にしない。1 行 1 行は差分ではなく、その時点の中身
（後で戻せる物）なので、Notion / Confluence 日本語版と同じ「バージョン履歴」にする。

-}
viewHistory : Model -> Html Msg
viewHistory model =
    case Loaded.toMaybe model.history of
        Just (first :: rest) ->
            let
                all : List Model.EntryVersion
                all =
                    first :: rest
            in
            div [ class "flex flex-col gap-2 border-t border-edge pt-4" ]
                [ span [ class "text-[11px] font-semibold tracking-wide text-ink-soft" ]
                    [ text ("バージョン履歴（" ++ String.fromInt (List.length all) ++ "）") ]
                , div [ class "flex flex-col gap-1.5" ] (List.map (viewVersion model) (List.take historyLimit all))

                -- **切った事を出す。** 出さないと、8 版しか無いように見える。
                , if List.length all > historyLimit then
                    Ui.actionLink [ class "self-start", onClick (HistoryToggled True) ]
                        [ text ("他 " ++ String.fromInt (List.length all - historyLimit) ++ " 件") ]

                  else
                    text ""
                ]

        _ ->
            text ""


{-| レールに出す版の数。**残りは引き出しで全部見せる**ので、ここは目安が付く数で足りる。
-}
historyLimit : Int
historyLimit =
    8


{-| 版の全部。レールは高さが決まっているので、多い時はここで見せる。
-}
viewHistoryDrawer : Model -> Html Msg
viewHistoryDrawer model =
    case ( model.historyOpen, Loaded.toMaybe model.history ) of
        ( True, Just all ) ->
            Ui.drawer
                { title = "バージョン履歴"
                , meta = [ span [ class "text-[11px] text-ink-faint" ] [ text (String.fromInt (List.length all) ++ " 件") ] ]
                , onClose = HistoryToggled False
                , onIgnore = Ignored
                }
                [ div [ class "flex flex-col gap-1.5" ] (List.map (viewVersion model) all) ]

        _ ->
            text ""


{-| 履歴の 1 行。**「いつ・誰が・何をした」を 1 行に収める。**

**「戻す」はその行に置く。** 版を選んでから別の場所の「戻す」を押す形にすると、
どの版に戻るのかが押す瞬間に見えない。Contentful / Sanity / WordPress も行に置いている。

WhyNot: 今の下書きの行（`v` が最大の物）にも「戻す」を出す。**出しても害が無く、
隠すと「なぜこの行だけ無いのか」を説明する物が要る。**戻せば同じ中身が入るだけ。

-}
viewVersion : Model -> Model.EntryVersion -> Html Msg
viewVersion model version =
    div [ class "flex items-center gap-2 text-xs text-ink-soft" ]
        [ span [ class "font-semibold text-ink" ] [ text ("v" ++ String.fromInt version.version) ]
        , span [ class "min-w-0 truncate" ] [ text (byText version) ]
        , span [ class "ml-auto shrink-0 font-mono text-[10px] text-ink-faint" ]
            [ text (Ui.DateTime.formatLocal model.zone version.createdAt) ]
        , Ui.actionLink [ class "shrink-0", onClick (RestoreOpened version) ] [ text "戻す" ]
        ]


{-| 「誰が何をしたか」。

WhyNot: 名前が空の時に「不明」と書かない。API キーや取り込みで積まれた版は
人が押した物ではないので、「不明」だと調べれば分かるように読める。

-}
byText : Model.EntryVersion -> String
byText version =
    if String.isEmpty (String.trim version.author) then
        reasonText version.reason

    else
        version.author ++ " が" ++ reasonText version.reason


{-| その行がどの操作で積まれたか。

WhyNot: 「保存した版」と書かない。「版」は行の頭の `v3` が既に表しているので、
残りは何をした時点かだけで足りる（後で「誰が」と「戻す」がこの行に並ぶ）。

-}
reasonText : String -> String
reasonText reason =
    if reason == "PUBLISH" then
        "公開した"

    else
        "下書きを保存した"


publishLabel : Model -> String
publishLabel model =
    if nothingToPublish model then
        -- 押せない時の文字。「変更を公開する」のままだと、公開する変更があるように見える。
        "公開中"

    else if model.stage == "DRAFT" then
        "公開する"

    else
        "変更を公開する"


{-| 確認の結果。違反はフォームの項目にも赤で出る。

**どの項目かを頭に付ける。** CMS の文言は「公開には値が要ります」だけなので、
そのまま並べると同じ行が 2 つ出て、どこを直せばいいか分からない（実際に分からなかった）。

-}
viewReport : Model -> Model.PublishReport -> Html Msg
viewReport model report =
    if report.ok then
        Ui.callout Ui.toneOk
            [ class "gap-1 p-3 text-xs" ]
            [ span [ class "font-semibold" ] [ text "公開できます" ]
            , if report.unpublished > 0 then
                span [] [ text ("一緒に公開される物: " ++ String.fromInt report.unpublished ++ " 件") ]

              else
                text ""
            ]

    else
        Ui.callout Ui.toneWarn
            [ class "gap-1 p-3 text-xs" ]
            (span [ class "font-semibold" ] [ text ("直す所が " ++ String.fromInt (List.length report.violations) ++ " 件あります") ]
                :: List.map (viewViolation model) report.violations
            )


viewViolation : Model -> Model.Violation -> Html Msg
viewViolation model violation =
    span []
        [ case fieldNameOf model violation.path of
            Just name ->
                Html.strong [ class "font-semibold" ] [ text (name ++ "：") ]

            Nothing ->
                text ""
        , text violation.message
        ]


{-| 違反の path（`fields.title`）を、人が見ている項目の名前にする。
-}
fieldNameOf : Model -> String -> Maybe String
fieldNameOf model path =
    case String.split "." path of
        "fields" :: raw :: _ ->
            let
                apiId : String
                apiId =
                    String.split "[" raw |> List.head |> Maybe.withDefault raw
            in
            Loaded.toMaybe model.contentType
                |> Maybe.map .fields
                |> Maybe.withDefault []
                |> List.filter (\field -> field.apiId == apiId)
                |> List.head
                |> Maybe.map .name

        _ ->
            Nothing


stageChip : String -> Html msg
stageChip stage =
    case stage of
        "PUBLISHED" ->
            Ui.chip Ui.toneOk "公開中"

        "CHANGED" ->
            Ui.chip Ui.toneWarn "公開中 · 下書きあり"

        _ ->
            Ui.chip Ui.toneNeutral "下書き"


publishText : Model -> String -> String
publishText model label =
    if model.publishing then
        "送っています…"

    else
        label


{-| 相手が先に保存した時。**自動で混ぜない。**
-}
viewConflict : EntryRow -> Html Msg
viewConflict theirs =
    Ui.card [ class "flex flex-col gap-3 border-[color:var(--color-warn)] bg-[color:var(--color-warn-bg)] p-4" ]
        [ Ui.subheading "他の人が先に保存しました"
        , Ui.note [ text ("相手のバージョンは v" ++ String.fromInt theirs.version ++ " です。自分の入力を上に乗せるか、相手の内容に切り替えるかを選んでください。") ]
        , div [ class "flex gap-2" ]
            [ Ui.button [ onClick KeepMine ] [ text "自分の入力を上に乗せる" ]
            , Ui.ghostButton [ onClick TakeTheirs ] [ text "相手の内容にする" ]
            ]
        ]


saveText : SaveState -> String
saveText state =
    case state of
        Saved ->
            "保存済み"

        Dirty ->
            "未保存"

        Saving _ ->
            "保存しています…"

        Conflicted ->
            "競合しました"

        SaveFailed message ->
            if String.isEmpty message then
                "入力に問題があります"

            else
                message


viewField : { types : List Model.ContentTypeSummary } -> Model -> FieldDef -> Html Msg
viewField args model field =
    let
        errors : List String
        errors =
            model.errors |> List.filter (\( key, _ ) -> key == field.apiId) |> List.map Tuple.second

        current : Value
        current =
            Dict.get field.apiId model.values |> Maybe.withDefault (FieldValue.blank field)

        typed : String
        typed =
            FieldValue.toText current
    in
    Ui.fieldWith
        { label =
            field.name
                ++ (if field.required then
                        " *"

                    else
                        ""
                   )
                ++ countLabel model field
        , hint =
            if field.required && String.isEmpty typed && not (isFilled current) then
                Just "公開するには入力が必要です"

            else
                Nothing
        , errors = errors
        , extra =
            case field.config.maxLength of
                Just limit ->
                    Ui.gauge { used = String.length typed, limit = limit }

                Nothing ->
                    text ""
        }
        [ case field.kind of
            "TEXT_AREA" ->
                textArea "min-h-24" typed (FieldValue.Text >> FieldTyped field.apiId)

            "RICH_TEXT" ->
                viewRich model field current

            "NUMBER" ->
                Ui.input
                    [ value typed
                    , Html.Attributes.type_ "number"
                    , onInput (FieldValue.Number >> FieldTyped field.apiId)
                    , class "max-w-40"
                    ]

            "BOOLEAN" ->
                Ui.checkbox
                    { label = "はい"
                    , checked = current == FieldValue.Bool True
                    , onToggle = FieldTyped field.apiId (FieldValue.Bool (current /= FieldValue.Bool True))
                    }

            "DATE" ->
                viewDateField model field typed

            "DATE_ONLY" ->
                viewDateField model field typed

            "SELECT" ->
                if field.many then
                    viewChoices field current

                else
                    Ui.select
                        [ onInput (FieldValue.Choice >> FieldTyped field.apiId) ]
                        (( "", "選んでください" ) :: List.map (\option -> ( option, option )) field.config.options)
                        typed

            "ASSET" ->
                if field.many then
                    viewAssetsField model field current

                else
                    viewAssetField model field current

            "REFERENCE" ->
                viewRefField args model field current

            "SLUG" ->
                Ui.input
                    [ value typed
                    , onInput (FieldValue.Text >> FieldTyped field.apiId)
                    , placeholder (slugPlaceholder model field)
                    , class "max-w-96 font-mono"
                    ]

            "OBJECT" ->
                viewUneditable

            "BLOCKS" ->
                viewUneditable

            _ ->
                Ui.input [ value typed, onInput (FieldValue.Text >> FieldTyped field.apiId), class "max-w-96" ]
        ]


{-| まだこの画面が持っていない種類。

WhyNot: 素の入力欄に落とさない。入れ子や並びの値が文字列で上書きされ、
保存した時点で中身が消える。

WhyNot: 何も出さない。フィールドが無いように見えて、値が消えたと思われる。

-}
viewUneditable : Html Msg
viewUneditable =
    Ui.note [ text "この種類はまだこの画面で編集できません。値はそのまま保たれます。" ]


{-| slug の欄の案内。元になるフィールドがあれば、その名前を出す。
-}
slugPlaceholder : Model -> FieldDef -> String
slugPlaceholder model field =
    case field.config.sourceField |> Maybe.andThen (fieldDefOf model) of
        Just source ->
            "空なら「" ++ source.name ++ "」から作られます"

        Nothing ->
            "half-width-letters-and-hyphens"


{-| 本文の欄。**広げるかどうかだけを外側で決める。**

長い記事を書く時、フォームの中の 12rem の枠では前後が見えない。
Contentful は欄の右上の展開ボタン、Sanity は全画面、Notion は幅を広げるトグルを持つ。
ここは Contentful に寄せて、**欄の右上のボタンで画面いっぱいにする**。

**印は斜めの矢印 2 つで、文字を出さない。**（Contentful / Notion / Sanity /
Google ドキュメントが揃ってこの形。）文字で「広げて書く」と書くと、
本文の欄の頭に本文でない言葉が並んで、項目の名前と読み違える。

WhyNot: 広げる時に `tiptap-editor` を別の親へ動かさない。カスタム要素なので、
親が変わると作り直しになり、書いていた履歴（取り消し）が消える。
**同じ場所に置いたまま、外側の div を `fixed inset-0` にする。**

WhyNot: Esc で閉じない。本文の中では Esc をコードブロックやリンクの面が先に使うので、
ここで拾うと、面を閉じたつもりが画面ごと閉じる。

-}
viewRich : Model -> FieldDef -> Value -> Html Msg
viewRich model field current =
    let
        big : Bool
        big =
            model.expanded == Just field.apiId
    in
    div
        [ class
            (if big then
                "fixed inset-0 z-(--z-drawer) flex flex-col gap-2 bg-app p-4"

             else
                "flex flex-col gap-1.5"
            )
        ]
        [ div
            [ class "flex items-center gap-2"

            -- 帯も本文と同じ幅に揃える（揃えないと畳む印だけが画面の端に離れる）。
            , Html.Attributes.classList [ ( "mx-auto w-full max-w-[53rem]", big ) ]
            ]
            [ if big then
                span [ class "truncate text-[13px] font-semibold text-ink" ] [ text field.name ]

              else
                text ""

            -- **広げている間も保存できるようにする。** 覆いが上の帯を隠すので、
            -- 置かないと書いた物を保存するのに一度畳む事になる（実際に押せなかった）。
            , if big then
                span [ class "ml-auto text-xs text-ink-soft" ] [ text (saveText model.save) ]

              else
                text ""
            , if big then
                Ui.ghostButton
                    [ onClick SaveWanted
                    , Html.Attributes.disabled (not (unsaved model))
                    , Html.Attributes.title "Command + S"
                    ]
                    [ text "下書き保存" ]

              else
                text ""
            , Html.button
                [ class "flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-ink-soft hover:bg-well hover:text-ink"

                -- 広げている時は左隣の保存が右へ寄せているので、ここで 2 度寄せない
                -- （寄せると保存だけが真ん中に取り残される）。
                , Html.Attributes.classList [ ( "ml-auto", not big ) ]
                , onClick
                    (ExpandToggled
                        (if big then
                            Nothing

                         else
                            Just field.apiId
                        )
                    )
                , Html.Attributes.title
                    (if big then
                        "元の大きさに戻す"

                     else
                        "広げて書く"
                    )
                ]
                [ Icon.view
                    (if big then
                        Icon.collapse

                     else
                        Icon.expand
                    )
                ]
            ]
        , richEditor big model field.apiId current
        ]


{-| リッチエディタ。TipTap を包んだ custom element に doc を渡し、変わったら受け取る。

Elm は TipTap を知らない（`web/tiptap-editor.ts` が閉じている）。

-}
richEditor : Bool -> Model -> String -> Value -> Html Msg
richEditor big model apiId current =
    Html.node "tiptap-editor"
        [ Html.Attributes.classList [ ( "is-big", big ) ]
        , Html.Attributes.attribute "doc" (FieldValue.toDocJson current)

        -- **リンク先の候補は Elm が引く。** エディタは API を知らない
        -- （URL もヘッダも `js/api.ts` と Elm が持つ）。打った文字が `linksearch` で来て、
        -- 候補を属性で返す。
        , Html.Attributes.attribute "entries" (E.encode 0 (E.list encodeCandidate model.linkCandidates))

        -- **本文が指しているコンテンツ。** 候補（探した結果）とは別で、既にかかっている
        -- リンクの指し先を出すのに使う。
        , Html.Attributes.attribute "linked" (E.encode 0 (E.list encodeCandidate model.linkedEntries))

        -- **本文の画像は `assetId` しか持たない。** 描くのに要る URL はここで渡す。
        , Html.Attributes.attribute "assets" (E.encode 0 (E.list encodeAsset (allAssets model)))
        , Html.Attributes.attribute "uploadinput" richInputId
        , Html.Attributes.attribute "insert" (encodeInsert apiId model.insert)
        , Html.Attributes.attribute "resolved"
            (E.encode 0 (E.list encodeResolved (List.filter (\done -> done.apiId == apiId) model.resolved)))
        , Html.Events.on "docchange" (D.map (FieldValue.Rich >> FieldTyped apiId) (D.field "detail" D.string))
        , Html.Attributes.attribute "entriestotal" (String.fromInt model.linkTotal)
        , Html.Events.on "linksearch" (D.map LinkSearched (D.field "detail" D.string))
        , Html.Events.on "linkmore" (D.succeed LinkMoreAsked)
        , Html.Events.on "linkresolve" (D.map LinkResolveAsked (D.field "detail" (D.list D.string)))
        , Html.Events.on "mediapick" (D.succeed (RichPickerOpened apiId))
        , Html.Events.on "mediaupload" (D.map (RichUploadStarted apiId) (D.field "detail" startedDecoder))
        ]
        []


startedDecoder : D.Decoder { token : String, fileName : String, mime : String, size : Int }
startedDecoder =
    D.map4 (\token fileName mime size -> { token = token, fileName = fileName, mime = mime, size = size })
        (D.field "token" D.string)
        (D.field "fileName" D.string)
        (D.field "mime" D.string)
        (D.field "size" D.int)


{-| 一覧に無いメディア（さっき上げた物）も混ぜる。**引き直しを待たずに本文へ出す。**
-}
allAssets : Model -> List Model.AssetRow
allAssets model =
    model.newAssets
        ++ (Loaded.toMaybe model.assets |> Maybe.map .nodes |> Maybe.withDefault [])


encodeAsset : Model.AssetRow -> E.Value
encodeAsset asset =
    E.object [ ( "id", E.string asset.id ), ( "url", E.string asset.url ), ( "alt", E.string asset.alt ) ]


encodeResolved : { apiId : String, token : String, assetId : String } -> E.Value
encodeResolved done =
    E.object [ ( "token", E.string done.token ), ( "assetId", E.string done.assetId ) ]


{-| 入れる指示。**入れ先のフィールドの物だけ渡す**（本文が 2 つある型で両方に入る）。
-}
encodeInsert : String -> Maybe { seq : Int, apiId : String, assetIds : List String } -> String
encodeInsert apiId order =
    case order of
        Just found ->
            if found.apiId == apiId then
                E.encode 0 (E.object [ ( "seq", E.int found.seq ), ( "assetIds", E.list E.string found.assetIds ) ])

            else
                ""

        Nothing ->
            ""


{-| 候補の行の頭に出す型の目印。名前とアイコン。
-}
type alias TypeMark =
    { name : String, icon : String }


markOf : Model.ContentTypeSummary -> TypeMark
markOf summary =
    { name = summary.name, icon = summary.icon }


{-| 本文のリンクの候補を、型ごとに 1 回で何件引くか。
-}
linkCandidatesPerType : Int
linkCandidatesPerType =
    20


{-| リンクの候補を型ごとに引く。`page` は 0 から数えた回数。
-}
linkFetch : { project : Slug, types : List Model.ContentTypeSummary } -> String -> Int -> List (Api.Call Msg)
linkFetch ctx query page =
    ctx.types
        |> List.map
            (\summary ->
                Api.call
                    (\id ->
                        Queries.entries id
                            ctx.project
                            { typeId = summary.id
                            , search = query
                            , stage = ""
                            , conditions = []
                            , ids = []
                            , order = ""
                            , first = linkCandidatesPerType
                            , skip = page * linkCandidatesPerType
                            }
                    )
                    (GotLinkCandidates (markOf summary))
            )


encodeCandidate : Model.LinkCandidate -> E.Value
encodeCandidate candidate =
    E.object
        [ ( "id", E.string candidate.id )
        , ( "title", E.string candidate.title )
        , ( "type", E.string candidate.typeName )

        -- 行の頭のアイコン。**`<svg>` の中身をそのまま渡す**（Web Component は Elm の
        -- Svg を受け取れない）。中身は `Ui.Icon` の表から出た物だけ。
        , ( "icon", E.string (Icon.markupByName candidate.typeIcon) )
        , ( "stage", E.string candidate.stage )
        , ( "path", candidate.path |> Maybe.map E.string |> Maybe.withDefault E.null )
        ]


{-| 参照（タグのように、コンテンツがコンテンツに繋がる物）。1 件でも複数でも同じ面。

**打つ度に CMS へ投げ直す。** 先読みした一覧を手元で絞る形だと、参照先が
1 ページを超えた時に、超えた分を選ぶ手段が画面から消える。

並びは Strapi / Sanity と同じ「ラベル（件数）→ 探す欄 → 選んである物」。
空だと分かる文は探す欄の placeholder に畳む（調べた 5 社に、独立した行を
取っている物は 1 つも無かった）。

-}
viewRefField : { types : List Model.ContentTypeSummary } -> Model -> FieldDef -> Value -> Html Msg
viewRefField args model field current =
    let
        chosen : List String
        chosen =
            FieldValue.idsOf current

        open : Bool
        open =
            model.refOpen == Just field.apiId
    in
    div [ class "flex flex-col gap-2" ]
        [ if open then
            Ui.dismissLayer RefClosed

          else
            text ""
        , div
            [ class
                (if open then
                    -- **持ち上げるのは開いている 1 本だけ。**
                    -- WhyNot: 参照フィールドを常に持ち上げない。同じ値の入れ物が縦に並ぶと
                    -- 後から描かれた方が勝ち、上のフィールドの候補が下のフィールドの
                    -- チップ・入力欄の後ろに回る（実際に回った）。
                    "relative z-(--z-dropdown) flex flex-col gap-2"

                 else
                    "relative flex flex-col gap-2"
                )
            ]
            -- **選んである物を探す欄の上に置く。** 下に置くと、開いた候補が
            -- そのまま覆いかぶさり、今足した物が見えず押せもしない（実際に押せなかった）。
            [ div [ class "flex flex-wrap gap-1.5" ] (List.map (viewChosenRef model field) chosen)
            , div [ class "relative flex max-w-96 flex-col" ]
                [ Ui.input
                    [ value (Dict.get field.apiId model.refQuery |> Maybe.withDefault "")
                    , onInput (RefSearched field.apiId)
                    , Html.Events.onFocus (RefOpened field.apiId)
                    , placeholder refPlaceholder
                    , class "w-full"
                    ]
                , if open then
                    viewRefCandidates args model field chosen

                  else
                    text ""
                ]
            ]
        ]


{-| 探す欄の案内。

WhyNot: 文章にしない。他の CMS の placeholder は「検索…」程度で、状態ごとに
言い回しを変えている物は無かった。

-}
refPlaceholder : String
refPlaceholder =
    "検索…"


{-| 選んである 1 件。押すと外れる。
-}
viewChosenRef : Model -> FieldDef -> String -> Html Msg
viewChosenRef model field entryId =
    Html.button
        [ class "flex max-w-full items-center gap-1 rounded-full border border-edge bg-well px-2.5 py-1 text-[11px] font-medium text-ink hover:border-[color:var(--color-bad)]"
        , Html.Attributes.title "押すと外れます"
        , onClick (RefDropped field.apiId entryId)
        ]
        [ span [ class "truncate" ] [ text (refLabelOf model entryId) ]
        , span [ class "shrink-0 text-ink-faint" ] [ text "×" ]
        ]


{-| 見出し。**検索の結果に居なくても出す**（id で引いた分と、選んだ時の分を貯めてある）。
-}
refLabelOf : Model -> String -> String
refLabelOf model entryId =
    Dict.get entryId model.refLabels |> Maybe.withDefault entryId


{-| 候補の一覧。まだ引いていない間は何も出さない（空と紛らわしくしない）。
-}
viewRefCandidates : { types : List Model.ContentTypeSummary } -> Model -> FieldDef -> List String -> Html Msg
viewRefCandidates args model field chosen =
    div [ class "absolute top-9 left-0 z-(--z-dropdown) flex max-h-56 w-full flex-col overflow-auto rounded-md border border-edge bg-panel shadow-lg" ]
        (case Dict.get field.apiId model.refs of
            Nothing ->
                [ span [ class "px-2 py-2 text-xs text-ink-faint" ] [ text "探しています…" ] ]

            Just [] ->
                [ viewNoCandidates args model field ]

            Just candidates ->
                List.map (viewRefCandidate field chosen) candidates ++ viewRefRest model field candidates
        )


{-| 出し切れなかった分の断り。

WhyNot: 出した分だけで終わらせない。1 度に引くのは 20 件なので、21 件目以降は
黙って落ちる。**ここからは絞って辿り着く**ので、その旨を添える。

-}
viewRefRest : Model -> FieldDef -> List ( String, String ) -> List (Html Msg)
viewRefRest model field candidates =
    let
        rest : Int
        rest =
            (Dict.get field.apiId model.refTotals |> Maybe.withDefault 0) - List.length candidates
    in
    if rest > 0 then
        [ span [ class "border-t border-edge px-2 py-2 text-[11px] text-ink-faint" ]
            [ text ("ほかに " ++ String.fromInt rest ++ " 件あります。打つと絞り込めます。") ]
        ]

    else
        []


{-| 候補が無い時。**まだ 1 件も無いのか、絞り込んで消えたのかを分ける。**
-}
viewNoCandidates : { types : List Model.ContentTypeSummary } -> Model -> FieldDef -> Html Msg
viewNoCandidates args model field =
    if String.isEmpty (Dict.get field.apiId model.refQuery |> Maybe.withDefault "") then
        div [ class "flex flex-col items-start gap-1 px-2 py-2" ]
            [ span [ class "text-xs text-ink-faint" ] [ text "まだ 1 件もありません" ]
            , case targetTypeOf model field.apiId |> Maybe.andThen (targetSummary args) of
                Just summary ->
                    -- **別のタブで開く。** 同じタブで移ると、書きかけの入力を捨てる事になる。
                    Ui.link
                        [ Html.Attributes.href (Route.toString (Route.NewEntry model.project summary.apiId))
                        , Html.Attributes.target "_blank"
                        , class "text-xs"
                        ]
                        [ text ("「" ++ summary.name ++ "」を作る") ]

                Nothing ->
                    text ""
            ]

    else
        span [ class "px-2 py-2 text-xs text-ink-faint" ] [ text "見つかりません" ]


targetSummary : { types : List Model.ContentTypeSummary } -> String -> Maybe Model.ContentTypeSummary
targetSummary args typeId =
    args.types |> List.filter (\summary -> summary.id == typeId) |> List.head


viewRefCandidate : FieldDef -> List String -> ( String, String ) -> Html Msg
viewRefCandidate field chosen ( entryId, label ) =
    Html.button
        [ class
            ("truncate px-2 py-1.5 text-left text-[13px] hover:bg-raised "
                ++ (if List.member entryId chosen then
                        "bg-well font-semibold text-ink"

                    else
                        "text-ink-soft"
                   )
            )
        , onClick (RefPicked field.apiId entryId)
        ]
        [ text label ]


{-| 日時。**canonical な `2026-09-09T00:00:00Z` しか CMS は受けない。**

WhyNot: `<input type="datetime-local">` を使わない。秒もタイムゾーンも付かない
`2026-09-09T09:00` を出すので、必ず断られる（並びと言語がブラウザ任せなのは
`Ui.DateTime` の doc の通り）。

WhyNot: 暦を触った時点では書かない。任意の DATE は空のままにできる必要があり、
月を送っただけで値が入ると空に戻せない。

-}
viewDateField : Model -> FieldDef -> String -> Html Msg
viewDateField model field iso =
    let
        onlyDate : Bool
        onlyDate =
            field.kind == "DATE_ONLY"

        what : String
        what =
            if onlyDate then
                "日付"

            else
                "日時"
    in
    div [ class "flex flex-col gap-2" ]
        [ div [ class "flex flex-wrap items-center gap-3" ]
            [ if String.isEmpty iso then
                span [ class "text-[13px] text-ink-faint" ] [ text (what ++ "が入っていません") ]

              else
                span [ class "font-mono text-[13px] text-ink" ]
                    [ text
                        (if onlyDate then
                            -- **文字列をそのまま出す。** 時刻を持たない値にタイムゾーンを
                            -- 当てると、負のオフセットの環境で前日に出る。
                            iso

                         else
                            Ui.DateTime.formatLocal model.zone iso
                        )
                    ]
            , Ui.ghostButton [ onClick (DateOpened field.apiId) ]
                [ text
                    (if String.isEmpty iso then
                        what ++ "を選ぶ"

                     else
                        "選び直す"
                    )
                ]

            -- 値を消すだけで、取り返しは付く。**赤は削除に取っておく。**
            , if String.isEmpty iso || field.required then
                text ""

              else
                Ui.quietActionLink [ onClick (DateCleared field.apiId) ] [ text "消す" ]
            ]
        , case ( model.dateOpen == Just field.apiId, Dict.get field.apiId model.dates ) of
            ( True, Just picked ) ->
                div [ class "flex flex-col items-start gap-2" ]
                    [ Html.map (DateMsg field.apiId)
                        (if onlyDate then
                            Ui.DateTime.viewDate picked

                         else
                            Ui.DateTime.view model.zone picked
                        )
                    , div [ class "flex items-center gap-2" ]
                        [ Ui.button [ onClick (DateApplied field.apiId) ] [ text ("この" ++ what ++ "にする") ]
                        , Ui.ghostButton [ onClick DateClosed ] [ text "やめる" ]
                        ]
                    ]

            _ ->
                text ""
        ]


{-| ラベルに付ける件数。**複数選べる物だけ**（Strapi と同じ位置）。
-}
countLabel : Model -> FieldDef -> String
countLabel model field =
    if field.many && List.member field.kind [ "REFERENCE", "ASSET" ] then
        case List.length (chosenOf model field.apiId) of
            0 ->
                ""

            count ->
                "（" ++ String.fromInt count ++ "）"

    else
        ""


{-| メディアの複数。**1 枚ごとにまとまりを作る。**

WhyNot: 見え姿と「外す」を別の列に並べない。前は id が横に並び、その下に「外す」だけが
並んでいて、どの「外す」がどの 1 枚なのか分からなかった（実際に分からなかった）。

-}
viewAssetsField : Model -> FieldDef -> Value -> Html Msg
viewAssetsField model field current =
    let
        chosen : List String
        chosen =
            FieldValue.idsOf current
    in
    -- 空だと分かる文は置かない。件数はラベルに出る（参照と揃える）。
    -- 並びは「選んである物 → 足す」（参照と揃える）。
    div [ class "flex flex-col gap-2" ]
        [ div [ class "flex flex-wrap gap-2" ]
            (List.map
                (\assetId ->
                    viewAssetCard model
                        assetId
                        [ Ui.quietActionLink
                            [ onClick (FieldTyped field.apiId (FieldValue.Refs (List.filter (\id -> id /= assetId) chosen))) ]
                            [ text "外す" ]
                        ]
                )
                chosen
            )
        , div [] [ Ui.ghostButton [ onClick (PickerOpened field.apiId) ] [ text (pickLabel (List.isEmpty chosen) field.many) ] ]
        ]


{-| メディアの 1 件。**エディタを離れずに選ぶ**（仕様 6.3）。
-}
viewAssetField : Model -> FieldDef -> Value -> Html Msg
viewAssetField model field current =
    let
        chosen : String
        chosen =
            FieldValue.toText current
    in
    div [ class "flex flex-wrap items-start gap-3" ]
        [ if String.isEmpty chosen then
            text ""

          else
            viewAssetCard model chosen []
        , div [ class "flex items-center gap-3 pt-1" ]
            [ Ui.ghostButton [ onClick (PickerOpened field.apiId) ] [ text (pickLabel (String.isEmpty chosen) field.many) ]
            , if String.isEmpty chosen then
                text ""

              else
                Ui.quietActionLink [ onClick (FieldTyped field.apiId (FieldValue.Ref "")) ] [ text "外す" ]
            ]
        ]


{-| メディアを選ぶボタンの文字。空か・複数か で 3 通りだけ持つ。
-}
pickLabel : Bool -> Bool -> String
pickLabel empty many =
    if many then
        "メディアを追加"

    else if empty then
        "メディアを選ぶ"

    else
        "選び直す"


{-| メディア 1 件の見え姿。**画像を出す。** ファイル名と大きさを添え、操作をその中に置く。

WhyNot: 一覧に見つからない時も id を裸で出さない。人には読めない文字列で、
消されたのか読み込み中なのかも分からない。

-}
viewAssetCard : Model -> String -> List (Html Msg) -> Html Msg
viewAssetCard model assetId actions =
    div [ class "flex w-32 flex-col gap-1 rounded-md border border-edge bg-panel p-1.5" ]
        (case assetOf model assetId of
            Just asset ->
                [ Ui.thumb "h-20" { url = asset.url, mime = asset.mime }
                , span [ class "truncate text-[11px] text-ink", Html.Attributes.title asset.fileName ] [ text asset.fileName ]
                , span [ class "text-[10px] text-ink-faint" ] [ text (sizeText asset.size) ]
                ]
                    ++ actions

            Nothing ->
                [ div [ class "flex h-20 items-center justify-center rounded bg-well" ]
                    [ span [ class "text-[10px] text-ink-faint" ] [ text "読み込んでいます…" ] ]
                , span [ class "truncate font-mono text-[10px] text-ink-faint" ] [ text assetId ]
                ]
                    ++ actions
        )


{-| ファイルの大きさ。**人が読む単位に丸める**（バイトの桁は読めない）。
-}
sizeText : Int -> String
sizeText size =
    if size >= 1024 * 1024 then
        String.fromInt (size // (1024 * 1024)) ++ " MB"

    else if size >= 1024 then
        String.fromInt (size // 1024) ++ " KB"

    else
        String.fromInt size ++ " B"


assetOf : Model -> String -> Maybe Model.AssetRow
assetOf model assetId =
    allAssets model
        |> List.filter (\asset -> asset.id == assetId)
        |> List.head


{-| メディアのピッカー。モーダルは 1 段（仕様 6.1）。
-}
viewPicker : Model -> Html Msg
viewPicker model =
    case ( model.picking, model.richPicking ) of
        ( Nothing, Nothing ) ->
            text ""

        _ ->
            let
                many : Bool
                many =
                    model.richPicking /= Nothing
            in
            Ui.overlay PickerClosed
                [ class "items-center" ]
                [ Ui.card [ class "flex max-h-[70vh] w-[760px] flex-col gap-3 overflow-auto p-5", keepOpen ]
                    [ Ui.subheading "メディアから選ぶ"
                    , if many then
                        Ui.note [ text "2 枚以上えらぶと、本文には横並び（gallery）で入ります。" ]

                      else
                        text ""
                    , Loaded.view
                        { loading = Ui.loadingCard
                        , missing = Ui.note [ text "メディアがありません。「メディア」の画面からアップロードしてください。" ]
                        , failed = \message -> span [ class "text-xs text-[color:var(--color-bad)]" ] [ text message ]
                        , present =
                            \_ ->
                                if List.isEmpty (allAssets model) then
                                    Ui.note [ text "メディアがありません。「メディア」の画面からアップロードしてください。" ]

                                else
                                    div [ class "grid grid-cols-5 gap-3" ]
                                        (List.map (viewPickable model.richPicked) (allAssets model))
                        }
                        model.assets
                    , if many then
                        div [ class "flex items-center gap-3" ]
                            [ Ui.button
                                [ onClick RichInsertWanted
                                , Html.Attributes.disabled (List.isEmpty model.richPicked)
                                ]
                                [ text ("本文に入れる（" ++ String.fromInt (List.length model.richPicked) ++ "）") ]
                            , Ui.ghostButton [ onClick PickerClosed ] [ text "やめる" ]
                            ]

                      else
                        text ""
                    ]
                ]


viewPickable : List String -> Model.AssetRow -> Html Msg
viewPickable picked asset =
    let
        at : Maybe Int
        at =
            picked |> List.indexedMap (\index id -> ( index, id )) |> List.filter (\( _, id ) -> id == asset.id) |> List.head |> Maybe.map Tuple.first
    in
    Html.button
        [ class
            ("relative flex flex-col overflow-hidden rounded-lg border bg-panel text-left "
                ++ (if at == Nothing then
                        "border-edge"

                    else
                        "border-accent ring-2 ring-accent"
                   )
            )
        , onClick (AssetPicked asset.id)
        ]
        [ div [ class "flex h-20 items-center justify-center bg-well" ]
            [ if String.startsWith "image/" asset.mime then
                Html.img [ Html.Attributes.src asset.url, class "h-20 w-full object-cover" ] []

              else
                span [ class "text-[10px] text-ink-faint" ] [ text asset.mime ]
            ]
        , case at of
            -- **何枚目かを出す。** 横並びの順はここで選んだ順になる。
            Just index ->
                span
                    [ class "absolute top-1 right-1 flex h-5 w-5 items-center justify-center rounded-full bg-accent text-[10px] font-semibold text-white" ]
                    [ text (String.fromInt (index + 1)) ]

            Nothing ->
                text ""
        , span [ class "truncate p-1.5 text-[11px] text-ink" ] [ text asset.fileName ]
        ]


{-| 複数選べるセレクト。**選んだ物をチップで出し、押して外せる。**
-}
viewChoices : FieldDef -> Value -> Html Msg
viewChoices field current =
    let
        chosen : List String
        chosen =
            case current of
                FieldValue.Choices values ->
                    values

                _ ->
                    []

        toggle : String -> Msg
        toggle option =
            FieldTyped field.apiId
                (FieldValue.Choices
                    (if List.member option chosen then
                        List.filter (\value -> value /= option) chosen

                     else
                        chosen ++ [ option ]
                    )
                )
    in
    div [ class "flex flex-wrap gap-1.5" ]
        (List.map
            (\option ->
                Html.button
                    [ class
                        -- **選んだ物が一目で分かるようにする。** 前は色の濃さだけが違い、
                        -- 選んであるかどうかが見分けられなかった。
                        ("rounded-full border px-2.5 py-1 text-[11px] font-medium "
                            ++ (if List.member option chosen then
                                    "border-accent bg-well font-semibold text-link"

                                else
                                    "border-edge bg-panel text-ink-soft hover:bg-well"
                               )
                        )
                    , onClick (toggle option)
                    ]
                    [ text option ]
            )
            field.config.options
        )


{-| 値が入っているか。チェックボックスや複数選択は文字列にならないので、別に見る。
-}
isFilled : Value -> Bool
isFilled value =
    case value of
        FieldValue.Bool _ ->
            True

        FieldValue.Choices choices ->
            not (List.isEmpty choices)

        FieldValue.Raw _ ->
            True

        other ->
            not (String.isEmpty (FieldValue.toText other))


textArea : String -> String -> (String -> Msg) -> Html Msg
textArea height current toMsg =
    Html.textarea
        [ class (height ++ " rounded-md border border-edge bg-panel p-3 text-sm text-ink outline-none focus:border-accent")
        , value current
        , onInput toMsg
        ]
        []
