module RouteTest exposing (suite)

{-| Route — URL の往復。
-}

import Expect
import Fuzz exposing (Fuzzer)
import Route exposing (Route(..), SettingsTab(..))
import Test exposing (Test, describe, fuzz, test)
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
                    |> List.map (\named -> Url.fromString ("https://x/p/tech-blog/settings/" ++ named) |> Maybe.map Route.fromUrl)
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
                    |> List.map (\named -> Url.fromString ("https://x/p/tech-blog/settings/" ++ named) |> Maybe.map Route.fromUrl)
                    |> Expect.equal
                        [ Just (NotFound (Just "tech-blog"))
                        , Just (NotFound (Just "tech-blog"))
                        , Just (NotFound (Just "tech-blog"))
                        , Just (NotFound (Just "tech-blog"))
                        ]
        , test "プロジェクトの下の知らない URL は、そのプロジェクトの NotFound" <|
            \_ ->
                [ "https://x/p/demo/media"
                , "https://x/p/demo/c/blogs/nope/nope"
                , "https://x/p/demo/assets/extra"
                ]
                    |> List.map (\text -> Url.fromString text |> Maybe.map Route.fromUrl)
                    |> Expect.equal
                        [ Just (NotFound (Just "demo"))
                        , Just (NotFound (Just "demo"))
                        , Just (NotFound (Just "demo"))
                        ]
        , test "プロジェクトの外の知らない URL は、プロジェクトを持たない NotFound" <|
            \_ ->
                [ "https://x/nonsense"
                , "https://x/nope/nope"
                , "https://x/account/nope"
                , "https://x/p"
                , "https://x/p/"
                ]
                    |> List.map (\text -> Url.fromString text |> Maybe.map Route.fromUrl)
                    |> Expect.equal
                        [ Just (NotFound Nothing)
                        , Just (NotFound Nothing)
                        , Just (NotFound Nothing)
                        , Just (NotFound Nothing)
                        , Just (NotFound Nothing)
                        ]
        , test "NotFound を文字列に戻す" <|
            \_ ->
                [ NotFound (Just "demo"), NotFound Nothing ]
                    |> List.map Route.toString
                    |> Expect.equal [ "/p/demo/not-found", "/not-found" ]
        , test "プロジェクトの slug をルートから取れる" <|
            \_ ->
                [ Entries "a" "blogs" [], Media "b", Settings "c" Members, Route.Account ]
                    |> List.map Route.projectOf
                    |> Expect.equal [ Just "a", Just "b", Just "c", Nothing ]
        , fuzz routeFuzzer "どの構築子でも、文字列にして読み直すと同じルートになる" <|
            \route ->
                Route.fromString (Route.toString route) |> Expect.equal (Just route)
        , test "見本が構築子を 1 つ残らず網羅している" <|
            \_ ->
                samples
                    |> List.map index
                    |> List.sort
                    |> Expect.equal (List.range 0 (List.length samples - 1))
        ]


{-| 往復の見本。`index` の case と組で、構築子を足した時にここを足し忘れると落ちる。
-}
samples : List Route
samples =
    [ Home
    , Projects
    , Account
    , AccountTokens
    , Organization "o1"
    , ProjectHome "a"
    , Entries "a" "blogs" []
    , Board "a" "blogs"
    , TypeSchema "a" "blogs"
    , TypeSettings "a" "blogs"
    , NewEntry "a" "blogs"
    , Entry "a" "blogs" "e1"
    , Media "a"
    , Settings "a" Members
    , NotFound (Just "a")
    ]


{-| 構築子ごとの通し番号。**`_ ->` を書かない。** 構築子を足すとここが網羅でなくなり、
往復の見本を足すまでコンパイルが通らない。
-}
index : Route -> Int
index route =
    case route of
        Home ->
            0

        Projects ->
            1

        Account ->
            2

        AccountTokens ->
            3

        Organization _ ->
            4

        ProjectHome _ ->
            5

        Entries _ _ _ ->
            6

        Board _ _ ->
            7

        TypeSchema _ _ ->
            8

        TypeSettings _ _ ->
            9

        NewEntry _ _ ->
            10

        Entry _ _ _ ->
            11

        Media _ ->
            12

        Settings _ _ ->
            13

        NotFound _ ->
            14


{-| 往復を試すルート。slug・apiId・絞り込みを振り、設定のタブも全て通る。
-}
routeFuzzer : Fuzzer Route
routeFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Home
        , Fuzz.constant Projects
        , Fuzz.constant Account
        , Fuzz.constant AccountTokens
        , Fuzz.constant (NotFound Nothing)
        , Fuzz.map (NotFound << Just) name
        , Fuzz.map Organization name
        , Fuzz.map ProjectHome name
        , Fuzz.map3 Entries name name (params [ "q", "where", "f", "order", "page", "cols", "after", "view" ])
        , Fuzz.map2 Board name name
        , Fuzz.map2 TypeSchema name name
        , Fuzz.map2 TypeSettings name name
        , Fuzz.map2 NewEntry name name
        , Fuzz.map3 Entry name name name
        , Fuzz.map Media name
        , Fuzz.map2 Settings name settingsTab
        ]


name : Fuzzer String
name =
    Fuzz.oneOfValues [ "a", "tech-blog", "shop2", "01J7Q" ]


settingsTab : Fuzzer SettingsTab
settingsTab =
    Fuzz.oneOf
        [ Fuzz.constant Members
        , Fuzz.constant ApiKeys
        , Fuzz.constant Webhooks
        , Fuzz.constant Workflow
        , Fuzz.constant ProjectSettings
        , Fuzz.map Audit (params [ "kind", "action", "since", "until", "id" ])
        ]


{-| URL に残る絞り込み。**決めた順の部分列だけ**を作る（順は Route が決めていて、
入れ替えて渡すと並べ直されて返る）。
-}
params : List String -> Fuzzer (List ( String, String ))
params keys =
    keys
        |> List.map (\key -> Fuzz.maybe (Fuzz.map (Tuple.pair key) value))
        |> List.foldr (Fuzz.map2 (::)) (Fuzz.constant [])
        |> Fuzz.map (List.filterMap identity)


value : Fuzzer String
value =
    Fuzz.oneOfValues [ "flix", "2026-09-01", "a-b", "member." ]
