module DateTimeTest exposing (suite)

{-| Ui.DateTime.daysFromToday: 今日から ISO 8601 の日時までの日数。手元のタイムゾーンの日付で数える。
-}

import Expect
import Test exposing (Test, describe, test)
import Time
import Ui.DateTime


{-| 日本時間（+9）。
-}
jst : Time.Zone
jst =
    Time.customZone (9 * 60) []


today : { year : Int, month : Int, day : Int }
today =
    { year = 2026, month = 9, day = 11 }


suite : Test
suite =
    describe "daysFromToday"
        [ test "3 日後" <|
            \_ -> Ui.DateTime.daysFromToday jst today "2026-09-14T03:00:00Z" |> Expect.equal (Just 3)
        , test "昨日" <|
            \_ -> Ui.DateTime.daysFromToday jst today "2026-09-10T03:00:00Z" |> Expect.equal (Just -1)
        , test "UTC では前日でも、日本時間では今日" <|
            \_ -> Ui.DateTime.daysFromToday jst today "2026-09-10T16:00:00Z" |> Expect.equal (Just 0)
        , test "月をまたぐ" <|
            \_ -> Ui.DateTime.daysFromToday jst today "2026-10-01T00:00:00Z" |> Expect.equal (Just 20)
        , test "読めなければ Nothing" <|
            \_ -> Ui.DateTime.daysFromToday jst today "" |> Expect.equal Nothing
        ]
