module Page.Projects exposing (Model, Msg, currentPerson, init, load, notFound, update, view)

{-| プロジェクトを選ぶ画面。組織ごとに並べ、そこから組織とプロジェクトを作る。

**組織を作る導線は、組織を 1 つも持っていない人にだけ出す**（編集者として招待された人に
「組織を作る」を見せない。CMS 側は CMS\_SIGNUP=open だと作れてしまうが、画面は勧めない）。

-}

import Api
import Dict exposing (Dict)
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Model exposing (Org, Person, Project)
import Queries
import Route
import Ui


type alias Model =
    { person : Person
    , newProject : Maybe { orgId : String, name : String, slug : String }
    , newOrg : Maybe String
    , errors : List String
    , busy : Bool

    {- 組織 id → その組織のプロジェクト id。組織側から引いた物。 -}
    , orgProjects : Dict String (List String)

    {- URL で開こうとして見つからなかったプロジェクトの slug。 -}
    , notFoundSlug : Maybe String
    }


type Msg
    = OpenProjectForm String
    | CloseForms
    | ProjectNameTyped String
    | ProjectSlugTyped String
    | ProjectSubmitted
    | GotProject (Result Api.Problem Project)
    | OpenOrgForm
    | OrgNameTyped String
    | OrgSubmitted
    | GotOrg (Result Api.Problem Org)
    | GotOrgProjects (Result Api.Problem { orgId : String, projectIds : List String })


init : Person -> Model
init person =
    { person = person, newProject = Nothing, newOrg = Nothing, errors = [], busy = False, orgProjects = Dict.empty, notFoundSlug = Nothing }


{-| この画面で作った組織とプロジェクトを含む、今の自分。親が枠へ写す。
-}
currentPerson : Model -> Person
currentPerson model =
    model.person


{-| URL のプロジェクトが見つからなかった事をこの画面で伝える。
-}
notFound : String -> Model -> Model
notFound slug model =
    { model | notFoundSlug = Just slug }


{-| 開いた時に、組織ごとのプロジェクトを引く。
-}
load : Person -> List (Api.Call Msg)
load person =
    person.organizations
        |> List.map (\org -> Api.call (\id -> Queries.organizationProjects id org.id) GotOrgProjects)


update : Msg -> Model -> ( Model, List (Api.Call Msg) )
update msg model =
    case msg of
        GotOrgProjects (Ok found) ->
            ( { model | orgProjects = Dict.insert found.orgId found.projectIds model.orgProjects }, [] )

        GotOrgProjects (Err _) ->
            ( model, [] )

        OpenProjectForm orgId ->
            ( { model | newProject = Just { orgId = orgId, name = "", slug = "" }, newOrg = Nothing, errors = [] }, [] )

        CloseForms ->
            ( { model | newProject = Nothing, newOrg = Nothing, errors = [] }, [] )

        ProjectNameTyped name ->
            ( { model
                | newProject =
                    model.newProject
                        |> Maybe.map (\form -> { form | name = name, slug = slugify name })
              }
            , []
            )

        ProjectSlugTyped slug ->
            ( { model | newProject = model.newProject |> Maybe.map (\form -> { form | slug = slug }) }, [] )

        ProjectSubmitted ->
            case model.newProject of
                Just form ->
                    ( { model | busy = True, errors = [] }
                    , [ Api.call (\id -> Queries.createProject id form) GotProject ]
                    )

                Nothing ->
                    ( model, [] )

        GotProject (Ok project) ->
            ( { model
                | busy = False
                , newProject = Nothing
                , person = addProject project model.person
              }
            , []
            )

        GotProject (Err problem) ->
            ( { model | busy = False, errors = [ (Api.problemToText problem).message ] }, [] )

        OpenOrgForm ->
            ( { model | newOrg = Just "", newProject = Nothing, errors = [] }, [] )

        OrgNameTyped name ->
            ( { model | newOrg = Just name }, [] )

        OrgSubmitted ->
            case model.newOrg of
                Just name ->
                    ( { model | busy = True, errors = [] }
                    , [ Api.call (\id -> Queries.createOrganization id name) GotOrg ]
                    )

                Nothing ->
                    ( model, [] )

        GotOrg (Ok org) ->
            let
                person : Person
                person =
                    model.person
            in
            ( { model | busy = False, newOrg = Nothing, person = { person | organizations = person.organizations ++ [ org ] } }, [] )

        GotOrg (Err problem) ->
            ( { model | busy = False, errors = [ (Api.problemToText problem).message ] }, [] )


addProject : Project -> Person -> Person
addProject project person =
    { person | projects = person.projects ++ [ project ] }


{-| 名前からプロジェクト slug を作る。DNS のラベルの形（英小文字・数字・ハイフン）に落とす。
-}
slugify : String -> String
slugify name =
    name
        |> String.toLower
        |> String.map
            (\c ->
                if Char.isAlphaNum c then
                    c

                else
                    '-'
            )
        |> String.filter (\c -> Char.isAlphaNum c || c == '-')
        |> String.left 63


view : Model -> Html Msg
view model =
    div [ class "mx-auto flex w-full max-w-4xl flex-col gap-8 py-10" ]
        [ Ui.heading "プロジェクトを選ぶ"
        , case model.notFoundSlug of
            Just slug ->
                Ui.messageCard "プロジェクトが見つかりません"
                    [ span [ class "text-xs text-ink-faint" ] [ text (slug ++ " を開く権限が無いか、プロジェクトが削除されたか、プロジェクト slug が変更されています。") ] ]

            Nothing ->
                text ""
        , div [ class "flex flex-col gap-8" ] (List.map (viewOrg model) (organizationsOf model))
        , if List.isEmpty model.person.organizations then
            viewOrgForm model

          else
            text ""
        , if List.isEmpty model.errors then
            text ""

          else
            div [ class "flex flex-col gap-1" ] (List.map (\e -> span [ class "text-xs text-[color:var(--color-bad)]" ] [ text e ]) model.errors)
        ]


{-| 組織ごとにプロジェクトを分ける。

**どのプロジェクトがどの組織の物かは組織側から引く**（`me.projects` は組織を持たない）。
まだ返っていない組織は空で出し、どの組織にも入らなかった物を「招待されたプロジェクト」に置く。

-}
organizationsOf : Model -> List ( Maybe Org, List Project )
organizationsOf model =
    let
        inOrg : String -> List Project
        inOrg orgId =
            case Dict.get orgId model.orgProjects of
                Just ids ->
                    model.person.projects |> List.filter (\project -> List.member project.id ids)

                Nothing ->
                    []

        grouped : List String
        grouped =
            Dict.values model.orgProjects |> List.concat

        owned : List ( Maybe Org, List Project )
        owned =
            model.person.organizations |> List.map (\org -> ( Just org, inOrg org.id ))

        loose : List Project
        loose =
            model.person.projects |> List.filter (\project -> not (List.member project.id grouped))
    in
    owned
        ++ (if List.isEmpty loose then
                []

            else
                [ ( Nothing, loose ) ]
           )


viewOrg : Model -> ( Maybe Org, List Project ) -> Html Msg
viewOrg model ( org, projects ) =
    div [ class "flex flex-col gap-3" ]
        [ div [ class "flex items-center gap-3 text-xs font-semibold tracking-wide text-ink-soft" ]
            [ text ("組織: " ++ (org |> Maybe.map .name |> Maybe.withDefault "招待されたプロジェクト"))
            , case org of
                Just chosen ->
                    if chosen.role == "OWNER" then
                        Ui.ghostButton [ class "ml-auto h-7", onClick (OpenProjectForm chosen.id) ] [ text "+ プロジェクトを作成" ]

                    else
                        text ""

                Nothing ->
                    text ""
            ]
        , div [ class "grid grid-cols-3 gap-4" ] (List.map viewProject projects)
        , case model.newProject of
            Just form ->
                if Just form.orgId == Maybe.map .id org then
                    viewProjectForm model form

                else
                    text ""

            Nothing ->
                text ""
        ]


viewProject : Project -> Html Msg
viewProject project =
    Ui.card [ class "flex flex-col gap-2 p-4" ]
        [ Ui.titleLink
            [ Html.Attributes.href (Route.toString (Route.Entries project.slug "" []))
            , class "text-[15px] font-semibold"
            ]
            [ text project.name ]
        , div [ class "flex items-center gap-3 text-xs text-ink-soft" ]
            [ span [ class "font-mono" ] [ text project.slug ]
            , span [ class "ml-auto" ] [ text (roleText project.role) ]
            ]
        ]


roleText : String -> String
roleText role =
    case role of
        "OWNER" ->
            "管理者"

        "EDITOR" ->
            "編集者"

        "WRITER" ->
            "投稿者"

        "VIEWER" ->
            "閲覧者"

        other ->
            other


viewProjectForm : Model -> { orgId : String, name : String, slug : String } -> Html Msg
viewProjectForm model form =
    Ui.card [ class "flex flex-col gap-4 p-4" ]
        [ Ui.subheading "プロジェクトを作成"
        , Ui.field { label = "名前", hint = Nothing, errors = [] }
            [ Ui.input [ value form.name, onInput ProjectNameTyped, placeholder "ブログ" ] ]
        , Ui.field { label = "プロジェクト slug", hint = Just "URL に出る名前。英小文字・数字・ハイフン", errors = [] }
            [ Ui.input [ value form.slug, onInput ProjectSlugTyped, class "font-mono", placeholder "blog" ] ]
        , div [ class "flex gap-2" ]
            [ Ui.button [ onClick ProjectSubmitted ] [ text (busyText model "作成") ]
            , Ui.ghostButton [ onClick CloseForms ] [ text "キャンセル" ]
            ]
        ]


viewOrgForm : Model -> Html Msg
viewOrgForm model =
    case model.newOrg of
        Just name ->
            Ui.card [ class "flex flex-col gap-4 p-4" ]
                [ Ui.subheading "組織を作成"
                , Ui.field { label = "名前", hint = Nothing, errors = [] }
                    [ Ui.input [ value name, onInput OrgNameTyped, placeholder "自分の組織" ] ]
                , div [ class "flex gap-2" ]
                    [ Ui.button [ onClick OrgSubmitted ] [ text (busyText model "作成") ]
                    , Ui.ghostButton [ onClick CloseForms ] [ text "キャンセル" ]
                    ]
                ]

        Nothing ->
            Ui.ghostButton [ onClick OpenOrgForm ] [ text "+ 組織を作成" ]


busyText : Model -> String -> String
busyText model label =
    if model.busy then
        "送信中…"

    else
        label
