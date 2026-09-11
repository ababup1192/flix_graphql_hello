module AuditSayTest exposing (suite)

{-| 監査の行の文と型紙。action ごとに 1 行。
-}

import Expect
import Json.Decode as D
import Json.Encode as E
import Model exposing (AuditRow)
import Page.Audit.Say as Say
import Test exposing (Test, describe, test)
import Time


suite : Test
suite =
    describe "Page.Audit.Say"
        [ describe "畳んだ行の文"
            (List.map sentenceTest sentences)
        , describe "開いた行の型紙"
            (List.map sheetTest sheets)
        , describe "並び替えに今の順を足す"
            [ test "動いた物だけに印が付く" <|
                \_ ->
                    Say.orderWith [ "a", "c", "d", "b" ] (Say.Order { before = [ "a", "b", "c", "d" ], after = Nothing, moved = [] })
                        |> Expect.equal (Say.Order { before = [ "a", "b", "c", "d" ], after = Just [ "a", "c", "d", "b" ], moved = [ "b" ] })
            , test "並び替え以外の型紙はそのまま" <|
                \_ ->
                    Say.orderWith [ "a" ] Say.Nothing_ |> Expect.equal Say.Nothing_
            ]
        ]


{-| action / 対象の種類 / 対象の id / detail の JSON → 期待の文。
-}
sentences : List ( ( String, String, String ), String, String )
sentences =
    [ ( ( "member.invited", "member", "hana@example.com" ), """{"role":"editor"}""", "hana@example.com を招待した（権限: 編集者）" )
    , ( ( "member.role_changed", "member", "7" ), """{"role":"owner"}""", "7 の権限を 管理者 にした" )
    , ( ( "member.removed", "member", "7" ), "{}", "メンバー 7 を外した" )
    , ( ( "invitation.cancelled", "invitation", "inv1" ), "{}", "招待 inv1 を取り消した" )
    , ( ( "api_key.created", "api_key", "k1" ), """{"name":"CI"}""", "API キー CI を発行した" )
    , ( ( "api_key.revoked", "api_key", "k1" ), "{}", "API キー k1 を失効した" )
    , ( ( "type.created", "type", "blogs" ), "{}", "API blogs を作成した" )
    , ( ( "type.updated", "type", "blogs" ), """{"before":{"apiId":"blogs","name":"ブログ"}}""", "API blogs を変更した" )
    , ( ( "type.deleted", "type", "uxprobes" ), typeDeleted 3, "API uxprobes（2 フィールド）を削除した。削除済みのコンテンツ 3 件も消えた" )
    , ( ( "type.deleted", "type", "uxprobes" ), typeDeleted 0, "API uxprobes（2 フィールド）を削除した" )
    , ( ( "field.added", "field", "uxprobes.title" ), "{}", "uxprobes に title を追加した" )
    , ( ( "field.updated", "field", "uxprobes.title" ), fieldBefore, "uxprobes の title を変更した" )
    , ( ( "field.removed", "field", "uxprobes.title" ), fieldBefore, "uxprobes の title を削除した" )
    , ( ( "fields.reordered", "type", "uxprobes" ), """{"before":{"fields":["title","body"]}}""", "API uxprobes のフィールドを並べ替えた" )
    , ( ( "project.visibility_changed", "project", "default" ), """{"before":"private","after":"public"}""", "公開範囲を 非公開 → 公開 にした" )
    , ( ( "webhook.created", "webhook", "w1" ), webhook, "Webhook Slack 通知（hooks.slack.com）を作成した" )
    , ( ( "webhook.updated", "webhook", "w1" ), before webhook, "Webhook Slack 通知（hooks.slack.com）を変更した" )
    , ( ( "webhook.deleted", "webhook", "w1" ), before webhook, "Webhook Slack 通知（hooks.slack.com）を削除した" )
    , ( ( "webhook.deleted", "webhook", "w1" ), "{}", "Webhook w1 を削除した" )
    , ( ( "webhook.redelivered", "webhook_delivery", "d1" ), "{}", "Webhook の配信 d1 を再送した" )
    , ( ( "asset.confirmed", "asset", "a1" ), asset, "メディア a1（image/png、120 KB）をアップロードした" )
    , ( ( "asset.deleted", "asset", "a1" ), before asset, "メディア a1 を削除した" )
    , ( ( "entry.unpublished", "entry", "4dda8b954371" ), """{"typeApiId":"blogs","version":1}""", "API blogs のコンテンツ 4dda8b954371 の公開を終えた（v1）" )
    , ( ( "entry.deleted", "entry", "4dda8b954371" ), """{"typeApiId":"blogs","version":2}""", "API blogs のコンテンツ 4dda8b954371 を削除した（v2）" )
    , ( ( "entry.published", "entry", "4dda8b954371" ), """{"typeApiId":"blogs","version":4,"scheduledFor":"2026-09-10T13:00:00Z"}""", "API blogs のコンテンツ 4dda8b954371 を予約どおり公開した（v4、予約は 2026-09-10 22:00 JST）" )
    , ( ( "foo.bar", "thing", "x" ), "{}", "foo.bar（thing x）" )
    ]


{-| action / 対象の種類 / 対象の id / detail の JSON → 期待の型紙の種類。
-}
sheets : List ( ( String, String, String ), String, String )
sheets =
    [ ( ( "member.invited", "member", "hana@example.com" ), """{"role":"editor"}""", "Facts" )
    , ( ( "member.role_changed", "member", "7" ), """{"role":"owner"}""", "Facts" )
    , ( ( "member.removed", "member", "7" ), "{}", "Nothing_" )
    , ( ( "invitation.cancelled", "invitation", "inv1" ), "{}", "Nothing_" )
    , ( ( "api_key.created", "api_key", "k1" ), """{"name":"CI"}""", "Facts" )
    , ( ( "api_key.revoked", "api_key", "k1" ), "{}", "Nothing_" )
    , ( ( "type.created", "type", "blogs" ), "{}", "Nothing_" )
    , ( ( "type.updated", "type", "blogs" ), """{"before":{"apiId":"blogs","name":"ブログ"}}""", "Changes" )
    , ( ( "type.deleted", "type", "uxprobes" ), typeDeleted 3, "FieldTable" )
    , ( ( "field.added", "field", "uxprobes.title" ), "{}", "Nothing_" )
    , ( ( "field.updated", "field", "uxprobes.title" ), fieldBefore, "Changes" )
    , ( ( "field.removed", "field", "uxprobes.title" ), fieldBefore, "FieldTable" )
    , ( ( "fields.reordered", "type", "uxprobes" ), """{"before":{"fields":["title","body"]}}""", "Order" )
    , ( ( "project.visibility_changed", "project", "default" ), """{"before":"private","after":"public"}""", "Changes" )
    , ( ( "webhook.created", "webhook", "w1" ), webhook, "Facts" )
    , ( ( "webhook.updated", "webhook", "w1" ), before webhook, "Facts" )
    , ( ( "webhook.deleted", "webhook", "w1" ), before webhook, "Facts" )
    , ( ( "webhook.redelivered", "webhook_delivery", "d1" ), "{}", "Nothing_" )
    , ( ( "asset.confirmed", "asset", "a1" ), asset, "Facts" )
    , ( ( "asset.deleted", "asset", "a1" ), before asset, "Facts" )
    , ( ( "entry.unpublished", "entry", "4dda8b954371" ), """{"typeApiId":"blogs","version":1}""", "Facts" )
    , ( ( "entry.deleted", "entry", "4dda8b954371" ), """{"typeApiId":"blogs","version":2}""", "Facts" )
    , ( ( "entry.published", "entry", "4dda8b954371" ), """{"typeApiId":"blogs","version":4,"scheduledFor":"2026-09-10T13:00:00Z"}""", "Facts" )
    , ( ( "foo.bar", "thing", "x" ), "{}", "Nothing_" )
    ]


sentenceTest : ( ( String, String, String ), String, String ) -> Test
sentenceTest ( ( action, kind, id ), json, expected ) =
    test (action ++ " → " ++ expected) <|
        \_ -> Say.sentence jst (rowOf action kind id json) |> Say.toText |> Expect.equal expected


sheetTest : ( ( String, String, String ), String, String ) -> Test
sheetTest ( ( action, kind, id ), json, expected ) =
    test (action ++ " → " ++ expected) <|
        \_ -> Say.sheet (rowOf action kind id json) |> kindOf |> Expect.equal expected


kindOf : Say.Sheet -> String
kindOf sheet =
    case sheet of
        Say.Changes _ ->
            "Changes"

        Say.Order _ ->
            "Order"

        Say.FieldTable _ ->
            "FieldTable"

        Say.Facts _ ->
            "Facts"

        Say.Nothing_ ->
            "Nothing_"


jst : Time.Zone
jst =
    Time.customZone (9 * 60) []


rowOf : String -> String -> String -> String -> AuditRow
rowOf action kind id json =
    { id = "01M26YZXM00GARCJXKA0NZ44J5"
    , actorKind = "USER"
    , actorId = "deb0f58dd032"
    , actor = "dev@localhost"
    , action = action
    , targetKind = kind
    , targetId = id
    , detail = D.decodeString D.value json |> Result.withDefault (E.object [])
    , createdAt = "2026-09-11T00:48:28Z"
    }


before : String -> String
before json =
    """{"before":""" ++ json ++ "}"


typeDeleted : Int -> String
typeDeleted purged =
    """{"before":{"apiId":"uxprobes","name":"UX probes","fields":[{"apiId":"title","name":"タイトル","kind":"text","required":true,"config":{"maxLength":120}},{"apiId":"body","name":"本文","kind":"richText","required":false,"config":{}}]},"purgedEntries":"""
        ++ String.fromInt purged
        ++ "}"


fieldBefore : String
fieldBefore =
    """{"before":{"apiId":"title","name":"タイトル","kind":"text","required":false,"unique":false,"many":false,"localized":false,"config":{"maxLength":120}}}"""


webhook : String
webhook =
    """{"name":"Slack 通知","url":{"host":"hooks.slack.com","pathHint":"/services/T0AAA/B0BBB/…","urlHash":"8f3a1c9e2b47"},"events":["entry.published"],"active":true}"""


asset : String
asset =
    """{"mime":"image/png","size":123456,"width":800,"height":600}"""
