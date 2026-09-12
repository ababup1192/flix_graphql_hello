module ProjectsPageTest exposing (suite)

{-| Page.Projects.slugify: プロジェクト名から slug の候補を作る。
-}

import Expect
import Page.Projects
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "slugify"
        (List.map
            (\( name, expected ) -> test ("「" ++ name ++ "」→「" ++ expected ++ "」") (\_ -> Page.Projects.slugify name |> Expect.equal expected))
            [ ( "Shop Blog", "shop-blog" )
            , ( "商店ブログ", "" )
            , ( "商店 blog", "blog" )
            , ( "a--b", "a-b" )
            , ( " x_y.z ", "x-y-z" )
            , ( "Ünïcode café", "ncode-caf" )
            ]
        )
