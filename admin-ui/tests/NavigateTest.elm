module NavigateTest exposing (suite)

{-| Navigate — URL のプロジェクトをどう扱うか。
-}

import Expect
import Model exposing (Project)
import Navigate exposing (Asked(..), Move(..))
import Route
import Test exposing (Test, describe, test)


project : String -> Project
project slug =
    { id = slug, slug = slug, name = slug, visibility = "PUBLIC", role = "ADMIN" }


suite : Test
suite =
    describe "Navigate"
        [ test "ルートが求めるプロジェクト" <|
            \_ ->
                [ Route.Entries "tech-blog" "blogs" []
                , Route.Settings "shop" Route.Members
                , Route.Projects
                , Route.Account
                , Route.NotFound
                ]
                    |> List.map Navigate.askedOf
                    |> Expect.equal
                        [ ForProject "tech-blog"
                        , ForProject "shop"
                        , NoProject
                        , NoProject
                        , Unreadable
                        ]
        , test "URL のプロジェクトごとの行き先" <|
            \_ ->
                -- 入っているプロジェクト: tech-blog, shop
                [ ( NoProject, Just "tech-blog" )
                , ( ForProject "tech-blog", Just "tech-blog" )
                , ( ForProject "shop", Just "tech-blog" )
                , ( ForProject "nope", Just "tech-blog" )
                , ( ForProject "nope", Nothing )
                , ( ForProject "tech-blog", Nothing )
                , ( Unreadable, Just "tech-blog" )
                , ( Unreadable, Nothing )
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
                        , Stay
                        , Stay
                        ]
        , test "入っていないプロジェクトの URL では読み込み直さない" <|
            \_ ->
                Navigate.moveFor { wanted = ForProject "nope", current = Just "tech-blog", known = [ "tech-blog" ] }
                    |> Expect.notEqual Reload
        , test "読めなかった URL では読み込み直さない" <|
            \_ ->
                Navigate.moveFor { wanted = Unreadable, current = Just "tech-blog", known = [ "tech-blog", "shop" ] }
                    |> Expect.equal Stay
        , test "URL のプロジェクトを選ぶ。入っていなければ選ばない" <|
            \_ ->
                [ ForProject "shop", ForProject "nope", NoProject ]
                    |> List.map (\wanted -> Navigate.pick wanted [ project "tech-blog", project "shop" ])
                    |> Expect.equal
                        [ Just (project "shop")
                        , Nothing
                        , Just (project "tech-blog")
                        ]
        , test "読めなかった URL ではプロジェクトを選ばない" <|
            \_ ->
                Navigate.pick Unreadable [ project "tech-blog", project "shop" ]
                    |> Expect.equal Nothing
        , test "プロジェクトが 1 つも無ければ選ばない" <|
            \_ ->
                [ ForProject "nope", NoProject, Unreadable ]
                    |> List.map (\wanted -> Navigate.pick wanted [])
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        ]
