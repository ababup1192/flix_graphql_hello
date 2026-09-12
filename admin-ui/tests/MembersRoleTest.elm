module MembersRoleTest exposing (suite)

{-| Members — 役割の綴りの読み取り。
-}

import Api.Admin.Enum.Role as Role
import Expect
import Page.Members as Members
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Members"
        [ test "選べる綴りは全て読める（選択肢と読み取りがずれたら落ちる）" <|
            \_ ->
                Members.roleOptions
                    |> List.map (Tuple.first >> Members.roleOf)
                    |> Expect.equal
                        [ Just Role.Owner, Just Role.Editor, Just Role.Writer, Just Role.Viewer ]
        , test "知らない綴りは読めない（投稿者に落とさない）" <|
            \_ ->
                [ "owner", "ADMIN", "" ]
                    |> List.map Members.roleOf
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        ]
