module ApiShapeTest exposing (suite)

{-| ApiShape: コンテンツ API の introspection を読み、型の綴りを組み立てる。
-}

import ApiShape
import Expect
import Json.Decode as D
import Test exposing (Test, describe, test)


{-| introspection の応答の見本。description は無い物と有る物を混ぜる（サーバ側は埋めている途中）。
-}
body : String
body =
    """
{ "data": { "__schema": { "types": [
  { "name": "Query", "kind": "OBJECT", "inputFields": null, "enumValues": null, "fields": [
    { "name": "blogs", "description": null, "type": { "kind": "NON_NULL", "name": null, "ofType": { "kind": "OBJECT", "name": "BlogConnection", "ofType": null } }, "args": [
      { "name": "first", "description": "1 ページの件数", "defaultValue": "20", "type": { "kind": "SCALAR", "name": "Int", "ofType": null } },
      { "name": "where", "description": null, "defaultValue": null, "type": { "kind": "INPUT_OBJECT", "name": "BlogWhere", "ofType": null } },
      { "name": "orderBy", "description": null, "defaultValue": null, "type": { "kind": "LIST", "name": null, "ofType": { "kind": "NON_NULL", "name": null, "ofType": { "kind": "ENUM", "name": "BlogOrderBy", "ofType": null } } } }
    ] },
    { "name": "authors", "description": null, "type": { "kind": "OBJECT", "name": "AuthorConnection", "ofType": null }, "args": [] }
  ] },
  { "name": "BlogConnection", "kind": "OBJECT", "inputFields": null, "enumValues": null, "fields": [
    { "name": "nodes", "description": null, "type": { "kind": "NON_NULL", "name": null, "ofType": { "kind": "LIST", "name": null, "ofType": { "kind": "NON_NULL", "name": null, "ofType": { "kind": "OBJECT", "name": "Blog", "ofType": null } } } }, "args": [] }
  ] },
  { "name": "BlogWhere", "kind": "INPUT_OBJECT", "enumValues": null, "fields": null, "inputFields": [
    { "name": "id_eq", "description": null, "type": { "kind": "SCALAR", "name": "ID", "ofType": null } },
    { "name": "title_eq", "description": "完全一致", "type": { "kind": "SCALAR", "name": "String", "ofType": null } },
    { "name": "title_in", "description": null, "type": { "kind": "LIST", "name": null, "ofType": { "kind": "NON_NULL", "name": null, "ofType": { "kind": "SCALAR", "name": "String", "ofType": null } } } },
    { "name": "title_contains", "description": null, "type": { "kind": "SCALAR", "name": "String", "ofType": null } },
    { "name": "author_id_eq", "description": null, "type": { "kind": "SCALAR", "name": "ID", "ofType": null } },
    { "name": "AND", "description": null, "type": { "kind": "LIST", "name": null, "ofType": { "kind": "INPUT_OBJECT", "name": "BlogWhereLeaf", "ofType": null } } }
  ] },
  { "name": "BlogOrderBy", "kind": "ENUM", "inputFields": null, "fields": null, "enumValues": [
    { "name": "publishedAt_ASC", "description": null },
    { "name": "publishedAt_DESC", "description": "公開日時の新しい順" }
  ] },
  { "name": "Blog", "kind": "OBJECT", "inputFields": null, "enumValues": null, "fields": [
    { "name": "id", "description": null, "type": { "kind": "NON_NULL", "name": null, "ofType": { "kind": "SCALAR", "name": "ID", "ofType": null } }, "args": [] },
    { "name": "body", "description": "本文", "type": { "kind": "OBJECT", "name": "RichText", "ofType": null }, "args": [] }
  ] },
  { "name": "RichText", "kind": "OBJECT", "inputFields": null, "enumValues": null, "fields": [
    { "name": "html", "description": null, "type": { "kind": "NON_NULL", "name": null, "ofType": { "kind": "SCALAR", "name": "String", "ofType": null } }, "args": [] }
  ] },
  { "name": "Asset", "kind": "OBJECT", "inputFields": null, "enumValues": null, "fields": [] }
] } } }
"""


decoded : Result D.Error ApiShape.Shape
decoded =
    D.decodeString (ApiShape.decoder "blogs") body


suite : Test
suite =
    describe "ApiShape"
        [ describe "decoder"
            [ test "where の入力フィールドはフィールド名ごとに畳まれ、演算子が並ぶ" <|
                \_ ->
                    decoded
                        |> Result.map (.filters >> List.map (\group -> ( group.field, List.map .operator group.operators )))
                        |> Expect.equal (Ok [ ( "id", [ "eq" ] ), ( "title", [ "eq", "in", "contains" ] ), ( "author", [ "id_eq" ] ), ( "AND", [ "" ] ) ])
            , test "型は SDL の綴りで出る" <|
                \_ ->
                    decoded
                        |> Result.map (.filters >> List.concatMap .operators >> List.map .typeText)
                        |> Expect.equal (Ok [ "ID", "String", "[String!]", "String", "ID", "[BlogWhereLeaf]" ])
            , test "description が無ければ空欄" <|
                \_ ->
                    decoded
                        |> Result.map (.filters >> List.concatMap .operators >> List.map .description)
                        |> Expect.equal (Ok [ "", "完全一致", "", "", "", "" ])
            , test "並び順は enum の値と説明" <|
                \_ ->
                    decoded
                        |> Result.map (.orders >> List.map (\order -> ( order.name, order.description )))
                        |> Expect.equal (Ok [ ( "publishedAt_ASC", "" ), ( "publishedAt_DESC", "公開日時の新しい順" ) ])
            , test "返る物のうち RichText は 1 段だけ展開される" <|
                \_ ->
                    decoded
                        |> Result.map (.returns >> List.map (\field -> ( field.name, field.typeText, List.map .name field.children )))
                        |> Expect.equal (Ok [ ( "id", "ID!", [] ), ( "body", "RichText", [ "html" ] ) ])
            , test "引数は自分の root field の物だけで、既定値も付く" <|
                \_ ->
                    decoded
                        |> Result.map (.arguments >> List.map (\arg -> ( arg.name, arg.typeText, arg.defaultValue )))
                        |> Expect.equal (Ok [ ( "first", "Int", "20" ), ( "where", "BlogWhere", "" ), ( "orderBy", "[BlogOrderBy!]", "" ) ])
            , test "root field が無い（1 件の名前を渡した等）なら引数は空" <|
                \_ ->
                    D.decodeString (ApiShape.decoder "nothing") body
                        |> Result.map .arguments
                        |> Expect.equal (Ok [])
            ]
        , describe "query"
            [ test "__type を並べず __schema を 1 回だけ引く" <|
                \_ ->
                    ( String.contains "__schema" ApiShape.query, String.contains "__type " ApiShape.query )
                        |> Expect.equal ( True, False )
            ]
        , describe "operatorName"
            [ test "参照の _id_in は 1 つの演算子" <|
                \_ ->
                    ApiShape.splitLeaf "author_id_in"
                        |> Expect.equal ( "author", "id_in" )
            , test "演算子が無い名前は丸ごとフィールド名" <|
                \_ ->
                    ApiShape.splitLeaf "OR"
                        |> Expect.equal ( "OR", "" )
            , test "フィールド名に _ があっても最後の演算子だけを切る" <|
                \_ ->
                    ApiShape.splitLeaf "sub_title_startsWith"
                        |> Expect.equal ( "sub_title", "startsWith" )
            ]
        ]
