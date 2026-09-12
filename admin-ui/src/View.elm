module View exposing (broken, loading, notFound, placeholder, signedOut)

{-| 入口の状態と、中に入った後の枠。

見た目は Tailwind のユーティリティを class の文字列で当てる（トークンは styles.css の @theme）。

WhyNot: elm-css を使わない。既存の Elm 資産（flix\_ge\_studio）が Tailwind で、揃える方が事故が少ない。

-}

import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)


{-| 起動中。me を引いている間の一瞬。
-}
loading : Html msg
loading =
    centered
        [ logo
        , div [ class "flex w-full max-w-md flex-col gap-2" ]
            [ skeleton "w-3/5", skeleton "w-4/5", skeleton "w-2/5" ]
        , span [ class "text-xs text-ink-faint" ] [ text "読み込んでいます" ]
        ]


{-| ログインの有効期限が切れた。押すとページを丸ごと読み直し、Access がログイン画面に飛ばす。
-}
signedOut : { onReload : msg } -> Html msg
signedOut args =
    centered
        [ logo
        , heading "ログインの有効期限が切れました"
        , paragraph [ text "入力中の内容は保存されていません。ログインし直してから、もう一度保存してください。" ]
        , button "再ログイン" args.onReload
        ]


{-| 想定していない失敗。

**requestId を必ず出す。** これがサーバのログの 1 行を引く唯一の鍵で、
無いと人は時刻とプロジェクト名で総当たりする事になる。

-}
broken : { message : String, requestId : Maybe String } -> Html msg
broken failure =
    centered
        [ logo
        , heading "読み込めませんでした"
        , paragraph [ text failure.message ]
        , case failure.requestId of
            Just id ->
                div [ class "flex flex-col items-center gap-1" ]
                    [ span [ class "text-xs text-ink-faint" ] [ text "運用に伝える時はこの id を添えてください" ]
                    , span [ class "rounded border border-edge bg-panel px-2 py-1 font-mono text-xs text-ink-soft" ] [ text id ]
                    ]

            Nothing ->
                text ""
        ]


{-| 読めなかった URL。どこに来たのかを出す。

WhyNot: URL を本文にも出さない。アドレス欄と同じ物が 2 つ並ぶだけになる。

WhyNot: 近そうな画面へ勝手に送らない。送ると URL と中身が食い違ったまま操作が続く。

-}
notFound : Html msg
notFound =
    div [ class "flex flex-col items-center gap-2 py-20 text-center" ]
        [ span [ class "text-[13px] text-ink-soft" ] [ text "この URL の画面はありません" ]
        , paragraph [ text "アドレスを確かめ直すか、左の一覧から選び直してください。" ]
        ]


{-| まだ作っていないページ。どの URL に来たかだけ出す。
-}
placeholder : String -> Html msg
placeholder url =
    div [ class "flex flex-col items-center gap-2 py-20 text-center" ]
        [ span [ class "text-[13px] text-ink-soft" ] [ text "この画面はまだありません" ]
        , span [ class "font-mono text-xs text-ink-faint" ] [ text url ]
        , paragraph [ text "左の一覧から選び直してください。" ]
        ]



-- 部品


centered : List (Html msg) -> Html msg
centered children =
    div [ class "flex h-screen flex-col items-center justify-center gap-4 bg-app px-6 text-center text-ink" ] children


logo : Html msg
logo =
    div [ class "flex h-10 w-10 items-center justify-center rounded-[10px] bg-accent text-lg font-bold text-white" ]
        [ text "C" ]


heading : String -> Html msg
heading title =
    span [ class "text-base font-semibold" ] [ text title ]


paragraph : List (Html msg) -> Html msg
paragraph children =
    span [ class "max-w-md text-[13px] leading-7 text-ink-soft" ] children


skeleton : String -> Html msg
skeleton width =
    div [ class ("h-3 rounded bg-edge " ++ width) ] []


button : String -> msg -> Html msg
button label msg =
    Html.button
        [ class "rounded-md bg-ink px-4 py-2 text-[13px] font-semibold text-panel"
        , onClick msg
        ]
        [ text label ]
