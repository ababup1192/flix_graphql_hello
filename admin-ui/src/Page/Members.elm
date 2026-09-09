module Page.Members exposing (Model, Msg, init, load, update, view)

{-| プロジェクト設定 › メンバー。招待・権限の変更・削除・招待の取り消し。

権限が無い人には操作を出さない（判定は CMS がする。画面は出し分けるだけ）。
招待は承認の操作が要らず、招待された人が次にログインした時にメンバーになる。

-}

import Api
import Api.Admin.Enum.Role as Role exposing (Role)
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Loaded exposing (Loaded)
import Model exposing (Invite, MemberRow, Slug)
import Queries
import Ui


type alias Model =
    { members : Loaded (List MemberRow)
    , invitations : Loaded (List Invite)
    , inviteEmail : String
    , inviteRole : Role
    , errors : List String
    , busy : Bool
    }


type Msg
    = GotMembers (Result Api.Problem (List MemberRow))
    | GotInvitations (Result Api.Problem (List Invite))
    | InviteEmailTyped String
    | InviteRoleChosen String
    | InviteSubmitted
    | GotInvite (Result Api.Problem Invite)
    | RoleChanged String String
    | GotRoleChange (Result Api.Problem MemberRow)
    | MemberRemoved String
    | GotRemoved (Result Api.Problem String)
    | InvitationCancelled String
    | GotCancelled (Result Api.Problem String)


init : Model
init =
    { members = Loaded.Loading, invitations = Loaded.Loading, inviteEmail = "", inviteRole = Role.Writer, errors = [], busy = False }


{-| 画面を開いた時に引く物。
-}
load : Slug -> List (Api.Call Msg)
load slug =
    [ Api.call (\id -> Queries.members id slug) GotMembers
    , Api.call (\id -> Queries.invitations id slug) GotInvitations
    ]


update : { project : Slug } -> Msg -> Model -> ( Model, List (Api.Call Msg) )
update ctx msg model =
    case msg of
        GotMembers result ->
            ( { model | members = Loaded.fromResult (Result.map Just result) }, [] )

        GotInvitations result ->
            ( { model | invitations = Loaded.fromResult (Result.map Just result) }, [] )

        InviteEmailTyped email ->
            ( { model | inviteEmail = String.toLower (String.trim email) }, [] )

        InviteRoleChosen text ->
            ( { model | inviteRole = roleOf text }, [] )

        InviteSubmitted ->
            if String.contains "@" model.inviteEmail then
                ( { model | busy = True, errors = [] }
                , [ Api.call
                        (\id -> Queries.inviteMember id ctx.project { email = model.inviteEmail, role = model.inviteRole })
                        GotInvite
                  ]
                )

            else
                ( { model | errors = [ "メールアドレスを入れてください" ] }, [] )

        GotInvite (Ok _) ->
            -- **応答をそのまま一覧に足さない。** 既にログインした事のある人を招待すると、
            -- CMS はその場でメンバーにし、行の無い Invitation を返す（その id では取り消せない）。
            -- どちらになったか分からないので、両方を引き直す。
            ( { model | busy = False, inviteEmail = "" }, load ctx.project )

        GotInvite (Err problem) ->
            ( failed problem model, [] )

        RoleChanged userId text ->
            ( { model | busy = True }
            , [ Api.call (\id -> Queries.changeMemberRole id ctx.project { userId = userId, role = roleOf text }) GotRoleChange ]
            )

        GotRoleChange (Ok member) ->
            ( { model
                | busy = False
                , members = Loaded.map (List.map (\row -> ifSame row member)) model.members
              }
            , []
            )

        GotRoleChange (Err problem) ->
            ( failed problem model, [] )

        MemberRemoved userId ->
            ( { model | busy = True }, [ Api.call (\id -> Queries.removeMember id ctx.project userId) GotRemoved ] )

        GotRemoved (Ok userId) ->
            ( { model | busy = False, members = Loaded.map (List.filter (\row -> row.userId /= userId)) model.members }, [] )

        GotRemoved (Err problem) ->
            ( failed problem model, [] )

        InvitationCancelled inviteId ->
            ( { model | busy = True }, [ Api.call (\id -> Queries.cancelInvitation id ctx.project inviteId) GotCancelled ] )

        GotCancelled (Ok inviteId) ->
            ( { model | busy = False, invitations = Loaded.map (List.filter (\invite -> invite.id /= inviteId)) model.invitations }, [] )

        GotCancelled (Err problem) ->
            ( failed problem model, [] )


ifSame : MemberRow -> MemberRow -> MemberRow
ifSame row updated =
    if row.userId == updated.userId then
        updated

    else
        row


failed : Api.Problem -> Model -> Model
failed problem model =
    { model | busy = False, errors = [ (Api.problemToText problem).message ] }


roleOf : String -> Role
roleOf text =
    case text of
        "OWNER" ->
            Role.Owner

        "EDITOR" ->
            Role.Editor

        "VIEWER" ->
            Role.Viewer

        _ ->
            Role.Writer


roleOptions : List ( String, String )
roleOptions =
    [ ( "OWNER", "管理者" ), ( "EDITOR", "編集者" ), ( "WRITER", "投稿者" ), ( "VIEWER", "閲覧者" ) ]


roleText : String -> String
roleText value =
    roleOptions |> List.filter (\( key, _ ) -> key == value) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault value


view : { canManage : Bool } -> Model -> Html Msg
view args model =
    Ui.page []
        [ Ui.pageHeader { title = "メンバー", icon = Nothing, meta = [], actions = [] }
        , Ui.note
            [ text "権限は 管理者 ⊃ 編集者 ⊃ 投稿者 ⊃ 閲覧者。招待した人は、次にログインした時にメンバーになります。" ]
        , Ui.errors model.errors
        , if args.canManage then
            viewInviteForm model

          else
            text ""
        , viewMembers args model
        , viewInvitations args model
        ]


viewInviteForm : Model -> Html Msg
viewInviteForm model =
    Ui.card [ class "flex items-end gap-4 p-4" ]
        [ div [ class "flex-1" ]
            [ Ui.field { label = "招待するメールアドレス", hint = Nothing, errors = [] }
                [ Ui.input [ value model.inviteEmail, onInput InviteEmailTyped, placeholder "editor@example.com" ] ]
            ]
        , div [ class "w-40" ]
            [ Ui.field { label = "権限", hint = Nothing, errors = [] }
                [ Ui.select [ onInput InviteRoleChosen ] roleOptions (Role.toString model.inviteRole) ]
            ]
        , Ui.button [ onClick InviteSubmitted ] [ text (busyText model "招待する") ]
        ]


busyText : Model -> String -> String
busyText model label =
    if model.busy then
        "送っています…"

    else
        label


viewMembers : { canManage : Bool } -> Model -> Html Msg
viewMembers args model =
    Loaded.view
        { loading = Ui.loadingCard
        , missing = Ui.table [ Ui.empty "メンバーがいません" ]
        , failed = Ui.failedCard
        , present =
            \rows ->
                if List.isEmpty rows then
                    Ui.messageCard "このプロジェクトのメンバーはまだいません"
                        [ Ui.note
                            [ text "組織の管理者は、プロジェクトのメンバーに入れなくても全部の操作ができます。そのため、ここには出ません。人を増やす時は上のメールアドレスから招待してください。" ]
                        ]

                else
                    Ui.table
                        (Ui.headRowOf memberColumns [ text "メンバー", text "権限", text "", text "" ]
                            :: List.map (viewMember args) rows
                        )
        }
        model.members


{-| メンバーの表の列。名前は広く、権限は選ぶ幅、右端に操作。
-}
memberColumns : String
memberColumns =
    "grid-cols-[1fr_170px_110px_80px]"


viewMember : { canManage : Bool } -> MemberRow -> Html Msg
viewMember args row =
    Ui.rowOf memberColumns
        [ div [ class "flex items-center gap-2.5" ]
            [ Ui.avatar (nameOf row)
            , div [ class "flex flex-col" ]
                [ span [ class "font-medium" ] [ text (nameOf row) ]
                , span [ class "text-[11px] text-ink-faint" ] [ text row.email ]
                ]
            ]
        , if args.canManage then
            Ui.select [ onInput (RoleChanged row.userId) ] roleOptions row.role

          else
            span [ class "text-ink-soft" ] [ text (roleText row.role) ]
        , text ""
        , if args.canManage then
            div [ class "text-right" ] [ Ui.dangerLink (MemberRemoved row.userId) "外す" ]

          else
            text ""
        ]


nameOf : MemberRow -> String
nameOf row =
    if String.isEmpty row.name then
        row.email |> String.split "@" |> List.head |> Maybe.withDefault row.email

    else
        row.name


viewInvitations : { canManage : Bool } -> Model -> Html Msg
viewInvitations args model =
    case Loaded.toMaybe model.invitations of
        Just (first :: rest) ->
            div [ class "flex flex-col gap-3" ]
                [ Ui.sectionTitle "招待中"
                , Ui.table
                    (Ui.headRowOf memberColumns [ text "メールアドレス", text "権限", text "", text "" ]
                        :: List.map (viewInvitation args) (first :: rest)
                    )
                ]

        _ ->
            text ""


viewInvitation : { canManage : Bool } -> Invite -> Html Msg
viewInvitation args invite =
    Ui.rowOf memberColumns
        [ span [ class "font-medium" ] [ text invite.email ]
        , span [ class "text-ink-soft" ] [ text (roleText invite.role) ]
        , Ui.chip Ui.toneNeutral "ログイン待ち"
        , if args.canManage then
            div [ class "text-right" ] [ Ui.dangerLink (InvitationCancelled invite.id) "取り消す" ]

          else
            text ""
        ]
