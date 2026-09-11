module Route exposing (Route(..), SettingsTab(..), fromString, fromUrl, projectOf, toString)

{-| URL の型。仕様 6.2 の表がそのままここに来る。

一覧の絞り込み・並び・列・ページも URL に持つ（戻っても状態が残る。絞り込んだ一覧を共有できる）。
今は素通しの文字列で持ち、意味づけは一覧のページがする。

WhyNot: elm-pages や elm-spa を使わない。ルートは 1 ファイルで足りる。

-}

import Url exposing (Url)
import Url.Builder as B
import Url.Parser as P exposing ((</>), Parser)
import Url.Parser.Query as Q


type Route
    = Home
    | Projects
    | Account
    | AccountTokens
    | Organization String
      {- プロジェクトの入口。**最初の API に送るだけ**の URL。
         プロジェクトを切り替える所と、`/p/{slug}/c/` を手で打った時の行き先。
      -}
    | ProjectHome String
    | Entries String String (List ( String, String ))
    | Board String String
    | TypeSchema String String
    | TypeSettings String String
    | NewEntry String String
    | Entry String String String
    | Media String
    | Settings String SettingsTab
    | NotFound


type SettingsTab
    = Members
    | ApiKeys
    | Webhooks
    | Workflow
    | ProjectSettings
    | Audit (List ( String, String ))


{-| 一覧で URL に残す物。値をここでだけ決め、ページと Route が同じ名前を使う。
-}
listParams : List String
listParams =
    [ "q", "where", "f", "order", "page", "cols", "after", "view" ]


{-| 監査ログで URL に残す物。絞り込み（誰が / 何を / 期間）と、開いている行の id。
-}
auditParams : List String
auditParams =
    [ "kind", "action", "since", "until", "id" ]


{-| 自分で組んだ絶対パスをルートに戻す。URL を書き換えた後に route を合わせるのに使う。
-}
fromString : String -> Maybe Route
fromString path =
    Url.fromString ("http://x" ++ path) |> Maybe.map fromUrl


fromUrl : Url -> Route
fromUrl url =
    P.parse (parser url) url |> Maybe.withDefault NotFound


parser : Url -> Parser (Route -> a) a
parser url =
    P.oneOf
        [ P.map Home P.top
        , P.map Projects (P.s "projects")
        , P.map Account (P.s "account")
        , P.map AccountTokens (P.s "account" </> P.s "tokens")
        , P.map Organization (P.s "account" </> P.s "orgs" </> P.string)
        , P.map ProjectHome (P.s "p" </> P.string)
        , P.map ProjectHome (P.s "p" </> P.string </> P.s "c")
        , P.map (\p t -> Entries p t (queryOf listParams url)) (P.s "p" </> P.string </> P.s "c" </> P.string)
        , P.map Board (P.s "p" </> P.string </> P.s "c" </> P.string </> P.s "board")
        , P.map TypeSchema (P.s "p" </> P.string </> P.s "c" </> P.string </> P.s "schema")
        , P.map TypeSettings (P.s "p" </> P.string </> P.s "c" </> P.string </> P.s "settings")
        , P.map NewEntry (P.s "p" </> P.string </> P.s "c" </> P.string </> P.s "new")
        , P.map Entry (P.s "p" </> P.string </> P.s "c" </> P.string </> P.string)
        , P.map Media (P.s "p" </> P.string </> P.s "assets")
        , P.map (\p -> Settings p Members) (P.s "p" </> P.string </> P.s "settings")
        , P.map (\p tab -> Settings p (settingsTabOf (queryOf auditParams url) tab)) (P.s "p" </> P.string </> P.s "settings" </> P.string)
        ]


{-| 一覧の絞り込みなどを、決めたキーの分だけ拾う。知らないキーは捨てる。
-}
queryOf : List String -> Url -> List ( String, String )
queryOf keys url =
    keys
        |> List.filterMap
            (\key ->
                P.parse (P.query (Q.string key)) { url | path = "" }
                    |> Maybe.andThen identity
                    |> Maybe.map (Tuple.pair key)
            )


{-| タブの名前から。query は監査ログだけが使う（他のタブは絞り込みを持たない）。
-}
settingsTabOf : List ( String, String ) -> String -> SettingsTab
settingsTabOf query text =
    case text of
        "audit" ->
            Audit query

        "api-keys" ->
            ApiKeys

        "webhooks" ->
            Webhooks

        "workflow" ->
            Workflow

        "project" ->
            ProjectSettings

        _ ->
            Members


settingsTabText : SettingsTab -> String
settingsTabText tab =
    case tab of
        Members ->
            "members"

        ApiKeys ->
            "api-keys"

        Webhooks ->
            "webhooks"

        Workflow ->
            "workflow"

        ProjectSettings ->
            "project"

        Audit _ ->
            "audit"


toString : Route -> String
toString route =
    case route of
        Home ->
            B.absolute [] []

        Projects ->
            B.absolute [ "projects" ] []

        Account ->
            B.absolute [ "account" ] []

        AccountTokens ->
            B.absolute [ "account", "tokens" ] []

        Organization id ->
            B.absolute [ "account", "orgs", id ] []

        ProjectHome project ->
            B.absolute [ "p", project ] []

        Entries project typeApiId params ->
            B.absolute [ "p", project, "c", typeApiId ] (List.map (\( k, v ) -> B.string k v) params)

        Board project typeApiId ->
            B.absolute [ "p", project, "c", typeApiId, "board" ] []

        TypeSchema project typeApiId ->
            B.absolute [ "p", project, "c", typeApiId, "schema" ] []

        TypeSettings project typeApiId ->
            B.absolute [ "p", project, "c", typeApiId, "settings" ] []

        NewEntry project typeApiId ->
            B.absolute [ "p", project, "c", typeApiId, "new" ] []

        Entry project typeApiId entryId ->
            B.absolute [ "p", project, "c", typeApiId, entryId ] []

        Media project ->
            B.absolute [ "p", project, "assets" ] []

        Settings project tab ->
            B.absolute [ "p", project, "settings", settingsTabText tab ] (List.map (\( k, v ) -> B.string k v) (settingsQuery tab))

        NotFound ->
            B.absolute [ "not-found" ] []


settingsQuery : SettingsTab -> List ( String, String )
settingsQuery tab =
    case tab of
        Audit query ->
            query

        _ ->
            []


{-| その URL がどのプロジェクトの物か。管理 API の URL を組むのに要る。
-}
projectOf : Route -> Maybe String
projectOf route =
    case route of
        ProjectHome project ->
            Just project

        Entries project _ _ ->
            Just project

        Board project _ ->
            Just project

        TypeSchema project _ ->
            Just project

        TypeSettings project _ ->
            Just project

        NewEntry project _ ->
            Just project

        Entry project _ _ ->
            Just project

        Media project ->
            Just project

        Settings project _ ->
            Just project

        _ ->
            Nothing
