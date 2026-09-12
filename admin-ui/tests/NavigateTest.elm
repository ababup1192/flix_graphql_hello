module NavigateTest exposing (suite)

{-| Navigate — URL のプロジェクトをどう扱うか。
-}

import Expect
import Model exposing (Project)
import Navigate exposing (Asked(..), Landing(..), Move(..))
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
        , test "入口の行き先" <|
            \_ ->
                [ ( False, [] )
                , ( False, [ "blogs", "news" ] )
                , ( True, [] )
                , ( True, [ "blogs", "news" ] )
                ]
                    |> List.map (\( arrived, types ) -> Navigate.landingOf { arrived = arrived, types = types })
                    |> Expect.equal
                        [ Waiting
                        , Waiting
                        , NoTypes
                        , GoFirst "blogs"
                        ]
        , test "型が未取得なら入口は待つ" <|
            \_ ->
                Navigate.landingOf { arrived = False, types = [] }
                    |> Expect.equal Waiting
        , test "型が 0 件なら API を作成へ" <|
            \_ ->
                Navigate.landingOf { arrived = True, types = [] }
                    |> Expect.equal NoTypes
        , test "型が届いてから決まるルート" <|
            \_ ->
                [ Route.Home
                , Route.ProjectHome "tech-blog"
                , Route.Projects
                , Route.Entries "tech-blog" "blogs" []
                , Route.Account
                , Route.NotFound
                ]
                    |> List.map Navigate.needsTypes
                    |> Expect.equal [ True, True, False, False, False, False ]
        ]
