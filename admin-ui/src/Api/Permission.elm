module Api.Permission exposing (Permission(..), canSeeProjectSettings, fromList, has)

{-| 権限。CMS は `[String!]!` で返すので型で守られない。ここで custom type に落とし、知らない文字列は捨てる。

判定は CMS がする。画面はボタンを出すか出さないかを決めるだけ（docs/design/admin-ui-spec.md 10.4）。

WhyNot: 役割（管理者 / 編集者 …）で分岐しない。役割と権限の対応は CMS の Datalog が持っていて、
画面が写しを持つと二重管理になる。

-}


type Permission
    = ReadDraft
    | WriteEntries
    | PublishEntries
    | ManageTypes
    | ManageAssets
    | ManageMembers
    | ManageApiKeys
    | ManageProject


fromString : String -> Maybe Permission
fromString text =
    case text of
        "readDraft" ->
            Just ReadDraft

        "writeEntries" ->
            Just WriteEntries

        "publishEntries" ->
            Just PublishEntries

        "manageTypes" ->
            Just ManageTypes

        "manageAssets" ->
            Just ManageAssets

        "manageMembers" ->
            Just ManageMembers

        "manageApiKeys" ->
            Just ManageApiKeys

        "manageProject" ->
            Just ManageProject

        _ ->
            Nothing


fromList : List String -> List Permission
fromList =
    List.filterMap fromString


has : Permission -> List Permission -> Bool
has =
    List.member


{-| サイドバーに「プロジェクト設定」を出すか。設定の中はタブごとに更に絞る。
-}
canSeeProjectSettings : List Permission -> Bool
canSeeProjectSettings permissions =
    List.any (\p -> has p permissions) [ ManageMembers, ManageApiKeys, ManageProject ]
