module Loaded exposing (Loaded(..), fromResult, map, toMaybe, view)

{-| 読み込みの状態。

**`Maybe` で表さない。** `Maybe` 1 つだと「まだ来ていない」「無かった」「失敗した」が同じ形になり、
画面がぐるぐる回り続ける（実際に起きた）。

`Missing` は「サーバが null を返した」で、`Failed` は「応答が読めなかった」。人がやる事が違う。

-}

import Api
import Html exposing (Html)


type Loaded a
    = Loading
    | Missing
    | Failed String
    | Present a


{-| 応答から状態を作る。null を返す query は `Maybe` で来るので、それも畳む。
-}
fromResult : Result Api.Problem (Maybe a) -> Loaded a
fromResult result =
    case result of
        Ok (Just value) ->
            Present value

        Ok Nothing ->
            Missing

        Err problem ->
            Failed (Api.problemToText problem).message


map : (a -> a) -> Loaded a -> Loaded a
map change loaded =
    case loaded of
        Present value ->
            Present (change value)

        other ->
            other


toMaybe : Loaded a -> Maybe a
toMaybe loaded =
    case loaded of
        Present value ->
            Just value

        _ ->
            Nothing


{-| 4 つの状態を描き分ける。中身がある時だけ `present` を呼ぶ。
-}
view :
    { loading : Html msg
    , missing : Html msg
    , failed : String -> Html msg
    , present : a -> Html msg
    }
    -> Loaded a
    -> Html msg
view how loaded =
    case loaded of
        Loading ->
            how.loading

        Missing ->
            how.missing

        Failed message ->
            how.failed message

        Present value ->
            how.present value
