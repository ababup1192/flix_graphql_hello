module Navigate exposing (Asked(..), Move(..), askedOf, moveFor, pick)

{-| URL のプロジェクトをどう扱うか、の判断だけを持つ。

`Main` から切り出してあるのは、ここが**無限リロードの分かれ目**だからで、
表で見張れる形にしている。

-}

import Model exposing (Project, Slug)
import Route exposing (Route)


{-| URL が求めているプロジェクト。

WhyNot: `Maybe Slug` で持たない。「プロジェクトを持たないルート」と「URL を読めなかった」が
同じ `Nothing` になり、読めなかった URL で先頭のプロジェクトを開いてしまう。

-}
type Asked
    = ForProject Slug
    | NoProject
    | Unreadable


{-| URL のプロジェクトに対して何をするか。
-}
type Move
    = Stay
    | Reload
    | Unknown Slug


askedOf : Route -> Asked
askedOf route =
    case route of
        Route.NotFound ->
            Unreadable

        _ ->
            case Route.projectOf route of
                Just slug ->
                    ForProject slug

                Nothing ->
                    NoProject


moveFor : { wanted : Asked, current : Maybe Slug, known : List Slug } -> Move
moveFor { wanted, current, known } =
    case wanted of
        NoProject ->
            Stay

        Unreadable ->
            -- WhyNot: 読み込み直さない。読めなかった URL には行き先が無く、
            -- 読み込み直しても同じ所に戻る。404 はその場で出す。
            Stay

        ForProject slug ->
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
pick : Asked -> List Project -> Maybe Project
pick wanted projects =
    case wanted of
        ForProject slug ->
            -- WhyNot: 見つからない時に別のプロジェクトへ落とさない。
            -- 人が気付かないまま別のプロジェクトを編集する事になる。
            projects |> List.filter (\project -> project.slug == slug) |> List.head

        NoProject ->
            List.head projects

        Unreadable ->
            -- WhyNot: 先頭へ落とさない。本文が 404 のまま上のバーとサイドバーだけ
            -- 別のプロジェクトを指し、リンクを押すと本当にそこへ入ってしまう。
            Nothing
