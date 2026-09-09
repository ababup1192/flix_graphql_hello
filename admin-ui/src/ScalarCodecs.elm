module ScalarCodecs exposing (Id, Json, codecs)

import Api.Admin.Scalar
import Json.Decode as Decode
import Json.Encode


type alias Id =
    String


type alias Json =
    Decode.Value


codecs : Api.Admin.Scalar.Codecs Id Json
codecs =
    Api.Admin.Scalar.defineCodecs
        { codecId =
            { encoder = \raw -> Json.Encode.string raw
            , decoder = Decode.string
            }
        , codecJson =
            { encoder = identity
            , decoder = Decode.value
            }
        }
