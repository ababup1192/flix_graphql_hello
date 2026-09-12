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
                , Route.NotFound (Just "demo")
                , Route.NotFound Nothing
                ]
                    |> List.map Navigate.askedOf
                    |> Expect.equal
                        [ ForProject "tech-blog"
                        , ForProject "shop"
                        , NoProject
                        , NoProject
                        , Unreadable (Just "demo")
                        , Unreadable Nothing
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
                , ( Unreadable Nothing, Just "tech-blog" )
                , ( Unreadable Nothing, Nothing )
                , ( Unreadable (Just "shop"), Just "tech-blog" )
                , ( Unreadable (Just "shop"), Nothing )
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
                        , Stay
                        , Stay
                        ]
        , test "入っていないプロジェクトの URL では読み込み直さない" <|
            \_ ->
                Navigate.moveFor { wanted = ForProject "nope", current = Just "tech-blog", known = [ "tech-blog" ] }
                    |> Expect.notEqual Reload
        , test "読めなかった URL では読み込み直さない" <|
            \_ ->
                Navigate.moveFor { wanted = Unreadable Nothing, current = Just "tech-blog", known = [ "tech-blog", "shop" ] }
                    |> Expect.equal Stay

        -- slug を持つ読めない URL でも、新規ロード（current = Nothing）で Reload を返さない
        , test "読めなかった URL は slug を持っていても読み込み直さない" <|
            \_ ->
                Navigate.moveFor { wanted = Unreadable (Just "tech-blog"), current = Nothing, known = [ "tech-blog", "shop" ] }
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
        , test "プロジェクトの外の読めなかった URL ではプロジェクトを選ばない" <|
            \_ ->
                Navigate.pick (Unreadable Nothing) [ project "tech-blog", project "shop" ]
                    |> Expect.equal Nothing
        , test "プロジェクトの下の読めなかった URL では、その slug のプロジェクトを選ぶ" <|
            \_ ->
                Navigate.pick (Unreadable (Just "shop")) [ project "tech-blog", project "shop" ]
                    |> Expect.equal (Just (project "shop"))
        , test "知らない slug の読めなかった URL では別のプロジェクトに落とさない" <|
            \_ ->
                Navigate.pick (Unreadable (Just "nope")) [ project "tech-blog", project "shop" ]
                    |> Expect.equal Nothing
        , test "プロジェクトが 1 つも無ければ選ばない" <|
            \_ ->
                [ ForProject "nope", NoProject, Unreadable Nothing, Unreadable (Just "tech-blog") ]
                    |> List.map (\wanted -> Navigate.pick wanted [])
                    |> Expect.equal [ Nothing, Nothing, Nothing, Nothing ]
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
                , Route.NotFound (Just "tech-blog")
                ]
                    |> List.map Navigate.needsTypes
                    |> Expect.equal [ True, True, False, False, False, False ]
        , test "新規の画面で entry が作られたら、その entry のルートへ差し替える" <|
            \_ ->
                Navigate.createdRoute { route = Route.NewEntry "tech-blog" "blogs", entryId = Just "e1" }
                    |> Expect.equal (Just (Route.Entry "tech-blog" "blogs" "e1"))
        , test "まだ作られていない・既存の entry・他の画面では差し替えない" <|
            \_ ->
                [ ( Route.NewEntry "tech-blog" "blogs", Nothing )
                , ( Route.Entry "tech-blog" "blogs" "e1", Just "e1" )
                , ( Route.Entries "tech-blog" "blogs" [], Just "e1" )
                ]
                    |> List.map (\( route, entryId ) -> Navigate.createdRoute { route = route, entryId = entryId })
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        ]
