module Sidebar exposing (Item(..), items)

{-| サイドバーに何の行を出すか、の判断だけを持つ。

`Shell` から切り出してあるのは、ここが**プロジェクト未選択の分かれ目**だからで、
表で見張れる形にしている。行が slug を持つので、プロジェクトを選んでいない時に
プロジェクトの中へのリンクを作りようが無い。

-}

import Api.Permission as Permission exposing (Permission)
import Model exposing (ContentTypeSummary, Project, Slug)


type Item
    = ApiRow Slug ContentTypeSummary
    | NewApiRow Slug
    | MediaRow Slug
    | ProjectSettingsRow Slug
    | PickProjectRow


items : { project : Maybe Project, permissions : List Permission, types : List ContentTypeSummary } -> List Item
items config =
    case config.project of
        Nothing ->
            -- WhyNot: 空の見出しだけを出さない。何も押せない列が残り、
            -- 読み込み中なのか入る所が無いのかが読めない。
            [ PickProjectRow ]

        Just project ->
            List.map (ApiRow project.slug) config.types
                ++ (if Permission.has Permission.ManageTypes config.permissions then
                        [ NewApiRow project.slug ]

                    else
                        []
                   )
                ++ MediaRow project.slug
                :: (if Permission.canSeeProjectSettings config.permissions then
                        [ ProjectSettingsRow project.slug ]

                    else
                        []
                   )
