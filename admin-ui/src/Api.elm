module Api exposing
    ( Call
    , Problem(..)
    , Request
    , Response
    , accountMutation
    , accountQuery
    , call
    , encodeRequest
    , mapCall
    , mutation
    , preview
    , problemToText
    , query
    , responseDecoder
    )

{-| CMS との通信の形。

**Elm は URL もヘッダも HTTP のメソッドも知らない。** 封筒（`{ id, kind, target, document, retriable }`）を
port で TypeScript に渡し、TypeScript が送る。dev のヘッダ（X-Dev-User）も TypeScript の外側の
proxy が付けるので、この層にも本番のビルドにも dev の分岐は入らない。

`requestId` は送る前に作って封筒に入れる（応答が返らなかった時も手元に id が残る）。

-}

import Api.Error as Error exposing (ApiError)
import Graphql.Document
import Graphql.Operation exposing (RootMutation, RootQuery)
import Graphql.SelectionSet exposing (SelectionSet)
import Json.Decode as D
import Json.Encode as E


{-| どちらの API に投げるか。管理 API はプロジェクトごとに URL が変わる。
-}
type Target
    = Admin String
    | Account
    | Content String


{-| 送る 1 本。`kind` はログと突き合わせるための人が読む名前（"me" / "updateEntry" など）。
-}
type alias Request =
    { id : String
    , kind : String
    , target : Target
    , document : String
    , retriable : Bool
    }


{-| 返ってきた 1 本。`ok` は HTTP が通ったか。`body` は GraphQL の応答の全体。
-}
type alias Response =
    { id : String
    , kind : String
    , ok : Bool
    , status : Int
    , requestId : Maybe String
    , body : D.Value
    }


{-| 読めなかった理由。

`Rejected` と `Unreachable` を分けるのは、**届いて断られた**のと**届かなかった**のとで
人がやる事が違うから（前者は requestId でログを引く、後者は接続を疑う）。

-}
type Problem
    = Failed (List ApiError)
    | Rejected { status : Int, requestId : Maybe String }
    | Unreachable
    | Malformed String



-- 組み立て


{-| 読むだけの物。**再試行してよい。**
-}
query : { id : String, kind : String, project : String } -> SelectionSet a RootQuery -> ( Request, D.Decoder a )
query args selection =
    ( { id = args.id
      , kind = args.kind
      , target = Admin args.project
      , document = named args.kind (Graphql.Document.serializeQuery selection)
      , retriable = True
      }
    , Graphql.Document.decoder selection
    )


{-| 書く物。**再試行しない**（createEntry や publishMany は冪等でなく、二重に作られる）。
-}
mutation : { id : String, kind : String, project : String } -> SelectionSet a RootMutation -> ( Request, D.Decoder a )
mutation args selection =
    ( { id = args.id
      , kind = args.kind
      , target = Admin args.project
      , document = named args.kind (Graphql.Document.serializeMutation selection)
      , retriable = False
      }
    , Graphql.Document.decoder selection
    )


accountMutation : { id : String, kind : String } -> SelectionSet a RootMutation -> ( Request, D.Decoder a )
accountMutation args selection =
    ( { id = args.id
      , kind = args.kind
      , target = Account
      , document = named args.kind (Graphql.Document.serializeMutation selection)
      , retriable = False
      }
    , Graphql.Document.decoder selection
    )


accountQuery : { id : String, kind : String } -> SelectionSet a RootQuery -> ( Request, D.Decoder a )
accountQuery args selection =
    ( { id = args.id
      , kind = args.kind
      , target = Account
      , document = named args.kind (Graphql.Document.serializeQuery selection)
      , retriable = True
      }
    , Graphql.Document.decoder selection
    )


{-| コンテンツ API に生の document を投げ、**応答をそのまま返す**。

API プレビューは「実際に返る JSON」を見せる物なので、`read` を通さない
（`read` は errors を失敗に畳んでしまい、人が見たい物が消える）。

-}
preview : { kind : String, project : String, document : String } -> (Response -> msg) -> Call msg
preview args toMsg id =
    ( { id = id
      , kind = args.kind
      , target = Content args.project
      , document = args.document
      , retriable = True
      }
    , toMsg
    )


{-| 匿名の document に操作名を付ける。

elm-graphql は名前の無い `query { ... }` を作る。名前が無いままだと CMS のログに
どの操作かが残らず、`operationName` を別に送ると「そんな操作は無い」で 500 になる。

名前は GraphQL の Name の形（英数字と `_`。数字始まりは不可）に丸める。

-}
named : String -> String -> String
named kind document =
    let
        safe : String
        safe =
            kind
                |> String.filter (\c -> Char.isAlphaNum c || c == '_')
                |> String.left 64

        prefix : String
        prefix =
            if String.isEmpty safe || Char.isDigit (String.left 1 safe |> String.toList |> List.head |> Maybe.withDefault '0') then
                "op"

            else
                safe
    in
    if String.startsWith "query {" document then
        "query " ++ prefix ++ " " ++ String.dropLeft 6 document

    else if String.startsWith "mutation {" document then
        "mutation " ++ prefix ++ " " ++ String.dropLeft 9 document

    else
        document


{-| 投げたい 1 本。**id はまだ決まっていない。**

ページは id を持たない（採番を配ると、どのページも通し番号を触る事になる）。
親が id を振って `Api.Request` にし、応答を `Api.Response -> msg` で持ち主に返す。

-}
type alias Call msg =
    String -> ( Request, Response -> msg )


{-| 「この query を投げて、結果をこの Msg にする」を 1 つの値にする。
-}
call : (String -> ( Request, D.Decoder a )) -> (Result Problem a -> msg) -> Call msg
call build toMsg id =
    let
        ( request, decoder ) =
            build id
    in
    ( request, \response -> toMsg (read decoder response) )


{-| ページの Msg を親の Msg に包む。
-}
mapCall : (a -> b) -> Call a -> Call b
mapCall change theCall id =
    theCall id |> Tuple.mapSecond (\handle -> handle >> change)



-- 封筒


encodeRequest : Request -> E.Value
encodeRequest request =
    E.object
        [ ( "id", E.string request.id )
        , ( "kind", E.string request.kind )
        , ( "path", E.string (pathOf request.target) )
        , ( "document", E.string request.document )
        , ( "retriable", E.bool request.retriable )
        ]


pathOf : Target -> String
pathOf target =
    case target of
        Admin project ->
            "/p/" ++ project ++ "/admin/graphql"

        Account ->
            "/account/graphql"

        Content project ->
            "/p/" ++ project ++ "/graphql"


responseDecoder : D.Decoder Response
responseDecoder =
    D.map6 Response
        (D.field "id" D.string)
        (D.field "kind" D.string)
        (D.field "ok" D.bool)
        (D.oneOf [ D.field "status" D.int, D.succeed 0 ])
        (D.maybe (D.field "requestId" D.string))
        (D.oneOf [ D.field "body" D.value, D.succeed E.null ])



-- 読む


{-| 応答を読む。**errors を先に読む。**

data を先に読むと、認証切れ（200 + path 無しの errors 1 件）や部分的失敗が
「謎のデコード失敗」になり、ログインし直しの画面に入れない。

-}
read : D.Decoder a -> Response -> Result Problem a
read dataDecoder response =
    if not response.ok then
        case D.decodeValue errorsDecoder response.body of
            Ok (first :: rest) ->
                Err (Failed (first :: rest))

            _ ->
                if response.status == 0 then
                    Err Unreachable

                else
                    Err (Rejected { status = response.status, requestId = response.requestId })

    else
        case D.decodeValue errorsDecoder response.body of
            Ok (first :: rest) ->
                Err (Failed (first :: rest))

            _ ->
                case D.decodeValue dataDecoder response.body of
                    Ok value ->
                        Ok value

                    Err err ->
                        Err (Malformed (D.errorToString err))


{-| 1 件の失敗を人に出す文にする。message が空なら code をそのまま見せる。
-}
describe : ApiError -> String
describe err =
    if String.isEmpty err.message then
        Error.codeText err.code

    else
        err.message


errorsDecoder : D.Decoder (List ApiError)
errorsDecoder =
    D.field "errors" (D.list Error.decoder)


{-| 人に出す文と、ログを引く鍵。

id は押してコピーできるように分けて返す（本文に混ぜると選びにくい）。

-}
problemToText : Problem -> { message : String, requestId : Maybe String }
problemToText problem =
    case problem of
        Failed errors ->
            { message = errors |> List.map describe |> String.join " / "
            , requestId = errors |> List.filterMap .requestId |> List.head
            }

        Rejected rejection ->
            { message = "サーバが " ++ String.fromInt rejection.status ++ " を返しました"
            , requestId = rejection.requestId
            }

        Unreachable ->
            { message = "サーバに届きませんでした", requestId = Nothing }

        Malformed detail ->
            { message = "応答の形が想定と違いました: " ++ String.left 200 detail
            , requestId = Nothing
            }
