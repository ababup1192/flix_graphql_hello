module Page.Schema exposing (Model, Msg, init, load, update, view)

{-| API スキーマ（型の定義）。フィールドの追加・編集・並び替え・削除。

**種類（kind）は後から変えられない**（CMS 側に更新の口が無い）。作る時にそう伝える。
消す前に `fieldImpact` で影響を引き、実際の件数を見せてから押させる。押す時は見た影響を
`expected` として送り、その間に増えていればサーバが止める。

-}

import Api
import Api.Admin.Enum.FieldKind as FieldKind exposing (FieldKind)
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, disabled, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Json.Decode as D
import Loaded exposing (Loaded(..))
import Model exposing (ContentTypeDetail, FieldDef, Slug)
import Queries
import Route
import Ui
import Ui.Icon as Icon


{-| 型を作るフォーム。`apiId` が "new" の時だけ出す。
-}
type alias NewType =
    { name : String
    , apiId : String
    , singleton : Bool
    }


type alias Model =
    { project : Slug
    , apiId : String
    , detail : Loaded ContentTypeDetail
    , panel : Panel
    , confirmRemove : Maybe FieldDef
    , removeImpact : Loaded Model.SchemaImpact
    , errors : List String
    , busy : Bool
    , newType : NewType
    , created : Maybe String
    , dragging : Maybe FieldDef
    }


{-| 右のペインに何を出すか。

**一覧を離れない**（Contentful / Strapi / Directus / Hygraph、GUI の CMS はどれも
一覧を見ながら足せる）。追加も編集もここで完結する。

-}
type Panel
    = Closed
    | Picking
    | Adding NewField
    | Editing EditForm
    | PickingIcon


{-| 編集の下書き。**行の値を直に触らない**（送るまでは一覧に反映させない。
送る前の状態が一覧に出ると、保存し忘れに気づけない）。

数は文字で持つ。空を「無し」として送れるようにするため。

-}
type alias EditForm =
    { id : String
    , apiId : String
    , kind : String
    , many : Bool
    , name : String
    , required : Bool
    , unique : Bool

    {- 画面には出さないが、今の値をそのまま送り返す。
       WhyNot: 出さないのは、CMS が印を持っているだけで読む所がまだ無いため
       （コンテンツ API に locale の引数が無く、entry の中身も言語で分かれていない）。
       入れても何も変わらない物を選ばせない。
    -}
    , localized : Bool
    , maxLength : String
    , min : String
    , max : String
    , integer : Bool
    , options : String
    , sourceField : String
    , dirty : Bool
    }


{-| integer は NUMBER だけの設定。他の種類で送るとサーバが config を弾き、
名前を直すだけの保存も通らなくなる。
-}
integerOf : EditForm -> Maybe Bool
integerOf form =
    if form.kind == "NUMBER" then
        Just form.integer

    else
        Nothing


formOf : FieldDef -> EditForm
formOf field =
    { id = field.id
    , apiId = field.apiId
    , kind = field.kind
    , many = field.many
    , name = field.name
    , required = field.required
    , unique = field.unique
    , localized = field.localized
    , maxLength = field.config.maxLength |> Maybe.map String.fromInt |> Maybe.withDefault ""
    , min = field.config.min |> Maybe.map numberText |> Maybe.withDefault ""
    , max = field.config.max |> Maybe.map numberText |> Maybe.withDefault ""
    , integer = field.config.integer |> Maybe.withDefault False
    , options = String.join ", " field.config.options
    , sourceField = field.config.sourceField |> Maybe.withDefault ""
    , dirty = False
    }


{-| 数を欄に出す文字。`3` を `3` と出す（`3.0` にしない）。
-}
numberText : Float -> String
numberText value =
    if value == toFloat (round value) then
        String.fromInt (round value)

    else
        String.fromFloat value


type alias NewField =
    { name : String
    , apiId : String
    , kind : FieldKind
    , required : Bool
    , many : Bool
    , sourceField : String
    , options : String
    , targetTypeId : String
    }


type Msg
    = GotType (Result Api.Problem (Maybe ContentTypeDetail))
    | PickerOpened
    | IconPickerOpened
    | IconChosen String
    | GotIcon (Result Api.Problem Model.ContentTypeSummary)
    | PanelClosed
    | NameTyped String
    | ApiIdTyped String
    | KindChosen String
    | SourceFieldChosen String
    | OptionsTyped String
    | TargetTypeChosen String
    | RequiredToggled
    | ManyToggled
    | AddSubmitted
    | GotField (Result Api.Problem FieldDef)
    | EditOpened FieldDef
    | EditChanged (EditForm -> EditForm)
    | EditSubmitted
    | RemoveAsked FieldDef
    | RemoveCancelled
    | RemoveConfirmed
    | GotRemoveImpact (Result Api.Problem Model.SchemaImpact)
    | GotRemoved (Result Api.Problem String)
    | Grabbed FieldDef
    | Released
    | HoveredOver
    | DroppedOn FieldDef
    | GotReordered (Result Api.Problem ContentTypeDetail)
    | TypeNameTyped String
    | TypeApiIdTyped String
    | TypeKindToggled
    | TypeSubmitted
    | GotNewType (Result Api.Problem Model.ContentTypeSummary)


init : Slug -> String -> Model
init project apiId =
    { project = project
    , apiId = apiId
    , detail = Loaded.Loading
    , panel = Closed
    , confirmRemove = Nothing
    , removeImpact = Loaded.Loading
    , errors = []
    , busy = False
    , newType = { name = "", apiId = "", singleton = False }
    , created = Nothing
    , dragging = Nothing
    }


{-| 画面を開いた時に引く物。`new` は作るフォームなので引かない。
-}
load : Slug -> String -> List (Api.Call Msg)
load slug apiId =
    if apiId == "new" then
        []

    else
        [ Api.call (\id -> Queries.contentType id slug apiId) GotType ]


type alias Context =
    { project : Slug }


update : Context -> Msg -> Model -> ( Model, List (Api.Call Msg) )
update ctx msg model =
    case msg of
        GotType result ->
            ( { model | detail = Loaded.fromResult result, errors = [] }, [] )

        PickerOpened ->
            ( { model | panel = Picking, errors = [] }, [] )

        IconPickerOpened ->
            ( { model | panel = PickingIcon, errors = [] }, [] )

        IconChosen icon ->
            case Loaded.toMaybe model.detail of
                Just detail ->
                    -- **省いた項目は触らない**ので、名前は今の値をそのまま渡す（CMS の決まり）。
                    ( { model | busy = True, errors = [] }
                    , [ Api.call
                            (\id ->
                                Queries.updateContentType id
                                    ctx.project
                                    { typeId = detail.id, name = detail.name, previewUrl = detail.previewUrl, linkPath = detail.linkPath, icon = icon }
                            )
                            GotIcon
                      ]
                    )

                Nothing ->
                    ( model, [] )

        GotIcon (Ok summary) ->
            ( { model
                | busy = False
                , panel = Closed
                , detail = Loaded.map (\detail -> { detail | icon = summary.icon }) model.detail
              }
            , []
            )

        GotIcon (Err problem) ->
            ( failed problem model, [] )

        PanelClosed ->
            ( { model | panel = Closed, confirmRemove = Nothing, errors = [] }, [] )

        NameTyped name ->
            ( { model | panel = mapAdding (\form -> { form | name = name, apiId = camelize name }) model }, [] )

        ApiIdTyped apiId ->
            ( { model | panel = mapAdding (\form -> { form | apiId = apiId }) model }, [] )

        KindChosen chosen ->
            -- **種類を選んだら下書きの行に進む**（Directus / Strapi と同じ。種類は後から
            -- 変えられないので、名前より先に決めさせる）。
            ( { model | panel = Adding { emptyField | kind = kindOf chosen }, errors = [] }, [] )

        SourceFieldChosen apiId ->
            ( { model | panel = mapAdding (\form -> { form | sourceField = apiId }) model }, [] )

        OptionsTyped raw ->
            ( { model | panel = mapAdding (\form -> { form | options = raw }) model }, [] )

        TargetTypeChosen typeId ->
            ( { model | panel = mapAdding (\form -> { form | targetTypeId = typeId }) model }, [] )

        RequiredToggled ->
            ( { model | panel = mapAdding (\form -> { form | required = not form.required }) model }, [] )

        ManyToggled ->
            ( { model | panel = mapAdding (\form -> { form | many = not form.many }) model }, [] )

        AddSubmitted ->
            case ( addingOf model, Loaded.toMaybe model.detail ) of
                ( Just form, Just detail ) ->
                    ( { model | busy = True, errors = [] }
                    , [ Api.call
                            (\id ->
                                Queries.addField id
                                    ctx.project
                                    { typeId = detail.id
                                    , apiId = form.apiId
                                    , name = form.name
                                    , kind = form.kind
                                    , required = form.required
                                    , many = form.many
                                    , sourceField = form.sourceField
                                    , options = optionsOf form.options
                                    , targetTypeId = form.targetTypeId
                                    }
                            )
                            GotField
                      ]
                    )

                _ ->
                    ( model, [] )

        GotField (Ok field) ->
            ( { model | busy = False, panel = Closed, detail = Loaded.map (upsertField field) model.detail }, [] )

        GotField (Err problem) ->
            ( failed problem model, [] )

        EditOpened field ->
            ( { model | panel = Editing (formOf field), confirmRemove = Nothing, errors = [] }, [] )

        EditChanged change ->
            ( { model
                | panel =
                    case model.panel of
                        Editing form ->
                            Editing (change { form | dirty = True })

                        other ->
                            other
              }
            , []
            )

        EditSubmitted ->
            case model.panel of
                Editing form ->
                    ( { model | busy = True, errors = [] }
                    , [ Api.call
                            (\id ->
                                Queries.updateField id
                                    ctx.project
                                    { fieldId = form.id
                                    , name = form.name
                                    , required = form.required
                                    , unique = form.unique
                                    , localized = form.localized
                                    , maxLength = String.toInt form.maxLength
                                    , sourceField = form.sourceField
                                    , min = String.toFloat form.min
                                    , max = String.toFloat form.max
                                    , integer = integerOf form
                                    , options = optionsOf form.options
                                    }
                            )
                            GotField
                      ]
                    )

                _ ->
                    ( model, [] )

        RemoveAsked field ->
            ( { model | confirmRemove = Just field, removeImpact = Loaded.Loading }
            , [ Api.call (\id -> Queries.removeFieldImpact id ctx.project field.id) GotRemoveImpact ]
            )

        GotRemoveImpact result ->
            ( { model | removeImpact = Loaded.fromResult (Result.map Just result) }, [] )

        RemoveCancelled ->
            ( { model | confirmRemove = Nothing, removeImpact = Loaded.Loading }, [] )

        RemoveConfirmed ->
            case model.confirmRemove of
                Just field ->
                    case Loaded.toMaybe model.removeImpact of
                        Just impact ->
                            ( { model | busy = True, confirmRemove = Nothing }
                            , [ Api.call (\id -> Queries.removeField id ctx.project { fieldId = field.id, expected = impact }) GotRemoved ]
                            )

                        Nothing ->
                            ( model, [] )

                Nothing ->
                    ( model, [] )

        GotRemoved (Ok fieldId) ->
            ( { model
                | busy = False
                , panel = Closed
                , detail = Loaded.map (\detail -> { detail | fields = List.filter (\f -> f.id /= fieldId) detail.fields }) model.detail
              }
            , []
            )

        GotRemoved (Err problem) ->
            ( failed problem model, [] )

        Grabbed field ->
            ( { model | dragging = Just field }, [] )

        Released ->
            ( { model | dragging = Nothing }, [] )

        HoveredOver ->
            -- **掴んでいる状態を消さない。** dragover は「ここに落とせる」と言うだけの物で、
            -- ここで解除すると drop の時に何を掴んでいたか分からなくなる。
            ( model, [] )

        DroppedOn target ->
            case model.dragging of
                Just field ->
                    if field.id == target.id then
                        ( { model | dragging = Nothing }, [] )

                    else
                        reorder ctx { model | dragging = Nothing } (moveBefore field target)

                Nothing ->
                    ( model, [] )

        GotReordered (Ok detail) ->
            ( { model | busy = False, detail = Present detail }, [] )

        GotReordered (Err problem) ->
            ( failed problem model, [] )

        TypeNameTyped name ->
            ( { model | newType = updateNewType (\form -> { form | name = name, apiId = pluralize (camelize name) }) model }, [] )

        TypeApiIdTyped apiId ->
            ( { model | newType = updateNewType (\form -> { form | apiId = apiId }) model }, [] )

        TypeKindToggled ->
            ( { model | newType = updateNewType (\form -> { form | singleton = not form.singleton }) model }, [] )

        TypeSubmitted ->
            ( { model | busy = True, errors = [] }
            , [ Api.call
                    (\id ->
                        Queries.createContentType id
                            ctx.project
                            { apiId = model.newType.apiId, name = model.newType.name, singleton = model.newType.singleton }
                    )
                    GotNewType
              ]
            )

        GotNewType (Ok summary) ->
            ( { model | busy = False, created = Just summary.apiId }, [] )

        GotNewType (Err problem) ->
            ( failed problem model, [] )


{-| 追加の下書き（種類を選んだ後）。
-}
addingOf : Model -> Maybe NewField
addingOf model =
    case model.panel of
        Adding form ->
            Just form

        _ ->
            Nothing


mapAdding : (NewField -> NewField) -> Model -> Panel
mapAdding change model =
    case model.panel of
        Adding form ->
            Adding (change form)

        other ->
            other


{-| 並べ替えは**全フィールドを過不足なく**渡す（CMS の決まり）。
-}
reorder : { project : Slug } -> Model -> (List FieldDef -> List FieldDef) -> ( Model, List (Api.Call Msg) )
reorder ctx model change =
    case Loaded.toMaybe model.detail of
        Just detail ->
            let
                ids : List String
                ids =
                    change detail.fields |> List.map .id
            in
            ( { model | busy = True }
            , [ Api.call (\id -> Queries.reorderFields id ctx.project { typeId = detail.id, ids = ids }) GotReordered ]
            )

        Nothing ->
            ( model, [] )


{-| 掴んだ物を、落とした先の場所に入れる。

**落とした行より前か後かは、元の位置で決める。** 上から下へ運んだ時は落とした行の後ろ、
下から上へ運んだ時は前に入れる（掴んだ物が指の下から動かないように見える）。

-}
moveBefore : FieldDef -> FieldDef -> List FieldDef -> List FieldDef
moveBefore field target fields =
    let
        indexOf : FieldDef -> Int
        indexOf wanted =
            fields
                |> List.indexedMap (\at f -> ( at, f ))
                |> List.filter (\( _, f ) -> f.id == wanted.id)
                |> List.head
                |> Maybe.map Tuple.first
                |> Maybe.withDefault 0

        downwards : Bool
        downwards =
            indexOf field < indexOf target

        without : List FieldDef
        without =
            List.filter (\f -> f.id /= field.id) fields
    in
    without
        |> List.concatMap
            (\f ->
                if f.id /= target.id then
                    [ f ]

                else if downwards then
                    [ f, field ]

                else
                    [ field, f ]
            )


upsertField : FieldDef -> ContentTypeDetail -> ContentTypeDetail
upsertField field detail =
    if List.any (\f -> f.id == field.id) detail.fields then
        { detail | fields = List.map (\f -> ifSame f field) detail.fields }

    else
        { detail | fields = detail.fields ++ [ field ] }


ifSame : FieldDef -> FieldDef -> FieldDef
ifSame current updated =
    if current.id == updated.id then
        updated

    else
        current


failed : Api.Problem -> Model -> Model
failed problem model =
    { model | busy = False, errors = [ (Api.problemToText problem).message ] }


updateNewType : (NewType -> NewType) -> Model -> NewType
updateNewType change model =
    change model.newType


{-| API に出す名前として使えるか。**送る前にここで止める。**

表示名が日本語だと `camelize` は何も作れない（英数字が 1 文字も無い）。
そのまま送ると CMS が「lowerCamel にしてください」と断るが、**人には
どこを直せばいいか分からない**（実際に、空のまま送って断られた）。

-}
apiIdError : String -> Maybe String
apiIdError apiId =
    if String.isEmpty apiId then
        Just "API に出す名前を入れてください（表示名が日本語だと自動では作れません）"

    else if not (startsLower apiId && String.all Char.isAlphaNum apiId) then
        Just "英字で始まり、英数字だけにしてください（例: publishedAt）"

    else
        Nothing


startsLower : String -> Bool
startsLower text =
    String.uncons text |> Maybe.map (Tuple.first >> Char.isLower) |> Maybe.withDefault False


{-| API の名前は複数形（`blogs`）。単純に s を足すだけで、合わなければ人が直す。
-}
pluralize : String -> String
pluralize word =
    if String.isEmpty word || String.endsWith "s" word then
        word

    else
        word ++ "s"


emptyField : NewField
emptyField =
    { name = "", apiId = "", kind = FieldKind.Text, required = False, many = False, sourceField = "", options = "", targetTypeId = "" }


{-| 表示名からフィールド ID を作る。lowerCamel に落とす。
-}
camelize : String -> String
camelize name =
    name
        |> String.toLower
        |> String.map
            (\c ->
                if Char.isAlphaNum c then
                    c

                else
                    ' '
            )
        |> String.words
        |> List.indexedMap
            (\index word ->
                if index == 0 then
                    word

                else
                    String.toUpper (String.left 1 word) ++ String.dropLeft 1 word
            )
        |> String.concat
        |> String.left 64


{-| 「,」区切りの入力を選択肢の一覧にする。空は落とす。
-}
optionsOf : String -> List String
optionsOf raw =
    raw
        |> String.split ","
        |> List.map String.trim
        |> List.filter (not << String.isEmpty)


kindOptions : List ( String, String )
kindOptions =
    [ ( "TEXT", "テキスト" )
    , ( "TEXT_AREA", "テキストエリア" )
    , ( "SLUG", "スラッグ" )
    , ( "NUMBER", "数値" )
    , ( "BOOLEAN", "真偽" )
    , ( "SELECT", "セレクト" )
    , ( "REFERENCE", "参照" )
    , ( "OBJECT", "オブジェクト" )
    , ( "BLOCKS", "ブロック" )
    , ( "ASSET", "メディア" )
    , ( "RICH_TEXT", "リッチエディタ" )
    , ( "DATE", "日時" )
    , ( "DATE_ONLY", "日付" )
    ]


kindOf : String -> FieldKind
kindOf value =
    FieldKind.list
        |> List.filter (\kind -> FieldKind.toString kind == value)
        |> List.head
        |> Maybe.withDefault FieldKind.Text


kindText : String -> String
kindText value =
    kindOptions |> List.filter (\( key, _ ) -> key == value) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault value


view : { canManage : Bool, types : List Model.ContentTypeSummary } -> Model -> Html Msg
view args model =
    if model.apiId == "new" then
        viewNewType model

    else
        Loaded.view
            { loading = Ui.loadingCard
            , missing =
                Ui.messageCard "この API はありません"
                    [ span [ class "font-mono text-xs text-ink-faint" ] [ text model.apiId ]
                    , Ui.note [ text "消されたか、URL が違います。左の一覧から選び直してください。" ]
                    ]
            , failed = Ui.failedCard
            , present = viewType args model
            }
            model.detail


{-| API を作るフォーム。作った後はその API のスキーマへ案内する。
-}
viewNewType : Model -> Html Msg
viewNewType model =
    case model.created of
        Just apiId ->
            Ui.messageCard "API を作りました"
                [ Ui.note [ text "続けてフィールドを足してください。" ]
                , Ui.link [ Html.Attributes.href (Route.toString (Route.TypeSchema model.project apiId)) ]
                    [ text (apiId ++ " のスキーマへ") ]
                ]

        Nothing ->
            Ui.page [ class "max-w-xl" ]
                [ Ui.pageHeader { title = "API を作る", icon = Nothing, meta = [], actions = [] }
                , Ui.note [ text "API はコンテンツの型です。作った後にフィールドを足します。エンドポイントは後から変えられません。" ]
                , Ui.errors model.errors
                , Ui.card [ class "flex flex-col gap-4 p-4" ]
                    [ Ui.field { label = "表示名", hint = Nothing, errors = [] }
                        [ Ui.input [ value model.newType.name, onInput TypeNameTyped, placeholder "ブログ" ] ]
                    , Ui.field
                        { label = "エンドポイント"
                        , hint = Just "URL と API に出る名前。英小文字の複数形"
                        , errors = apiIdError model.newType.apiId |> Maybe.map List.singleton |> Maybe.withDefault []
                        }
                        [ Ui.input [ value model.newType.apiId, onInput TypeApiIdTyped, class "font-mono", placeholder "blogs" ] ]
                    , Ui.checkbox
                        { label = "オブジェクト形式（サイト設定のように 1 件だけ持つ）"
                        , checked = model.newType.singleton
                        , onToggle = TypeKindToggled
                        }
                    , div [ class "flex gap-2" ] [ Ui.button [ onClick TypeSubmitted, Html.Attributes.disabled (apiIdError model.newType.apiId /= Nothing || model.busy) ] [ text (busyText model "作る") ] ]
                    ]
                ]


{-| 型のスキーマ。**左に一覧、右に設定**の 2 ペイン。

追加も編集も右のペインで完結する（Contentful / Strapi / Directus / Hygraph、
GUI の CMS はどれも一覧を離れない）。一覧の下にフォームを足すと、行との対応が取れない。

-}
viewType : { canManage : Bool, types : List Model.ContentTypeSummary } -> Model -> ContentTypeDetail -> Html Msg
viewType args model detail =
    Ui.page []
        [ Ui.pageHeader
            { title = detail.name
            , icon =
                if args.canManage then
                    Just ( Icon.byName detail.icon, IconPickerOpened )

                else
                    Nothing
            , meta = [ span [ class "rounded border border-edge px-1.5 py-0.5 font-mono text-[11px] text-ink-soft" ] [ text ("/" ++ detail.apiId) ] ]
            , actions =
                if args.canManage then
                    [ Ui.button [ onClick PickerOpened ] [ text "+ フィールドを追加" ] ]

                else
                    []
            }
        , Ui.errors model.errors
        , div [ class "flex items-start gap-5" ]
            [ div [ class "min-w-0 flex-1" ] [ viewFields args model detail ]
            , if args.canManage then
                {- WhyNot: 面を上に置いたままにしない。フィールドが 40 個あると表が 2478px になり、
                   下の方の行を押しても設定の面が画面の外に出たままで編集できない（実際にできなかった）。
                -}
                div [ class "sticky top-6 z-(--z-sticky) max-h-[calc(100vh-6rem)] w-[380px] shrink-0 overflow-auto" ]
                    [ viewPanel args model detail ]

              else
                text ""
            ]
        ]


{-| 右のペイン。何も選んでいなければ、何ができるかを出す（空白にしない）。
-}
viewPanel : { canManage : Bool, types : List Model.ContentTypeSummary } -> Model -> ContentTypeDetail -> Html Msg
viewPanel args model detail =
    case model.panel of
        Closed ->
            Ui.card [ class "flex flex-col gap-2 p-4" ]
                [ Ui.sectionTitle "フィールドの設定"
                , Ui.note [ text "左の行を押すと、そのフィールドの設定が出ます。掴んで動かすと並びが変わります。" ]
                , div [ class "pt-1" ] [ Ui.ghostButton [ onClick PickerOpened ] [ text "+ フィールドを追加" ] ]
                ]

        Picking ->
            viewKindPicker

        PickingIcon ->
            viewIconPicker model

        Adding form ->
            viewAddPanel args model form

        Editing form ->
            viewEditPanel model detail form


{-| API のアイコンを選ぶ。**何度でも選び直せる**（Notion のページの絵文字、
Directus のコレクションのアイコンと同じ）。押した時点で送る（選ぶだけの操作なので、
別に保存を押させない）。
-}
viewIconPicker : Model -> Html Msg
viewIconPicker model =
    let
        now : String
        now =
            Loaded.toMaybe model.detail |> Maybe.map .icon |> Maybe.withDefault "list"
    in
    Ui.card [ class "flex flex-col gap-3 p-4" ]
        [ div [ class "flex items-center gap-2" ]
            [ Ui.sectionTitle "アイコンを選ぶ"
            , div [ class "ml-auto" ] [ Ui.ghostButton [ onClick PanelClosed ] [ text "閉じる" ] ]
            ]
        , div [ class "grid grid-cols-6 gap-1.5" ] (List.map (viewIconTile now) Icon.choices)
        , Ui.note [ text "左のサイドバーと一覧に出ます。いつでも選び直せます。" ]
        ]


viewIconTile : String -> ( String, String ) -> Html Msg
viewIconTile now ( name, label ) =
    Html.button
        [ class
            ("flex h-9 items-center justify-center rounded-md border "
                ++ (if now == name then
                        "border-accent bg-[color:var(--color-accent-bg)] text-ink"

                    else
                        "border-edge bg-panel text-ink-soft hover:bg-raised hover:text-ink"
                   )
            )
        , Html.Attributes.title label
        , onClick (IconChosen name)
        ]
        [ Icon.view (Icon.byName name) ]


{-| 種類を選ぶ。**アイコン付きの札を分類ごとに並べる。**

`<select>` の 12 行では「オブジェクト」と「ブロック」の違いが読めない
（Directus は 6 分類、Hygraph はパレット、Strapi はアイコン付きの一覧）。

-}
viewKindPicker : Html Msg
viewKindPicker =
    Ui.card [ class "flex flex-col gap-4 p-4" ]
        (div [ class "flex items-center gap-2" ]
            [ Ui.sectionTitle "種類を選ぶ"
            , div [ class "ml-auto" ] [ Ui.ghostButton [ onClick PanelClosed ] [ text "やめる" ] ]
            ]
            :: List.map viewKindGroup kindGroups
            ++ [ Ui.note [ text "種類は後から変えられません。" ] ]
        )


viewKindGroup : ( String, List String ) -> Html Msg
viewKindGroup ( title, kinds ) =
    div [ class "flex flex-col gap-1.5" ]
        [ span [ class "text-[11px] font-semibold text-ink-faint" ] [ text title ]
        , div [ class "grid grid-cols-2 gap-1.5" ] (List.map viewKindTile kinds)
        ]


viewKindTile : String -> Html Msg
viewKindTile kind =
    Html.button
        [ class "flex items-center gap-2 rounded-md border border-edge bg-panel px-2.5 py-2 text-left text-[13px] text-ink-soft hover:border-accent hover:bg-raised hover:text-ink"
        , onClick (KindChosen kind)
        ]
        [ span [] [ Icon.view (Icon.ofKind kind) ]
        , span [ class "truncate" ] [ text (kindText kind) ]
        ]


{-| 種類の分類。Directus の 6 分類に寄せ、この CMS が持つ 12 種類に当てる。
-}
kindGroups : List ( String, List String )
kindGroups =
    [ ( "文字", [ "TEXT", "TEXT_AREA", "SLUG", "RICH_TEXT" ] )
    , ( "数・真偽・日時", [ "NUMBER", "BOOLEAN", "DATE", "DATE_ONLY" ] )
    , ( "選ぶ・つなぐ", [ "SELECT", "REFERENCE" ] )
    , ( "メディア", [ "ASSET" ] )
    , ( "入れ子", [ "OBJECT", "BLOCKS" ] )
    ]


viewAddPanel : { canManage : Bool, types : List Model.ContentTypeSummary } -> Model -> NewField -> Html Msg
viewAddPanel args model form =
    let
        kind : String
        kind =
            FieldKind.toString form.kind
    in
    Ui.card [ class "flex flex-col gap-4 p-4" ]
        [ div [ class "flex items-center gap-2" ]
            [ span [ class "text-ink-soft" ] [ Icon.view (Icon.ofKind kind) ]
            , Ui.sectionTitle (kindText kind ++ " を追加")
            , div [ class "ml-auto" ] [ Ui.ghostButton [ onClick PickerOpened ] [ text "種類を選び直す" ] ]
            ]
        , Ui.field { label = "表示名", hint = Just "画面に出る名前", errors = [] }
            [ Ui.input [ value form.name, onInput NameTyped, placeholder "タイトル" ] ]
        , Ui.field
            { label = "フィールド ID"
            , hint = Just "API に出る名前。作った後は変えられません"
            , errors = apiIdError form.apiId |> Maybe.map List.singleton |> Maybe.withDefault []
            }
            [ Ui.input [ value form.apiId, onInput ApiIdTyped, class "font-mono", placeholder "title" ] ]
        , viewKindConfig args model form
        , div [ class "flex flex-col gap-2" ]
            [ Ui.checkbox { label = "必須（公開する時にチェックします）", checked = form.required, onToggle = RequiredToggled }
            , Ui.checkbox { label = "複数（値をいくつも入れられます）", checked = form.many, onToggle = ManyToggled }
            ]
        , div [ class "flex gap-2" ]
            [ Ui.button
                [ onClick AddSubmitted, Html.Attributes.disabled (apiIdError form.apiId /= Nothing || model.busy) ]
                [ text (busyText model "追加する") ]
            , Ui.ghostButton [ onClick PanelClosed ] [ text "やめる" ]
            ]
        ]


{-| 種類ごとに要る設定。足りないと CMS が INVALID で断るので、ここで入れさせる。
-}
viewKindConfig : { canManage : Bool, types : List Model.ContentTypeSummary } -> Model -> NewField -> Html Msg
viewKindConfig args model form =
    case FieldKind.toString form.kind of
        "SLUG" ->
            Ui.field { label = "元にするフィールド", hint = Just "この値からスラッグを作ります", errors = [] }
                [ Ui.select [ onInput SourceFieldChosen ] (( "", "選んでください" ) :: textFieldsOf model) form.sourceField ]

        "SELECT" ->
            Ui.field { label = "選択肢", hint = Just "「,」で区切って書きます（例: 技術, 運用, お知らせ）", errors = [] }
                [ Ui.input [ value form.options, onInput OptionsTyped, placeholder "技術, 運用" ] ]

        "REFERENCE" ->
            Ui.field { label = "参照先の API", hint = Nothing, errors = [] }
                [ Ui.select [ onInput TargetTypeChosen ] (( "", "選んでください" ) :: typeOptionsOf args) form.targetTypeId ]

        _ ->
            text ""


{-| SLUG の元にできるフィールド（テキストの物だけ）。
-}
textFieldsOf : Model -> List ( String, String )
textFieldsOf model =
    Loaded.toMaybe model.detail
        |> Maybe.map .fields
        |> Maybe.withDefault []
        |> List.filter (\field -> field.kind == "TEXT" || field.kind == "TEXT_AREA")
        |> List.map (\field -> ( field.apiId, field.name ))


{-| 参照先に選べる型。プロジェクトの全部の API から選ぶ。
-}
typeOptionsOf : { canManage : Bool, types : List Model.ContentTypeSummary } -> List ( String, String )
typeOptionsOf args =
    args.types |> List.map (\summary -> ( summary.id, summary.name ))


{-| フィールドの設定。**保存は人が押す**（送るまで一覧は変わらない）。

出す項目は 9 社に共通する物に揃える: 表示名 / フィールド ID / 種類 / 必須 / 重複不可 /
言語ごと / 種類ごとの制約。CMS が持っているのに画面に無かった `config` をここで全部出す。

-}
viewEditPanel : Model -> ContentTypeDetail -> EditForm -> Html Msg
viewEditPanel model detail form =
    Ui.card [ class "flex flex-col gap-4 p-4" ]
        [ div [ class "flex items-center gap-2" ]
            [ span [ class "text-ink-soft" ] [ Icon.view (Icon.ofKind form.kind) ]
            , Ui.sectionTitle form.name
            , if form.dirty then
                Ui.chip Ui.toneWarn "未保存"

              else
                text ""
            , div [ class "ml-auto" ] [ Ui.ghostButton [ onClick PanelClosed ] [ text "閉じる" ] ]
            ]
        , Ui.field { label = "表示名", hint = Just "画面に出る名前", errors = [] }
            [ Ui.input [ value form.name, onInput (\typed -> EditChanged (\f -> { f | name = typed })) ] ]
        , Ui.field { label = "フィールド ID", hint = Just "API に出る名前。変えられません（変えると今の API が壊れます）", errors = [] }
            [ Ui.input [ value form.apiId, Html.Attributes.disabled True, class "font-mono" ] ]
        , Ui.field { label = "種類", hint = Just "変えられません。変えたい時は新しく作って値を移します", errors = [] }
            [ div [ class "flex items-center gap-2 text-[13px] text-ink" ]
                [ text (kindText form.kind)
                , if form.many then
                    Ui.chip Ui.toneNeutral "複数"

                  else
                    text ""
                ]
            ]
        , div [ class "flex flex-col gap-2 border-t border-edge pt-4" ]
            [ Ui.sectionTitle "入力の決まり"
            , Ui.checkbox
                { label = "必須（公開する時にチェックします）"
                , checked = form.required
                , onToggle = EditChanged (\f -> { f | required = not f.required })
                }
            , Ui.checkbox
                { label = "重複不可（同じ値を 2 つ公開できません）"
                , checked = form.unique
                , onToggle = EditChanged (\f -> { f | unique = not f.unique })
                }
            ]
        , viewEditConfig detail form
        , div [ class "flex gap-2 border-t border-edge pt-4" ]
            [ Ui.button [ onClick EditSubmitted, Html.Attributes.disabled (not form.dirty || model.busy) ]
                [ text (busyText model "保存") ]
            , Ui.ghostButton [ onClick PanelClosed ] [ text "やめる" ]
            ]
        , viewRemove model form
        ]


{-| 種類ごとの制約。**CMS が持っている物は全部出す**（画面から使えないと無いのと同じ）。
-}
viewEditConfig : ContentTypeDetail -> EditForm -> Html Msg
viewEditConfig detail form =
    let
        section : List (Html Msg) -> Html Msg
        section children =
            div [ class "flex flex-col gap-3 border-t border-edge pt-4" ] (Ui.sectionTitle "この種類の設定" :: children)
    in
    case form.kind of
        "TEXT" ->
            section [ viewMaxLength form ]

        "TEXT_AREA" ->
            section [ viewMaxLength form ]

        "RICH_TEXT" ->
            section [ viewMaxLength form ]

        "NUMBER" ->
            section
                [ div [ class "grid grid-cols-2 gap-3" ]
                    [ Ui.field { label = "最小", hint = Nothing, errors = [] }
                        [ Ui.input [ value form.min, onInput (\typed -> EditChanged (\f -> { f | min = typed })), placeholder "無し" ] ]
                    , Ui.field { label = "最大", hint = Nothing, errors = [] }
                        [ Ui.input [ value form.max, onInput (\typed -> EditChanged (\f -> { f | max = typed })), placeholder "無し" ] ]
                    ]
                , Ui.checkbox
                    { label = "整数だけ"
                    , checked = form.integer
                    , onToggle = EditChanged (\f -> { f | integer = not f.integer })
                    }
                ]

        "SELECT" ->
            section
                [ Ui.field { label = "選択肢", hint = Just "「,」で区切ります。**消すと、その値の公開中のコンテンツが壊れます**", errors = [] }
                    [ Ui.input [ value form.options, onInput (\typed -> EditChanged (\f -> { f | options = typed })) ] ]
                ]

        "SLUG" ->
            section
                [ Ui.field { label = "元にするフィールド", hint = Just "この値からスラッグを作ります", errors = [] }
                    [ Ui.select
                        [ onInput (\typed -> EditChanged (\f -> { f | sourceField = typed })) ]
                        (( "", "選んでください" ) :: slugSourcesOf detail)
                        form.sourceField
                    ]
                ]

        _ ->
            text ""


viewMaxLength : EditForm -> Html Msg
viewMaxLength form =
    Ui.field { label = "文字数の上限", hint = Just "入れると、入力欄に残り文字数の丸が出ます", errors = [] }
        [ Ui.input
            [ value form.maxLength
            , onInput (\typed -> EditChanged (\f -> { f | maxLength = typed }))
            , placeholder "無し"
            ]
        ]


slugSourcesOf : ContentTypeDetail -> List ( String, String )
slugSourcesOf detail =
    detail.fields
        |> List.filter (\field -> field.kind == "TEXT" || field.kind == "TEXT_AREA")
        |> List.map (\field -> ( field.apiId, field.name ))


{-| 削除。**危ない操作は下に離す**（保存を押しに来て間違えて押さないように）。

押す前に `fieldImpact` を引いて、実際に当たるコンテンツの件数を出す。数えている間は
押させない（0 件と 4000 件で人がする判断が違う）。

-}
viewRemove : Model -> EditForm -> Html Msg
viewRemove model form =
    case model.confirmRemove of
        Just asked ->
            if asked.id == form.id then
                Ui.callout Ui.toneWarn
                    [ class "gap-2 p-3" ]
                    (Ui.subheading ("「" ++ form.name ++ "」を削除しますか")
                        :: viewImpact model.removeImpact
                        ++ [ div [ class "flex gap-2" ]
                                [ Ui.button
                                    [ onClick RemoveConfirmed, disabled (Loaded.toMaybe model.removeImpact == Nothing) ]
                                    [ text (busyText model "削除する") ]
                                , Ui.ghostButton [ onClick RemoveCancelled ] [ text "やめる" ]
                                ]
                           ]
                    )

            else
                text ""

        Nothing ->
            div [ class "border-t border-edge pt-3" ]
                [ Ui.dangerLink (RemoveAsked (removable form)) "このフィールドを削除…" ]


{-| 押すと何が起きるか。**サーバが数えた件数をそのまま出す。**

`safe` なら「影響はありません」。効果があるなら 1 行ずつ、当たるコンテンツの件数を添える。

-}
viewImpact : Loaded Model.SchemaImpact -> List (Html Msg)
viewImpact loaded =
    case loaded of
        Loaded.Loading ->
            [ Ui.note [ text "影響を調べています…" ] ]

        Loaded.Failed problem ->
            [ Ui.note [ text ("影響を調べられませんでした（" ++ problem ++ "）。もう一度お試しください") ] ]

        Loaded.Missing ->
            [ Ui.note [ text "影響を調べられませんでした。もう一度お試しください" ] ]

        Loaded.Present impact ->
            if impact.safe then
                [ Ui.note [ text "このフィールドに値を入れているコンテンツはありません。消しても配信は変わりません" ] ]

            else
                List.map viewEffect impact.effects


{-| 影響 1 行。
-}
viewEffect : Model.SchemaEffect -> Html Msg
viewEffect effect =
    Ui.note [ text (effectText effect.kind ++ "（下書き " ++ String.fromInt effect.draft ++ " 件 / 公開中 " ++ String.fromInt effect.published ++ " 件）") ]


{-| 影響の種類の言い方。サーバの enum に 1 対 1 で当てる。
-}
effectText : String -> String
effectText kind =
    case kind of
        "VALUES_HIDDEN" ->
            "値が API から見えなくなります（DB には残ります）"

        "REFERENCES_HIDDEN" ->
            "参照が API から見えなくなります"

        "ASSETS_HIDDEN" ->
            "メディアの参照が API から見えなくなります"

        "VALUES_RESURRECTED" ->
            "消したはずの値が API に戻ります"

        "PUBLISH_BLOCKED" ->
            "公開中のコンテンツが再公開できなくなります"

        "DRAFT_BLOCKED" ->
            "下書きの保存が通らなくなります"

        "ENTRIES_REMOVED" ->
            "型と一緒にコンテンツが消えます"

        other ->
            other


{-| 削除の確認は行そのものを持つ。下書きから id と名前だけ作る。
-}
removable : EditForm -> FieldDef
removable form =
    { id = form.id
    , apiId = form.apiId
    , name = form.name
    , kind = form.kind
    , many = form.many
    , required = form.required
    , unique = form.unique
    , localized = form.localized
    , targetTypeId = Nothing
    , config = { maxLength = Nothing, sourceField = Nothing, min = Nothing, max = Nothing, integer = Nothing, options = [] }
    }


viewFields : { canManage : Bool, types : List Model.ContentTypeSummary } -> Model -> ContentTypeDetail -> Html Msg
viewFields args model detail =
    if List.isEmpty detail.fields then
        Ui.table [ Ui.empty "フィールドがありません" ]

    else
        Ui.table
            (Ui.headRowOf fieldColumns [ text "", text "表示名 / フィールド ID", text "種類", text "制約" ]
                :: List.map (viewField args model) detail.fields
            )


fieldColumns : String
fieldColumns =
    "grid-cols-[28px_1fr_150px_130px]"


{-| フィールドの 1 行。

**行ごと押すと右のペインが開く**（GUI の CMS はどれも行から開く。右端の小さな
「編集」だけが的だと遠い）。

**掴む所は左端**（Directus / GitHub / Notion と同じ）。行のどこでも掴めるようにすると、
文字を選べなくなる。

-}
viewField : { canManage : Bool, types : List Model.ContentTypeSummary } -> Model -> FieldDef -> Html Msg
viewField args model field =
    let
        dragged : Bool
        dragged =
            model.dragging |> Maybe.map (\held -> held.id == field.id) |> Maybe.withDefault False

        chosen : Bool
        chosen =
            case model.panel of
                Editing form ->
                    form.id == field.id

                _ ->
                    False
    in
    Html.div
        (class
            ("grid items-center gap-3 border-b border-edge px-4 py-3 text-[13px] text-ink last:border-b-0 "
                ++ fieldColumns
                ++ (if dragged then
                        " opacity-40"

                    else if chosen then
                        " bg-raised"

                    else
                        " hover:bg-raised"
                   )
                ++ (if args.canManage then
                        " cursor-pointer"

                    else
                        ""
                   )
            )
            :: (if args.canManage then
                    [ onClick (EditOpened field)
                    , Html.Attributes.draggable "true"
                    , Html.Events.on "dragstart" (D.succeed (Grabbed field))
                    , Html.Events.on "dragend" (D.succeed Released)
                    , Html.Events.preventDefaultOn "dragover" (D.succeed ( HoveredOver, True ))
                    , Html.Events.preventDefaultOn "drop" (D.succeed ( DroppedOn field, True ))
                    ]

                else
                    []
               )
        )
        [ div [ class "flex items-center text-ink-faint" ]
            [ if args.canManage then
                span [ class "cursor-grab" ] [ Icon.view Icon.grip ]

              else
                text ""
            ]
        , div [ class "flex min-w-0 items-center gap-2" ]
            [ span [ class "text-ink-soft" ] [ Icon.view (Icon.ofKind field.kind) ]
            , div [ class "flex min-w-0 flex-col" ]
                [ span [ class "truncate font-medium" ] [ text field.name ]
                , span [ class "truncate font-mono text-[11px] text-ink-faint" ] [ text field.apiId ]
                ]
            ]
        , span [ class "truncate text-ink-soft" ]
            [ text
                (kindText field.kind
                    ++ (if field.many then
                            "（複数）"

                        else
                            ""
                       )
                )
            ]
        , div [ class "flex flex-wrap gap-1" ]
            [ if field.required then
                Ui.chip Ui.toneNeutral "必須"

              else
                text ""
            , if field.unique then
                Ui.chip Ui.toneNeutral "重複不可"

              else
                text ""
            ]
        ]


busyText : Model -> String -> String
busyText model label =
    if model.busy then
        "送っています…"

    else
        label
