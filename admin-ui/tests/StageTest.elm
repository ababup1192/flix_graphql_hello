module StageTest exposing (suite)

{-| Ui.Stage.name: CMS の ContentStage を画面の言葉（仕様 7 章）にする。
-}

import Expect
import Test exposing (Test, describe, test)
import Ui.Stage


suite : Test
suite =
    describe "Ui.Stage.name"
        (List.map
            (\( stage, expected ) -> test stage (\_ -> Ui.Stage.name stage |> Expect.equal expected))
            [ ( "DRAFT", "下書き" )
            , ( "PUBLISHED", "公開中" )
            , ( "CHANGED", "公開中 · 下書きあり" )
            ]
        )
