module Ui.DateRange exposing (Model, Msg, close, dates, init, update, view, withToday)

{-| 期間を選ぶ。**暦をそのまま開き、始まりと終わりを 1 つの暦で続けて選ぶ。**

WhyNot: `<input type="date">` を 2 つ並べない。文字で打ちたい場面がほとんど無いのに
`mm / dd / yyyy` を打たせる形になり、並びも暦もブラウザの言語で決まる（`Ui.DateTime` と同じ理由）。
範囲を 2 つの欄に分けると、選んでいる間どこからどこまでかが見えない。

Google アナリティクス / Stripe / GitHub Insights と同じ形にしてある。よく使う期間を左に並べ、
暦は 1 つ、始まりを選ぶ → 終わりを選ぶ、の順。選んでいる間はなぞった所が帯で光る。

-}

import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick, onMouseEnter)
import Ui
import Ui.Icon as Icon


type alias Day =
    { year : Int, month : Int, day : Int }


type alias Model =
    { open : Bool
    , shownYear : Int
    , shownMonth : Int
    , from : Maybe Day
    , to : Maybe Day

    {- 終わりを選ぶ途中で、なぞっている日。帯を出すのに使う。 -}
    , hover : Maybe Day
    , today : Maybe Day
    }


type Msg
    = Opened
    | Closed
    | MonthMoved Int
    | DayChosen Day
    | DayHovered Day
    | PresetChosen Int
    | Cleared


{-| URL から来た `YYYY-MM-DD` の 2 つで始める。読めない物は空として扱う。
-}
init : { since : String, until : String } -> Model
init args =
    let
        from : Maybe Day
        from =
            dayOf args.since

        to : Maybe Day
        to =
            dayOf args.until

        shown : Day
        shown =
            from |> Maybe.withDefault { year = 2026, month = 1, day = 1 }
    in
    { open = False
    , shownYear = shown.year
    , shownMonth = shown.month
    , from = from
    , to = to
    , hover = Nothing
    , today = Nothing
    }


{-| 今日が分かったら覚える。暦の初めの月と「過去 N 日間」の基準になる。

**画面を描く時ではなく、`update` で覚える。** 描く時に混ぜると、次に押した時の計算が
覚えていない方（初めの月）で行われ、暦が別の月に飛ぶ（実際に飛んだ）。

-}
withToday : { year : Int, month : Int, day : Int } -> Model -> Model
withToday today model =
    { model
        | today = Just today
        , shownYear =
            if model.from == Nothing then
                today.year

            else
                model.shownYear
        , shownMonth =
            if model.from == Nothing then
                today.month

            else
                model.shownMonth
    }


close : Model -> Model
close model =
    { model | open = False, hover = Nothing }


{-| 今選んでいる期間。`YYYY-MM-DD` の 2 つで、空なら空文字。
-}
dates : Model -> { since : String, until : String }
dates model =
    { since = model.from |> Maybe.map isoOf |> Maybe.withDefault ""
    , until = model.to |> Maybe.map isoOf |> Maybe.withDefault ""
    }


{-| 今日を知らせる。親が `Effect.Today` で受け取って渡す。
-}
update : Msg -> Model -> Model
update msg model =
    case msg of
        Opened ->
            { model | open = True }

        Closed ->
            close model

        MonthMoved step ->
            let
                ( year, month ) =
                    shiftMonth model.shownYear model.shownMonth step
            in
            { model | shownYear = year, shownMonth = month }

        DayHovered day ->
            { model | hover = Just day }

        -- 1 回目は始まり、2 回目は終わり。始まりより前を押したら、そこを新しい始まりにする
        DayChosen day ->
            case ( model.from, model.to ) of
                ( Just from, Nothing ) ->
                    if before day from then
                        { model | from = Just day }

                    else
                        { model | from = Just from, to = Just day, hover = Nothing, open = False }

                _ ->
                    { model | from = Just day, to = Nothing, hover = Nothing }

        PresetChosen days ->
            case model.today of
                Just today ->
                    { model | from = Just (shiftDays today (negate days)), to = Just today, hover = Nothing, open = False }

                Nothing ->
                    model

        Cleared ->
            { model | from = Nothing, to = Nothing, hover = Nothing, open = False }


{-| 押すと暦が開くボタンと、その下の暦。
-}
view : (Msg -> msg) -> Model -> Html msg
view toMsg model =
    Html.map toMsg
        (div [ class "relative" ]
            [ Ui.ghostButton
                [ onClick
                    (if model.open then
                        Closed

                     else
                        Opened
                    )
                , class "w-64 justify-between"
                ]
                [ span [] [ text (label model) ], Icon.view Icon.calendar ]
            , if model.open then
                div [ class "absolute top-9 left-0 z-(--z-dropdown)" ] [ viewPanel model ]

              else
                text ""
            , if model.open then
                Ui.dismissLayer Closed

              else
                text ""
            ]
        )


label : Model -> String
label model =
    case ( model.from, model.to ) of
        ( Just from, Just to ) ->
            isoOf from ++ " 〜 " ++ isoOf to

        -- 終わりを選ぶ途中。ボタンの幅に収まる長さにして、案内は暦の中に出す
        ( Just from, Nothing ) ->
            isoOf from ++ " 〜"

        _ ->
            "すべての期間"


viewPanel : Model -> Html Msg
viewPanel model =
    div [ class "flex gap-2 rounded-md border border-edge bg-panel p-2 shadow-lg" ]
        [ div [ class "flex w-28 shrink-0 flex-col gap-1 border-r border-edge pr-2" ]
            (List.map viewPreset presets
                ++ [ Ui.quietActionLink [ onClick Cleared, class "mt-1 px-2 py-1 text-left" ] [ text "期間を外す" ] ]
            )
        , viewCalendar model
        ]


presets : List ( String, Int )
presets =
    [ ( "今日", 0 ), ( "過去 7 日間", 6 ), ( "過去 30 日間", 29 ), ( "過去 90 日間", 89 ) ]


viewPreset : ( String, Int ) -> Html Msg
viewPreset ( text_, days ) =
    Html.button
        [ class "rounded px-2 py-1 text-left text-[12px] text-ink hover:bg-well"
        , Html.Attributes.type_ "button"
        , onClick (PresetChosen days)
        ]
        [ text text_ ]


viewCalendar : Model -> Html Msg
viewCalendar model =
    div [ class "flex w-[252px] flex-col gap-2" ]
        [ div [ class "flex items-center gap-1" ]
            [ arrow (MonthMoved -1) "前の月" True
            , span [ class "flex-1 text-center text-[13px] font-semibold text-ink" ]
                [ text (String.fromInt model.shownYear ++ " 年 " ++ String.fromInt model.shownMonth ++ " 月") ]
            , arrow (MonthMoved 1) "次の月" False
            ]
        , div [ class "grid grid-cols-7 gap-y-0.5" ]
            (List.indexedMap viewWeekday weekdays ++ viewDays model)
        , case ( model.from, model.to ) of
            ( Just _, Nothing ) ->
                span [ class "text-center text-[11px] text-ink-soft" ] [ text "終わりの日を選んでください" ]

            _ ->
                text ""
        ]


weekdays : List String
weekdays =
    [ "日", "月", "火", "水", "木", "金", "土" ]


viewWeekday : Int -> String -> Html Msg
viewWeekday at text_ =
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
        [ text text_ ]


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


{-| 1 日。端は丸く塗り、間は帯にする。**選んでいる途中はなぞった所まで帯を伸ばす**
（どこからどこまでになるかを、押す前に見せる）。
-}
viewDay : Model -> Int -> Html Msg
viewDay model number =
    let
        day : Day
        day =
            { year = model.shownYear, month = model.shownMonth, day = number }

        finish : Maybe Day
        finish =
            case model.to of
                Just to ->
                    Just to

                Nothing ->
                    model.hover

        isEdge : Bool
        isEdge =
            model.from == Just day || finish == Just day

        inside : Bool
        inside =
            case ( model.from, finish ) of
                ( Just from, Just to ) ->
                    not (before day from) && not (before to day)

                _ ->
                    False

        isToday : Bool
        isToday =
            model.today == Just day
    in
    div
        [ class
            ("flex justify-center py-px "
                ++ (if inside && not isEdge then
                        "bg-well"

                    else
                        ""
                   )
            )
        ]
        [ Html.button
            [ class
                -- 今日は枠で示す。選んでいる日は塗りなので、塗りと枠で見分けが付く
                ("h-7 w-7 rounded text-[12px] "
                    ++ (if isToday && not isEdge then
                            "border border-accent "

                        else
                            ""
                       )
                    ++ (if isEdge then
                            "bg-accent font-semibold text-white"

                        else if inside then
                            "text-ink"

                        else
                            "text-ink hover:bg-well"
                       )
                )
            , Html.Attributes.type_ "button"
            , Html.Attributes.title
                (if isToday then
                    "今日"

                 else
                    ""
                )
            , onClick (DayChosen day)
            , onMouseEnter (DayHovered day)
            ]
            [ text (String.fromInt number) ]
        ]


arrow : Msg -> String -> Bool -> Html Msg
arrow msg title back =
    Ui.iconButton { title = title, onClick = msg }
        [ class
            (if back then
                "rotate-90"

             else
                "-rotate-90"
            )
        ]
        Icon.caret



-- 暦の計算。日付の並びだけなので Ui.DateTime とは別に持つ（あちらは時刻とタイムゾーンを持つ）


isoOf : Day -> String
isoOf day =
    pad 4 day.year ++ "-" ++ pad 2 day.month ++ "-" ++ pad 2 day.day


pad : Int -> Int -> String
pad width n =
    String.padLeft width '0' (String.fromInt n)


dayOf : String -> Maybe Day
dayOf date =
    case ( String.toInt (String.slice 0 4 date), String.toInt (String.slice 5 7 date), String.toInt (String.slice 8 10 date) ) of
        ( Just year, Just month, Just day ) ->
            if month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth year month then
                Just { year = year, month = month, day = day }

            else
                Nothing

        _ ->
            Nothing


before : Day -> Day -> Bool
before left right =
    ( left.year, left.month, left.day ) < ( right.year, right.month, right.day )


{-| step 日ずらす。1970-01-01 からの通算日で数える（`Ui.DateTime` と同じ数え方）。
-}
shiftDays : Day -> Int -> Day
shiftDays day step =
    fromEpochDays (toEpochDays day + step)


toEpochDays : Day -> Int
toEpochDays day =
    List.sum (List.map daysInYear (List.range 1970 (day.year - 1)))
        + List.sum (List.map (daysInMonth day.year) (List.range 1 (day.month - 1)))
        + (day.day - 1)


fromEpochDays : Int -> Day
fromEpochDays days =
    let
        year : Int
        year =
            yearOf 1970 days

        left : Int
        left =
            days - toEpochDays { year = year, month = 1, day = 1 }

        ( month, dayOfMonth ) =
            monthOf year 1 left
    in
    { year = year, month = month, day = dayOfMonth }


yearOf : Int -> Int -> Int
yearOf year days =
    let
        size : Int
        size =
            daysInYear year
    in
    if days < size then
        year

    else
        yearOf (year + 1) (days - size)


monthOf : Int -> Int -> Int -> ( Int, Int )
monthOf year month left =
    let
        size : Int
        size =
            daysInMonth year month
    in
    if left < size || month == 12 then
        ( month, left + 1 )

    else
        monthOf year (month + 1) (left - size)


daysInYear : Int -> Int
daysInYear year =
    List.sum (List.map (daysInMonth year) (List.range 1 12))


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


shiftMonth : Int -> Int -> Int -> ( Int, Int )
shiftMonth year month step =
    let
        moved : Int
        moved =
            (year * 12 + (month - 1)) + step
    in
    ( moved // 12, modBy 12 moved + 1 )


{-| その月の 1 日が何曜日か（0 = 日）。
-}
firstWeekday : Int -> Int -> Int
firstWeekday year month =
    modBy 7 (toEpochDays { year = year, month = month, day = 1 } + 4)
