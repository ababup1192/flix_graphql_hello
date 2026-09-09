module AccountCodecs exposing (Id, codecs)

{-| Account API の scalar。ID を素の String にして、画面が包みを剥がさずに済むようにする。
-}

import Api.Account.Scalar
import Json.Decode as Decode
import Json.Encode


type alias Id =
    String


codecs : Api.Account.Scalar.Codecs Id
codecs =
    Api.Account.Scalar.defineCodecs
        { codecId =
            { encoder = Json.Encode.string
            , decoder = Decode.string
            }
        }
