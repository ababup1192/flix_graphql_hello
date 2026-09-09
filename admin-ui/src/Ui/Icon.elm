module Ui.Icon exposing
    ( byName
    , caret
    , check
    , choices
    , collapse
    , entry
    , expand
    , grip
    , media
    , ofKind
    , panel
    , project
    , search
    , stage
    , view
    )

{-| 線のアイコン。24px の枠、線 1.8。Lucide の形に揃えて自作している。

**絵文字を使わない**（拡大と再着色ができない）。色は `currentColor` を継ぐ。

フィールドの種類のアイコンは、一覧・入力欄のラベル・API スキーマの表で同じ物を使う。

-}

import Html exposing (Html)
import Svg exposing (Svg, svg)
import Svg.Attributes as A


{-| 16px で描く。文の中や表の行に置く既定の大きさ。
-}
view : List (Svg msg) -> Html msg
view paths =
    svg
        [ A.viewBox "0 0 24 24"
        , A.width "16"
        , A.height "16"
        , A.fill "none"
        , A.stroke "currentColor"
        , A.strokeWidth "1.8"
        , A.strokeLinecap "round"
        , A.strokeLinejoin "round"
        , A.class "shrink-0"
        ]
        paths



-- フィールドの種類


{-| フィールドの種類のアイコン。**一覧・入力欄のラベル・種類を選ぶ所で同じ物を使う**
（場所ごとに変えると、同じ種類だと分からなくなる）。
-}
ofKind : String -> List (Svg msg)
ofKind kind =
    case kind of
        "TEXT" ->
            [ path "M4 7V5h16v2", path "M12 5v14", path "M9 19h6" ]

        "TEXT_AREA" ->
            [ rect "3" "4" "18" "16" "2", path "M7 9h10", path "M7 13h10", path "M7 17h6" ]

        "SLUG" ->
            [ path "M10 13a5 5 0 007 0l3-3a5 5 0 00-7-7l-1 1", path "M14 11a5 5 0 00-7 0l-3 3a5 5 0 007 7l1-1" ]

        "NUMBER" ->
            [ path "M10 4L8 20", path "M16 4l-2 16", path "M4 9h16", path "M3 15h16" ]

        "BOOLEAN" ->
            [ rect "2" "7" "20" "10" "5", circle "16" "12" "3" ]

        "SELECT" ->
            [ rect "3" "5" "18" "14" "2", path "M8 12l3 3 5-6" ]

        "REFERENCE" ->
            [ path "M10 13a5 5 0 007 0l3-3a5 5 0 00-7-7l-1 1", path "M14 11a5 5 0 00-7 0l-3 3a5 5 0 007 7l1-1" ]

        "OBJECT" ->
            [ rect "3" "3" "18" "18" "2", path "M8 8h8", path "M8 12h8", path "M8 16h4" ]

        "BLOCKS" ->
            [ rect "3" "4" "18" "6" "1.5", rect "3" "14" "18" "6" "1.5" ]

        "ASSET" ->
            [ rect "3" "4" "18" "16" "2", circle "9" "10" "2", path "M21 16l-5-5-7 7" ]

        "RICH_TEXT" ->
            [ path "M6 4h9a4 4 0 010 8H6z", path "M6 12h10a4 4 0 010 8H6z" ]

        "DATE" ->
            calendar

        "DATE_ONLY" ->
            calendar

        _ ->
            [ circle "12" "12" "9", path "M12 8v4", path "M12 16h.01" ]


{-| 日付と日時で同じ暦を使う。**違うのは時刻を持つかだけ**で、絵で分ける物ではない。
-}
calendar : List (Svg.Svg msg)
calendar =
    [ rect "3" "5" "18" "16" "2", path "M8 3v4", path "M16 3v4", path "M3 11h18" ]



-- API の種類


{-| 人が選べるアイコン。**名前で持つ**（CMS の `ContentType.icon` に入る識別子）。

WhyNot: 絵文字にしない。Notion は絵文字だが、拡大と再着色ができず、
暗いテーマで沈む（仕様 8 章）。線のアイコンなら `currentColor` を継ぐ。

CMS が受ける形は `[a-z][a-z0-9-]*` の 32 文字まで。ここの名前もその形に揃える。

-}
choices : List ( String, String )
choices =
    [ ( "list", "一覧" )
    , ( "file", "1 枚" )
    , ( "book", "本" )
    , ( "news", "お知らせ" )
    , ( "tag", "タグ" )
    , ( "user", "人" )
    , ( "image", "画像" )
    , ( "video", "動画" )
    , ( "cart", "商品" )
    , ( "star", "おすすめ" )
    , ( "pin", "場所" )
    , ( "calendar", "予定" )
    , ( "message", "声" )
    , ( "question", "質問" )
    , ( "box", "箱" )
    , ( "code", "コード" )
    , ( "chart", "数字" )
    , ( "flag", "目印" )
    ]


{-| 名前からアイコン。知らない名前は一覧のアイコンにする（CMS が名前を増やしても壊れない）。
-}
byName : String -> List (Svg msg)
byName name =
    case name of
        "file" ->
            singleton

        "book" ->
            [ path "M4 19.5A2.5 2.5 0 016.5 17H20", path "M6.5 2H20v20H6.5A2.5 2.5 0 014 19.5v-15A2.5 2.5 0 016.5 2z" ]

        "news" ->
            [ rect "3" "4" "18" "16" "2", path "M7 8h6", path "M7 12h10", path "M7 16h10" ]

        "tag" ->
            [ path "M12 2H2v10l10 10 10-10z", circle "7" "7" "1.4" ]

        "user" ->
            [ circle "12" "8" "4", path "M4 21a8 8 0 0116 0" ]

        "image" ->
            media

        "video" ->
            [ rect "2" "5" "14" "14" "2", path "M22 8l-6 4 6 4z" ]

        "cart" ->
            [ circle "9" "20" "1.4", circle "18" "20" "1.4", path "M2 3h3l2.7 11.5a2 2 0 002 1.5h7.7a2 2 0 002-1.5L21 7H6" ]

        "star" ->
            [ path "M12 3l2.9 5.9 6.5.9-4.7 4.6 1.1 6.5L12 17.8 6.2 20.9l1.1-6.5L2.6 9.8l6.5-.9z" ]

        "pin" ->
            [ path "M12 21s7-6.3 7-11a7 7 0 10-14 0c0 4.7 7 11 7 11z", circle "12" "10" "2.5" ]

        "calendar" ->
            [ rect "3" "5" "18" "16" "2", path "M8 3v4", path "M16 3v4", path "M3 11h18" ]

        "message" ->
            [ path "M21 15a2 2 0 01-2 2H8l-5 4V5a2 2 0 012-2h14a2 2 0 012 2z" ]

        "question" ->
            [ circle "12" "12" "9", path "M9.5 9a2.5 2.5 0 115 .5c0 1.5-2.5 2-2.5 3.5", path "M12 17h.01" ]

        "box" ->
            [ path "M21 8l-9-5-9 5v8l9 5 9-5z", path "M3 8l9 5 9-5", path "M12 13v9" ]

        "code" ->
            [ path "M9 17l-5-5 5-5", path "M15 7l5 5-5 5" ]

        "chart" ->
            [ path "M3 21h18", path "M7 21V11", path "M12 21V4", path "M17 21v-7" ]

        "flag" ->
            [ path "M4 21V4", path "M4 5h12l-2 4 2 4H4" ]

        _ ->
            collection


{-| 何件も持つ API（COLLECTION）。**積み重なった紙**。
-}
collection : List (Svg msg)
collection =
    [ rect "3" "7" "18" "14" "2", path "M6 4h12" ]


{-| 1 件だけの API（SINGLETON）。**紙 1 枚**。
-}
singleton : List (Svg msg)
singleton =
    [ path "M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8z", path "M14 3v5h5" ]


media : List (Svg msg)
media =
    [ rect "3" "4" "18" "16" "2", circle "9" "10" "2", path "M21 16l-5-5-7 7" ]


{-| プロジェクトの設定。歯車。
-}
project : List (Svg msg)
project =
    [ circle "12" "12" "3"
    , path "M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 11-2.83 2.83l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 11-4 0v-.09A1.65 1.65 0 008 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 11-2.83-2.83l.06-.06A1.65 1.65 0 003.68 15a1.65 1.65 0 00-1.51-1H2a2 2 0 110-4h.09A1.65 1.65 0 003.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 112.83-2.83l.06.06A1.65 1.65 0 009 4.6 1.65 1.65 0 0010 3.09V3a2 2 0 114 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 112.83 2.83l-.06.06A1.65 1.65 0 0020.4 9v0a1.65 1.65 0 001.51 1H22a2 2 0 110 4h-.09a1.65 1.65 0 00-1.51 1z"
    ]



-- 画面の操作


{-| 掴んで動かす所。**行の左端**に置く（GitHub / Notion / Contentful と同じ）。
-}
grip : List (Svg msg)
grip =
    [ circle "9" "6" "1", circle "15" "6" "1", circle "9" "12" "1", circle "15" "12" "1", circle "9" "18" "1", circle "15" "18" "1" ]


panel : List (Svg msg)
panel =
    [ rect "3" "3" "18" "18" "2", path "M9 3v18", path "M16 15l-3-3 3-3" ]


{-| 列の状態を表す丸（GitHub の Projects と同じ形）。
-}
stage : List (Svg msg)
stage =
    [ circle "12" "12" "8" ]


{-| コンテンツ 1 件。カードの左肩に置く。
-}
entry : List (Svg msg)
entry =
    [ circle "12" "12" "9", circle "12" "12" "3" ]


caret : List (Svg msg)
caret =
    [ path "M6 9l6 6 6-6" ]


{-| 広げる / 畳む。**斜めの矢印 2 つ。**
外向き（左下と右上へ出る）が広げる、内向きが元に戻す。
Contentful / Notion / Sanity / Google ドキュメントが揃ってこの形を使っている。
-}
expand : List (Svg msg)
expand =
    [ path "M14 4h6v6", path "M10 20H4v-6", path "M20 4l-7 7", path "M4 20l7-7" ]


collapse : List (Svg msg)
collapse =
    [ path "M14 10h6V4", path "M10 14H4v6", path "M20 4l-7 7", path "M4 20l7-7" ]


{-| 検索。上のバーの中央の欄に置く。**狭い画面ではこれだけが残る。**
-}
search : List (Svg msg)
search =
    [ circle "11" "11" "7", path "M20 20l-4.3-4.3" ]


{-| 選んでいる物の印。行の右端に置く。
-}
check : List (Svg msg)
check =
    [ path "M4 12.5l5 5 11-11" ]



-- 下ごしらえ


path : String -> Svg msg
path d =
    Svg.path [ A.d d ] []


circle : String -> String -> String -> Svg msg
circle cx cy r =
    Svg.circle [ A.cx cx, A.cy cy, A.r r ] []


rect : String -> String -> String -> String -> String -> Svg msg
rect x y width height radius =
    Svg.rect [ A.x x, A.y y, A.width width, A.height height, A.rx radius ] []
