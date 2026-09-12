module Navigate exposing (Asked(..), Landing(..), Move(..), askedOf, landingOf, moveFor, needsTypes, pick)

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
      {- WhyNot: slug を捨てない。読めない URL でもプロジェクトの下なら、
         上のバーとサイドバーはそのプロジェクトのまま出せる。
      -}
    | Unreadable (Maybe Slug)


{-| URL のプロジェクトに対して何をするか。
-}
type Move
    = Stay
    | Reload
    | Unknown Slug


askedOf : Route -> Asked
askedOf route =
    case route of
        Route.NotFound slug ->
            Unreadable slug

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

        Unreadable _ ->
            -- WhyNot: 読み込み直さない。読めなかった URL には行き先が無く、
            -- 読み込み直しても同じ所に戻る。404 はその場で出す。
            --
            -- WhyNot: slug を持っていても `ForProject` と同じ扱いにしない。
            -- 新規ロードでは `current` が `Nothing` なので `Reload` になり、
            -- 読み込み直した先で同じ判断を通って永久に読み込み直す。
            -- slug を使うのは選ぶ（`pick`）時だけ。
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


{-| プロジェクトの入口（`ProjectHome` / `Home`）で何をするか。
-}
type Landing a
    = Waiting
    | GoFirst a
    | NoTypes


{-| 入口の行き先。

WhyNot: 空の `types` だけを見て決めない。「まだ取得していない」と「0 件」が
同じ空になり、画面を開いた直後に必ず 0 件の側（API を作成）へ落ちる。

-}
landingOf : { arrived : Bool, types : List a } -> Landing a
landingOf { arrived, types } =
    if not arrived then
        Waiting

    else
        case List.head types of
            Just first ->
                GoFirst first

            Nothing ->
                NoTypes


{-| 型が届いてから決まるルートか。**届いた時にここをやり直す**ので、
この表が漏れると入口が待機のまま止まる。
-}
needsTypes : Route -> Bool
needsTypes route =
    case route of
        Route.Home ->
            True

        Route.ProjectHome _ ->
            True

        _ ->
            False


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

        Unreadable (Just slug) ->
            -- WhyNot: 枠ごと失わせない。URL がプロジェクトを名指ししているのに
            -- 選ばないと、打ち間違いだけで自分の居たプロジェクトが消える。
            -- 見つからない時に別のプロジェクトへ落とさないのは `ForProject` と同じ。
            projects |> List.filter (\project -> project.slug == slug) |> List.head

        Unreadable Nothing ->
            -- WhyNot: 先頭へ落とさない。本文が 404 のまま上のバーとサイドバーだけ
            -- 別のプロジェクトを指し、リンクを押すと本当にそこへ入ってしまう。
            Nothing
