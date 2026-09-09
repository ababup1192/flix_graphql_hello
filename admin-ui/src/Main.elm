port module Main exposing (main)

{-| 入口。

やっている事の順:

1.  起動して `me` を 1 本引く（誰で、どのプロジェクトに入れるか）
2.  入口の状態を決める（読み込み中 / メンバーでない / ログインし直し / 中に入る）
3.  プロジェクトが決まったら `viewer` で権限を引き、URL に合うページを読み込む
4.  封筒の応答を id で待っている物に配る

-}

import Api
import Api.Error as Error
import Api.Permission as Permission exposing (Permission)
import Browser
import Browser.Events
import Browser.Navigation as Nav
import Dict exposing (Dict)
import Effect exposing (Effect)
import Html exposing (Html)
import Json.Decode as D
import Json.Encode as E
import Model exposing (ContentTypeSummary, Person, Project, Slug)
import Page.Account as Account
import Page.Board as Board
import Page.Editor as Editor
import Page.Entries as Entries
import Page.Keys as Keys
import Page.Media as Media
import Page.Members as Members
import Page.Preview as Preview
import Page.Project as ProjectPage
import Page.Projects as Projects
import Page.Schema as Schema
import Page.TypeSettings as TypeSettings
import Palette
import Queries
import Route exposing (Route)
import Shell
import Url exposing (Url)
import View



-- port（封筒 2 本だけ。URL もヘッダも TypeScript 側）


port apiRequest_Api_JS : E.Value -> Cmd msg


port apiResponse_Api_ELM : (D.Value -> msg) -> Sub msg


{-| 署名付き URL にファイルを PUT する。**ファイルの中身は Elm に持ち込まない。**
-}
port uploadAsset_Media_JS : E.Value -> Cmd msg


port uploadFinished_Media_ELM : (D.Value -> msg) -> Sub msg


{-| テーマ。system / light / dark を html の属性と localStorage に写す。
-}
port setTheme_Shell_JS : String -> Cmd msg


{-| 未保存の入力があるか。**画面を閉じる時の警告は JS 側が出す**
（Elm から beforeunload は触れない）。保存は人が押す物になったので、
これが無いと書きかけが黙って消える。
-}
port setUnsaved_Editor_JS : Bool -> Cmd msg



-- MODEL


type alias Model =
    ModelWith Nav.Key


{-| key を型引数にするのは、テストの枠組みが init に Nav.Key を渡さないため
（`ProgramTest.createApplication` の init は第 3 引数が `()`）。update は key に触らない。
-}
type alias ModelWith key =
    { key : key
    , route : Route
    , phase : Phase
    , toast : Maybe String
    , seq : Int
    , waiting : Dict String (Api.Response -> Msg)
    , origin : String
    , palette : Palette.Model

    {- API プレビューの引き出し。**ページではなく重ねる物**なので、
       ページの入れ替えでは消えない所に置く。
    -}
    , preview : Maybe Preview.Model
    , menu : Shell.Menu
    , sidebarCollapsed : Bool
    , theme : String
    }


{-| 入口の状態（仕様 13.5）。ログイン画面は Access が持つので、ここには無い。
-}
type Phase
    = Loading
    | NotMember { email : String }
    | SignedOut
    | Broken { message : String, requestId : Maybe String }
    | Ready Workspace


{-| 中に入った後。今のプロジェクトとその権限、今のページ。
-}
type alias Workspace =
    { person : Person
    , project : Maybe Project
    , permissions : List Permission
    , types : List ContentTypeSummary
    , origin : String
    , page : Page
    }


type Page
    = ProjectsPage Projects.Model
    | MembersPage Members.Model
    | SchemaPage Schema.Model
    | TypeSettingsPage TypeSettings.Model
    | EntriesPage Entries.Model
    | BoardPage Board.Model
    | EditorPage Editor.Model
    | KeysPage Keys.Model
    | MediaPage Media.Model
    | AccountPage Account.Model
    | ProjectPage ProjectPage.Model
    | Placeholder String


type Msg
    = UrlChanged Url
    | LinkClicked Browser.UrlRequest
    | GotApiResponse D.Value
    | ToastShown String
    | ToastClosed
    | ReloadClicked
    | GotMe (Result Api.Problem (Maybe Person))
    | GotViewer (Result Api.Problem Model.ViewerInfo)
    | GotTypes (Result Api.Problem (List ContentTypeSummary))
    | ProjectsMsg Projects.Msg
    | MembersMsg Members.Msg
    | SchemaMsg Schema.Msg
    | TypeSettingsMsg TypeSettings.Msg
    | EntriesMsg Entries.Msg
    | BoardMsg Board.Msg
    | EditorMsg Editor.Msg
    | PreviewMsg Preview.Msg
    | KeysMsg Keys.Msg
    | MediaMsg Media.Msg
    | AccountMsg Account.Msg
    | ProjectMsg ProjectPage.Msg
    | PaletteMsg Palette.Msg
    | KeyPressed String
    | Ignored
    | MenuToggled Shell.Menu
    | SidebarToggled
    | ThemeChosen String
    | UploadFinished D.Value


main : Program D.Value Model Msg
main =
    Browser.application
        { init = \_ url key -> init url key |> Tuple.mapSecond (Effect.perform (caps key))
        , update = \msg model -> update msg model |> Tuple.mapSecond (Effect.perform (caps model.key))
        , view = view
        , subscriptions = subscriptions
        , onUrlChange = UrlChanged
        , onUrlRequest = LinkClicked
        }


{-| perform が外に触るのに要る物。Effect が port を知らずに済む。
-}
caps : Nav.Key -> Effect.Caps Msg
caps key =
    { key = key
    , send = apiRequest_Api_JS
    , upload = uploadAsset_Media_JS
    , theme = setTheme_Shell_JS
    , ignore = Ignored
    , toast = ToastShown
    , unsaved = setUnsaved_Editor_JS
    }


{-| 今のオリジン。MCP のつなぎ先の URL を組むのに使う。
-}
originOf : Url -> String
originOf url =
    let
        scheme : String
        scheme =
            case url.protocol of
                Url.Https ->
                    "https://"

                Url.Http ->
                    "http://"
    in
    scheme
        ++ url.host
        ++ (case url.port_ of
                Just number ->
                    ":" ++ String.fromInt number

                Nothing ->
                    ""
           )


{-| 起動して me を 1 本引く。key は素通しするだけで、update からは触らない。
-}
init : Url -> key -> ( ModelWith key, Effect Msg )
init url key =
    { key = key
    , route = Route.fromUrl url
    , phase = Loading
    , toast = Nothing
    , seq = 0
    , waiting = Dict.empty
    , origin = originOf url
    , palette = Palette.init
    , preview = Nothing
    , menu = Shell.NoMenu
    , sidebarCollapsed = False
    , theme = "system"
    }
        |> send (Api.call Queries.me GotMe)



-- 送る


{-| 1 本投げ、応答を待つ物に登録する。

id はここで採番する（update の中なので純粋なまま）。応答は id で持ち主に配る。

-}
send : Api.Call Msg -> ModelWith key -> ( ModelWith key, Effect Msg )
send theCall model =
    let
        seq : Int
        seq =
            model.seq + 1

        id : String
        id =
            "r" ++ String.fromInt seq

        ( request, handle ) =
            theCall id
    in
    ( { model | seq = seq, waiting = Dict.insert id handle model.waiting }
    , Effect.SendGraphql request
    )


{-| 何本かまとめて投げる。
-}
sendAll : List (Api.Call Msg) -> ModelWith key -> ( ModelWith key, Effect Msg )
sendAll calls model =
    List.foldl
        (\theCall ( acc, effects ) ->
            let
                ( next, effect ) =
                    send theCall acc
            in
            ( next, effect :: effects )
        )
        ( model, [] )
        calls
        |> Tuple.mapSecond Effect.batch



-- UPDATE


update : Msg -> ModelWith key -> ( ModelWith key, Effect Msg )
update msg model =
    case msg of
        UrlChanged url ->
            -- 画面を離れたら未保存の印を下ろす（別の画面で閉じる時に警告が出ない）。
            -- 上のバーのメニューは項目が動いた後に閉じる。
            enterRoute (Route.fromUrl url) model
                |> Tuple.mapFirst (\next -> { next | menu = Shell.NoMenu })
                |> Tuple.mapSecond (\effect -> Effect.batch [ Effect.SetUnsaved False, effect ])

        LinkClicked (Browser.Internal url) ->
            ( model, Effect.PushRoute (Url.toString url) )

        LinkClicked (Browser.External url) ->
            ( model, Effect.LoadUrl url )

        ToastShown text ->
            ( { model | toast = Just text }, Effect.none )

        ToastClosed ->
            ( { model | toast = Nothing }, Effect.none )

        ReloadClicked ->
            ( model, Effect.Reload )

        GotApiResponse raw ->
            dispatch raw model

        GotMe (Ok (Just person)) ->
            gotPerson person model

        GotMe (Ok Nothing) ->
            ( { model | phase = SignedOut }, Effect.none )

        GotMe (Err problem) ->
            ( { model | phase = failureOf problem }, Effect.none )

        GotViewer result ->
            ( updateWorkspace
                (\workspace ->
                    { workspace
                        | permissions =
                            result
                                |> Result.map (.permissions >> Permission.fromList)
                                |> Result.withDefault []
                    }
                )
                model
            , Effect.none
            )

        GotTypes result ->
            ( updateWorkspace (\workspace -> { workspace | types = Result.withDefault [] result }) model, Effect.none )

        ProjectsMsg pageMsg ->
            withPage model
                (\workspace ->
                    case workspace.page of
                        ProjectsPage page ->
                            Projects.update pageMsg page |> mapPage ProjectsPage ProjectsMsg workspace

                        _ ->
                            ( workspace, [] )
                )

        MediaMsg pageMsg ->
            case model.phase of
                Ready workspace ->
                    case workspace.page of
                        MediaPage page ->
                            let
                                ( updated, calls ) =
                                    Media.update (context workspace) pageMsg page

                                ( next, upload ) =
                                    Media.takeUpload updated

                                ( sent, effect ) =
                                    sendAll (List.map (Api.mapCall MediaMsg) calls)
                                        { model | phase = Ready { workspace | page = MediaPage next } }
                            in
                            ( sent
                            , Effect.batch
                                [ effect
                                , case upload of
                                    Just chosen ->
                                        Effect.Upload
                                            (E.object
                                                [ ( "assetId", E.string chosen.assetId )
                                                , ( "url", E.string chosen.uploadUrl )
                                                , ( "inputId", E.string Media.inputId )
                                                ]
                                            )

                                    Nothing ->
                                        Effect.none
                                ]
                            )

                        _ ->
                            ( model, Effect.none )

                _ ->
                    ( model, Effect.none )

        UploadFinished raw ->
            -- **どちらの画面が上げたかは、今開いている画面で決まる**（port は 1 本）。
            case ( D.decodeValue uploadResultDecoder raw, model.phase ) of
                ( Ok result, Ready workspace ) ->
                    case workspace.page of
                        EditorPage _ ->
                            update (EditorMsg (Editor.RichUploadFinished result)) model

                        _ ->
                            update (MediaMsg (Media.UploadFinished result)) model

                _ ->
                    ( model, Effect.none )

        Ignored ->
            ( model, Effect.none )

        MenuToggled menu ->
            ( { model | menu = menu }, Effect.none )

        SidebarToggled ->
            ( { model | sidebarCollapsed = not model.sidebarCollapsed }, Effect.none )

        ThemeChosen theme ->
            ( { model | theme = theme, menu = Shell.NoMenu }, Effect.SetTheme theme )

        PaletteMsg paletteMsg ->
            paletteUpdate paletteMsg model

        KeyPressed key ->
            if key == "k" then
                paletteUpdate Palette.Opened model

            else if key == "Escape" then
                paletteUpdate Palette.Closed { model | menu = Shell.NoMenu }

            else
                ( model, Effect.none )

        AccountMsg pageMsg ->
            withPage model
                (\workspace ->
                    case workspace.page of
                        AccountPage page ->
                            Account.update pageMsg page |> mapPage AccountPage AccountMsg workspace

                        _ ->
                            ( workspace, [] )
                )

        ProjectMsg pageMsg ->
            withPage model
                (\workspace ->
                    case workspace.page of
                        ProjectPage page ->
                            ProjectPage.update (context workspace) pageMsg page
                                |> mapPage ProjectPage ProjectMsg workspace

                        _ ->
                            ( workspace, [] )
                )

        BoardMsg pageMsg ->
            withPage model
                (\workspace ->
                    case workspace.page of
                        BoardPage page ->
                            Board.update (context workspace) pageMsg page
                                |> mapPage BoardPage BoardMsg workspace

                        _ ->
                            ( workspace, [] )
                )

        KeysMsg pageMsg ->
            withPage model
                (\workspace ->
                    case workspace.page of
                        KeysPage page ->
                            Keys.update (context workspace) pageMsg page
                                |> mapPage KeysPage KeysMsg workspace

                        _ ->
                            ( workspace, [] )
                )

        PreviewMsg Preview.Closed ->
            ( { model | preview = Nothing }, Effect.none )

        PreviewMsg pageMsg ->
            case model.preview of
                Just page ->
                    let
                        ( next, calls ) =
                            Preview.update { project = projectSlugOf model } pageMsg page
                    in
                    sendAll (List.map (Api.mapCall PreviewMsg) calls) { model | preview = Just next }

                Nothing ->
                    ( model, Effect.none )

        EntriesMsg Entries.ApiPreviewWanted ->
            openPreview Nothing model

        EntriesMsg pageMsg ->
            case model.phase of
                Ready workspace ->
                    case workspace.page of
                        EntriesPage page ->
                            let
                                ( next, calls ) =
                                    Entries.update (context workspace) pageMsg page

                                ( sent, effect ) =
                                    sendAll (List.map (Api.mapCall EntriesMsg) calls)
                                        { model | phase = Ready { workspace | page = EntriesPage next } }

                                url : String
                                url =
                                    Entries.urlOf next
                            in
                            -- 絞り込みを URL に書き戻す。**履歴は増やさない**（1 文字ごとに戻るが増えると使えない）。
                            ( { sent | route = Route.fromString url |> Maybe.withDefault sent.route }
                            , Effect.batch
                                [ effect
                                , if url == Route.toString model.route then
                                    Effect.none

                                  else
                                    Effect.ReplaceRoute url
                                , searchDebounce pageMsg next
                                ]
                            )

                        _ ->
                            ( model, Effect.none )

                _ ->
                    ( model, Effect.none )

        EditorMsg Editor.ApiPreviewWanted ->
            case model.phase of
                Ready workspace ->
                    case workspace.page of
                        EditorPage page ->
                            openPreview (Editor.previewOf page) model

                        _ ->
                            ( model, Effect.none )

                _ ->
                    ( model, Effect.none )

        EditorMsg pageMsg ->
            editorUpdate pageMsg model

        TypeSettingsMsg pageMsg ->
            withPage model
                (\workspace ->
                    case workspace.page of
                        TypeSettingsPage page ->
                            TypeSettings.update (context workspace) pageMsg page
                                |> mapPage TypeSettingsPage TypeSettingsMsg workspace

                        _ ->
                            ( workspace, [] )
                )

        SchemaMsg pageMsg ->
            withPage model
                (\workspace ->
                    case workspace.page of
                        SchemaPage page ->
                            Schema.update (context workspace) pageMsg page
                                |> mapPage SchemaPage SchemaMsg workspace

                        _ ->
                            ( workspace, [] )
                )

        MembersMsg pageMsg ->
            withPage model
                (\workspace ->
                    case workspace.page of
                        MembersPage page ->
                            Members.update (context workspace) pageMsg page
                                |> mapPage MembersPage MembersMsg workspace

                        _ ->
                            ( workspace, [] )
                )


{-| 一覧の検索は**手が止まってから引く**。打つ度に投げると、1 文字ごとに問い合わせが
飛び、画面が描き直されて入力欄の焦点が外れる（実際に外れた）。

待つのは親が持つ（ページに時間の effect を持たせると、テストから見えなくなる）。

-}
searchDebounce : Entries.Msg -> Entries.Model -> Effect Msg
searchDebounce pageMsg page =
    case pageMsg of
        Entries.SearchTyped _ ->
            -- 打った回数を持たせる。**その番号が今と同じ時だけ引く**
            -- （Elm はタイマーを取り消せないので、古い物は自分で捨てる）。
            Effect.After 300 (EntriesMsg (Entries.SearchFired (Entries.typedAt page)))

        _ ->
            Effect.none


{-| ⌘K。選んだらそのページへ飛ぶ。入力ごとに型の数だけ検索を投げる。
-}
paletteUpdate : Palette.Msg -> ModelWith key -> ( ModelWith key, Effect Msg )
paletteUpdate paletteMsg model =
    let
        palette : Palette.Model
        palette =
            Palette.update paletteMsg model.palette

        withPalette : ModelWith key
        withPalette =
            { model | palette = palette }
    in
    case ( paletteMsg, model.phase ) of
        ( Palette.Opened, _ ) ->
            -- **開いたら入力に focus を当てる。** autofocus は Elm が要素を作り直す時に効かない。
            ( withPalette, Effect.Focus Palette.inputId )

        ( Palette.Chosen item, _ ) ->
            ( withPalette, Effect.PushRoute (Route.toString item.route) )

        ( Palette.Confirmed, Ready workspace ) ->
            -- Enter で今選んでいる物へ飛ぶ。**選べる物が無くても閉じる**（開いたままにしない）。
            let
                closed : ModelWith key
                closed =
                    { model | palette = Palette.update Palette.Closed model.palette }
            in
            case Palette.pickedItem (context workspace).project workspace.types model.palette of
                Just item ->
                    ( closed, Effect.PushRoute (Route.toString item.route) )

                Nothing ->
                    ( closed, Effect.none )

        ( Palette.Typed query, Ready workspace ) ->
            sendAll
                (List.map (Api.mapCall PaletteMsg)
                    (Palette.searchCalls (context workspace).project workspace.types query)
                )
                withPalette

        _ ->
            ( withPalette, Effect.none )


{-| エディタの更新。

**自動保存はしない**（保存は人が「下書き保存」を押した時だけ）。代わりに、未保存が
あるかを毎回 JS へ知らせ、画面を閉じようとした時に警告を出させる。

-}
editorUpdate : Editor.Msg -> ModelWith key -> ( ModelWith key, Effect Msg )
editorUpdate pageMsg model =
    case model.phase of
        Ready workspace ->
            case workspace.page of
                EditorPage page ->
                    let
                        ( updated, calls ) =
                            Editor.update { project = (context workspace).project, types = workspace.types } pageMsg page

                        ( next, upload ) =
                            Editor.takeRichUpload updated

                        ( sent, effect ) =
                            sendAll (List.map (Api.mapCall EditorMsg) calls)
                                { model | phase = Ready { workspace | page = EditorPage next } }
                    in
                    ( sent
                    , Effect.batch
                        [ effect
                        , Effect.SetUnsaved (Editor.unsaved next)
                        , scheduleToday pageMsg next

                        -- 本文に貼られた画像。メディアの画面と同じ道（署名付き URL に PUT）。
                        , case upload of
                            Just chosen ->
                                Effect.Upload
                                    (E.object
                                        [ ( "assetId", E.string chosen.assetId )
                                        , ( "url", E.string chosen.uploadUrl )
                                        , ( "inputId", E.string Editor.richInputId )
                                        ]
                                    )

                            Nothing ->
                                Effect.none
                        ]
                    )

                _ ->
                    ( model, Effect.none )

        _ ->
            ( model, Effect.none )


{-| 予約の日付を選ぶ所は、開いた時に「今日」から始める。

今日が何日かはページからは分からない（ページは `Api.Call` しか返せない）ので、
親が `Effect.Today` を出して返す。

-}
scheduleToday : Editor.Msg -> Editor.Model -> Effect Msg
scheduleToday pageMsg page =
    case ( pageMsg, page.schedulingOpen ) of
        ( Editor.ScheduleOpened, True ) ->
            editorToday

        _ ->
            Effect.none


{-| 今日と、手元のタイムゾーン。

WhyNot: 予約を開いた時だけでは足りない。予約の一覧は開く前から出ていて、
タイムゾーンが分からないと UTC のまま出てしまう。

-}
editorToday : Effect Msg
editorToday =
    Effect.Today (\zone year month day -> EditorMsg (Editor.TodayKnown zone year month day))


withEditorToday : ( ModelWith key, Effect Msg ) -> ( ModelWith key, Effect Msg )
withEditorToday ( model, effect ) =
    ( model, Effect.batch [ effect, editorToday ] )


{-| ページが投げたい物を、親が id を振って送る形に直す。

ページは通信の id を持たない（持たせると採番を配る事になる）。

-}
mapPage :
    (pageModel -> Page)
    -> (pageMsg -> Msg)
    -> Workspace
    -> ( pageModel, List (Api.Call pageMsg) )
    -> ( Workspace, List (Api.Call Msg) )
mapPage toPage toMsg workspace ( pageModel, calls ) =
    ( { workspace | page = toPage pageModel }, List.map (Api.mapCall toMsg) calls )


context : Workspace -> { project : Slug }
context workspace =
    { project = workspace.project |> Maybe.map .slug |> Maybe.withDefault "default" }


{-| API プレビューの引き出しを開く。**今の型で開く**（どの API を見ているかは URL が持つ）。
-}
openPreview : Maybe { entryId : String, draft : Bool } -> ModelWith key -> ( ModelWith key, Effect Msg )
openPreview one model =
    case typeApiIdOf model.route of
        Just apiId ->
            let
                slug : Slug
                slug =
                    projectSlugOf model
            in
            sendAll (List.map (Api.mapCall PreviewMsg) (Preview.load slug apiId))
                { model | preview = Just (Preview.init slug apiId one) }

        Nothing ->
            ( model, Effect.none )


{-| 今どの型の画面にいるか。引き出しはその型の API を見せる。
-}
typeApiIdOf : Route -> Maybe String
typeApiIdOf route =
    case route of
        Route.Entries _ apiId _ ->
            Just apiId

        Route.Board _ apiId ->
            Just apiId

        Route.Entry _ apiId _ ->
            Just apiId

        Route.NewEntry _ apiId ->
            Just apiId

        _ ->
            Nothing


{-| 今のプロジェクト slug。引き出しのように Workspace を持たない所から使う。
-}
projectSlugOf : ModelWith key -> Slug
projectSlugOf model =
    case model.phase of
        Ready workspace ->
            context workspace |> .project

        _ ->
            Route.projectOf model.route |> Maybe.withDefault "default"


withPage : ModelWith key -> (Workspace -> ( Workspace, List (Api.Call Msg) )) -> ( ModelWith key, Effect Msg )
withPage model change =
    case model.phase of
        Ready workspace ->
            let
                ( next, calls ) =
                    change workspace
            in
            sendAll calls { model | phase = Ready next }

        _ ->
            ( model, Effect.none )


updateWorkspace : (Workspace -> Workspace) -> ModelWith key -> ModelWith key
updateWorkspace change model =
    case model.phase of
        Ready workspace ->
            { model | phase = Ready (change workspace) }

        _ ->
            model


failureOf : Api.Problem -> Phase
failureOf problem =
    case problem of
        Api.Failed errors ->
            if List.any Error.isAuthProblem errors then
                SignedOut

            else
                Broken (Api.problemToText problem)

        _ ->
            Broken (Api.problemToText problem)


{-| me が返ってきた。プロジェクトに入っていない人はそこで止める。
-}
gotPerson : Person -> ModelWith key -> ( ModelWith key, Effect Msg )
gotPerson person model =
    if List.isEmpty person.projects then
        ( { model | phase = NotMember { email = person.email } }, Effect.none )

    else
        let
            project : Maybe Project
            project =
                pickProject model.route person

            workspace : Workspace
            workspace =
                { person = person
                , project = project
                , permissions = []
                , types = []
                , origin = model.origin
                , page = Placeholder ""
                }

            ( withViewer, viewerEffect ) =
                case project of
                    Just chosen ->
                        { model | phase = Ready workspace }
                            |> send (Api.call (\id -> Queries.viewer id chosen.slug) GotViewer)

                    Nothing ->
                        ( { model | phase = Ready workspace }, Effect.none )

            ( withTypes, typesEffect ) =
                case project of
                    Just chosen ->
                        withViewer |> send (Api.call (\id -> Queries.contentTypes id chosen.slug) GotTypes)

                    Nothing ->
                        ( withViewer, Effect.none )

            ( final, routeEffect ) =
                enterRoute model.route withTypes
        in
        ( final, Effect.batch [ viewerEffect, typesEffect, routeEffect ] )


{-| URL のプロジェクトを優先し、無ければ最初の 1 つ。
-}
pickProject : Route -> Person -> Maybe Project
pickProject route person =
    case Route.projectOf route of
        Just slug ->
            person.projects
                |> List.filter (\project -> project.slug == slug)
                |> List.head
                |> Maybe.withDefault (List.head person.projects |> Maybe.withDefault emptyProject)
                |> Just

        Nothing ->
            List.head person.projects


emptyProject : Project
emptyProject =
    { id = "", slug = "", name = "", visibility = "PUBLIC", role = "" }


{-| URL が変わった時にページを作る。

**同じ画面の中で絞り込みだけ変わった時は作り直さない。** 一覧は絞り込みを URL に
書き戻すので、作り直すと入力欄が作り替わって焦点が外れ、引き直しも走って
画面がちらつく（実際に、検索の 1 文字ごとに外れた）。

-}
enterRoute : Route -> ModelWith key -> ( ModelWith key, Effect Msg )
enterRoute route model =
    if staysOnPage model route then
        ( { model | route = route }, Effect.none )

    else
        enterNewRoute route model


{-| 同じ画面のままか。**今その画面が出ている事まで見る**（route だけを比べると、
最初に開いた時にページが作られない）。今は一覧だけ（絞り込みを URL に持つのがここだけ）。
-}
staysOnPage : ModelWith key -> Route -> Bool
staysOnPage model to =
    case ( model.phase, model.route, to ) of
        ( Ready workspace, Route.Entries fromProject fromApiId _, Route.Entries toProject toApiId _ ) ->
            case workspace.page of
                EntriesPage _ ->
                    fromProject == toProject && fromApiId == toApiId

                _ ->
                    False

        _ ->
            False


enterNewRoute : Route -> ModelWith key -> ( ModelWith key, Effect Msg )
enterNewRoute route model =
    if movesProject model route then
        -- **別のプロジェクトへは読み込み直す。** 中で切り替えると、今のプロジェクトの
        -- 型や権限を持ったまま別のプロジェクトの URL を開く事になり、
        -- 問い合わせが古いプロジェクトへ飛ぶ。
        ( model, Effect.LoadUrl (Route.toString route) )

    else
        enterPage route model


{-| 今いるプロジェクトと違うプロジェクトの URL か。
-}
movesProject : ModelWith key -> Route -> Bool
movesProject model route =
    case ( model.phase, Route.projectOf route ) of
        ( Ready workspace, Just wanted ) ->
            (workspace.project |> Maybe.map .slug) /= Just wanted

        _ ->
            False


enterPage : Route -> ModelWith key -> ( ModelWith key, Effect Msg )
enterPage route model =
    case model.phase of
        Ready workspace ->
            let
                slug : Slug
                slug =
                    workspace.project |> Maybe.map .slug |> Maybe.withDefault "default"
            in
            case route of
                Route.Home ->
                    -- 最初の API の一覧へ送る。API が無ければプロジェクト選択へ。
                    case List.head workspace.types of
                        Just first ->
                            ( { model | route = route }, Effect.ReplaceRoute (Route.toString (Route.Entries slug first.apiId [])) )

                        Nothing ->
                            { model | route = route, phase = Ready { workspace | page = ProjectsPage (Projects.init workspace.person) } }
                                |> sendAll (List.map (Api.mapCall ProjectsMsg) (Projects.load workspace.person))

                Route.Projects ->
                    { model | route = route, phase = Ready { workspace | page = ProjectsPage (Projects.init workspace.person) } }
                        |> sendAll (List.map (Api.mapCall ProjectsMsg) (Projects.load workspace.person))

                -- **プロジェクトの入口は最初の API へ送る。**
                -- 「画面がありません」を出しても、人は何をすればいいか分からない。
                Route.ProjectHome _ ->
                    case List.head workspace.types of
                        Just firstType ->
                            ( { model | route = route }
                            , Effect.ReplaceRoute (Route.toString (Route.Entries slug firstType.apiId []))
                            )

                        Nothing ->
                            ( { model | route = route, phase = Ready { workspace | page = SchemaPage (Schema.init slug "new") } }, Effect.none )

                Route.Entries _ apiId params ->
                    { model | route = route, phase = Ready { workspace | page = EntriesPage (Entries.init slug apiId params) } }
                        |> sendAll (List.map (Api.mapCall EntriesMsg) (Entries.load slug apiId))

                Route.Board _ apiId ->
                    { model | route = route, phase = Ready { workspace | page = BoardPage (Board.init slug apiId) } }
                        |> sendAll (List.map (Api.mapCall BoardMsg) (Board.load slug apiId))

                Route.NewEntry _ apiId ->
                    { model | route = route, phase = Ready { workspace | page = EditorPage (Editor.init slug apiId Nothing) } }
                        |> sendAll (List.map (Api.mapCall EditorMsg) (Editor.load slug apiId Nothing))
                        |> withEditorToday

                Route.Entry _ apiId entryId ->
                    { model | route = route, phase = Ready { workspace | page = EditorPage (Editor.init slug apiId (Just entryId)) } }
                        |> sendAll (List.map (Api.mapCall EditorMsg) (Editor.load slug apiId (Just entryId)))
                        |> withEditorToday

                Route.TypeSettings _ apiId ->
                    { model | route = route, phase = Ready { workspace | page = TypeSettingsPage (TypeSettings.init slug apiId) } }
                        |> sendAll (List.map (Api.mapCall TypeSettingsMsg) (TypeSettings.load slug apiId))

                Route.TypeSchema _ apiId ->
                    { model | route = route, phase = Ready { workspace | page = SchemaPage (Schema.init slug apiId) } }
                        |> sendAll (List.map (Api.mapCall SchemaMsg) (Schema.load slug apiId))

                Route.Account ->
                    { model | route = route, phase = Ready { workspace | page = AccountPage (Account.init workspace.person) } }
                        |> sendAll (List.map (Api.mapCall AccountMsg) Account.load)

                Route.AccountTokens ->
                    { model | route = route, phase = Ready { workspace | page = AccountPage (Account.init workspace.person) } }
                        |> sendAll (List.map (Api.mapCall AccountMsg) Account.load)

                Route.Settings _ Route.ProjectSettings ->
                    ( { model
                        | route = route
                        , phase =
                            Ready
                                { workspace
                                    | page =
                                        ProjectPage
                                            (ProjectPage.init (workspace.project |> Maybe.withDefault emptyProject))
                                }
                      }
                    , Effect.none
                    )

                Route.Media _ ->
                    { model | route = route, phase = Ready { workspace | page = MediaPage Media.init } }
                        |> sendAll (List.map (Api.mapCall MediaMsg) (Media.load slug))

                Route.Settings _ Route.ApiKeys ->
                    { model | route = route, phase = Ready { workspace | page = KeysPage Keys.init } }
                        |> sendAll (List.map (Api.mapCall KeysMsg) (Keys.load slug))

                Route.Settings _ Route.Webhooks ->
                    { model | route = route, phase = Ready { workspace | page = KeysPage Keys.init } }
                        |> sendAll (List.map (Api.mapCall KeysMsg) (Keys.load slug))

                Route.Settings _ Route.Members ->
                    { model | route = route, phase = Ready { workspace | page = MembersPage Members.init } }
                        |> loadMembers slug

                _ ->
                    ( { model | route = route, phase = Ready { workspace | page = Placeholder (Route.toString route) } }, Effect.none )

        _ ->
            ( { model | route = route }, Effect.none )


loadMembers : Slug -> ModelWith key -> ( ModelWith key, Effect Msg )
loadMembers slug model =
    sendAll (List.map (Api.mapCall MembersMsg) (Members.load slug)) model



-- 応答を配る


dispatch : D.Value -> ModelWith key -> ( ModelWith key, Effect Msg )
dispatch raw model =
    case D.decodeValue Api.responseDecoder raw of
        Ok response ->
            case Dict.get response.id model.waiting of
                Just handler ->
                    update (handler response) { model | waiting = Dict.remove response.id model.waiting }

                Nothing ->
                    ( model, Effect.none )

        Err err ->
            ( { model | phase = Broken { message = D.errorToString err, requestId = Nothing } }, Effect.none )


subscriptions : ModelWith key -> Sub Msg
subscriptions model =
    Sub.batch
        [ apiResponse_Api_ELM GotApiResponse
        , uploadFinished_Media_ELM UploadFinished
        , Browser.Events.onKeyDown (keyDecoder (Palette.isOpen model.palette))
        ]


{-| キーの受け口。**検索が開いている間は上下と Enter も拾う**（画面のどこに focus が
あっても効くように、要素ではなく画面で拾う）。
-}
keyDecoder : Bool -> D.Decoder Msg
keyDecoder paletteOpen =
    D.map3 (\key meta ctrl -> ( key, meta || ctrl ))
        (D.field "key" D.string)
        (D.field "metaKey" D.bool)
        (D.field "ctrlKey" D.bool)
        |> D.andThen
            (\( key, modified ) ->
                if key == "k" && modified then
                    D.succeed (KeyPressed "k")

                else if (key == "s" || key == "S") && modified then
                    -- **⌘S で下書き保存**（書き物の画面の当たり前。既定の「ページを保存」は
                    -- JS 側の capture で止める。Elm からは preventDefault できない）。
                    D.succeed (EditorMsg Editor.SaveWanted)

                else if key == "Escape" then
                    D.succeed (KeyPressed "Escape")

                else if not paletteOpen then
                    D.fail "見ない"

                else
                    case key of
                        "ArrowDown" ->
                            D.succeed (PaletteMsg (Palette.Moved 1))

                        "ArrowUp" ->
                            D.succeed (PaletteMsg (Palette.Moved -1))

                        "Enter" ->
                            D.succeed (PaletteMsg Palette.Confirmed)

                        _ ->
                            D.fail "見ない"
            )


uploadResultDecoder : D.Decoder { assetId : String, ok : Bool }
uploadResultDecoder =
    D.map2 (\assetId ok -> { assetId = assetId, ok = ok })
        (D.field "assetId" D.string)
        (D.field "ok" D.bool)



-- VIEW


view : ModelWith key -> Browser.Document Msg
view model =
    { title = "CMS"
    , body =
        [ case model.phase of
            Loading ->
                View.loading

            NotMember { email } ->
                View.notMember { email = email, onReload = ReloadClicked }

            SignedOut ->
                View.signedOut { onReload = ReloadClicked }

            Broken failure ->
                View.broken failure

            Ready workspace ->
                Shell.view
                    { person = workspace.person
                    , projects = workspace.person.projects
                    , project = workspace.project
                    , permissions = workspace.permissions
                    , types = workspace.types
                    , route = model.route
                    , toast = model.toast
                    , menu = model.menu
                    , collapsed = model.sidebarCollapsed
                    , breadcrumb = breadcrumbOf workspace model.route
                    , onMenu = MenuToggled
                    , onToggleSidebar = SidebarToggled
                    , theme = model.theme
                    , onTheme = ThemeChosen
                    , onCloseToast = ToastClosed
                    , onOpenSearch = PaletteMsg Palette.Opened
                    }
                    (pageView workspace)
                    (Palette.view (context workspace).project workspace.types model.palette |> Html.map PaletteMsg)
        , -- API プレビューの引き出し。ページの上に重ねる（ページは閉じない）。
          case model.preview of
            Just page ->
                Preview.view page |> Html.map PreviewMsg

            Nothing ->
                Html.text ""
        ]
    }


{-| パンくず。最後の 1 つは今いる場所（リンクにしない）。
-}
breadcrumbOf : Workspace -> Route -> List ( String, Maybe Route )
breadcrumbOf workspace route =
    let
        slug : Slug
        slug =
            workspace.project |> Maybe.map .slug |> Maybe.withDefault "default"

        typeName : String -> String
        typeName apiId =
            workspace.types
                |> List.filter (\summary -> summary.apiId == apiId)
                |> List.head
                |> Maybe.map .name
                |> Maybe.withDefault apiId

        ofType : String -> ( String, Maybe Route )
        ofType apiId =
            ( typeName apiId, Just (Route.Entries slug apiId []) )
    in
    case route of
        Route.Entries _ apiId _ ->
            [ ( typeName apiId, Nothing ) ]

        Route.Board _ apiId ->
            [ ofType apiId, ( "ボード", Nothing ) ]

        Route.TypeSchema _ apiId ->
            [ ofType apiId, ( "API スキーマ", Nothing ) ]

        Route.TypeSettings _ apiId ->
            [ ofType apiId, ( "API 設定", Nothing ) ]

        Route.NewEntry _ apiId ->
            [ ofType apiId, ( "新規", Nothing ) ]

        Route.Entry _ apiId _ ->
            [ ofType apiId, ( entryTitle workspace, Nothing ) ]

        Route.Media _ ->
            [ ( "メディア", Nothing ) ]

        Route.Settings _ tab ->
            [ ( "プロジェクト設定", Just (Route.Settings slug Route.Members) ), ( settingsName tab, Nothing ) ]

        Route.Account ->
            [ ( "自分", Nothing ) ]

        Route.AccountTokens ->
            [ ( "自分", Just Route.Account ), ( "Personal Access Token", Nothing ) ]

        _ ->
            []


{-| 今開いているコンテンツの見出し。エディタのパンくずに出す。
-}
entryTitle : Workspace -> String
entryTitle workspace =
    case workspace.page of
        EditorPage page ->
            Editor.title page

        _ ->
            ""


settingsName : Route.SettingsTab -> String
settingsName tab =
    case tab of
        Route.Members ->
            "メンバー"

        Route.ApiKeys ->
            "API キーと Webhook"

        Route.Webhooks ->
            "API キーと Webhook"

        Route.Workflow ->
            "ワークフロー"

        Route.ProjectSettings ->
            "プロジェクトと MCP"


pageView : Workspace -> Html Msg
pageView workspace =
    case workspace.page of
        ProjectsPage page ->
            Projects.view page |> Html.map ProjectsMsg

        MembersPage page ->
            Members.view { canManage = Permission.has Permission.ManageMembers workspace.permissions } page
                |> Html.map MembersMsg

        EntriesPage page ->
            Entries.view page |> Html.map EntriesMsg

        BoardPage page ->
            Board.view page |> Html.map BoardMsg

        KeysPage page ->
            Keys.view page |> Html.map KeysMsg

        MediaPage page ->
            Media.view page |> Html.map MediaMsg

        AccountPage page ->
            Account.view page |> Html.map AccountMsg

        ProjectPage page ->
            ProjectPage.view
                { project = workspace.project |> Maybe.withDefault emptyProject
                , origin = workspace.origin
                }
                page
                |> Html.map ProjectMsg

        EditorPage page ->
            Editor.view { types = workspace.types } page |> Html.map EditorMsg

        TypeSettingsPage page ->
            TypeSettings.view { canManage = Permission.has Permission.ManageTypes workspace.permissions } page
                |> Html.map TypeSettingsMsg

        SchemaPage page ->
            Schema.view
                { canManage = Permission.has Permission.ManageTypes workspace.permissions
                , types = workspace.types
                }
                page
                |> Html.map SchemaMsg

        Placeholder url ->
            View.placeholder url
