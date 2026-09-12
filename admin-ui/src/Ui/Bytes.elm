module Ui.Bytes exposing (human)

{-| ファイルの大きさの見せ方。

WhyNot: 画面ごとに丸め方を書かない。同じ 1 枚のメディアが一覧では「0 KB」、
エディタでは「812 B」、監査ログでは「0.7 MB」と読める形になっていた。

-}


{-| 人が読む単位。1024 未満は B、1 MB 未満は KB、その上は MB。

WhyNot: MB を整数で丸めない。MB は一番粗い単位で、切り捨てると 1.9 MB が
「1 MB」になり半分近く違って読める。KB と B は 1 段下の単位が残るので整数で足りる。

-}
human : Int -> String
human size =
    if size >= 1024 * 1024 then
        String.fromFloat (toFloat (size * 10 // (1024 * 1024)) / 10) ++ " MB"

    else if size >= 1024 then
        String.fromInt (size // 1024) ++ " KB"

    else
        String.fromInt size ++ " B"
