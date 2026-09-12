module NavigateTest exposing (suite)

{-| Navigate — URL のプロジェクトをどう扱うか。
-}

import Expect
import Model exposing (Project)
import Navigate exposing (Move(..))
import Test exposing (Test, describe, test)


project : String -> Project
project slug =
    { id = slug, slug = slug, name = slug, visibility = "PUBLIC", role = "ADMIN" }


suite : Test
suite =
    describe "Navigate"
        [ test "URL のプロジェクトごとの行き先" <|
            \_ ->
                -- 入っているプロジェクト: tech-blog, shop
                [ ( Nothing, Just "tech-blog" )
                , ( Just "tech-blog", Just "tech-blog" )
                , ( Just "shop", Just "tech-blog" )
                , ( Just "nope", Just "tech-blog" )
                , ( Just "nope", Nothing )
                , ( Just "tech-blog", Nothing )
                ]
                    |> List.map
                        (\( wanted, current ) ->
                            Navigate.moveFor { wanted = wanted, current = current, known = [ "tech-blog", "shop" ] }
                        )
                    |> Expect.equal
                        [ Stay
                        , Stay
                        , Reload
                        , Unknown "nope"
                        , Unknown "nope"
                        , Reload
                        ]
        , test "入っていないプロジェクトの URL では読み込み直さない" <|
            \_ ->
                Navigate.moveFor { wanted = Just "nope", current = Just "tech-blog", known = [ "tech-blog" ] }
                    |> Expect.notEqual Reload
        , test "URL のプロジェクトを選ぶ。入っていなければ選ばない" <|
            \_ ->
                [ Just "shop", Just "nope", Nothing ]
                    |> List.map (\wanted -> Navigate.pick wanted [ project "tech-blog", project "shop" ])
                    |> Expect.equal
                        [ Just (project "shop")
                        , Nothing
                        , Just (project "tech-blog")
                        ]
        , test "プロジェクトが 1 つも無ければ選ばない" <|
            \_ ->
                [ Just "nope", Nothing ]
                    |> List.map (\wanted -> Navigate.pick wanted [])
                    |> Expect.equal [ Nothing, Nothing ]
        ]
