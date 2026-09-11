module Ui.Reply exposing
    ( Reply
    , addButton
    , banner
    , done
    , errorsFor
    , failed
    , general
    , idle
    , isSending
    , saveButton
    , sending
    , touched
    , unsavedChip
    , view
    )

{-| フォームの「返事」。**押したら必ず何かが返る**を 1 つの部品で揃える。

  - 送信中は「送信中…」を出し、ボタンを押せなくする
  - 失敗したら理由を出す。**欄に対応する違反はその欄の下に**、それ以外はボタンの横に

成功をどこに出すかは、フォームの種類で分ける。

  - **直すフォーム**（API 設定のように入力が残る）は `saveButton`。「保存しました」を
    ボタンの横に出し、次に入力を触るまで残す（時間で消すと、消えた瞬間を見逃した時に
    保存できたか分からなくなる）
  - **足すフォーム**（招待・API キー・Webhook のように入力が空に戻る）は `addButton` と
    `banner`。成功は**一覧の上の帯**に「x@example.com を招待しました」と誰に対してかを添えて
    出す。GitHub / Slack と同じ形。フォームの横に残すと、次の入力を始めているのに前回の結果が
    居座る

エディタの保存状態（`Editor.SaveState`）と同じ考え方を、設定・キー・メンバーのような
小さいフォームで使える形にした物。

-}

import Api
import Api.Error
import Html exposing (Html)
import Html.Attributes as A
import Html.Events as E
import Ui


{-| 今どうなっているか。
-}
type Reply
    = Idle
    | Sending
    | Done String
    | Failed { byField : List ( String, String ), general : List String }


idle : Reply
idle =
    Idle


sending : Reply
sending =
    Sending


{-| 成功した。文言は画面が決める（「保存しました」「送信しました」）。
-}
done : String -> Reply
done =
    Done


{-| 失敗した。違反は path の先頭の項目名で欄に振り分け、残りはまとめて出す。

`id: entry が 3 件あります` のように path が付いた文はサーバがそのまま返すが、
違反の message は path を含まないので、そちらを使う。

-}
failed : Api.Problem -> Reply
failed problem =
    case problem of
        Api.Failed errors ->
            let
                violations : List Api.Error.Violation
                violations =
                    List.concatMap .violations errors

                byField : List ( String, String )
                byField =
                    violations
                        |> List.filterMap
                            (\violation ->
                                case violation.path.segments of
                                    (Api.Error.Key name) :: _ ->
                                        Just ( name, violation.message )

                                    _ ->
                                        Nothing
                            )

                plain : List String
                plain =
                    errors
                        |> List.filter (\err -> List.isEmpty err.violations)
                        |> List.map (\err -> (Api.problemToText (Api.Failed [ err ])).message)
            in
            Failed { byField = byField, general = plain }

        other ->
            Failed { byField = [], general = [ (Api.problemToText other).message ] }


{-| 入力を触った。「保存しました」を消し、失敗の理由も下ろす（直した物にまだ古い理由が
付いていると、直っていないように見える）。送信中は触っても変えない。
-}
touched : Reply -> Reply
touched reply =
    if reply == Sending then
        Sending

    else
        Idle


isSending : Reply -> Bool
isSending reply =
    reply == Sending


{-| その欄に付ける理由。`Ui.field` の `errors` に渡す。
-}
errorsFor : String -> Reply -> List String
errorsFor name reply =
    case reply of
        Failed { byField } ->
            byField |> List.filter (\( field, _ ) -> field == name) |> List.map Tuple.second

        _ ->
            []


{-| 欄に振り分けられなかった理由。
-}
general : Reply -> List String
general reply =
    case reply of
        Failed failure ->
            failure.general
                ++ (failure.byField
                        |> List.filter (\( field, _ ) -> field == "id")
                        |> List.map Tuple.second
                   )

        _ ->
            []


{-| ボタンの横に出す返事。送信中・成功・欄に付かなかった失敗。
-}
view : Reply -> Html msg
view reply =
    case reply of
        Idle ->
            Html.text ""

        Sending ->
            Html.span [ A.class "inline-flex items-center gap-2 text-xs text-ink-soft" ] [ Ui.spinner, Html.text "送信中…" ]

        Done text ->
            Html.span [ A.class "text-xs text-[color:var(--color-ok)]" ] [ Html.text text ]

        -- 欄に付いた理由はその欄が出す。ここで繰り返すと同じ事が 2 か所に出る
        Failed _ ->
            case general reply of
                [] ->
                    Html.text ""

                messages ->
                    Html.div [ A.class "flex flex-col gap-0.5" ]
                        (List.map (\text -> Html.span [ A.class "text-xs text-[color:var(--color-bad)]" ] [ Html.text text ]) messages)


{-| 保存のボタンと返事を 1 行に。**変更が無ければ押せない**（押しても何も起きないボタンを置かない）。
直すフォーム用。足すフォームは `addButton` と `banner`。
-}
saveButton : { label : String, dirty : Bool, reply : Reply, onSave : msg } -> Html msg
saveButton args =
    Html.div [ A.class "flex items-center gap-3" ]
        [ Ui.button
            [ E.onClick args.onSave, A.disabled (not args.dirty || isSending args.reply) ]
            [ Html.text args.label ]
        , view args.reply
        ]


{-| 足すフォームのボタン。**成功は横に出さない**（`banner` が一覧の上に出す）。
送信中と、欄に付かなかった失敗だけ横に出る。
-}
addButton : { label : String, ready : Bool, reply : Reply, onAdd : msg } -> Html msg
addButton args =
    Html.div [ A.class "flex items-center gap-3" ]
        [ Ui.button
            [ E.onClick args.onAdd, A.disabled (not args.ready || isSending args.reply) ]
            [ Html.text args.label ]
        , case args.reply of
            Done _ ->
                Html.text ""

            other ->
                view other
        ]


{-| 足した結果の帯。一覧の上に出し、押して閉じられる。何に対してかを文に入れる
（「招待しました」だけでは誰に送ったか分からない）。

**フォームの返事（`Reply`）とは別に持つ。** 帯は一覧に起きた事で、フォームの状態ではない。
同じ物にすると、次の入力を打ち始めた瞬間に（エラーを下ろすのと一緒に）消える。

-}
banner : { message : Maybe String, onClose : msg } -> Html msg
banner args =
    case args.message of
        Just message ->
            Ui.callout Ui.toneOk
                [ A.class "flex-row items-center justify-between gap-3 px-4 py-2.5" ]
                [ Html.span [ A.class "text-[13px]" ] [ Html.text message ]
                , Html.button
                    [ A.type_ "button"
                    , A.class "shrink-0 text-xs text-ink-soft hover:text-ink"
                    , A.attribute "aria-label" "閉じる"
                    , E.onClick args.onClose
                    ]
                    [ Html.text "✕" ]
                ]

        Nothing ->
            Html.text ""


{-| 未保存の印。見出しの横に置く。
-}
unsavedChip : Bool -> Html msg
unsavedChip dirty =
    if dirty then
        Ui.chip Ui.toneWarn "未保存"

    else
        Html.text ""
