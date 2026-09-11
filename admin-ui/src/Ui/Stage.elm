module Ui.Stage exposing (chip, icon, name, options, tone)

{-| 公開状態（CMS の ContentStage: `DRAFT` / `PUBLISHED` / `CHANGED`）の見せ方。

名前・chip・印・絞り込みの選択肢を**ここだけが持つ**。一覧の chip、エディタの帯、
ボードの列、絞り込みの選択肢が同じ言葉と色になる。

WhyNot: 画面ごとに `case stage of` を書かない。4 か所で「公開中 · 下書きあり」の
書き方が食い違うと、利用者は別の状態だと読む。

-}

import Html exposing (Html)
import Ui
import Ui.Icon as Icon


{-| 画面の言葉（仕様 7 章）。
-}
name : String -> String
name stage =
    case stage of
        "PUBLISHED" ->
            "公開中"

        "CHANGED" ->
            "公開中 · 下書きあり"

        _ ->
            "下書き"


chip : String -> Html msg
chip stage =
    case stage of
        "PUBLISHED" ->
            Ui.chip Ui.toneOk (name stage)

        "CHANGED" ->
            Ui.chip Ui.toneWarn (name stage)

        _ ->
            Ui.chip Ui.toneNeutral (name stage)


{-| 状態を表す形。**色だけで分けない。**
-}
icon : String -> List Icon.Shape
icon stage =
    case stage of
        "PUBLISHED" ->
            Icon.stagePublished

        "CHANGED" ->
            Icon.stageChanged

        _ ->
            Icon.stageDraft


{-| 印（`icon`）の文字色。chip の `tone` と違い、枠も背景も持たない。
-}
tone : String -> String
tone stage =
    case stage of
        "PUBLISHED" ->
            "text-[color:var(--color-ok)]"

        "CHANGED" ->
            "text-[color:var(--color-warn)]"

        _ ->
            "text-ink-faint"


{-| 絞り込みの選択肢。「すべて」は呼ぶ側が頭に足す。
-}
options : List ( String, String )
options =
    List.map (\stage -> ( stage, name stage )) [ "DRAFT", "PUBLISHED", "CHANGED" ]
