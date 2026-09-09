module PermissionTest exposing (suite)

{-| Api.Permission — 文字列から権限へ、権限からボタンの出し分けへ。
-}

import Api.Permission as Permission exposing (Permission(..))
import Expect
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Api.Permission"
        [ test "知らない権限は捨てる" <|
            \_ ->
                Permission.fromList [ "readDraft", "writeEntries", "somethingNew" ]
                    |> Expect.equal [ ReadDraft, WriteEntries ]
        , test "編集者にはプロジェクト設定を出さない" <|
            \_ ->
                Permission.fromList [ "readDraft", "writeEntries", "publishEntries", "manageTypes", "manageAssets" ]
                    |> Permission.canSeeProjectSettings
                    |> Expect.equal False
        , test "管理者にはプロジェクト設定を出す" <|
            \_ ->
                Permission.fromList [ "readDraft", "manageMembers", "manageApiKeys", "manageProject" ]
                    |> Permission.canSeeProjectSettings
                    |> Expect.equal True
        ]
