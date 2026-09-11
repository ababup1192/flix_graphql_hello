module Ui.Secret exposing (view)

{-| 発行した秘密（API キー・Webhook の署名の鍵・PAT）を 1 回だけ見せる箱。

GitHub の PAT、Stripe の API キーと同じ形にしてある: 緑の成功の帯、「今しか表示されません」の一文、
等幅の値と、**枠の中の右端にコピーのアイコン**（押すと 2 秒だけチェックに変わり、何度でも押せる）、閉じるは目立たないボタン。
成功なので緑。琥珀は「押す前の確認」に取っておく。

-}

import Html exposing (Html)
import Html.Attributes as A
import Html.Events as E
import Ui
import Ui.Icon as Icon


view :
    { title : String
    , value : String
    , copied : Bool
    , onCopy : msg
    , onClose : msg
    }
    -> Html msg
view args =
    Ui.callout Ui.toneOk
        [ A.class "gap-3" ]
        [ Ui.subheading args.title
        , Html.p [ A.class "text-[13px]" ] [ Html.text "この値は今しか表示されません。コピーして安全な場所に保存してください。" ]
        , Html.div [ A.class "flex items-center gap-2 rounded-md border border-edge bg-raised pr-1 pl-3" ]
            [ Html.code
                [ A.class "min-w-0 flex-1 overflow-x-auto py-2 font-mono text-sm text-ink select-all" ]
                [ Html.text args.value ]
            , Ui.iconButton
                { title =
                    if args.copied then
                        "コピーしました"

                    else
                        "コピー"
                , onClick = args.onCopy
                }
                (A.attribute "aria-label" "コピー"
                    :: (if args.copied then
                            [ A.style "color" "var(--color-ok)" ]

                        else
                            []
                       )
                )
                (if args.copied then
                    Icon.check

                 else
                    Icon.copy
                )
            , if args.copied then
                Html.span [ A.class "pr-2 text-xs text-[color:var(--color-ok)]" ] [ Html.text "コピーしました" ]

              else
                Html.text ""
            ]
        , Html.div [] [ Ui.ghostButton [ E.onClick args.onClose ] [ Html.text "閉じる" ] ]
        ]
