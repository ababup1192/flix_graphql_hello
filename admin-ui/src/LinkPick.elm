module LinkPick exposing
    ( Choice
    , Mode(..)
    , Open
    , Row
    , Sent
    , State
    , chosen
    , chosenRow
    , inputId
    , labelOf
    , modeFromString
    , move
    , rows
    , view
    )

{-| 本文にリンクを張る時の面。

**入力欄は 1 本。** 打った文字でコンテンツを検索し、`http` や `mailto:` で始まったら
一番上に「この URL にリンクする」が出る。行は「URL」と「コンテンツ」に分けて見出しを付ける。

WhyNot: タブやラジオで「URL かコンテンツか」を先に選ばせない。押す前にどちらをしたいか
決めさせる事になり、一番多い「URL を入力」が 2 手になる。Contentful はセレクト、Payload は
ラジオで先に聞くが、あちらは URL / Entry / Asset / Resource と 4 通り以上ある。ここは
2 通りなので、打った物で分かる（WordPress と同じ）。

WhyNot: Model と Msg をここに持たない（`docs/design/admin-ui-shared-ui.md`）。状態は
`Page.Editor` が持ち、ここは**行の組み立て**と**上下の移動**と**描き方**だけを持つ。

-}

import Html exposing (Html)
import Html.Attributes as A
import Html.Events as E
import Json.Decode as D
import Model
import Ui
import Ui.Icon as Icon
import Ui.Modal as Modal
import Ui.Stage as Stage


{-| 面が受ける物の幅。本文のリンクは URL とコンテンツの両方、画像のリンクは URL だけ。

WhyNot: 画像のリンクに `entryId` を許さない。CMS の `image.href` は http(s) だけで、
コンテンツを選べても保存で断られる。

-}
type Mode
    = LinkMode
    | UrlMode


{-| TS の `linkopen` が渡す物。今かかっているリンクと、面を置く位置。
-}
type alias Open =
    { seq : Int
    , mode : Mode
    , href : String
    , entryId : Maybe String
    , at : Modal.Anchor
    }


{-| 開いている面。`at` は上下キーで動かしている位置。
-}
type alias State =
    { apiId : String
    , open : Open
    , query : String
    , at : Int
    }


{-| TS に返す物。`remove` はリンクを外す、`cancel` は何もせず閉じる（focus を本文へ戻す）。
-}
type alias Choice =
    { href : String
    , entryId : String
    , label : String
    , remove : Bool
    , cancel : Bool
    }


{-| 返した物と、返す相手。`seq` は開いた時の番号で、TS は新しい物だけを実行する。
-}
type alias Sent =
    { apiId : String
    , seq : Int
    , choice : Choice
    }


{-| 面の 1 行。URL は打った文字そのもの、コンテンツは候補。
-}
type Row
    = UrlRow String
    | EntryRow Model.LinkCandidate


{-| 入力の id。開いた時に focus を当てるのに使う。
-}
inputId : String
inputId =
    "link-pick-input"


{-| 面の幅（px）。置き場所の計算に使う。
-}
panelWidth : Int
panelWidth =
    300


{-| 面の見込みの高さ（px）。下に入らなければ上へ返すのに使う。

**実際に出る高さと合わせる。** 低く見積もると下に置いた面が画面の下から出て
「リンクを削除」が押せず、高く見積もると下に入る面まで上へ返って押した物から離れる
（入力欄 38 + 候補 226 + 余白 8 に、今のリンク先 56 と削除 34 が付く）。

-}
panelHeight : State -> Int
panelHeight state =
    if hasNow state.open then
        -- 今のリンク先（56）と「リンクを削除」（34）が付く
        362

    else
        272


{-| 今かかっているリンクがあるか。面の頭の「今のリンク先」と、下の「リンクを削除」を出す目印。
-}
hasNow : Open -> Bool
hasNow open =
    open.entryId /= Nothing || not (String.isEmpty open.href)


{-| CMS が受ける href の形（`RichText.isSafeHref`）。これ以外はコンテンツの検索に回す。
-}
isUrlLike : String -> Bool
isUrlLike typed =
    let
        lower : String
        lower =
            String.toLower (String.trim typed)
    in
    String.startsWith "http://" lower
        || String.startsWith "https://" lower
        || String.startsWith "mailto:" lower


{-| 今出す行。URL が先、コンテンツが後。
-}
rows : Mode -> String -> List Model.LinkCandidate -> List Row
rows mode query candidates =
    let
        typed : String
        typed =
            String.trim query

        urlRows : List Row
        urlRows =
            if isUrlLike typed then
                [ UrlRow typed ]

            else
                []
    in
    case mode of
        UrlMode ->
            urlRows

        LinkMode ->
            urlRows ++ List.map EntryRow candidates


{-| 上下の移動。行の数に丸める（下に行き過ぎたら最後、上は先頭）。
-}
move : Int -> Int -> List Row -> Int
move step at shown =
    let
        count : Int
        count =
            List.length shown
    in
    if count == 0 then
        0

    else
        clamp 0 (count - 1) (at + step)


{-| Enter で決まる物。行が無ければ何も返さない。
-}
chosen : Int -> List Row -> Maybe Choice
chosen at shown =
    shown |> List.drop (move 0 at shown) |> List.head |> Maybe.map chosenRow


{-| 1 行を選んだ時に返る物。
-}
chosenRow : Row -> Choice
chosenRow row =
    case row of
        UrlRow url ->
            { href = url, entryId = "", label = url, remove = False, cancel = False }

        EntryRow candidate ->
            { href = "", entryId = candidate.id, label = candidate.title, remove = False, cancel = False }


{-| 行に出す名前。テストと描き方で同じ物を使う。
-}
labelOf : Row -> String
labelOf row =
    case row of
        UrlRow url ->
            url

        EntryRow candidate ->
            candidate.title



-- VIEW


{-| 面。呼ぶ側が Msg を渡す（ここは状態を持たない）。
-}
view :
    { onInput : String -> msg
    , onMove : Int -> msg
    , onConfirm : msg
    , onPick : Row -> msg
    , onRemove : msg
    , onMore : msg
    , onClose : msg
    , candidates : List Model.LinkCandidate
    , linked : List Model.LinkCandidate
    , total : Int
    , waiting : Bool
    }
    -> State
    -> Html msg
view args state =
    let
        shown : List Row
        shown =
            rows state.open.mode state.query args.candidates

        picked : Int
        picked =
            move 0 state.at shown
    in
    Modal.anchored
        { at = state.open.at, width = panelWidth, height = panelHeight state, onClose = args.onClose }
        (viewNow args.linked state.open
            ++ [ Html.input
                    [ A.id inputId
                    , A.class "m-2 mb-0 h-[30px] rounded border border-edge bg-panel px-2 text-xs text-ink outline-none focus:border-accent"
                    , A.placeholder (placeholderOf state.open.mode)
                    , A.attribute "aria-label" "リンク先"
                    , A.value state.query
                    , A.autofocus True
                    , E.onInput args.onInput
                    , onKeys args
                    ]
                    []
               , Html.div [ A.class "flex max-h-[220px] flex-col overflow-auto p-1.5" ]
                    (viewRows args state picked shown
                        ++ viewMore args state shown
                    )
               ]
            ++ viewRemove args state.open
        )


{-| 上下と Enter は面の中で拾う。**画面には漏らさない**（本文のカーソルが動く）。
Esc は拾わず、画面の Escape（`Page.Editor.escapeOne`）に任せる。
-}
onKeys :
    { a
        | onMove : Int -> msg
        , onConfirm : msg
    }
    -> Html.Attribute msg
onKeys args =
    E.preventDefaultOn "keydown"
        (D.field "key" D.string
            |> D.andThen
                (\key ->
                    case key of
                        "ArrowDown" ->
                            D.succeed ( args.onMove 1, True )

                        "ArrowUp" ->
                            D.succeed ( args.onMove -1, True )

                        "Enter" ->
                            D.succeed ( args.onConfirm, True )

                        _ ->
                            D.fail "見ない"
                )
        )


placeholderOf : Mode -> String
placeholderOf mode =
    case mode of
        UrlMode ->
            "URL を入力"

        LinkMode ->
            "コンテンツを検索、または URL を入力"


{-| 今どこを指しているか。**出さないと、既にかかっているリンクを押しても入力欄が空のまま**
（コンテンツへのリンクは href を持たない）で、指し先が分からない。
-}
viewNow : List Model.LinkCandidate -> Open -> List (Html msg)
viewNow linked open =
    case open.entryId of
        Just entryId ->
            case List.filter (\found -> found.id == entryId) linked |> List.head of
                Just found ->
                    [ nowBox False
                        "今のリンク先（コンテンツ）"
                        (Icon.byName found.typeIcon)
                        (found.title ++ "（" ++ found.typeName ++ " · " ++ Stage.name found.stage ++ "）")
                        (Maybe.withDefault ("#entry:" ++ entryId) found.path)
                    ]

                Nothing ->
                    -- **消えた指し先は赤く出す。** 公開の時に断られる物を、書いている間に見せる。
                    [ nowBox True
                        "今のリンク先（コンテンツ）"
                        Icon.entry
                        ("見つかりません（" ++ entryId ++ "）")
                        ("#entry:" ++ entryId)
                    ]

        Nothing ->
            if String.isEmpty open.href then
                []

            else
                [ nowBox False "今のリンク先（外部）" Icon.external open.href "" ]


nowBox : Bool -> String -> List Icon.Shape -> String -> String -> Html msg
nowBox bad label shapes body where_ =
    Html.div
        [ A.attribute "data-link-now"
            (if bad then
                "bad"

             else
                "ok"
            )
        , A.class
            ("m-2 mb-0 rounded px-2 py-1.5 text-xs "
                ++ (if bad then
                        "bg-bad-bg text-[color:var(--color-bad)]"

                    else
                        "bg-well"
                   )
            )
        ]
        [ Html.div [ A.class "text-[10px] text-ink-faint" ] [ Html.text label ]
        , Html.div [ A.class "flex min-w-0 items-center gap-1.5" ]
            [ Html.span [ A.class "shrink-0 text-ink-faint" ] [ Icon.view shapes ]
            , Html.span [ A.class "truncate", A.title body ] [ Html.text body ]
            ]

        -- **配信で出るパスも添える。** どのコンテンツを指しているかだけでは、サイトのどの
        -- URL になるかが分からず、型紙の付け忘れに気付けない。
        , if String.isEmpty where_ then
            Html.text ""

          else
            Html.code [ A.class "block truncate text-[10px] text-ink-faint" ] [ Html.text where_ ]
        ]


viewRows :
    { a
        | onPick : Row -> msg
        , onMove : Int -> msg
    }
    -> State
    -> Int
    -> List Row
    -> List (Html msg)
viewRows args state picked shown =
    if List.isEmpty shown then
        []

    else
        let
            urls : List Row
            urls =
                List.filter isUrlRow shown

            entries : List Row
            entries =
                List.filter (isUrlRow >> not) shown
        in
        (if List.isEmpty urls then
            []

         else
            head "URL" :: List.indexedMap (\index row -> viewRow args picked index row) urls
        )
            ++ (if List.isEmpty entries then
                    []

                else
                    head (entriesHead state)
                        :: List.indexedMap (\index row -> viewRow args picked (List.length urls + index) row) entries
               )


isUrlRow : Row -> Bool
isUrlRow row =
    case row of
        UrlRow _ ->
            True

        EntryRow _ ->
            False


viewRow :
    { a
        | onPick : Row -> msg
        , onMove : Int -> msg
    }
    -> Int
    -> Int
    -> Row
    -> Html msg
viewRow args picked index row =
    let
        ( shapes, side, tone ) =
            case row of
                UrlRow _ ->
                    ( Icon.external, "外部のページ", "text-link" )

                EntryRow candidate ->
                    ( Icon.byName candidate.typeIcon
                    , candidate.typeName ++ " · " ++ Stage.name candidate.stage
                    , "text-ink"
                    )

        title : String
        title =
            labelOf row
    in
    Html.button
        [ A.class
            ("flex w-full min-w-0 items-center gap-2 rounded px-2 py-1 text-left text-xs "
                ++ (if index == picked then
                        "bg-well"

                    else
                        ""
                   )
            )
        , A.title (title ++ "（" ++ side ++ "）")

        -- 手元の確かめの道具（`scripts/link-check.mjs`）が行を掴む目印。
        , A.attribute "data-link-row"
            (case row of
                UrlRow _ ->
                    "url"

                EntryRow _ ->
                    "entry"
            )
        , A.attribute "data-at"
            (if index == picked then
                "1"

             else
                "0"
            )
        , E.onClick (args.onPick row)

        -- 乗せた行を選択位置にもする（見た目だけ動いて Enter は別の物、を作らない）。
        , E.onMouseEnter (args.onMove (index - picked))
        ]
        [ Html.span [ A.class "shrink-0 text-ink-faint" ] [ Icon.view shapes ]
        , Html.span [ A.class ("min-w-0 flex-1 truncate " ++ tone) ] [ Html.text title ]
        , Html.span [ A.class "max-w-[40%] shrink-0 truncate text-[10px] text-ink-faint" ] [ Html.text side ]
        ]


{-| 打つ前は「最近の」と名乗る。全件のつもりで眺めて「見つかりません」と諦めさせない。
-}
entriesHead : State -> String
entriesHead state =
    if String.isEmpty (String.trim state.query) then
        "最近のコンテンツ"

    else
        "コンテンツ"


head : String -> Html msg
head label =
    Html.div [ A.class "px-2 pt-1.5 pb-0.5 text-[10px] font-semibold tracking-wide text-ink-faint" ]
        [ Html.text label ]


{-| 行が無い時の一言と、「もっと見る」。

WhyNot: 押した分だけ面の中で出し直す、にしない。引いてあるのは上位の何件かで、
その外にある物は何回押しても出ない。ここは CMS に続きを頼む。

-}
viewMore :
    { a
        | onMore : msg
        , total : Int
        , candidates : List Model.LinkCandidate
        , waiting : Bool
    }
    -> State
    -> List Row
    -> List (Html msg)
viewMore args state shown =
    let
        rest : Int
        rest =
            args.total - List.length args.candidates
    in
    if List.isEmpty shown then
        [ Html.div [ A.class "p-2 text-[11px] text-ink-faint" ] [ Html.text (emptyNote state) ] ]

    else if state.open.mode == LinkMode && rest > 0 then
        [ Html.button
            [ A.attribute "data-link-more" "1"
            , A.class "rounded px-2 py-1.5 text-left text-[11px] text-link hover:bg-well"
            , A.disabled args.waiting
            , E.onClick args.onMore
            ]
            [ Html.text
                (if args.waiting then
                    "読み込み中…"

                 else
                    "もっと見る（あと " ++ String.fromInt rest ++ " 件）"
                )
            ]
        ]

    else
        []


emptyNote : State -> String
emptyNote state =
    case state.open.mode of
        UrlMode ->
            "http(s) の URL を入力してください"

        LinkMode ->
            if String.isEmpty (String.trim state.query) then
                "コンテンツ名か URL を入力してください"

            else
                "見つかりません"


viewRemove : { a | onRemove : msg } -> Open -> List (Html msg)
viewRemove args open =
    if not (hasNow open) then
        []

    else
        [ Html.div [ A.class "flex px-2 pb-2" ]
            [ Ui.dangerLink args.onRemove "リンクを削除" ]
        ]


{-| TS が渡す `mode` の文字。
-}
modeFromString : String -> Mode
modeFromString name =
    if name == "url" then
        UrlMode

    else
        LinkMode
