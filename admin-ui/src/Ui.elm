module Ui exposing
    ( actionLink
    , avatar
    , button
    , callout
    , card
    , checkbox
    , chip
    , codeBlock
    , dangerLink
    , dismissLayer
    , drawer
    , empty
    , errors
    , failedCard
    , field
    , fieldWith
    , gauge
    , ghostButton
    , headRow
    , headRowOf
    , heading
    , initialMark
    , input
    , link
    , loadingCard
    , messageCard
    , note
    , overlay
    , page
    , pageHeader
    , plainLink
    , quietActionLink
    , quietLink
    , railSection
    , railTitle
    , row
    , rowOf
    , scopeBox
    , sectionTitle
    , select
    , spinner
    , subheading
    , table
    , tabs
    , thumb
    , tile
    , titleLink
    , toast
    , toneBad
    , toneNeutral
    , toneOk
    , toneWarn
    )

{-| 画面の部品。

API は `List (Attribute msg) -> List (Html msg) -> Html msg` を基本にして、呼ぶ側が
`class` を足して微調整できるようにする（部品を fork せずに済む）。

見た目のトークンは styles.css の @theme。ここに生の色を書かない。

-}

import Html exposing (Html)
import Html.Attributes as A
import Html.Events as E
import Json.Decode
import Svg
import Svg.Attributes as SvgA
import Ui.Icon as Icon


{-| 主な操作のボタン。色はアクセント（GitHub / Contentful と同じで、黒ではなく青系）。
-}
button : List (Html.Attribute msg) -> List (Html msg) -> Html msg
button attrs =
    Html.button (A.class "inline-flex h-8 items-center gap-1.5 rounded-md bg-accent px-3 text-[13px] font-semibold text-white hover:opacity-90 disabled:opacity-40" :: attrs)


ghostButton : List (Html.Attribute msg) -> List (Html msg) -> Html msg
ghostButton attrs =
    Html.button (A.class "inline-flex h-8 items-center gap-1.5 rounded-md border border-edge bg-panel px-3 text-[13px] font-medium text-ink hover:bg-raised disabled:opacity-40" :: attrs)


{-| リンクの見た目はここだけが持つ。


## 下線

**単独で置くリンク（行・見出し・操作）はホバーで下線、文の中のリンクは最初から下線。**
文の中のリンクは今のところリッチテキストの本文だけで、styles.css の `.tt-body a` が持つ。

WhyNot: 単独のリンクにも常時下線を引かない。表の 1 行 1 行、レールの操作、カードの題が
全部下線になり、画面が線だらけで読めなくなる（一覧は 1 画面に 20 本以上ある）。
WhyNot: 文の中のリンクをホバー待ちにしない。地の文に埋まっていると、色だけでは
リンクがあると気づけない（色を見分けにくい人には手掛かりが無くなる）。


## カーソル

押せる物はすべて指。素の要素に頼らず、部品側でも `cursor-pointer` を当てる。
WhyNot: styles.css の既定だけに頼らない。`Html.a` に `href` を付け忘れると
ブラウザは指を出さないので、リンクに見えて指が出ない所ができる（実際にできた）。


## 危ない操作

**削除・取り下げは塗ったボタンにしない。** 赤い塗りのボタンは押す物として目立ちすぎ、
戻せない操作が画面で一番目を引く物になる。赤いリンクとして置き、確認の枠
（`callout`）の中の「削除する」だけを塗ったボタンにする。

-}
link : List (Html.Attribute msg) -> List (Html msg) -> Html msg
link attrs =
    Html.a (A.class "cursor-pointer text-link hover:underline" :: attrs)


{-| 目立たせないリンク（パンくず・補助の案内）。本文より薄く置き、ホバーで濃くする。
-}
quietLink : List (Html.Attribute msg) -> List (Html msg) -> Html msg
quietLink attrs =
    Html.a (A.class "cursor-pointer text-ink-soft hover:text-ink hover:underline" :: attrs)


{-| 一覧の行やカードの題。**本文の色のまま**置き、ホバーでリンクの色になる。

WhyNot: 題を最初からリンクの色にしない。表の 1 列目が全部青くなると、
どれが今読みたい物かではなく「青い列」として目に入る。

-}
titleLink : List (Html.Attribute msg) -> List (Html msg) -> Html msg
titleLink attrs =
    Html.a (A.class "cursor-pointer text-ink hover:text-link hover:underline" :: attrs)


{-| 見た目を持たないリンク。ボタンやカードを丸ごと包む時に使う。

WhyNot: 包む用途に `link` を使わない。中のボタンの文字まで下線が付く（実際に付いた）。

-}
plainLink : List (Html.Attribute msg) -> List (Html msg) -> Html msg
plainLink attrs =
    Html.a (A.class "cursor-pointer" :: attrs)


{-| リンクに見えるが、行き先ではなく操作を起こす物（面を開く・条件を消す）。
-}
actionLink : List (Html.Attribute msg) -> List (Html msg) -> Html msg
actionLink attrs =
    Html.button (A.class "cursor-pointer text-xs text-link hover:underline" :: A.type_ "button" :: attrs)


{-| 目立たせない操作（かかっている条件を全部消す、など）。
-}
quietActionLink : List (Html.Attribute msg) -> List (Html msg) -> Html msg
quietActionLink attrs =
    Html.button (A.class "cursor-pointer text-xs text-ink-soft hover:text-ink hover:underline" :: A.type_ "button" :: attrs)


{-| 危ない操作（削除・取り下げ・失効）。
-}
dangerActionLink : List (Html.Attribute msg) -> List (Html msg) -> Html msg
dangerActionLink attrs =
    Html.button (A.class "cursor-pointer text-xs text-[color:var(--color-bad)] hover:underline" :: A.type_ "button" :: attrs)


{-| 文字だけの危ない操作。`dangerActionLink` の短い書き方。
-}
dangerLink : msg -> String -> Html msg
dangerLink msg label =
    dangerActionLink [ E.onClick msg ] [ Html.text label ]


card : List (Html.Attribute msg) -> List (Html msg) -> Html msg
card attrs =
    Html.div (A.class "rounded-md border border-edge bg-panel" :: attrs)


heading : String -> Html msg
heading text =
    Html.h1 [ A.class "text-xl font-semibold text-ink" ] [ Html.text text ]


subheading : String -> Html msg
subheading text =
    Html.h2 [ A.class "text-[13px] font-semibold text-ink" ] [ Html.text text ]


note : List (Html msg) -> Html msg
note =
    Html.p [ A.class "text-xs leading-6 text-ink-soft" ]


{-| 残り文字数の丸いゲージ。

**超えてから気づく**のを避けるために、残りが減ると色が変わり、超えると赤くなる
（docs/design/microcms-pain-points.md の「残り文字数が視覚的に分かりづらい」）。

-}
gauge : { used : Int, limit : Int } -> Html msg
gauge args =
    let
        ratio : Float
        ratio =
            if args.limit <= 0 then
                0

            else
                toFloat args.used / toFloat args.limit

        color : String
        color =
            if ratio > 1 then
                "var(--color-bad)"

            else if ratio > 0.9 then
                "var(--color-warn)"

            else
                "var(--color-ok)"

        circumference : Float
        circumference =
            2 * pi * 7

        filled : Float
        filled =
            circumference * min 1 ratio
    in
    Html.span [ A.class "ml-auto flex items-center gap-1.5 text-[11px]", A.style "color" color ]
        [ Svg.svg
            [ SvgA.viewBox "0 0 18 18", SvgA.width "16", SvgA.height "16" ]
            [ Svg.circle
                [ SvgA.cx "9", SvgA.cy "9", SvgA.r "7", SvgA.fill "none", SvgA.stroke "currentColor", SvgA.strokeOpacity "0.2", SvgA.strokeWidth "2.4" ]
                []
            , Svg.circle
                [ SvgA.cx "9"
                , SvgA.cy "9"
                , SvgA.r "7"
                , SvgA.fill "none"
                , SvgA.stroke "currentColor"
                , SvgA.strokeWidth "2.4"
                , SvgA.strokeLinecap "round"
                , SvgA.strokeDasharray (String.fromFloat circumference)
                , SvgA.strokeDashoffset (String.fromFloat (circumference - filled))
                , SvgA.transform "rotate(-90 9 9)"
                ]
                []
            ]
        , Html.text
            (if ratio > 1 then
                String.fromInt (args.used - args.limit) ++ " 字 超過"

             else
                "残り " ++ String.fromInt (args.limit - args.used) ++ " / " ++ String.fromInt args.limit
            )
        ]


{-| 入力欄 1 つ。違反があれば欄の下に赤で出す（サーバの violations をそのまま写す）。
-}
field : { label : String, hint : Maybe String, errors : List String } -> List (Html msg) -> Html msg
field args children =
    fieldWith { label = args.label, hint = args.hint, errors = args.errors, extra = Html.text "" } children


{-| ラベルの行に何か足せる版（残り文字数のゲージなど）。
-}
fieldWith : { label : String, hint : Maybe String, errors : List String, extra : Html msg } -> List (Html msg) -> Html msg
fieldWith args children =
    Html.div [ A.class "flex flex-col gap-2" ]
        (Html.label [ A.class "flex items-center gap-2 text-[13px] font-semibold text-ink" ] [ Html.text args.label, args.extra ]
            :: children
            ++ [ case args.hint of
                    Just hint ->
                        Html.span [ A.class "text-xs text-ink-faint" ] [ Html.text hint ]

                    Nothing ->
                        Html.text ""
               ]
            ++ List.map (\text -> Html.span [ A.class "text-xs text-[color:var(--color-bad)]" ] [ Html.text text ]) args.errors
        )


input : List (Html.Attribute msg) -> Html msg
input attrs =
    Html.input (A.class "h-8 rounded-md border border-edge bg-panel px-3 text-[13px] text-ink outline-none placeholder:text-ink-faint focus:border-accent" :: attrs) []


{-| 選ぶ入力。

WhyNot: 幅を中身任せにしない。`select` は指定が無いと**一番長い option に合わせて伸び**、
選択肢が長い型（並び替え・参照の候補）で画面の外まで出る（実際に出た）。

-}
select : List (Html.Attribute msg) -> List ( String, String ) -> String -> Html msg
select attrs options selected =
    Html.select (A.class "h-8 max-w-56 rounded-md border border-edge bg-panel px-2 text-[13px] text-ink hover:bg-raised" :: attrs)
        (List.map (\( value, label ) -> Html.option [ A.value value, A.selected (value == selected) ] [ Html.text label ]) options)


{-| 状態などの小さな印。**内容の幅に収まる**（grid の中で伸びない）。
-}
chip : String -> String -> Html msg
chip tone text =
    Html.span
        [ A.class ("inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[11px] font-medium whitespace-nowrap " ++ tone) ]
        [ Html.text text ]


avatar : String -> Html msg
avatar text =
    Html.span
        [ A.class "flex h-6 w-6 items-center justify-center rounded-full bg-accent text-[10px] font-semibold text-white" ]
        [ Html.text (String.left 2 text |> String.toUpper) ]


{-| 物の印。頭文字 1 文字を、`seed` から決まる色の四角に載せる。

WhyNot: `avatar` を使い回さない。丸は人、四角は物という並びが崩れると、
上のバーで「今いるプロジェクト」と「自分」が同じ形で並ぶ。
WhyNot: 色を DB の設定にしない。`seed` から決まるので何度出しても同じ色になり、
設定を足すまで全部が同じ色、という間を作らずに済む。

-}
initialMark : { seed : String, label : String } -> Html msg
initialMark args =
    Html.span
        [ A.class ("flex h-5 w-5 shrink-0 items-center justify-center rounded text-[10px] font-semibold text-white " ++ markTone args.seed) ]
        [ Html.text (String.left 1 args.label |> String.toUpper) ]


markTone : String -> String
markTone seed =
    case modBy 8 (String.foldl (\char acc -> modBy 4096 (acc * 31 + Char.toCode char)) 7 seed) of
        0 ->
            "bg-[color:var(--color-mark-1)]"

        1 ->
            "bg-[color:var(--color-mark-2)]"

        2 ->
            "bg-[color:var(--color-mark-3)]"

        3 ->
            "bg-[color:var(--color-mark-4)]"

        4 ->
            "bg-[color:var(--color-mark-5)]"

        5 ->
            "bg-[color:var(--color-mark-6)]"

        6 ->
            "bg-[color:var(--color-mark-7)]"

        _ ->
            "bg-[color:var(--color-mark-8)]"


table : List (Html msg) -> Html msg
table =
    Html.div [ A.class "overflow-hidden rounded-md border border-edge bg-panel" ]


{-| 表の見出し。**1 つずつ包む。**

包まずに `text` を並べると、CSS の grid は続いた文字を 1 つの物として扱い、
見出しが全部くっついて出る（実際にくっついた）。

-}
headRow : List (Html msg) -> Html msg
headRow cells =
    Html.div
        [ A.class ("grid items-center gap-3 border-b border-edge bg-raised px-4 py-2.5 text-xs font-semibold text-ink-soft " ++ rowColumns) ]
        (List.indexedMap (\index cell -> Html.div [ A.class (cellClass index) ] [ cell ]) cells)


row : List (Html msg) -> Html msg
row cells =
    Html.div
        [ A.class ("grid items-center gap-3 border-b border-edge px-4 py-3 text-[13px] text-ink last:border-b-0 hover:bg-raised " ++ rowColumns) ]
        (List.indexedMap (\index cell -> Html.div [ A.class (cellClass index) ] [ cell ]) cells)


{-| 既定の表の列（題 / 状態 / 日時 / 操作）。

WhyNot: 4 列を固定幅のまま狭い画面に出さない。縮むのが `1fr` の題だけになり、
幅 768 で 40px まで潰れて `あ..` しか読めなくなる（実際になった）。狭い時は
日時の列ごと落とす。

-}
rowColumns : String
rowColumns =
    "grid-cols-[minmax(0,1fr)_132px_auto] lg:grid-cols-[minmax(0,1fr)_150px_130px_70px]"


{-| 3 番目（日時）だけ狭い画面で消す。

WhyNot: `visibility` や幅 0 で隠さない。grid の子として残ると列を 1 つ食い、
見出しと中身の並びがずれる。

-}
cellClass : Int -> String
cellClass index =
    if index == 2 then
        "hidden min-w-0 lg:block"

    else
        "min-w-0"


spinner : Html msg
spinner =
    Html.div [ A.class "h-5 w-5 animate-spin rounded-full border-2 border-edge border-t-accent" ] []


empty : String -> Html msg
empty text =
    Html.div [ A.class "px-3 py-6 text-center text-[13px] text-ink-faint" ] [ Html.text text ]


{-| 一時的な知らせ。押して消す。
-}
toast : msg -> String -> Html msg
toast onClose text =
    Html.div
        [ A.class "fixed bottom-5 left-1/2 z-(--z-toast) flex -translate-x-1/2 items-center gap-3 rounded-lg border border-edge bg-panel px-4 py-2.5 text-[13px] text-ink shadow-lg" ]
        [ Html.text text
        , Html.button [ A.class "text-ink-faint", E.onClick onClose ] [ Html.text "✕" ]
        ]


{-| 読み込み中の枠。
-}
loadingCard : Html msg
loadingCard =
    card [ A.class "my-6 flex justify-center p-8" ] [ spinner ]


{-| 「無い」「読めなかった」を伝える枠。
-}
messageCard : String -> List (Html msg) -> Html msg
messageCard title children =
    card [ A.class "my-6 flex flex-col items-center gap-2 p-8 text-center" ]
        (Html.span [ A.class "text-[13px] text-ink" ] [ Html.text title ] :: children)


{-| 画面の中のタブ。**同じ物の別の見方**を並べる（一覧 / ボード / API スキーマ / API 設定）。
-}
tabs : List { label : String, url : String, on : Bool } -> Html msg
tabs items =
    Html.div [ A.class "flex gap-1 border-b border-edge" ]
        (List.map
            (\item ->
                Html.a
                    [ A.href item.url
                    , A.class
                        ("-mb-px border-b-2 px-3 py-2.5 text-[13px] "
                            ++ (if item.on then
                                    "border-ink font-semibold text-ink"

                                else
                                    "border-transparent text-ink-soft hover:border-edge hover:text-ink"
                               )
                        )
                    ]
                    [ Html.text item.label ]
            )
            items
        )


{-| 画面の中の区切り。上に線を引いて、まとまりを分ける。
-}
sectionTitle : String -> Html msg
sectionTitle text =
    Html.h2 [ A.class "border-b border-edge pb-2 text-sm font-semibold text-ink" ] [ Html.text text ]


{-| 画面の外枠。**どの画面も同じ余白**にする（画面ごとに py が違うと、
タブを移った時に見出しの位置が飛ぶ）。幅を絞る画面は `class "max-w-2xl"` を足す。
-}
page : List (Html.Attribute msg) -> List (Html msg) -> Html msg
page attrs =
    Html.div (A.class "flex flex-col gap-5 py-6" :: attrs)


{-| 画面の題の行。`meta` は題のすぐ右（API の名前など）、`actions` は右端に寄る。
-}
pageHeader : { title : String, icon : Maybe ( List Icon.Shape, msg ), meta : List (Html msg), actions : List (Html msg) } -> Html msg
pageHeader args =
    -- 狭い画面では折り返す。題と操作を 1 行に押し込むと、どちらも 1 文字ずつ縦に割れる
    Html.div [ A.class "flex min-h-8 flex-wrap items-center gap-x-3 gap-y-2" ]
        (viewHeaderIcon args.icon
            :: heading args.title
            :: args.meta
            ++ [ Html.div [ A.class "ml-auto flex shrink-0 items-center gap-2" ] args.actions ]
        )


{-| 題の左のアイコン。**押すと選び直せる**（Notion のページの絵文字と同じ）。
選べない人には出さない。
-}
viewHeaderIcon : Maybe ( List Icon.Shape, msg ) -> Html msg
viewHeaderIcon icon =
    case icon of
        Just ( paths, onPick ) ->
            Html.button
                [ A.class "flex h-8 w-8 items-center justify-center rounded-md text-ink-soft hover:bg-well hover:text-ink"
                , A.title "アイコンを選ぶ"
                , E.onClick onPick
                ]
                [ Html.div [ A.class "scale-125" ] [ Icon.view paths ] ]

        Nothing ->
            Html.text ""


{-| 右のレールの小見出し。表の見出しと同じ重さにして、レールが本文と競わないようにする。
-}
railTitle : String -> Html msg
railTitle text =
    Html.span [ A.class "text-xs font-semibold text-ink-soft" ] [ Html.text text ]


{-| レールの中の区切り。上に線を引いて、公開・予約・履歴を分ける。
`trailing` は見出しの行の右端（「予約する」のような、その区切りだけの操作）。
-}
railSection : String -> List (Html msg) -> List (Html msg) -> Html msg
railSection title trailing children =
    Html.div [ A.class "flex flex-col gap-2 border-t border-edge pt-4" ]
        (Html.div [ A.class "flex items-center gap-2" ]
            [ railTitle title, Html.div [ A.class "ml-auto flex items-center gap-2" ] trailing ]
            :: children
        )


{-| 送信に失敗した理由。**欄の下ではなく画面の頭に出す**（どの欄か分からない失敗があるため）。
-}
errors : List String -> Html msg
errors messages =
    if List.isEmpty messages then
        Html.text ""

    else
        Html.div [ A.class "flex flex-col gap-1 rounded-md border border-[color:var(--color-bad)] bg-[color:var(--color-bad-bg)] px-3 py-2" ]
            (List.map (\text -> Html.span [ A.class "text-xs text-[color:var(--color-bad)]" ] [ Html.text text ]) messages)


{-| 読み込みに失敗した枠。文言は画面をまたいで揃える。
-}
failedCard : String -> Html msg
failedCard message =
    messageCard "読み込めませんでした"
        [ Html.span [ A.class "text-xs text-[color:var(--color-bad)]" ] [ Html.text message ] ]


{-| 注意を引く枠（確認・競合・発行した鍵）。`tone` は `toneOk` などを渡す。

枠と背景だけを色で変え、**中の文字は本文の色のまま**にする。色の上に色を重ねると
ダークで沈む（実際に警告の枠の中の説明が読めなくなった）。

-}
callout : String -> List (Html.Attribute msg) -> List (Html msg) -> Html msg
callout tone attrs =
    Html.div (A.class ("flex flex-col gap-3 rounded-md border p-4 text-ink " ++ tone) :: attrs)


{-| 状態の色。chip と callout で同じ物を使う（画面ごとに書くと意味がずれる）。
-}
toneOk : String
toneOk =
    "border-[color:var(--color-ok)] bg-[color:var(--color-ok-bg)] text-[color:var(--color-ok)]"


toneWarn : String
toneWarn =
    "border-[color:var(--color-warn)] bg-[color:var(--color-warn-bg)] text-[color:var(--color-warn)]"


toneBad : String
toneBad =
    "border-[color:var(--color-bad)] bg-[color:var(--color-bad-bg)] text-[color:var(--color-bad)]"


toneNeutral : String
toneNeutral =
    "border-edge bg-well text-ink-soft"


{-| コピーして使う値（鍵・URL・コマンド）。折り返して全部見せる。
-}
codeBlock : List (Html.Attribute msg) -> String -> Html msg
codeBlock attrs value =
    Html.div
        (A.class "rounded-md border border-edge bg-raised px-3 py-2 font-mono text-xs leading-6 break-all text-ink" :: attrs)
        [ Html.text value ]


{-| チェックボックス。ラベルごと押せるようにする（12px の四角だけが的だと押しにくい）。
-}
checkbox : { label : String, checked : Bool, onToggle : msg } -> Html msg
checkbox args =
    Html.label [ A.class "flex h-8 cursor-pointer items-center gap-2 text-[13px] text-ink" ]
        [ Html.input
            [ A.type_ "checkbox"
            , A.class "h-3.5 w-3.5 accent-[color:var(--color-accent)]"
            , A.checked args.checked
            , E.onClick args.onToggle
            ]
            []
        , Html.text args.label
        ]


{-| 権限の 1 つ。**説明を 1 行添える**（名前だけでは何ができるか分からない）。

GitHub の Personal access token の "Select scopes" と同じ形。上位の権限を入れると下位は
自動で入り、外せなくなる（`locked`）。

-}
scopeBox : { label : String, description : String, checked : Bool, locked : Bool, onToggle : msg } -> Html msg
scopeBox args =
    Html.label
        [ A.class
            ("flex items-start gap-2.5 rounded-md px-2 py-1.5 text-[13px] "
                ++ (if args.locked then
                        "cursor-default"

                    else
                        "cursor-pointer hover:bg-well"
                   )
            )
        ]
        [ Html.input
            [ A.type_ "checkbox"
            , A.class "mt-0.5 h-3.5 w-3.5 accent-[color:var(--color-accent)]"
            , A.checked args.checked
            , A.disabled args.locked
            , E.onClick args.onToggle
            ]
            []
        , Html.span [ A.class "flex flex-col gap-0.5" ]
            [ Html.span [ A.class "font-medium text-ink" ] [ Html.text args.label ]
            , Html.span [ A.class "text-[11px] text-ink-soft" ] [ Html.text args.description ]
            ]
        ]


{-| 右から出る引き出し。**画面は閉じない**（今見ていた物の上に重ねる）。

覆いを押すと閉じ、中を押しても閉じない。`onIgnore` は「中を押した」を捨てるための
何もしない Msg（これが無いと、中の入力を押した瞬間に閉じる）。

見出しの行（題と「閉じる」）はここが持つ。中身だけ呼ぶ側が渡す。

-}
drawer :
    { title : String
    , meta : List (Html msg)
    , onClose : msg
    , onIgnore : msg
    }
    -> List (Html msg)
    -> Html msg
drawer args children =
    Html.div
        [ A.class "fixed inset-0 z-(--z-drawer) flex justify-end bg-black/30", E.onClick args.onClose ]
        [ Html.div
            [ A.class "flex h-full w-[720px] max-w-full flex-col gap-4 overflow-auto border-l border-edge bg-panel p-5"
            , E.stopPropagationOn "click" (Json.Decode.succeed ( args.onIgnore, True ))
            ]
            (Html.div [ A.class "flex items-center gap-3" ]
                (subheading args.title
                    :: args.meta
                    ++ [ Html.div [ A.class "ml-auto" ]
                            [ ghostButton [ E.onClick args.onClose ] [ Html.text "閉じる" ] ]
                       ]
                )
                :: children
            )
        ]


{-| 画面を覆う層。押すと閉じる。**縦の寄せは呼ぶ側**が決める（検索は上、ピッカーは中央）。
-}
overlay : msg -> List (Html.Attribute msg) -> List (Html msg) -> Html msg
overlay onClose attrs =
    Html.div (A.class "fixed inset-0 z-(--z-dialog) flex justify-center bg-black/40" :: E.onClick onClose :: attrs)


{-| 開いている面の外を押したら閉じるための、**見た目を持たない**層。

`--z-dismiss` は開いている面（`--z-dropdown`）より下なので、面の中の項目はそのまま押せる。

WhyNot: 背景を塗らない。塗ると「モーダルは 1 段まで」（仕様 6 章）の覆いと見分けが付かず、
メニューが重い物に見える。
WhyNot: 開いていない時も敷いたままにしない。透明でも下の画面の押下を全部奪う。
WhyNot: 貼り付く帯（`--z-sticky`）より上に敷かない。面を開いている間、帯の「下書き保存」を
押すのに 2 回かかる。

-}
dismissLayer : msg -> Html msg
dismissLayer onDismiss =
    Html.div [ A.class "fixed inset-0 z-(--z-dismiss)", E.onClick onDismiss ] []


{-| メディアの 1 枚。押して選ぶ。
-}
tile : List (Html.Attribute msg) -> List (Html msg) -> Html msg
tile attrs =
    Html.button
        (A.class "flex flex-col overflow-hidden rounded-md border border-edge bg-panel text-left hover:border-accent" :: attrs)


{-| メディアの見え姿。画像でない物は mime を出す（読めない四角を並べない）。

`size` は高さか縦横比のクラス（`h-24` / `aspect-[4/3]`）。一覧のように幅が変わる所は
縦横比で渡す。高さを固定すると、狭い画面で細長く切り取られる。

-}
thumb : String -> { url : String, mime : String } -> Html msg
thumb size asset =
    Html.div [ A.class ("flex w-full items-center justify-center bg-well " ++ size) ]
        [ if String.startsWith "image/" asset.mime then
            Html.img [ A.src asset.url, A.class ("h-full w-full object-cover " ++ size) ] []

          else
            Html.span [ A.class "px-2 text-center text-[10px] text-ink-faint" ] [ Html.text asset.mime ]
        ]


{-| 列の幅を指定する表。既定（`headRow` / `row`）で合わない画面に使う。
-}
headRowOf : String -> List (Html msg) -> Html msg
headRowOf columns cells =
    Html.div
        [ A.class ("grid items-center gap-3 border-b border-edge bg-raised px-4 py-2.5 text-xs font-semibold text-ink-soft " ++ columns) ]
        (List.map (\cell -> Html.div [] [ cell ]) cells)


rowOf : String -> List (Html msg) -> Html msg
rowOf columns cells =
    Html.div
        [ A.class ("grid items-center gap-3 border-b border-edge px-4 py-3 text-[13px] text-ink last:border-b-0 hover:bg-raised " ++ columns) ]
        (List.map (\cell -> Html.div [ A.class "min-w-0" ] [ cell ]) cells)
