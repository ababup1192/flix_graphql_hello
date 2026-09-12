module RouteTest exposing (suite)

{-| Route — URL の往復。
-}

import Expect
import Route exposing (Route(..), SettingsTab(..))
import Test exposing (Test, describe, test)
import Url


suite : Test
suite =
    describe "Route"
        [ test "URL からルートに読め、文字列に戻すと同じ URL になる" <|
            \_ ->
                let
                    roundTrip : String -> Maybe String
                    roundTrip url =
                        url
                            |> Url.fromString
                            |> Maybe.map Route.fromUrl
                            |> Maybe.map Route.toString
                in
                [ "https://x/"
                , "https://x/projects"
                , "https://x/account"
                , "https://x/account/tokens"
                , "https://x/account/orgs/o1"
                , "https://x/p/tech-blog/c/blogs"
                , "https://x/p/tech-blog/c/blogs/board"
                , "https://x/p/tech-blog/c/blogs/schema"
                , "https://x/p/tech-blog/c/blogs/settings"
                , "https://x/p/tech-blog/c/blogs/new"
                , "https://x/p/tech-blog/c/blogs/e1"
                , "https://x/p/tech-blog/assets"
                , "https://x/p/tech-blog/settings/api-keys"
                , "https://x/p/tech-blog/settings/audit"
                , "https://x/p/tech-blog/settings/audit?kind=USER&action=webhook.&since=2026-08-01&until=2026-09-11&id=01J7Q"
                ]
                    |> List.map roundTrip
                    |> Expect.equal
                        ([ "/"
                         , "/projects"
                         , "/account"
                         , "/account/tokens"
                         , "/account/orgs/o1"
                         , "/p/tech-blog/c/blogs"
                         , "/p/tech-blog/c/blogs/board"
                         , "/p/tech-blog/c/blogs/schema"
                         , "/p/tech-blog/c/blogs/settings"
                         , "/p/tech-blog/c/blogs/new"
                         , "/p/tech-blog/c/blogs/e1"
                         , "/p/tech-blog/assets"
                         , "/p/tech-blog/settings/api-keys"
                         , "/p/tech-blog/settings/audit"
                         , "/p/tech-blog/settings/audit?kind=USER&action=webhook.&since=2026-08-01&until=2026-09-11&id=01J7Q"
                         ]
                            |> List.map Just
                        )
        , test "一覧の絞り込みは URL に残る" <|
            \_ ->
                "https://x/p/tech-blog/c/blogs?q=flix&order=publishedAt"
                    |> Url.fromString
                    |> Maybe.map Route.fromUrl
                    |> Expect.equal (Just (Entries "tech-blog" "blogs" [ ( "q", "flix" ), ( "order", "publishedAt" ) ]))
        , test "監査ログの絞り込みは URL に残る（知らないキーは捨てる）" <|
            \_ ->
                "https://x/p/tech-blog/settings/audit?action=member.&q=x&kind=SYSTEM"
                    |> Url.fromString
                    |> Maybe.map Route.fromUrl
                    |> Expect.equal (Just (Settings "tech-blog" (Audit [ ( "kind", "SYSTEM" ), ( "action", "member." ) ])))
        , test "知っているタブの名前はそのタブになる" <|
            \_ ->
                [ "members", "api-keys", "webhooks", "workflow", "project" ]
                    |> List.map (\tab -> Url.fromString ("https://x/p/tech-blog/settings/" ++ tab) |> Maybe.map Route.fromUrl)
                    |> Expect.equal
                        [ Just (Settings "tech-blog" Members)
                        , Just (Settings "tech-blog" ApiKeys)
                        , Just (Settings "tech-blog" Webhooks)
                        , Just (Settings "tech-blog" Workflow)
                        , Just (Settings "tech-blog" ProjectSettings)
                        ]
        , test "知らないタブの名前は NotFound（メンバーに落とさない）" <|
            \_ ->
                [ "keys", "member", "audits", "Members" ]
                    |> List.map (\tab -> Url.fromString ("https://x/p/tech-blog/settings/" ++ tab) |> Maybe.map Route.fromUrl)
                    |> Expect.equal
                        [ Just NotFound
                        , Just NotFound
                        , Just NotFound
                        , Just NotFound
                        ]
        , test "知らない URL は NotFound" <|
            \_ ->
                "https://x/nope/nope"
                    |> Url.fromString
                    |> Maybe.map Route.fromUrl
                    |> Expect.equal (Just NotFound)
        , test "プロジェクトの slug をルートから取れる" <|
            \_ ->
                [ Entries "a" "blogs" [], Media "b", Settings "c" Members, Route.Account ]
                    |> List.map Route.projectOf
                    |> Expect.equal [ Just "a", Just "b", Just "c", Nothing ]
        ]
