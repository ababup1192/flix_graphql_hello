module ProjectPageTest exposing (suite)

{-| Page.Project.mcpUrl: MCP のつなぎ先。配備のオリジン（CMS\_PUBLIC\_ORIGIN）の後ろにプロジェクトを繋ぐ。
オリジンが無ければ出さない。
-}

import Expect
import Model exposing (Project)
import Page.Project
import Test exposing (Test, describe, test)


demo : Project
demo =
    { id = "p1", slug = "demo", name = "デモ", visibility = "PUBLIC", role = "owner" }


suite : Test
suite =
    describe "mcpUrl"
        [ test "公開側のオリジンの後ろに /p/{slug}/mcp" <|
            \_ ->
                Page.Project.mcpUrl { project = demo, publicOrigin = "https://cms.example.com" }
                    |> Expect.equal (Just "https://cms.example.com/p/demo/mcp")
        , test "開発ではコンテンツ API のポート" <|
            \_ ->
                Page.Project.mcpUrl { project = demo, publicOrigin = "http://localhost:8080" }
                    |> Expect.equal (Just "http://localhost:8080/p/demo/mcp")
        , test "オリジンが無ければ出さない（管理画面のオリジンで代わりに組まない）" <|
            \_ ->
                Page.Project.mcpUrl { project = demo, publicOrigin = "" }
                    |> Expect.equal Nothing
        ]
