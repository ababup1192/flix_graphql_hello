module Api.Error exposing
    ( ApiError
    , Code(..)
    , Path
    , Seg(..)
    , Violation
    , codeOf
    , codeText
    , decoder
    , isAuthProblem
    , parsePath
    , pathToString
    , violationsFor
    )

{-| GraphQL の errors[] を型にする置き場。

`Main` でなくここに在るのは、失敗の分類が純粋な規則で、画面から独立にテストしたいから。
CMS 側の分類は docs/design/error-codes.md が正で、ここはその写し。

WhyNot: `Graphql.Http` の `RawError` を使わない。封筒の port で送るので生の Value しか手元に無く、
どのみち自前で読む事になる。

-}

import Json.Decode as D



-- コード


{-| extensions.code の 7 種類。知らない文字列は Unknown に落とす（CMS が増やしても画面は壊れない）。
-}
type Code
    = Invalid
    | NotFound
    | Forbidden
    | Conflict
    | RequiresLogin
    | Unauthenticated
    | Internal
    | Unknown String


{-| errors[] の 1 件。

  - path: GraphQL の応答の path（どのフィールドで落ちたか）。認証の失敗では空
  - violations: INVALID の時だけ中身がある
  - entity / entityId: NOT\_FOUND と CONFLICT で何が無かったか
  - requestId: INTERNAL の時だけ。ログの行を引く鍵

-}
type alias ApiError =
    { message : String
    , code : Code
    , path : List String
    , violations : List Violation
    , entity : Maybe String
    , entityId : Maybe String
    , requestId : Maybe String
    , expectedVersion : Maybe Int
    , actualVersion : Maybe Int
    }


{-| 入力の違反 1 件。path はフォームのどの項目かを指す。
-}
type alias Violation =
    { path : Path
    , raw : String
    , message : String
    }



-- デコード


{-| errors[] の 1 件を読む。

violations のキーは 2 種類ある（`extensions.violations` は `field`、GraphQL の `Violation` 型は `path`）。
どちらでも読めるようにしてある。

-}
decoder : D.Decoder ApiError
decoder =
    D.map3
        (\message path ext ->
            { message = message
            , code = ext.code
            , path = path
            , violations = ext.violations
            , entity = ext.entity
            , entityId = ext.entityId
            , requestId = ext.requestId
            , expectedVersion = ext.expectedVersion
            , actualVersion = ext.actualVersion
            }
        )
        (D.oneOf [ D.field "message" D.string, D.succeed "" ])
        (D.oneOf [ D.field "path" (D.list pathSegmentDecoder), D.succeed [] ])
        (D.oneOf [ D.field "extensions" extensionsDecoder, D.succeed emptyExtensions ])


type alias Extensions =
    { code : Code
    , violations : List Violation
    , entity : Maybe String
    , entityId : Maybe String
    , requestId : Maybe String
    , expectedVersion : Maybe Int
    , actualVersion : Maybe Int
    }


emptyExtensions : Extensions
emptyExtensions =
    { code = Unknown ""
    , violations = []
    , entity = Nothing
    , entityId = Nothing
    , requestId = Nothing
    , expectedVersion = Nothing
    , actualVersion = Nothing
    }


extensionsDecoder : D.Decoder Extensions
extensionsDecoder =
    D.map7 Extensions
        (D.oneOf [ D.field "code" (D.map codeOf D.string), D.succeed (Unknown "") ])
        (D.oneOf [ D.field "violations" (D.list violationDecoder), D.succeed [] ])
        (D.maybe (D.field "entity" D.string))
        (D.maybe (D.field "id" D.string))
        (D.maybe (D.field "requestId" D.string))
        (D.maybe (D.field "expectedVersion" D.int))
        (D.maybe (D.field "actualVersion" D.int))


violationDecoder : D.Decoder Violation
violationDecoder =
    D.map2
        (\raw message -> { path = parsePath raw, raw = raw, message = message })
        (D.oneOf [ D.field "field" D.string, D.field "path" D.string, D.succeed "" ])
        (D.oneOf [ D.field "message" D.string, D.succeed "" ])


{-| 応答の path は文字列と数値が混ざる。
-}
pathSegmentDecoder : D.Decoder String
pathSegmentDecoder =
    D.oneOf [ D.string, D.map String.fromInt D.int ]


{-| 人に出す時の code の文字。知らない code はそのまま見せる（CMS が増やした時に気づける）。
-}
codeText : Code -> String
codeText code =
    case code of
        Invalid ->
            "INVALID"

        NotFound ->
            "NOT_FOUND"

        Forbidden ->
            "FORBIDDEN"

        Conflict ->
            "CONFLICT"

        RequiresLogin ->
            "REQUIRES_LOGIN"

        Unauthenticated ->
            "UNAUTHENTICATED"

        Internal ->
            "INTERNAL"

        Unknown other ->
            other


codeOf : String -> Code
codeOf text =
    case text of
        "INVALID" ->
            Invalid

        "NOT_FOUND" ->
            NotFound

        "FORBIDDEN" ->
            Forbidden

        "CONFLICT" ->
            Conflict

        "REQUIRES_LOGIN" ->
            RequiresLogin

        "UNAUTHENTICATED" ->
            Unauthenticated

        "INTERNAL" ->
            Internal

        other ->
            Unknown other


{-| ログインし直しが要る失敗。path が空で来る（リクエスト全体が断られた）。
-}
isAuthProblem : ApiError -> Bool
isAuthProblem err =
    case err.code of
        Unauthenticated ->
            True

        RequiresLogin ->
            True

        _ ->
            False



-- path


{-| violation の path。3 つの規則を 1 つの形に正規化する。

  - `fields.title` → segments = [ Key "fields", Key "title" ]
  - `fields.sections[0].headline` → [ Key "fields", Key "sections", Index 0, Key "headline" ]
  - `b1.fields.title`（publishMany）→ entryId = Just "b1"
  - `references` / `assets` のようにフィールドに紐づかない物 → segments 1 つだけ

-}
type alias Path =
    { entryId : Maybe String
    , segments : List Seg
    }


type Seg
    = Key String
    | Index Int


parsePath : String -> Path
parsePath raw =
    let
        segments : List Seg
        segments =
            raw
                |> String.split "."
                |> List.concatMap parsePart
    in
    case segments of
        (Key head) :: (Key "fields") :: rest ->
            { entryId = Just head, segments = Key "fields" :: rest }

        _ ->
            { entryId = Nothing, segments = segments }


{-| `sections[0]` のような 1 区切りを、名前と添字に割る。
-}
parsePart : String -> List Seg
parsePart part =
    case String.split "[" part of
        [] ->
            []

        name :: brackets ->
            let
                indexes : List Seg
                indexes =
                    brackets
                        |> List.filterMap
                            (\b ->
                                b
                                    |> String.replace "]" ""
                                    |> String.toInt
                                    |> Maybe.map Index
                            )
            in
            if String.isEmpty name then
                indexes

            else
                Key name :: indexes


pathToString : Path -> String
pathToString path =
    let
        body : String
        body =
            path.segments
                |> List.map
                    (\seg ->
                        case seg of
                            Key k ->
                                "." ++ k

                            Index i ->
                                "[" ++ String.fromInt i ++ "]"
                    )
                |> String.concat
                |> String.dropLeft 1

        prefix : String
        prefix =
            path.entryId |> Maybe.map (\id -> id ++ ".") |> Maybe.withDefault ""
    in
    prefix ++ body


{-| フォームの 1 項目（`fields.title` の `title`）に付ける違反を選ぶ。

richText の中まで伸びた path（`fields.body.content[2]...`）も、その項目の物として拾う。

-}
violationsFor : String -> List Violation -> List Violation
violationsFor apiId violations =
    violations
        |> List.filter
            (\v ->
                case v.path.segments of
                    (Key "fields") :: (Key name) :: _ ->
                        name == apiId

                    _ ->
                        False
            )
