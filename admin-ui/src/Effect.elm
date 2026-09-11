module Effect exposing (Caps, Effect(..), batch, none, perform)

{-| update が返す副作用の値。

**Cmd を直接返さない。** Cmd を返すとテストから中身が見えず、「どの操作でどのリクエストが飛ぶか」を
検査できない。Cmd にするのは `perform` の 1 か所だけで、テストは同じ値を SimulatedEffect に写す。

WhyNot: ここに port を書かない。書くと Effect がテストから import できなくなる。
port と Msg の構築子は `Caps` のレコードで受ける。

WhyNot: `fromCmd` の素通しを置かない。置くと全部それで済ませてしまい、抽象化の利益が消える。

-}

import Api
import Browser.Dom
import Browser.Navigation as Nav
import Json.Encode as E
import Process
import Shell
import Task
import Time


type Effect msg
    = None
    | Batch (List (Effect msg))
    | SendGraphql Api.Request
    | Upload E.Value
    | SetTheme String
    | SetUnsaved Bool
    | Copy String {- ブラウザに URL を開かせる（ダウンロードの口）。 -}
    | OpenUrl String
    | Focus String {- その id の要素が画面の上の方に来るまで縦に送る（固定 URL で開いた行など）。 -}
    | ScrollTo String {- 少し待ってから Msg を出す。**打つ度に問い合わせない**ために使う。 -}
    | After Float msg {- 下書きの自動保存の待ち。**入力が止まってから書く**ための間で、Msg は待ちの番号を持って戻る。 -}
    | Autosave Float msg {- 今日は何日か。日付を選ぶ画面の初めの月を決めるのに要る。 -}
    | Today (Time.Zone -> Int -> Int -> Int -> msg) {- 今の時刻と手元のタイムゾーン。「保存済み 12:34」の時刻に要る。 -}
    | Now (Time.Zone -> Time.Posix -> msg)
    | PushRoute String
    | ReplaceRoute String
    | LoadUrl String
    | Reload


{-| perform が外に触るのに要る物。`key` をここで受けるので **Model に Nav.Key を持たない**
（テストの枠組みが init に Key を渡さないため。持つと全ページの型に伝染する）。
-}
type alias Caps msg =
    { key : Nav.Key
    , send : E.Value -> Cmd msg
    , upload : E.Value -> Cmd msg
    , theme : String -> Cmd msg
    , unsaved : Bool -> Cmd msg
    , copy : String -> Cmd msg
    , open : String -> Cmd msg
    , ignore : msg
    , toast : String -> msg
    }


{-| まとめて出す。空なら何もしない。
-}
batch : List (Effect msg) -> Effect msg
batch effects =
    case effects of
        [] ->
            None

        [ single ] ->
            single

        many ->
            Batch many


none : Effect msg
none =
    None


{-| `Time.Month` を数に。
-}
monthNumber : Time.Month -> Int
monthNumber month =
    case month of
        Time.Jan ->
            1

        Time.Feb ->
            2

        Time.Mar ->
            3

        Time.Apr ->
            4

        Time.May ->
            5

        Time.Jun ->
            6

        Time.Jul ->
            7

        Time.Aug ->
            8

        Time.Sep ->
            9

        Time.Oct ->
            10

        Time.Nov ->
            11

        Time.Dec ->
            12


perform : Caps msg -> Effect msg -> Cmd msg
perform caps effect =
    case effect of
        None ->
            Cmd.none

        Batch effects ->
            Cmd.batch (List.map (perform caps) effects)

        SendGraphql request ->
            caps.send (Api.encodeRequest request)

        Upload payload ->
            caps.upload payload

        SetTheme theme ->
            caps.theme theme

        SetUnsaved dirty ->
            caps.unsaved dirty

        Copy value ->
            caps.copy value

        OpenUrl url ->
            caps.open url

        After delay msg ->
            Task.perform (\_ -> msg) (Process.sleep delay)

        Autosave delay msg ->
            -- 待ちの取り消しは Elm にはできない。番号で捨てるのはページの側。
            Task.perform (\_ -> msg) (Process.sleep delay)

        Now toMsg ->
            Task.perform (\( zone, now ) -> toMsg zone now) (Task.map2 Tuple.pair Time.here Time.now)

        Today toMsg ->
            -- WhyNot: UTC で数えない。人が見る「今日」は手元のタイムゾーンの今日で、
            -- 時差の分だけ日付が前後する。UTC への変換は送る直前だけ。
            Task.perform
                (\( zone, now ) -> toMsg zone (Time.toYear zone now) (monthNumber (Time.toMonth zone now)) (Time.toDay zone now))
                (Task.map2 Tuple.pair Time.here Time.now)

        Focus elementId ->
            -- 当てられなくても画面は動くので、結果は捨てる。
            Task.attempt (\_ -> caps.ignore) (Browser.Dom.focus elementId)

        ScrollTo elementId ->
            -- 画面は window でなく Shell の中身の箱の中で流れる。要素と箱の位置を測り、箱の今の位置に差を足して送る。無ければ何もしない。
            Task.map3 (\target box viewport -> viewport.viewport.y + target.element.y - box.element.y - 16)
                (Browser.Dom.getElement elementId)
                (Browser.Dom.getElement Shell.contentId)
                (Browser.Dom.getViewportOf Shell.contentId)
                |> Task.andThen (Browser.Dom.setViewportOf Shell.contentId 0)
                |> Task.attempt (\_ -> caps.ignore)

        PushRoute url ->
            Nav.pushUrl caps.key url

        ReplaceRoute url ->
            Nav.replaceUrl caps.key url

        LoadUrl url ->
            Nav.load url

        Reload ->
            Nav.reload
