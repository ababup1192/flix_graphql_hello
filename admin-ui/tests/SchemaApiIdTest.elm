module SchemaApiIdTest exposing (suite)

{-| Page.Schema — API / フィールドの ID の欄。未入力のうちは赤い理由を出さず、
押せないボタンで止める。
-}

import Expect
import Page.Schema as Schema
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Schema.apiIdSay / apiIdReady"
        [ test "開いた直後（未入力）は理由を出さない" <|
            \_ ->
                Schema.apiIdSay "" |> Expect.equal Nothing
        , test "未入力では作成のボタンを押せない" <|
            \_ ->
                Schema.apiIdReady "" |> Expect.equal False
        , describe "入力した値が綴りに合わなければ理由を出す"
            (List.map
                (\value -> test value (\_ -> Schema.apiIdSay value |> Expect.equal (Just "英字で始まり、英数字だけにしてください（例: publishedAt）")))
                [ "Blogs", "blog-posts", "1blogs", "ブログ" ]
            )
        , test "綴りに合う値は理由を出さない" <|
            \_ ->
                Schema.apiIdSay "publishedAt" |> Expect.equal Nothing
        , test "綴りに合う値なら押せる" <|
            \_ ->
                Schema.apiIdReady "publishedAt" |> Expect.equal True
        ]
