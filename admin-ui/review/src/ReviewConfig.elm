module ReviewConfig exposing (config)

{-| elm-review の設定。

方針: **消し忘れと書きすぎを機械に見張らせ、設計の決まりは人が見る。**
（Effect を素通しにしない、Session を読み取り専用にする、のような決まりは
docs/design/admin-ui-spec.md の 11 章にあり、ここでは検査しない）

`generated/` は elm-graphql の出力なので除く。

-}

import NoExposingEverything
import NoImportingEverything
import NoMissingTypeAnnotation
import NoMissingTypeAnnotationInLetIn
import NoUnused.CustomTypeConstructorArgs
import NoUnused.CustomTypeConstructors
import NoUnused.Dependencies
import NoUnused.Exports
import NoUnused.Modules
import NoUnused.Parameters
import NoUnused.Patterns
import NoUnused.Variables
import Review.Rule exposing (Rule)
import Simplify


config : List Rule
config =
    [ NoExposingEverything.rule
    , NoImportingEverything.rule []
    , NoMissingTypeAnnotation.rule
    , NoMissingTypeAnnotationInLetIn.rule
    , NoUnused.CustomTypeConstructors.rule []
    , NoUnused.CustomTypeConstructorArgs.rule
    , NoUnused.Dependencies.rule
    , NoUnused.Exports.rule
    , NoUnused.Modules.rule
    , NoUnused.Parameters.rule
    , NoUnused.Patterns.rule
    , NoUnused.Variables.rule
    , Simplify.rule Simplify.defaults
    ]
        |> List.map (Review.Rule.ignoreErrorsForDirectories [ "generated/" ])
