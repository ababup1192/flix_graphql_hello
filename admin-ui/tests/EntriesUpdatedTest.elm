module EntriesUpdatedTest exposing (suite)

{-| Page.Entries — 一覧の更新日時の見せ方。相対で出し、絶対の日時はホバーに回す。
-}

import Expect
import Page.Entries as Entries
import Test exposing (Test, describe, test)
import Time


{-| 日本時間（+9）。
-}
jst : Time.Zone
jst =
    Time.customZone (9 * 60) []


today : Maybe { year : Int, month : Int, day : Int }
today =
    Just { year = 2026, month = 9, day = 12 }


suite : Test
suite =
    describe "Entries.updatedSay"
        [ describe "今日が分かる時は相対で出し、ホバーは手元のタイムゾーンの日時"
            (List.map
                (\( iso, expected ) -> test iso (\_ -> Entries.updatedSay jst today iso |> Expect.equal expected))
                [ ( "2026-09-12T07:49:00Z", { shown = "今日", title = Just "2026-09-12 16:49" } )
                , ( "2026-09-11T20:00:00Z", { shown = "今日", title = Just "2026-09-12 05:00" } )
                , ( "2026-09-11T14:00:00Z", { shown = "昨日", title = Just "2026-09-11 23:00" } )
                , ( "2026-09-09T00:00:00Z", { shown = "3 日前", title = Just "2026-09-09 09:00" } )
                ]
            )
        , test "今日がまだ分からなければ絶対の日時（UTC のままにしない）" <|
            \_ ->
                Entries.updatedSay jst Nothing "2026-09-12T07:49:00Z"
                    |> Expect.equal { shown = "2026-09-12 16:49", title = Nothing }
        , test "読めない値はそのまま出す" <|
            \_ ->
                Entries.updatedSay jst today "unknown"
                    |> Expect.equal { shown = "unknown", title = Nothing }
        ]
