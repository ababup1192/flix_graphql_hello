module Navigate exposing (Move(..), moveFor, pick)

{-| URL のプロジェクトをどう扱うか、の判断だけを持つ。

`Main` から切り出してあるのは、ここが**無限リロードの分かれ目**だからで、
表で見張れる形にしている。

-}

import Model exposing (Project, Slug)


{-| URL のプロジェクトに対して何をするか。
-}
type Move
    = Stay
    | Reload
    | Unknown Slug


moveFor : { wanted : Maybe Slug, current : Maybe Slug, known : List Slug } -> Move
moveFor { wanted, current, known } =
    case wanted of
        Nothing ->
            Stay

        Just slug ->
            if current == Just slug then
                Stay

            else if List.member slug known then
                Reload

            else
                -- WhyNot: 読み込み直さない。入っていないプロジェクトは読み込み直しても
                -- 手に入らず、同じ判断をもう一度通って永久に読み込み直す。
                Unknown slug


{-| URL のプロジェクトを選ぶ。
-}
pick : Maybe Slug -> List Project -> Maybe Project
pick wanted projects =
    case wanted of
        Just slug ->
            -- WhyNot: 見つからない時に別のプロジェクトへ落とさない。
            -- 人が気付かないまま別のプロジェクトを編集する事になる。
            projects |> List.filter (\project -> project.slug == slug) |> List.head

        Nothing ->
            List.head projects
