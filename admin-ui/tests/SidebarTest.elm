module SidebarTest exposing (suite)

{-| Sidebar — プロジェクトを選んでいる時といない時で、何の行を出すか。
-}

import Api.Permission as Permission exposing (Permission)
import Expect
import Model exposing (ContentTypeSummary, Project)
import Sidebar exposing (Item(..))
import Test exposing (Test, describe, test)


project : Project
project =
    { id = "p1", slug = "tech-blog", name = "Tech Blog", visibility = "PUBLIC", role = "ADMIN" }


blogs : ContentTypeSummary
blogs =
    { id = "t1", apiId = "blogs", name = "ブログ", kind = "COLLECTION", icon = "book" }


all : List Permission
all =
    [ Permission.ManageTypes, Permission.ManageMembers, Permission.ManageApiKeys, Permission.ManageProject ]


suite : Test
suite =
    describe "Sidebar"
        [ test "プロジェクトを選んでいなければ、選び直す行だけ" <|
            \_ ->
                Sidebar.items { project = Nothing, permissions = all, types = [ blogs ] }
                    |> Expect.equal [ PickProjectRow ]
        , test "プロジェクトの中の行は全て、その URL の slug で組む" <|
            \_ ->
                Sidebar.items { project = Just project, permissions = all, types = [ blogs ] }
                    |> Expect.equal
                        [ ApiRow "tech-blog" blogs
                        , NewApiRow "tech-blog"
                        , MediaRow "tech-blog"
                        , ProjectSettingsRow "tech-blog"
                        ]
        , test "権限が無ければ、API の作成とプロジェクト設定は出さない" <|
            \_ ->
                Sidebar.items { project = Just project, permissions = [], types = [ blogs ] }
                    |> Expect.equal [ ApiRow "tech-blog" blogs, MediaRow "tech-blog" ]
        ]
