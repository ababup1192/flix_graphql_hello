module Shell exposing (Menu(..), view)

{-| 中に入った後の枠。上のバー・サイドバー・中身。

**サイドバーと設定は `viewer.permissions` で出し分ける**（役割では判定しない。
役割と権限の対応は CMS の Datalog が持っていて、画面が写しを持つと二重管理になる）。

-}

import Api.Permission as Permission exposing (Permission)
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, href)
import Html.Events
import Model exposing (ContentTypeSummary, Person, Project)
import Route exposing (Route)
import Svg
import Ui
import Ui.Icon as Icon


type alias Config msg =
    { person : Person
    , projects : List Project
    , menu : Menu
    , collapsed : Bool
    , onMenu : Menu -> msg
    , onToggleSidebar : msg
    , theme : String
    , onTheme : String -> msg
    , breadcrumb : List ( String, Maybe Route )
    , project : Maybe Project
    , permissions : List Permission
    , types : List ContentTypeSummary
    , route : Route
    , toast : Maybe String
    , onCloseToast : msg
    , onOpenSearch : msg
    }


{-| 上のバーの開いているメニュー。**1 つだけ開く。**

プロジェクトのメニューは絞り込みの文字を持つ。
WhyNot: 絞り込みの文字を Shell の外の Model に別の欄で持たない。開いていない時にも
残り続け、次に開いた時に前の文字で絞られた状態から始まる。

-}
type Menu
    = NoMenu
    | ProjectMenu String
    | SelfMenu


view : Config msg -> Html msg -> Html msg -> Html msg
view config content palette =
    div [ class "flex h-screen flex-col bg-app text-ink" ]
        [ topBar config
        , div [ class "flex min-h-0 flex-1" ]
            [ sidebar config
            , div [ class "mx-auto flex min-h-0 w-full max-w-[1200px] flex-1 flex-col overflow-auto px-8" ]
                [ viewBreadcrumb config, viewTypeTabs config, viewSettingsTabs config, content ]
            ]
        , palette
        , case config.toast of
            Just message ->
                Ui.toast config.onCloseToast message

            Nothing ->
                text ""
        ]


{-| パンくず。今どこにいるかを 1 行で出す。
-}
viewBreadcrumb : Config msg -> Html msg
viewBreadcrumb config =
    if List.length config.breadcrumb < 2 then
        text ""

    else
        div [ class "flex items-center gap-1.5 pt-4 text-xs text-ink-soft" ]
            (config.breadcrumb
                |> List.map
                    (\( label, route ) ->
                        case route of
                            Just target ->
                                Ui.quietLink [ href (Route.toString target), class "max-w-60 truncate", Html.Attributes.title label ] [ text label ]

                            Nothing ->
                                span [ class "max-w-60 truncate text-ink", Html.Attributes.title label ] [ text label ]
                    )
                |> List.intersperse (span [ class "text-ink-faint" ] [ text "›" ])
            )


{-| 型の画面のタブ。型に関わる物を 1 か所に畳む（仕様 6.1）。
-}
viewTypeTabs : Config msg -> Html msg
viewTypeTabs config =
    case typeApiIdOf config.route of
        Just apiId ->
            let
                slug : String
                slug =
                    slugOf config

                tab : String -> Route -> { label : String, url : String, on : Bool }
                tab label route =
                    { label = label
                    , url = Route.toString route
                    , on = Route.toString config.route == Route.toString route
                    }
            in
            div [ class "pt-3" ]
                [ Ui.tabs
                    ([ tab "コンテンツ一覧" (Route.Entries slug apiId [])
                     , tab "ボード" (Route.Board slug apiId)
                     ]
                        ++ (if Permission.has Permission.ManageTypes config.permissions then
                                [ tab "API スキーマ" (Route.TypeSchema slug apiId)
                                , tab "API 設定" (Route.TypeSettings slug apiId)
                                ]

                            else
                                []
                           )
                    )
                ]

        Nothing ->
            text ""


{-| プロジェクト設定のタブ。メンバー / API キーと Webhook / プロジェクトと MCP を並べる。

型の画面のタブと同じ部品。ここが無いと、API キーの画面には ⌘K か URL の直打ちでしか着けない
（Contentful の Settings メニュー、GitHub の設定の左の一覧に当たる物）。

-}
viewSettingsTabs : Config msg -> Html msg
viewSettingsTabs config =
    case config.route of
        Route.Settings _ current ->
            let
                slug : String
                slug =
                    slugOf config

                tab : String -> Route.SettingsTab -> { label : String, url : String, on : Bool }
                tab label target =
                    { label = label
                    , url = Route.toString (Route.Settings slug target)
                    , on = sameSettings current target
                    }
            in
            div [ class "pt-3" ]
                [ Ui.tabs
                    (List.concat
                        [ if Permission.has Permission.ManageMembers config.permissions then
                            [ tab "メンバー" Route.Members ]

                          else
                            []
                        , if Permission.has Permission.ManageApiKeys config.permissions then
                            [ tab "API キーと Webhook" Route.ApiKeys ]

                          else
                            []
                        , if Permission.has Permission.ManageProject config.permissions then
                            [ tab "プロジェクトと MCP" Route.ProjectSettings ]

                          else
                            []
                        ]
                    )
                ]

        _ ->
            text ""


{-| API キーと Webhook は同じ画面。
-}
sameSettings : Route.SettingsTab -> Route.SettingsTab -> Bool
sameSettings current target =
    current == target || (current == Route.Webhooks && target == Route.ApiKeys)


{-| 型の画面か。エディタと新規作成では出さない（そこは 1 件の話なので）。
-}
typeApiIdOf : Route -> Maybe String
typeApiIdOf route =
    case route of
        Route.Entries _ apiId _ ->
            Just apiId

        Route.Board _ apiId ->
            Just apiId

        Route.TypeSchema _ apiId ->
            if apiId == "new" then
                Nothing

            else
                Just apiId

        Route.TypeSettings _ apiId ->
            Just apiId

        _ ->
            Nothing


{-| 上のバー。**左に居場所、中央に検索、右に自分。**

**検索を中央に置く。** Contentful / Sanity / Strapi / GitHub が揃ってここに置いていて、
右端に寄せると自分のメニューと並んで「設定の一種」に見える。検索は画面のどこからでも
使う物なので、左右のどちらの持ち物でもない場所に出す。

3 列の格子にして、真ん中の列を中央に置く。**絶対位置で中央に置かない**（狭い画面で
プロジェクト名の上に重なる。格子なら重ならずに左右が縮む）。

真ん中の列は `minmax(0, 18rem)`。**上限だけ決めて、狭ければ縮む。**
`w-72` を欄に直に置くと 390 幅で 18rem が譲らず、プロジェクト名の上に乗った。

-}
topBar : Config msg -> Html msg
topBar config =
    div [ class "relative grid h-12 shrink-0 grid-cols-[minmax(min-content,1fr)_minmax(0,18rem)_minmax(min-content,1fr)] items-center gap-2.5 border-b border-edge bg-panel px-3" ]
        [ -- メニューの外を押したら閉じる。開いている間だけ敷く。
          if config.menu == NoMenu then
            text ""

          else
            Ui.dismissLayer (config.onMenu NoMenu)
        , div [ class "flex min-w-0 items-center gap-2.5" ]
            [ Html.button
                [ class "flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-ink-soft hover:bg-well"
                , Html.Events.onClick config.onToggleSidebar
                , Html.Attributes.title "サイドバーを畳む"
                ]
                [ Icon.view Icon.panel ]
            , Html.button
                [ class "flex min-w-0 items-center gap-2 rounded-md bg-well px-2.5 py-1.5 text-[13px] font-semibold text-ink hover:bg-edge"
                , Html.Events.onClick (config.onMenu (toggledProjectMenu config.menu))
                ]
                [ viewProjectMark config.project
                , span [ class "max-w-40 truncate", Html.Attributes.title (projectName config) ] [ text (projectName config) ]
                , Icon.view Icon.caret
                ]
            , case config.menu of
                ProjectMenu query ->
                    viewProjectMenu config query

                _ ->
                    text ""
            ]
        , Html.button
            [ class "flex w-full min-w-0 items-center gap-2 rounded-md border border-edge bg-raised px-2.5 py-1.5 text-left text-xs text-ink-faint hover:border-ink-faint"
            , Html.Events.onClick config.onOpenSearch
            , Html.Attributes.title "API・コンテンツ・メディア・設定を検索"
            ]
            -- **狭い画面では虫眼鏡だけ残す。** 文字と ⌘K を残すと 18rem が譲らず、
            -- プロジェクト名の上に乗る（390 幅で乗った）。
            [ span [ class "shrink-0" ] [ Icon.view Icon.search ]
            , span [ class "hidden truncate sm:inline" ] [ text "API・コンテンツ・メディア・設定を検索" ]
            , span [ class "ml-auto hidden shrink-0 rounded border border-edge px-1 py-0.5 text-[10px] sm:inline" ] [ text "⌘K" ]
            ]
        , div [ class "flex min-w-0 items-center justify-end gap-2.5" ]
            [ Html.button
                [ class "flex min-w-0 items-center gap-2 text-xs text-ink-soft"
                , Html.Events.onClick (config.onMenu (toggleMenu SelfMenu config.menu))
                ]
                [ span [ class "truncate" ] [ text config.person.email ], Ui.avatar config.person.email ]
            , if config.menu == SelfMenu then
                viewSelfMenu config

              else
                text ""
            ]
        ]


toggleMenu : Menu -> Menu -> Menu
toggleMenu wanted current =
    if wanted == current then
        NoMenu

    else
        wanted


toggledProjectMenu : Menu -> Menu
toggledProjectMenu current =
    case current of
        ProjectMenu _ ->
            NoMenu

        _ ->
            ProjectMenu ""


viewProjectMark : Maybe Project -> Html msg
viewProjectMark project =
    case project of
        Just chosen ->
            Ui.initialMark { seed = chosen.id, label = chosen.name }

        Nothing ->
            span [ class "h-5 w-5 shrink-0 rounded bg-edge" ] []


{-| プロジェクトの切り替え。**1 つしか無くても出す。**

WhyNot: 1 つの時に隠さない。2 つ目を作った瞬間に上のバーの形が変わって、
覚えた位置が壊れる。このボタンは切り替えだけでなく「今どのプロジェクトにいるか」の
表示も兼ねている。

WhyNot: 今いる行に「今ここ」のような文字を置かない。ボタン側に同じ名前が出ていて
冗長で、その行だけ右に文字が生えて幅が揃わず、行の右端は役割やプランを出す席として
空けておきたい。✓ は読ませずに拾える。

-}
viewProjectMenu : Config msg -> String -> Html msg
viewProjectMenu config query =
    let
        shown : List Project
        shown =
            List.filter (matchesQuery query) config.projects
    in
    menuBox "left-10 top-10"
        (viewProjectFilter config query
            :: (if List.isEmpty shown then
                    [ div [ class "px-3 py-3 text-[13px] text-ink-faint" ] [ text "見つかりません" ] ]

                else
                    List.map (viewProjectRow config) shown
               )
            ++ [ menuDivider
               , menuLink (Route.toString Route.Projects) "すべてのプロジェクト"
               , menuLink (Route.toString Route.Projects) "＋ プロジェクトを作る"
               ]
        )


{-| 絞り込みの入力。**8 件以上の時だけ出す。**

WhyNot: 少ない時にも出さない。目で 1 秒で拾える数に打鍵を強いるうえ、
開いた瞬間の 1 行目が入力欄になって、切り替えが 1 手増える。

-}
viewProjectFilter : Config msg -> String -> Html msg
viewProjectFilter config query =
    if List.length config.projects < 8 then
        text ""

    else
        div [ class "px-2 pb-1.5 pt-1" ]
            [ Ui.input
                [ class "w-full"
                , Html.Attributes.value query
                , Html.Attributes.placeholder "プロジェクトを探す"
                , Html.Events.onInput (\typed -> config.onMenu (ProjectMenu typed))
                ]
            ]


matchesQuery : String -> Project -> Bool
matchesQuery query project =
    let
        needle : String
        needle =
            String.toLower (String.trim query)
    in
    String.isEmpty needle
        || String.contains needle (String.toLower project.name)
        || String.contains needle (String.toLower project.slug)


{-| メニューの 1 行。今いるプロジェクトも**押せる**（閉じるだけ）。

WhyNot: 今いる行を `div` にしない。ホバーもカーソルも効かず、その行だけ壊れて見える。

-}
viewProjectRow : Config msg -> Project -> Html msg
viewProjectRow config project =
    if Just project.slug == Maybe.map .slug config.project then
        Html.button
            [ class (menuRowClass ++ " bg-well font-semibold hover:bg-edge")
            , Html.Events.onClick (config.onMenu NoMenu)
            ]
            [ Ui.initialMark { seed = project.id, label = project.name }
            , truncated project.name
            , span [ class "ml-auto text-link" ] [ Icon.view Icon.check ]
            ]

    else
        Html.a
            [ href (Route.toString (Route.ProjectHome project.slug)), class menuRowClass ]
            [ Ui.initialMark { seed = project.id, label = project.name }
            , truncated project.name
            ]


{-| 自分のメニュー。ログアウトは Access のログアウト URL へ（仕様 13.2）。
-}
viewSelfMenu : Config msg -> Html msg
viewSelfMenu config =
    menuBox "right-2.5 top-10"
        [ menuLink (Route.toString Route.Account) "アカウント"
        , menuLink (Route.toString Route.AccountTokens) "Personal Access Token"
        , menuDivider
        , div [ class "px-3 pb-1 pt-1.5 text-[11px] font-semibold text-ink-soft" ] [ text "テーマ" ]
        , div [ class "flex gap-1 px-2 pb-1.5" ]
            (List.map (themeButton config) [ ( "system", "自動" ), ( "light", "ライト" ), ( "dark", "ダーク" ) ])
        , menuDivider
        , menuLink "/cdn-cgi/access/logout" "ログアウト"
        ]


{-| テーマは 3 状態。**自動**はブラウザの設定に従う（属性を付けない）。
-}
themeButton : Config msg -> ( String, String ) -> Html msg
themeButton config ( value, label ) =
    Html.button
        [ class
            ("flex-1 rounded-md px-2 py-1.5 text-[11px] font-medium "
                ++ (if config.theme == value then
                        "bg-well text-link"

                    else
                        "text-ink-soft hover:bg-well"
                   )
            )
        , Html.Events.onClick (config.onTheme value)
        ]
        [ text label ]


menuBox : String -> List (Html msg) -> Html msg
menuBox place children =
    div [ class ("absolute z-(--z-dropdown) flex w-60 flex-col rounded-lg border border-edge bg-panel py-1 shadow-lg " ++ place) ] children


{-| メニューの行の見た目。リンクの行もボタンの行も同じ当たり判定にする。
-}
menuRowClass : String
menuRowClass =
    "flex w-full items-center gap-2 px-3 py-2 text-left text-[13px] text-ink hover:bg-well"


menuLink : String -> String -> Html msg
menuLink url label =
    Html.a [ href url, class menuRowClass ] [ text label ]


menuDivider : Html msg
menuDivider =
    div [ class "my-1 border-t border-edge" ] []


sidebar : Config msg -> Html msg
sidebar config =
    if config.collapsed then
        text ""

    else
        div [ class "flex w-60 shrink-0 flex-col gap-0.5 overflow-auto border-r border-edge bg-raised px-2 py-3" ]
            (sectionLabel "API"
                :: List.map (typeLink config) config.types
                ++ [ if Permission.has Permission.ManageTypes config.permissions then
                        Html.a
                            [ href (Route.toString (Route.TypeSchema (slugOf config) "new"))
                            , class "px-2 py-2 pl-6 text-[13px] text-ink-soft hover:text-ink"
                            ]
                            [ text "+ API を作る" ]

                     else
                        text ""
                   , sectionLabel "その他"
                   , linkWith config (mediaRoute config) "メディア" Icon.media
                   , if Permission.canSeeProjectSettings config.permissions then
                        linkWith config (settingsRoute config) "プロジェクト設定" Icon.project

                     else
                        text ""
                   ]
            )


sectionLabel : String -> Html msg
sectionLabel label =
    span [ class "px-2 pb-1 pt-3 text-[11px] font-semibold tracking-[0.04em] text-ink-faint uppercase" ] [ text label ]


{-| サイドバーの API 1 本。**アイコンは人が選ぶ**（`ContentType.icon`）。
選び直すのは API スキーマの画面。既定は種類で決まる（何件も持つ物か、1 件だけの物か）。
-}
typeLink : Config msg -> ContentTypeSummary -> Html msg
typeLink config summary =
    navRow config
        (Route.Entries (slugOf config) summary.apiId [])
        (Icon.byName summary.icon)
        (truncated summary.name)


mediaRoute : Config msg -> Route
mediaRoute config =
    Route.Media (slugOf config)


settingsRoute : Config msg -> Route
settingsRoute config =
    Route.Settings (slugOf config) Route.Members


projectName : Config msg -> String
projectName config =
    config.project |> Maybe.map .name |> Maybe.withDefault "プロジェクト"


slugOf : Config msg -> String
slugOf config =
    config.project |> Maybe.map .slug |> Maybe.withDefault "default"


{-| アイコン付きの行。アイコンは**文字より薄く**して、名前が読みやすいままにする。
文言が固定の行（「メディア」など）に使う。
-}
linkWith : Config msg -> Route -> String -> List (Svg.Svg msg) -> Html msg
linkWith config route label icon =
    navRow config route icon (text label)


navRow : Config msg -> Route -> List (Svg.Svg msg) -> Html msg -> Html msg
navRow config route icon label =
    let
        on : Bool
        on =
            Route.toString config.route == Route.toString route
    in
    Html.a
        [ href (Route.toString route)
        , class
            ("flex items-center gap-2 rounded-md px-2 py-1.5 text-[13px] "
                ++ (if on then
                        "bg-well font-semibold text-ink"

                    else
                        "text-ink-soft hover:bg-well hover:text-ink"
                   )
            )
        ]
        [ Html.span [ class "text-ink-faint" ] [ Icon.view icon ], label ]


{-| 人が付けた名前。**1 行に切り、`title` に元の名前を入れる。**

人が付ける名前に長さの上限は無く、折り返すとサイドバーが縦に伸びて、
その下の項目が画面外に出る（実際に出た）。

WhyNot: 文言が固定の物（「メディア」のような言葉）には使わない。切れていないのに
カーソルを置くたびツールチップが出て、うるさい。

-}
truncated : String -> Html msg
truncated label =
    span [ class "truncate", Html.Attributes.title label ] [ text label ]
