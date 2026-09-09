module ApiTest exposing (suite)

{-| Api — 封筒の形と、操作名の埋め込み。
-}

import Api
import Api.Account.Object.Me as Me
import Api.Account.Query
import Expect
import Json.Decode as D
import Json.Encode as E
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Api"
        [ test "匿名の query に操作名が埋まる" <|
            \_ ->
                Api.accountQuery { id = "r1", kind = "me" } (Api.Account.Query.me Me.email)
                    |> Tuple.first
                    |> .document
                    |> String.startsWith "query me {"
                    |> Expect.equal True
        , test "読むだけの物は再試行してよい" <|
            \_ ->
                Api.accountQuery { id = "r1", kind = "me" } (Api.Account.Query.me Me.email)
                    |> Tuple.first
                    |> .retriable
                    |> Expect.equal True
        , test "封筒は id / kind / path / document / retriable を持つ" <|
            \_ ->
                Api.accountQuery { id = "r1", kind = "me" } (Api.Account.Query.me Me.email)
                    |> Tuple.first
                    |> Api.encodeRequest
                    |> E.encode 0
                    |> D.decodeString (D.map2 Tuple.pair (D.field "path" D.string) (D.field "retriable" D.bool))
                    |> Expect.equal (Ok ( "/account/graphql", True ))
        ]
