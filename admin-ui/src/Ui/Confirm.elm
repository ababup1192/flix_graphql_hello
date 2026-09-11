module Ui.Confirm exposing (view)

{-| 取り返しの付かない操作の確認。**モーダルで、確定は赤。**

GitHub（PAT の Delete）・Stripe・Vercel・microCMS・Contentful はどれもこの形。題は「〜しますか」、
本文に何が起きるかを 1〜2 文、右下に「キャンセル」と赤い確定。外側クリックと Esc で閉じる。

WhyNot: 行の下に琥珀の帯を伸ばす形にしない。琥珀はスキーマ変更の「件数と見本を読んでから押す」に
使っていて、「読む」物と「止まる」物を同じ見た目にすると、どちらも軽く見える。

-}

import Html exposing (Html)
import Html.Attributes as A
import Html.Events as E
import Json.Decode as D
import Ui
import Ui.Reply as Reply exposing (Reply)


view :
    { title : String
    , body : String
    , confirm : String
    , reply : Reply
    , onConfirm : msg
    , onCancel : msg
    , ignore : msg
    }
    -> Html msg
view args =
    Ui.overlay args.onCancel
        [ A.class "items-center" ]
        [ Ui.card
            [ A.class "flex w-[440px] flex-col gap-3 p-5"
            , A.attribute "role" "dialog"
            , A.attribute "aria-modal" "true"
            , E.stopPropagationOn "click" (D.succeed ( args.ignore, True ))
            ]
            [ Ui.subheading args.title
            , Html.p [ A.class "text-[13px] text-ink-soft" ] [ Html.text args.body ]
            , Reply.view args.reply
            , Html.div [ A.class "flex justify-end gap-2" ]
                [ Ui.ghostButton [ E.onClick args.onCancel ] [ Html.text "キャンセル" ]
                , Html.button
                    [ A.type_ "button"
                    , A.class "inline-flex h-8 items-center rounded-md bg-[color:var(--color-bad)] px-3 text-[13px] font-semibold text-white hover:opacity-90 disabled:opacity-40"
                    , E.onClick args.onConfirm
                    , A.disabled (Reply.isSending args.reply)
                    ]
                    [ Html.text args.confirm ]
                ]
            ]
        ]
