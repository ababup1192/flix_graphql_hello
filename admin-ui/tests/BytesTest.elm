module BytesTest exposing (suite)

{-| Ui.Bytes.human: ファイルの大きさを人が読む単位にする。

メディアの一覧・エディタのカバー画像・監査ログの 3 画面が同じ字を出す。

-}

import Expect
import Test exposing (Test, describe, test)
import Ui.Bytes


suite : Test
suite =
    describe "Ui.Bytes.human"
        (List.map
            (\( size, expected ) ->
                test (String.fromInt size ++ " → " ++ expected)
                    (\_ -> Ui.Bytes.human size |> Expect.equal expected)
            )
            [ -- B の範囲。0 も 1 も丸めずにそのまま出す
              ( 0, "0 B" )
            , ( 1, "1 B" )
            , ( 999, "999 B" )
            , ( 1023, "1023 B" )

            -- KB の境目。1024 ちょうどから KB
            , ( 1024, "1 KB" )
            , ( 1025, "1 KB" )
            , ( 2048, "2 KB" )
            , ( 1048575, "1023 KB" )

            -- MB の境目。1024 * 1024 ちょうどから MB
            , ( 1048576, "1 MB" )
            , ( 1572864, "1.5 MB" )
            , ( 2621440, "2.5 MB" )
            , ( 104857600, "100 MB" )
            ]
        )
