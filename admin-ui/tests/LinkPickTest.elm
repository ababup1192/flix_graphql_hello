module LinkPickTest exposing (suite)

{-| LinkPick: 本文にリンクを張る面の、行の組み立てと上下の移動と Enter。
-}

import Expect
import LinkPick exposing (Mode(..))
import Model
import Test exposing (Test, describe, test)


candidate : String -> String -> Model.LinkCandidate
candidate id title =
    { id = id, title = title, typeName = "ブログ", typeIcon = "news", stage = "PUBLISHED", path = Nothing }


candidates : List Model.LinkCandidate
candidates =
    [ candidate "e1" "はじめての記事", candidate "e2" "2 本目" ]


suite : Test
suite =
    describe "LinkPick"
        [ describe "rows: 打った文字で行が絞られる"
            (List.map
                (\( name, ( mode, query ), expected ) ->
                    test name (\_ -> LinkPick.rows mode query candidates |> List.map LinkPick.labelOf |> Expect.equal expected)
                )
                [ ( "打つ前はコンテンツだけ", ( LinkMode, "" ), [ "はじめての記事", "2 本目" ] )
                , ( "URL を打つと一番上に URL の行", ( LinkMode, "https://example.com/a" ), [ "https://example.com/a", "はじめての記事", "2 本目" ] )
                , ( "mailto も URL の行", ( LinkMode, "mailto:a@example.com" ), [ "mailto:a@example.com", "はじめての記事", "2 本目" ] )
                , ( "前後の空白は落とす", ( LinkMode, "  https://example.com/a  " ), [ "https://example.com/a", "はじめての記事", "2 本目" ] )
                , ( "URL でない文字はコンテンツの検索に回る", ( LinkMode, "記事" ), [ "はじめての記事", "2 本目" ] )
                , ( "URL だけの所はコンテンツを出さない", ( UrlMode, "https://example.com/a" ), [ "https://example.com/a" ] )
                , ( "URL だけの所で URL でなければ行は無い", ( UrlMode, "記事" ), [] )
                ]
            )
        , describe "move: 上下の移動は行の数に丸める"
            (List.map
                (\( name, ( step, at ), expected ) ->
                    test name (\_ -> LinkPick.move step at (LinkPick.rows LinkMode "" candidates) |> Expect.equal expected)
                )
                [ ( "下へ 1", ( 1, 0 ), 1 )
                , ( "最後より下へは行かない", ( 1, 1 ), 1 )
                , ( "上へ 1", ( -1, 1 ), 0 )
                , ( "先頭より上へは行かない", ( -1, 0 ), 0 )
                , ( "行の外から戻す", ( 0, 9 ), 1 )
                ]
            )
        , test "move: 行が無ければ 0"
            (\_ -> LinkPick.move 1 0 [] |> Expect.equal 0)
        , describe "chosen: Enter で決まる物"
            [ test "コンテンツの行は entryId と題を返す"
                (\_ ->
                    LinkPick.chosen 1 (LinkPick.rows LinkMode "" candidates)
                        |> Expect.equal (Just { href = "", entryId = "e2", label = "2 本目", remove = False, cancel = False })
                )
            , test "URL の行は href と打った文字を返す"
                (\_ ->
                    LinkPick.chosen 0 (LinkPick.rows LinkMode "https://example.com/a" candidates)
                        |> Expect.equal (Just { href = "https://example.com/a", entryId = "", label = "https://example.com/a", remove = False, cancel = False })
                )
            , test "行が無ければ何も返さない"
                (\_ -> LinkPick.chosen 0 [] |> Expect.equal Nothing)
            ]
        ]
