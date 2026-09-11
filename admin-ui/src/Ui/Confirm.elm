module Ui.Confirm exposing (view)

{-| 取り返しの付かない操作の確認。**モーダルで、確定は赤。**

GitHub（PAT の Delete）・Stripe・Vercel・microCMS・Contentful はどれもこの形。題は「〜しますか」、
本文に何が起きるかを 1〜2 文、右下に「キャンセル」と赤い確定。外側クリックと Esc で閉じる。

WhyNot: 行の下に琥珀の帯を伸ばす形にしない。琥珀はスキーマ変更の「件数と見本を読んでから押す」に
使っていて、「読む」物と「止まる」物を同じ見た目にすると、どちらも軽く見える。

-}

import Html exposing (Html)
import Html.Attributes as A
import Ui.Modal as Modal
import Ui.Reply as Reply exposing (Reply)


view :
    { title : String

    {- 件数や見本のような「読んでから決める」物。**本文の 1 文より先に置く。**

       WhyNot: 本文の後ろに回さない。要約の 1 文を先に読ませると、その下の
       件数と見本が補足に見え、読まずに押す形になる。
    -}
    , details : List (Html msg)
    , body : String
    , confirm : String
    , reply : Reply
    , onConfirm : msg
    , onCancel : msg
    }
    -> Html msg
view args =
    Modal.dialog
        { title = args.title
        , onClose = args.onCancel
        , error = Nothing
        , footer =
            Modal.actions
                { confirm = args.confirm
                , danger = True
                , onConfirm = args.onConfirm
                , onCancel = args.onCancel
                , busy = Reply.isSending args.reply
                }
        }
        (args.details
            ++ [ Html.p [ A.class "text-[13px] text-ink-soft" ] [ Html.text args.body ]

               -- 送信中は確定のボタンが「送信中…」になるので、返事の方では出さない
               , if Reply.isSending args.reply then
                    Html.text ""

                 else
                    Reply.view args.reply
               ]
        )
