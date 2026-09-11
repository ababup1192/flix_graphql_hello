module Ui.DateTime exposing
    ( Model
    , Msg
    , dayAfterToIso
    , dayToIso
    , formatLocal
    , formatLocalShort
    , init
    , toIso
    , toIsoDate
    , update
    , view
    , viewDate
    , zoneAbbr
    )

{-| 日時を選ぶ。**年月日の順、曜日は日月火水木金土。**

WhyNot: `<input type="datetime-local">` を使わない。並び（月/日/年）も月の名前も曜日も
**ブラウザと OS の言語で決まり、ページからは変えられない**。日本語の環境でも英語のまま出て、
`09 / 09 / 2026` の順になる（実際にそう出た）。

**時刻は最初から入れておく**（既定 9:00）。空のままだと、日付だけ選んだ時に
ブラウザが「Please enter valid date and time」と断る。

暦の計算は自前で持つ（`elm/time` だけで、外の暦のライブラリを足さない）。

-}

import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick, onInput)
import Time
import Ui
import Ui.Icon as Icon


type alias Model =
    { year : Int
    , month : Int
    , day : Int
    , hour : Int
    , minute : Int

    {- 一覧に出している月。日を選ばずに前後の月を見られる。 -}
    , shownYear : Int
    , shownMonth : Int
    }


type Msg
    = MonthMoved Int
    | DayChosen Int Int Int
    | HourChosen String
    | MinuteChosen String


{-| 今日の次の日の 9 時から始める。**予約は「これから」の物**なので、今日より前を既定にしない。
-}
init : { year : Int, month : Int, day : Int } -> Model
init today =
    let
        ( year, month, day ) =
            nextDay today.year today.month today.day
    in
    { year = year
    , month = month
    , day = day
    , hour = 9
    , minute = 0
    , shownYear = year
    , shownMonth = month
    }


update : Msg -> Model -> Model
update msg model =
    case msg of
        MonthMoved step ->
            let
                ( year, month ) =
                    shiftMonth model.shownYear model.shownMonth step
            in
            { model | shownYear = year, shownMonth = month }

        DayChosen year month day ->
            { model | year = year, month = month, day = day, shownYear = year, shownMonth = month }

        HourChosen typed ->
            { model | hour = String.toInt typed |> Maybe.withDefault model.hour }

        MinuteChosen typed ->
            { model | minute = String.toInt typed |> Maybe.withDefault model.minute }


{-| CMS に送る形（ISO 8601、UTC）。人が選んだのは手元のタイムゾーンの時刻なので、
UTC に直してから送る。

WhyNot: 選んだ値をそのまま `Z` を付けて送らない。手元が UTC でない限り時差の分だけずれる。

-}
toIso : Time.Zone -> Model -> String
toIso zone model =
    let
        wall : Int
        wall =
            wallMillis model.year model.month model.day model.hour model.minute

        at : Time.Posix
        at =
            Time.millisToPosix (wall - offsetMillis zone wall)
    in
    pad 4 (Time.toYear Time.utc at)
        ++ "-"
        ++ pad 2 (monthNumber (Time.toMonth Time.utc at))
        ++ "-"
        ++ pad 2 (Time.toDay Time.utc at)
        ++ "T"
        ++ pad 2 (Time.toHour Time.utc at)
        ++ ":"
        ++ pad 2 (Time.toMinute Time.utc at)
        ++ ":00Z"


{-| 日付だけの欄に送る形（`YYYY-MM-DD`）。

WhyNot: UTC に直さない。日付だけの値は時刻を持たないので、時差で日をずらすと
「9 月 9 日」と入れた物が 9 月 8 日になる。人が暦で押した日をそのまま送る。

-}
toIsoDate : Model -> String
toIsoDate model =
    pad 4 model.year ++ "-" ++ pad 2 model.month ++ "-" ++ pad 2 model.day


{-| CMS から来た UTC の ISO 8601 を、手元のタイムゾーンの `YYYY-MM-DD HH:MM` に。

WhyNot: 読めない文字列を空にしない。CMS が形を変えた時に、画面から予約が消えたように
見えるより、そのまま出た方が気付ける。

-}
formatLocal : Time.Zone -> String -> String
formatLocal zone iso =
    case ( parseInt 0 4 iso, ( parseInt 5 7 iso, parseInt 8 10 iso ), ( parseInt 11 13 iso, parseInt 14 16 iso ) ) of
        ( Just year, ( Just month, Just day ), ( Just hour, Just minute ) ) ->
            let
                utc : Int
                utc =
                    wallMillis year month day hour minute

                at : Time.Posix
                at =
                    Time.millisToPosix utc
            in
            pad 4 (Time.toYear zone at)
                ++ "-"
                ++ pad 2 (monthNumber (Time.toMonth zone at))
                ++ "-"
                ++ pad 2 (Time.toDay zone at)
                ++ " "
                ++ pad 2 (Time.toHour zone at)
                ++ ":"
                ++ pad 2 (Time.toMinute zone at)

        _ ->
            String.left 16 iso


{-| 一覧の狭い列に出す形（`MM-DD HH:MM`）。年は展開した所の ISO 8601 で分かる。
-}
formatLocalShort : Time.Zone -> String -> String
formatLocalShort zone iso =
    String.dropLeft 5 (formatLocal zone iso)


{-| 手元のタイムゾーンの略号。+09:00 は JST、0 は UTC、他は `UTC+hh:mm` の形。

WhyNot: 地名（Asia/Tokyo）を出さない。Elm の `Time.Zone` は名前を持たず、
port を足してまで出す物でもない（この CMS の利用者はほぼ日本）。

-}
zoneAbbr : Time.Zone -> String -> String
zoneAbbr zone iso =
    let
        minutes : Int
        minutes =
            case ( parseInt 0 4 iso, ( parseInt 5 7 iso, parseInt 8 10 iso ) ) of
                ( Just year, ( Just month, Just day ) ) ->
                    offsetMillis zone (wallMillis year month day 0 0) // 60000

                _ ->
                    offsetMillis zone 0 // 60000

        sign : String
        sign =
            if minutes < 0 then
                "-"

            else
                "+"
    in
    if minutes == 9 * 60 then
        "JST"

    else if minutes == 0 then
        "UTC"

    else
        "UTC" ++ sign ++ pad 2 (abs minutes // 60) ++ ":" ++ pad 2 (modBy 60 (abs minutes))


{-| `YYYY-MM-DD` の**手元の 0 時**を UTC の ISO 8601 に。期間の始まりに使う。
-}
dayToIso : Time.Zone -> String -> Maybe String
dayToIso zone date =
    Maybe.map (\( year, month, day ) -> toIso zone { year = year, month = month, day = day, hour = 0, minute = 0, shownYear = year, shownMonth = month })
        (parseDate date)


{-| `YYYY-MM-DD` の**次の日の手元の 0 時**を UTC の ISO 8601 に。「その日まで」を未満で送る時に使う。
-}
dayAfterToIso : Time.Zone -> String -> Maybe String
dayAfterToIso zone date =
    Maybe.map
        (\( year, month, day ) ->
            let
                ( nextYear, nextMonth, nextDate ) =
                    nextDay year month day
            in
            toIso zone { year = nextYear, month = nextMonth, day = nextDate, hour = 0, minute = 0, shownYear = nextYear, shownMonth = nextMonth }
        )
        (parseDate date)


parseDate : String -> Maybe ( Int, Int, Int )
parseDate date =
    case ( parseInt 0 4 date, parseInt 5 7 date, parseInt 8 10 date ) of
        ( Just year, Just month, Just day ) ->
            if month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth year month then
                Just ( year, month, day )

            else
                Nothing

        _ ->
            Nothing


parseInt : Int -> Int -> String -> Maybe Int
parseInt from to text =
    String.toInt (String.slice from to text)


pad : Int -> Int -> String
pad width value =
    String.padLeft width '0' (String.fromInt value)



-- タイムゾーン


{-| 1970-01-01 00:00 からの経過（ミリ秒）。何のタイムゾーンかは呼ぶ側が決める。
-}
wallMillis : Int -> Int -> Int -> Int -> Int -> Int
wallMillis year month day hour minute =
    ((daysFromEpoch year month day * 24 + hour) * 60 + minute) * 60000


daysFromEpoch : Int -> Int -> Int -> Int
daysFromEpoch year month day =
    List.sum (List.map daysInYear (List.range 1970 (year - 1)))
        + List.sum (List.map (daysInMonth year) (List.range 1 (month - 1)))
        + (day - 1)


daysInYear : Int -> Int
daysInYear year =
    List.sum (List.map (daysInMonth year) (List.range 1 12))


{-| その時刻での時差（ミリ秒）。`wall` は UTC の目盛りで数えたミリ秒。
-}
offsetMillis : Time.Zone -> Int -> Int
offsetMillis zone wall =
    let
        at : Time.Posix
        at =
            Time.millisToPosix wall
    in
    wallMillis (Time.toYear zone at)
        (monthNumber (Time.toMonth zone at))
        (Time.toDay zone at)
        (Time.toHour zone at)
        (Time.toMinute zone at)
        - wall


{-| 手元のタイムゾーンが日本時間からずれている時だけ出す断り。揃っていれば `Nothing`。

WhyNot: 常に出さない。**日本のユーザーには要らない情報**で、日時の欄の横に何か書いてある
だけで読む物が増える。日本の SaaS 9 社（kintone / Backlog / Garoon / freee / SmartHR /
Shopify 日本語版 / ジョブカン / マネーフォワード / サイボウズ Office）は全社、日時を入れる欄に
タイムゾーンを出していない。

WhyNot: 消し切りもしない。この CMS は**チームで使う**ので、出張中や海外のメンバーが端末の
時刻で予約すると、東京の同僚が見た時に読み違える。Sanity #1923 は、別のタイムゾーンから
見た人が「間違っている」と思って直し、元の日時が壊れ続けた例。

WhyNot: `UTC+09:00` のような機械の表記にしない。調べた 24 社で入力欄にオフセットを出して
いるのは 2 社だけで、その 2 社も地名を添える。NN/g は「**ほとんどのユーザーは自分のオフセットを
知らない**」と書いている。

判定は WordPress の `timezone.tsx` と同じでオフセットだけを見る。同じ +09:00 の別の
タイムゾーン（ソウルなど）では出ないが、日本時間として読んで実害が無い。

-}
offsetLabel : Time.Zone -> Model -> Maybe String
offsetLabel zone model =
    let
        minutes : Int
        minutes =
            offsetMillis zone (wallMillis model.year model.month model.day model.hour model.minute) // 60000
    in
    if minutes == 9 * 60 then
        Nothing

    else
        Just "日本時間ではありません"


monthNumber : Time.Month -> Int
monthNumber month =
    case month of
        Time.Jan ->
            1

        Time.Feb ->
            2

        Time.Mar ->
            3

        Time.Apr ->
            4

        Time.May ->
            5

        Time.Jun ->
            6

        Time.Jul ->
            7

        Time.Aug ->
            8

        Time.Sep ->
            9

        Time.Oct ->
            10

        Time.Nov ->
            11

        Time.Dec ->
            12



-- 暦


{-| うるう年。4 で割れて、100 で割れず、400 で割れる年は入れる。
-}
daysInMonth : Int -> Int -> Int
daysInMonth year month =
    case month of
        2 ->
            if modBy 4 year == 0 && (modBy 100 year /= 0 || modBy 400 year == 0) then
                29

            else
                28

        4 ->
            30

        6 ->
            30

        9 ->
            30

        11 ->
            30

        _ ->
            31


nextDay : Int -> Int -> Int -> ( Int, Int, Int )
nextDay year month day =
    if day < daysInMonth year month then
        ( year, month, day + 1 )

    else if month < 12 then
        ( year, month + 1, 1 )

    else
        ( year + 1, 1, 1 )


shiftMonth : Int -> Int -> Int -> ( Int, Int )
shiftMonth year month step =
    let
        moved : Int
        moved =
            (year * 12 + (month - 1)) + step
    in
    ( moved // 12, modBy 12 moved + 1 )


{-| その月の 1 日が何曜日か（0 = 日）。Sakamoto の方法。
-}
firstWeekday : Int -> Int -> Int
firstWeekday year month =
    let
        shift : Int
        shift =
            [ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 ] |> List.drop (month - 1) |> List.head |> Maybe.withDefault 0

        y : Int
        y =
            if month < 3 then
                year - 1

            else
                year
    in
    modBy 7 (y + y // 4 - y // 100 + y // 400 + shift + 1)



-- 画面


weekdays : List String
weekdays =
    [ "日", "月", "火", "水", "木", "金", "土" ]


view : Time.Zone -> Model -> Html Msg
view zone model =
    viewCalendar model
        [ div [ class "flex flex-wrap items-center gap-1 border-t border-edge pt-2" ]
            [ span [ class "shrink-0 text-[11px] text-ink-soft" ] [ text "時刻" ]
            , Ui.select [ onInput HourChosen ] (List.range 0 23 |> List.map (numberOption "時")) (String.fromInt model.hour)
            , Ui.select [ onInput MinuteChosen ] ([ 0, 15, 30, 45 ] |> List.map (numberOption "分")) (String.fromInt model.minute)
            , viewOffset zone model
            ]
        ]


{-| 日付だけを選ぶ。**時刻の行を出さない。**

WhyNot: `view` を使い回さない。日付だけの値に時刻の欄が付いていると、選んでも
どこにも入らない物を触らせる事になる。タイムゾーンの断りも要らない（時刻を持たない）。

-}
viewDate : Model -> Html Msg
viewDate model =
    viewCalendar model []


viewCalendar : Model -> List (Html Msg) -> Html Msg
viewCalendar model below =
    div [ class "flex w-[268px] max-w-full flex-col gap-2 rounded-md border border-edge bg-panel p-2" ]
        (div [ class "flex items-center gap-1" ]
            [ arrow (MonthMoved -1) "前の月" True
            , span [ class "flex-1 text-center text-[13px] font-semibold text-ink" ]
                [ text (String.fromInt model.shownYear ++ " 年 " ++ String.fromInt model.shownMonth ++ " 月") ]
            , arrow (MonthMoved 1) "次の月" False
            ]
            :: div [ class "grid grid-cols-7 gap-0.5" ]
                (List.indexedMap viewWeekday weekdays ++ viewDays model)
            :: below
        )


viewOffset : Time.Zone -> Model -> Html Msg
viewOffset zone model =
    case offsetLabel zone model of
        Nothing ->
            text ""

        Just label ->
            span
                [ class "ml-auto shrink-0 text-[11px] text-[color:var(--color-warn)]"
                , Html.Attributes.title "お使いの端末のタイムゾーンで指定しています。日本時間で指定したい場合は時刻を読み替えてください。"
                ]
                [ text label ]


numberOption : String -> Int -> ( String, String )
numberOption unit value =
    ( String.fromInt value, String.fromInt value ++ " " ++ unit )


arrow : Msg -> String -> Bool -> Html Msg
arrow msg label back =
    Html.button
        [ class "flex h-6 w-6 items-center justify-center rounded text-ink-soft hover:bg-well hover:text-ink"
        , Html.Attributes.title label
        , onClick msg
        ]
        [ div
            [ class
                (if back then
                    "rotate-90"

                 else
                    "-rotate-90"
                )
            ]
            [ Icon.view Icon.caret ]
        ]


viewWeekday : Int -> String -> Html Msg
viewWeekday at label =
    span
        [ class
            ("py-1 text-center text-[11px] "
                ++ (if at == 0 then
                        "text-[color:var(--color-bad)]"

                    else if at == 6 then
                        "text-link"

                    else
                        "text-ink-faint"
                   )
            )
        ]
        [ text label ]


viewDays : Model -> List (Html Msg)
viewDays model =
    let
        blanks : Int
        blanks =
            firstWeekday model.shownYear model.shownMonth

        total : Int
        total =
            daysInMonth model.shownYear model.shownMonth
    in
    List.repeat blanks (span [] []) ++ List.map (viewDay model) (List.range 1 total)


viewDay : Model -> Int -> Html Msg
viewDay model day =
    let
        chosen : Bool
        chosen =
            model.year == model.shownYear && model.month == model.shownMonth && model.day == day
    in
    Html.button
        [ class
            ("h-7 rounded text-[12px] "
                ++ (if chosen then
                        "bg-accent font-semibold text-white"

                    else
                        "text-ink hover:bg-well"
                   )
            )
        , onClick (DayChosen model.shownYear model.shownMonth day)
        ]
        [ text (String.fromInt day) ]
