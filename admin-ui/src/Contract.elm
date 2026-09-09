port module Contract exposing (main)

{-| 契約の確認に使う document を吐き出すだけの入口。

`Queries.all` が返す物をそのまま出す。**query を足す時は Queries に足せば、確認も自動で増える。**

-}

import Api
import Json.Encode as E
import Queries


port contractOut : E.Value -> Cmd msg


main : Program E.Value () ()
main =
    Platform.worker
        { init = \_ -> ( (), contractOut documents )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


documents : E.Value
documents =
    Queries.all { project = "default" }
        |> E.list (Tuple.second >> Api.encodeRequest)
