module Page.Members exposing (Model, Msg(..), init, load, update, view)

{-| プロジェクト設定 › メンバー。招待・権限の変更・削除・招待の取り消し。

権限が無い人には操作を出さない（判定は CMS がする。画面は出し分けるだけ）。
招待は承認の操作が要らず、招待された人が次にログインしたときにメンバーになる。

返事と確認は `Ui.Reply` / `Ui.Confirm`。GitHub / Contentful と同じく、外す・取り消すは
モーダルで確かめ、権限の変更はその行のすぐ横に結果を出す。

用語は spec 7 章の表に従って「権限」（ロールとは呼ばない）。

-}

import Api
import Api.Admin.Enum.Role as Role exposing (Role)
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, value)
import Html.Events exposing (onInput)
import Loaded exposing (Loaded)
import Model exposing (Invite, MemberRow, Slug)
import Queries
import Time
import Ui
import Ui.Confirm
import Ui.DateTime
import Ui.Reply as Reply exposing (Reply)


type alias Model =
    { members : Loaded (List MemberRow)
    , invitations : Loaded (List Invite)
    , inviteEmail : String
    , inviteRole : Role
    , inviteReply : Reply

    {- 招待できた事の帯。一覧側の出来事なので、フォームの返事とは別に持つ。 -}
    , invited : Maybe String

    {- 権限を変えた行と、その返事。1 度に 1 行しか変えられない。 -}
    , roleReply : Maybe ( String, Reply )
    , confirmRemove : Maybe MemberRow
    , removing : Reply
    , confirmCancel : Maybe Invite
    , cancelling : Reply
    , zone : Time.Zone
    , today : Maybe { year : Int, month : Int, day : Int }
    }


type Msg
    = GotMembers (Result Api.Problem (List MemberRow))
    | GotInvitations (Result Api.Problem (List Invite))
    | InviteEmailTyped String
    | InviteRoleChosen String
    | InviteSubmitted
    | GotInvite (Result Api.Problem Invite)
    | InviteBannerClosed
    | RoleChanged String String
    | GotRoleChange (Result Api.Problem MemberRow)
    | RoleReplyShown
    | RemoveAsked MemberRow
    | RemoveCancelled
    | RemoveConfirmed
    | GotRemoved (Result Api.Problem String)
    | CancelAsked Invite
    | CancelDismissed
    | CancelConfirmed
    | GotCancelled (Result Api.Problem String)
    | TodayKnown Time.Zone Int Int Int
    | EscapePressed
    | Ignored


init : Model
init =
    { members = Loaded.Loading
    , invitations = Loaded.Loading
    , inviteEmail = ""
    , inviteRole = Role.Writer
    , inviteReply = Reply.idle
    , invited = Nothing
    , roleReply = Nothing
    , confirmRemove = Nothing
    , removing = Reply.idle
    , confirmCancel = Nothing
    , cancelling = Reply.idle
    , zone = Time.utc
    , today = Nothing
    }


{-| 画面を開いたときに引く物。
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
            ( { model | inviteEmail = String.toLower (String.trim email), inviteReply = Reply.touched model.inviteReply }, [] )

        InviteRoleChosen chosen ->
            ( { model | inviteRole = roleOf chosen, inviteReply = Reply.touched model.inviteReply }, [] )

        InviteSubmitted ->
            ( { model | inviteReply = Reply.sending }
            , [ Api.call
                    (\id -> Queries.inviteMember id ctx.project { email = model.inviteEmail, role = model.inviteRole })
                    GotInvite
              ]
            )

        GotInvite (Ok _) ->
            -- **応答をそのまま一覧に足さない。** 既にログインした事のある人を招待すると、
            -- CMS はその場でメンバーにし、行の無い Invitation を返す（その id では取り消せない）。
            -- どちらになったか分からないので、両方を引き直す。
            ( { model | inviteReply = Reply.idle, invited = Just ("「" ++ model.inviteEmail ++ "」を招待しました"), inviteEmail = "" }, load ctx.project )

        GotInvite (Err problem) ->
            ( { model | inviteReply = Reply.failed problem }, [] )

        InviteBannerClosed ->
            ( { model | invited = Nothing }, [] )

        RoleChanged userId chosen ->
            ( { model | roleReply = Just ( userId, Reply.sending ) }
            , [ Api.call (\id -> Queries.changeMemberRole id ctx.project { userId = userId, role = roleOf chosen }) GotRoleChange ]
            )

        GotRoleChange (Ok member) ->
            ( { model
                | roleReply = Just ( member.userId, Reply.done "変更しました" )
                , members = Loaded.map (List.map (\row -> ifSame row member)) model.members
              }
            , []
            )

        GotRoleChange (Err problem) ->
            ( { model | roleReply = model.roleReply |> Maybe.map (\( userId, _ ) -> ( userId, Reply.failed problem )) }, [] )

        -- 成功の印だけ数秒で下ろす。失敗の理由は読むまで残す
        RoleReplyShown ->
            ( { model | roleReply = model.roleReply |> Maybe.andThen keepIfFailed }, [] )

        RemoveAsked row ->
            ( { model | confirmRemove = Just row, removing = Reply.idle }, [] )

        RemoveCancelled ->
            ( { model | confirmRemove = Nothing }, [] )

        RemoveConfirmed ->
            case model.confirmRemove of
                Just row ->
                    ( { model | removing = Reply.sending }, [ Api.call (\id -> Queries.removeMember id ctx.project row.userId) GotRemoved ] )

                Nothing ->
                    ( model, [] )

        GotRemoved (Ok userId) ->
            ( { model
                | removing = Reply.idle
                , confirmRemove = Nothing
                , members = Loaded.map (List.filter (\row -> row.userId /= userId)) model.members
              }
            , []
            )

        GotRemoved (Err problem) ->
            ( { model | removing = Reply.failed problem }, [] )

        CancelAsked invite ->
            ( { model | confirmCancel = Just invite, cancelling = Reply.idle }, [] )

        CancelDismissed ->
            ( { model | confirmCancel = Nothing }, [] )

        CancelConfirmed ->
            case model.confirmCancel of
                Just invite ->
                    ( { model | cancelling = Reply.sending }, [ Api.call (\id -> Queries.cancelInvitation id ctx.project invite.id) GotCancelled ] )

                Nothing ->
                    ( model, [] )

        GotCancelled (Ok inviteId) ->
            ( { model
                | cancelling = Reply.idle
                , confirmCancel = Nothing
                , invitations = Loaded.map (List.filter (\invite -> invite.id /= inviteId)) model.invitations
              }
            , []
            )

        GotCancelled (Err problem) ->
            ( { model | cancelling = Reply.failed problem }, [] )

        TodayKnown zone year month day ->
            ( { model | zone = zone, today = Just { year = year, month = month, day = day } }, [] )

        EscapePressed ->
            ( { model | confirmRemove = Nothing, confirmCancel = Nothing }, [] )

        Ignored ->
            ( model, [] )


keepIfFailed : ( String, Reply ) -> Maybe ( String, Reply )
keepIfFailed ( userId, reply ) =
    if List.isEmpty (Reply.general reply) then
        Nothing

    else
        Just ( userId, reply )


ifSame : MemberRow -> MemberRow -> MemberRow
ifSame row updated =
    if row.userId == updated.userId then
        updated

    else
        row


roleOf : String -> Role
roleOf value =
    case value of
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
            [ text "権限は 管理者・編集者・投稿者・閲覧者 の順に、上位が下位の操作をすべて含みます。招待した人は、次にログインしたときにメンバーになります。" ]
        , if args.canManage then
            viewInviteForm model

          else
            text ""
        , Reply.banner { message = model.invited, onClose = InviteBannerClosed }
        , viewMembers args model
        , viewInvitations args model
        , case model.confirmRemove of
            Just row ->
                Ui.Confirm.view
                    { title = "「" ++ nameOf row ++ "」をこのプロジェクトから外しますか"
                    , body = "このプロジェクトのコンテンツを読み書きできなくなります。招待し直せば戻せます。"
                    , confirm = "外す"
                    , reply = model.removing
                    , onConfirm = RemoveConfirmed
                    , onCancel = RemoveCancelled
                    , ignore = Ignored
                    }

            Nothing ->
                text ""
        , case model.confirmCancel of
            Just invite ->
                Ui.Confirm.view
                    { title = "「" ++ invite.email ++ "」への招待を取り消しますか"
                    , body = "この人はログインしてもメンバーになりません。もう一度招待し直せます。"
                    , confirm = "取り消す"
                    , reply = model.cancelling
                    , onConfirm = CancelConfirmed
                    , onCancel = CancelDismissed
                    , ignore = Ignored
                    }

            Nothing ->
                text ""
        ]


viewInviteForm : Model -> Html Msg
viewInviteForm model =
    Ui.card [ class "flex items-end gap-4 p-4" ]
        [ div [ class "flex-1" ]
            [ Ui.field { label = "招待するメールアドレス", hint = Nothing, errors = Reply.errorsFor "email" model.inviteReply }
                [ Ui.input [ value model.inviteEmail, onInput InviteEmailTyped, placeholder "editor@example.com" ] ]
            ]
        , div [ class "w-40" ]
            [ Ui.field { label = "権限", hint = Nothing, errors = Reply.errorsFor "role" model.inviteReply }
                [ Ui.select [ onInput InviteRoleChosen ] roleOptions (Role.toString model.inviteRole) ]
            ]
        , Reply.addButton
            { label = "招待"
            , ready = String.contains "@" model.inviteEmail
            , reply = model.inviteReply
            , onAdd = InviteSubmitted
            }
        ]


viewMembers : { canManage : Bool } -> Model -> Html Msg
viewMembers args model =
    Loaded.view
        { loading = Ui.loadingCard
        , missing = Ui.table [ Ui.empty "メンバーがいません" ]
        , failed = Ui.failedCard
        , present =
            \rows ->
                if List.isEmpty rows then
                    Ui.messageCard "メンバーがいません"
                        [ Ui.note
                            [ text "組織の管理者は、プロジェクトのメンバーでなくてもすべての操作ができるため、この一覧には表示されません。メンバーを追加するには、上のフォームからメールアドレスで招待してください。" ]
                        ]

                else
                    Ui.table
                        (Ui.headRowOf memberColumns [ text "メンバー", text "権限", text "", text "" ]
                            :: List.map (viewMember args model) rows
                        )
        }
        model.members


{-| メンバーの表の列。名前は広く、権限は選ぶ幅、右端に操作。
-}
memberColumns : String
memberColumns =
    "grid-cols-[1fr_170px_140px_80px]"


viewMember : { canManage : Bool } -> Model -> MemberRow -> Html Msg
viewMember args model row =
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
        , case model.roleReply of
            Just ( userId, reply ) ->
                if userId == row.userId then
                    Reply.view reply

                else
                    text ""

            Nothing ->
                text ""
        , if args.canManage then
            div [ class "text-right" ] [ Ui.dangerLink (RemoveAsked row) "外す" ]

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
                    (Ui.headRowOf memberColumns [ text "メールアドレス", text "権限", text "招待", text "" ]
                        :: List.map (viewInvitation args model) (first :: rest)
                    )
                ]

        _ ->
            text ""


viewInvitation : { canManage : Bool } -> Model -> Invite -> Html Msg
viewInvitation args model invite =
    Ui.rowOf memberColumns
        [ span [ class "font-medium" ] [ text invite.email ]
        , span [ class "text-ink-soft" ] [ text (roleText invite.role) ]
        , viewInvitedAt model invite
        , if args.canManage then
            div [ class "text-right" ] [ Ui.dangerLink (CancelAsked invite) "取り消す" ]

          else
            text ""
        ]


{-| いつ招待したか。GitHub の "Invited 3 days ago" と同じく相対で、絶対の日時はホバーに。
-}
viewInvitedAt : Model -> Invite -> Html Msg
viewInvitedAt model invite =
    let
        absolute : String
        absolute =
            Ui.DateTime.formatLocal model.zone invite.invitedAt
    in
    case model.today |> Maybe.andThen (\today -> Ui.DateTime.daysFromToday model.zone today invite.invitedAt) of
        Just ago ->
            span [ class "text-[11px] text-ink-soft", Html.Attributes.title absolute ] [ text (relative (negate ago)) ]

        Nothing ->
            span [ class "font-mono text-[11px] text-ink-soft" ] [ text absolute ]


relative : Int -> String
relative daysAgo =
    if daysAgo <= 0 then
        "今日"

    else if daysAgo == 1 then
        "昨日"

    else if daysAgo < 30 then
        String.fromInt daysAgo ++ " 日前"

    else if daysAgo < 365 then
        String.fromInt (daysAgo // 30) ++ " か月前"

    else
        String.fromInt (daysAgo // 365) ++ " 年前"
