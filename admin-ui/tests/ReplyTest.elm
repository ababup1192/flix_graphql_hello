module ReplyTest exposing (suite)

{-| Ui.Reply: サーバの失敗を「欄の下に出す物」と「ボタンの横に出す物」に振り分ける。
-}

import Api
import Api.Error
import Expect
import Test exposing (Test, describe, test)
import Ui.Reply as Reply


violation : String -> String -> Api.Error.Violation
violation path message =
    { path = Api.Error.parsePath path, raw = path, message = message }


apiError : String -> List Api.Error.Violation -> Api.Error.ApiError
apiError message violations =
    { message = message
    , code = Api.Error.Invalid
    , path = []
    , violations = violations
    , entity = Nothing
    , entityId = Nothing
    , requestId = Nothing
    , expectedVersion = Nothing
    , actualVersion = Nothing
    }


suite : Test
suite =
    describe "Ui.Reply.failed"
        [ test "path の先頭が欄の名前なら、その欄に付く" <|
            \_ ->
                Reply.failed (Api.Failed [ apiError "name: 空です" [ violation "name" "空です" ] ])
                    |> Reply.errorsFor "name"
                    |> Expect.equal [ "空です" ]
        , test "path が id の違反は、欄が無いのでボタンの横" <|
            \_ ->
                Reply.failed (Api.Failed [ apiError "id: entry が 3 件あります" [ violation "id" "entry が 3 件あります" ] ])
                    |> Reply.general
                    |> Expect.equal [ "entry が 3 件あります" ]
        , test "違反の無い失敗はそのまま横に" <|
            \_ ->
                Reply.failed (Api.Failed [ apiError "この操作の権限がありません" [] ])
                    |> Reply.general
                    |> Expect.equal [ "この操作の権限がありません" ]
        , test "届かなかった時も横に" <|
            \_ ->
                Reply.failed Api.Unreachable
                    |> Reply.general
                    |> Expect.equal [ "サーバに届きませんでした" ]
        , test "触ると理由が下りる" <|
            \_ ->
                Reply.failed (Api.Failed [ apiError "x" [ violation "name" "空です" ] ])
                    |> Reply.touched
                    |> Reply.errorsFor "name"
                    |> Expect.equal []
        ]
