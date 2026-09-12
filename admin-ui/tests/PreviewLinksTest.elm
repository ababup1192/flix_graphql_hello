module PreviewLinksTest exposing (suite)

{-| API プレビューの引き出しから Explorer とリファレンスへ渡す URL。
-}

import Expect
import Page.Preview as Preview
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Preview のリンク"
        [ describe "explorerUrl"
            [ test "query が空なら ?query= を付けない" <|
                \_ ->
                    Preview.explorerUrl "acme" ""
                        |> Expect.equal "/p/acme/graphiql"
            , test "日本語と改行は URL エンコードされる" <|
                \_ ->
                    Preview.explorerUrl "acme" "query 記事 {\n  blogs\n}"
                        |> Expect.equal "/p/acme/graphiql?query=query%20%E8%A8%98%E4%BA%8B%20%7B%0A%20%20blogs%0A%7D"
            ]
        , describe "docsUrl"
            [ test "プロジェクトのリファレンス" <|
                \_ ->
                    Preview.docsUrl "acme"
                        |> Expect.equal "/p/acme/docs"
            ]
        ]
