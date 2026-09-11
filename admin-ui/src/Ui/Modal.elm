module Ui.Modal exposing (Anchor, actions, anchored, dialog, fullscreen, sheet)

{-| 画面の上に重ねる物。**モーダルは 1 段まで**（仕様 6 章）。

  - `dialog`: 確認（中央、幅 440px）。本文の下に `error`、その下に `footer`（普通は `actions`）
  - `sheet`: 上寄せの面（⌘K、メディアから選ぶ）。上下の帯を固定し、中だけスクロールする
  - `fullscreen`: 画面いっぱいに広げる（本文のプレビュー）
  - `anchored`: 押した物の下に置く小さな面（本文のリンク）。覆いは透明

覆いを押すと閉じ、中を押しても閉じない。Esc は `Main` が今の画面に配る（ここでは拾わない）。

WhyNot: 中の要素に `stopPropagation` を付けない。付けると呼ぶ側が「何もしない Msg」を
用意する事になり、画面ごとに `keepOpen` が生える（実際に 4 つあった）。覆いは
**押された物が覆い自身の時だけ**閉じる。

-}

import Html exposing (Html)
import Html.Attributes as A
import Html.Events as E
import Json.Decode as D
import Ui
import Ui.Icon as Icon


{-| 確認。題、本文、断られた理由、右寄せの操作。
-}
dialog :
    { title : String
    , onClose : msg
    , error : Maybe String
    , footer : Html msg
    }
    -> List (Html msg)
    -> Html msg
dialog args children =
    backdrop args.onClose
        "items-center"
        [ Ui.card
            [ A.class "flex w-[440px] max-w-full flex-col gap-3 p-5"
            , A.attribute "role" "dialog"
            , A.attribute "aria-modal" "true"
            ]
            (Ui.subheading args.title
                :: children
                ++ [ case args.error of
                        Just message ->
                            Ui.callout Ui.toneBad [ A.class "gap-1 p-3 text-xs" ] [ Html.text message ]

                        Nothing ->
                            Html.text ""
                   , args.footer
                   ]
            )
        ]


{-| 確認の操作。**右寄せ、確定は右端。** 危ない物（削除・公開を終える）は赤、それ以外は青。
送信中は押せず、文字が「送信中…」になる。
-}
actions :
    { confirm : String
    , danger : Bool
    , onConfirm : msg
    , onCancel : msg
    , busy : Bool
    }
    -> Html msg
actions args =
    let
        label : String
        label =
            if args.busy then
                "送信中…"

            else
                args.confirm

        attrs : List (Html.Attribute msg)
        attrs =
            [ E.onClick args.onConfirm, A.disabled args.busy ]
    in
    Html.div [ A.class "flex justify-end gap-2" ]
        [ Ui.ghostButton [ E.onClick args.onCancel ] [ Html.text "キャンセル" ]
        , if args.danger then
            Ui.dangerButton attrs [ Html.text label ]

          else
            Ui.button attrs [ Html.text label ]
        ]


{-| 上寄せの面。`head` は上の帯（題と説明、または検索の入力）、`footer` は下の帯（決定と閉じる）。
帯には余白を付けない（入力を帯いっぱいに置く面があるため）。`footer` だけは余白を持つ。
-}
sheet :
    { head : List (Html msg)
    , onClose : msg
    , footer : List (Html msg)
    , width : String
    }
    -> List (Html msg)
    -> Html msg
sheet args children =
    backdrop args.onClose
        "items-start pt-32"
        [ Html.div
            [ A.class ("flex max-h-[70vh] max-w-full flex-col overflow-hidden rounded-xl border border-edge bg-panel shadow-2xl " ++ args.width)
            , A.attribute "role" "dialog"
            , A.attribute "aria-modal" "true"
            ]
            [ Html.div [ A.class "flex shrink-0 flex-col gap-2 border-b border-edge" ] args.head
            , Html.div [ A.class "min-h-0 flex-1 overflow-auto" ] children
            , if List.isEmpty args.footer then
                Html.text ""

              else
                Html.div [ A.class "flex shrink-0 items-center gap-3 border-t border-edge px-5 py-3" ] args.footer
            ]
        ]


{-| 画面いっぱい。上の帯に題・`trailing`・畳む印を置き、その下に `children`。
`contentWidth` は帯の幅（中身と揃える。中身が自分で幅を決めている時に渡す）。

引き出しと同じ高さ（`--z-drawer`）に置く。確認（`dialog`）はこの上に出る。

-}
fullscreen :
    { title : String
    , trailing : List (Html msg)
    , onClose : msg
    , contentWidth : String
    }
    -> List (Html msg)
    -> Html msg
fullscreen args children =
    Html.div [ A.class "fixed inset-0 z-(--z-drawer) flex flex-col gap-2 bg-app p-4" ]
        (Html.div [ A.class ("mx-auto flex w-full items-center gap-2 " ++ args.contentWidth) ]
            (Html.span [ A.class "truncate text-[13px] font-semibold text-ink" ] [ Html.text args.title ]
                :: args.trailing
                ++ [ Ui.iconButton { title = "元の大きさに戻す", onClick = args.onClose } [] Icon.collapse ]
            )
            :: children
        )


{-| 押した物の矩形と、その時の画面の大きさ。custom element の `getBoundingClientRect` と
`window.innerWidth` / `innerHeight` がそのまま来る。
-}
type alias Anchor =
    { left : Float
    , top : Float
    , bottom : Float
    , spaceWidth : Float
    , spaceHeight : Float
    }


{-| 押した物の下に置く面。`width` と `height` は px（`height` は置き場所を決めるのに使う
見込みの高さで、面そのものには掛けない）。

**押した所から離れた場所に出さない。** 中身が打つ度に変わる面は、目がボタンと面を往復する。

WhyNot: 覆いを黒くしない。ここは 1 手で終わる小さな面で、`dialog` のように画面を止める物では
ない（`Ui.dismissLayer` と同じ透明の層で、外を押したら閉じるだけ）。

-}
anchored : { at : Anchor, width : Int, height : Int, onClose : msg } -> List (Html msg) -> Html msg
anchored args children =
    let
        gap : Float
        gap =
            6

        below : Float
        below =
            args.at.bottom + gap

        top : Float
        top =
            if below + toFloat args.height > args.at.spaceHeight - 8 then
                max 8 (args.at.top - gap - toFloat args.height)

            else
                below

        left : Float
        left =
            min (max 8 args.at.left) (args.at.spaceWidth - toFloat args.width - 8)
    in
    Html.div []
        [ Ui.dismissLayer args.onClose
        , Html.div
            [ A.class "fixed z-(--z-dropdown) flex flex-col overflow-hidden rounded-md border border-edge bg-panel shadow-2xl"
            , A.style "left" (String.fromInt (round left) ++ "px")
            , A.style "top" (String.fromInt (round top) ++ "px")
            , A.style "width" (String.fromInt args.width ++ "px")

            -- 見込みが外れても画面の外にはみ出さない。
            , A.style "max-height" "calc(100vh - 16px)"
            , A.attribute "role" "dialog"
            ]
            children
        ]


{-| 覆い。押された物が覆い自身の時だけ閉じる。
-}
backdrop : msg -> String -> List (Html msg) -> Html msg
backdrop onClose align children =
    Html.div
        [ A.class ("fixed inset-0 z-(--z-dialog) flex justify-center bg-black/40 " ++ align)
        , A.attribute "data-backdrop" "1"
        , E.on "click" (D.at [ "target", "dataset", "backdrop" ] D.string |> D.map (\_ -> onClose))
        ]
        children
