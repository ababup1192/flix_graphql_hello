module Queries exposing
    ( AuditQuery
    , FieldPatch
    , Kind
    , NewField
    , addField
    , addFieldImpact
    , all
    , apiKeys
    , assets
    , auditEvents
    , auditEventsCount
    , cancelInvitation
    , cancelSchedule
    , changeMemberRole
    , chunkIds
    , confirmAsset
    , contentType
    , contentTypes
    , createApiKey
    , createContentType
    , createEntry
    , createOrganization
    , createPersonalToken
    , createProject
    , createUploadUrl
    , createWebhook
    , deleteAsset
    , deleteContentType
    , deleteWebhook
    , entries
    , entry
    , fetchLinkCard
    , invitations
    , inviteMember
    , linkCards
    , me
    , members
    , organizationProjects
    , personalTokens
    , publishCheck
    , publishEntry
    , referrers
    , removeField
    , removeFieldImpact
    , removeMember
    , reorderFields
    , restoreVersion
    , revokeApiKey
    , revokePersonalToken
    , saveVersion
    , schedulePublish
    , schedules
    , unpublishEntry
    , updateAsset
    , updateContentType
    , updateEntry
    , updateField
    , updateFieldImpact
    , updateProjectVisibility
    , versions
    , viewer
    , webhooks
    )

{-| CMS に投げる物を全部ここに置く。

**ここに置かないと契約の確認に乗らない。** `all` が返す物を `scripts/contract.mjs` が
実際の CMS に投げて、200 が返るかを見る。型が通ってもサーバに拒まれる物（操作名の食い違い、
引数の形、権限）は Elm の型では防げないので、ここで捕まえる。

-}

import Api
import Api.Account.Enum.OrgRole as OrgRole
import Api.Account.Enum.PatScope as PatScope
import Api.Account.Enum.Role as AccountRole
import Api.Account.Enum.Visibility as AccountVisibility
import Api.Account.Mutation as AccountMutation
import Api.Account.Object
import Api.Account.Object.IssuedPersonalAccessToken as IssuedPat
import Api.Account.Object.Me as Me
import Api.Account.Object.Organization as Organization
import Api.Account.Object.OrganizationMembership as OrgMembership
import Api.Account.Object.PersonalAccessToken as Pat
import Api.Account.Object.Project as AccountProject
import Api.Account.Object.ProjectMembership as ProjectMembership
import Api.Account.Query
import Api.Admin.Enum.ActorKind as ActorKind exposing (ActorKind)
import Api.Admin.Enum.ApiKeyScope as ApiKeyScope exposing (ApiKeyScope)
import Api.Admin.Enum.AssetStatus as AssetStatus
import Api.Admin.Enum.ContentStage as ContentStage
import Api.Admin.Enum.EntryStage as EntryStage
import Api.Admin.Enum.FieldConditionOp as FieldOp
import Api.Admin.Enum.FieldKind as FieldKind exposing (FieldKind)
import Api.Admin.Enum.ImpactAction as ImpactAction
import Api.Admin.Enum.Role as AdminRole
import Api.Admin.Enum.ScheduleAction as ScheduleAction
import Api.Admin.Enum.ScheduleStatus as ScheduleStatus
import Api.Admin.Enum.SchemaAction as SchemaAction
import Api.Admin.Enum.SchemaEffectKind as SchemaEffectKind
import Api.Admin.Enum.SortDirection as SortDirection
import Api.Admin.Enum.TypeKind as TypeKind
import Api.Admin.Enum.VersionReason as VersionReason
import Api.Admin.Enum.Visibility as Visibility
import Api.Admin.Enum.WebhookEvent as WebhookEvent exposing (WebhookEvent)
import Api.Admin.InputObject as Input
import Api.Admin.Mutation as AdminMutation
import Api.Admin.Object
import Api.Admin.Object.ApiKey as ApiKey
import Api.Admin.Object.Asset as Asset
import Api.Admin.Object.AssetPage as AssetPage
import Api.Admin.Object.AuditEvent as AuditEvent
import Api.Admin.Object.ContentType as ContentType
import Api.Admin.Object.Entry as Entry
import Api.Admin.Object.EntryPage as EntryPage
import Api.Admin.Object.EntryVersion as EntryVersion
import Api.Admin.Object.FieldConfig as FieldConfig
import Api.Admin.Object.FieldDef as FieldDef
import Api.Admin.Object.Impact as Impact
import Api.Admin.Object.Invitation as Invitation
import Api.Admin.Object.IssuedApiKey as IssuedApiKey
import Api.Admin.Object.IssuedWebhook as IssuedWebhook
import Api.Admin.Object.LinkCard as LinkCard
import Api.Admin.Object.Member as Member
import Api.Admin.Object.Project as AdminProject
import Api.Admin.Object.PublishReport as PublishReport
import Api.Admin.Object.Referrer as Referrer
import Api.Admin.Object.Schedule as Schedule
import Api.Admin.Object.SchemaEffect as SchemaEffect
import Api.Admin.Object.SchemaImpact as SchemaImpact
import Api.Admin.Object.Upload as Upload
import Api.Admin.Object.Viewer as Viewer
import Api.Admin.Object.Violation as Violation
import Api.Admin.Object.Webhook as Webhook
import Api.Admin.Query
import EntryLabel
import Filter
import Graphql.OptionalArgument as Opt
import Graphql.SelectionSet as SS exposing (SelectionSet)
import Json.Decode as D
import Json.Encode as E
import Model exposing (AuditRow, ContentTypeDetail, ContentTypeSummary, EntryList, EntryRow, FieldDef, Invite, MemberRow, Org, Person, Slug, ViewerInfo)
import ScalarCodecs


{-| 契約の確認に投げる物の名前。
-}
type Kind
    = Me
    | Viewer
    | ContentTypes
    | Members
    | Invitations
    | OneContentType
    | EntriesQuery
    | OrgProjects
    | AuditEvents
    | AuditEventsCount
    | LinkCardsQuery
    | FetchLinkCardMutation


{-| 確認に投げる読むだけの物。書く物は投げない（実データが増える）。

WhyNot: `fetchLinkCard` は mutation だが例外で載せる。private アドレスの URL は
取りに行かず表にも残らない（error だけ返る）ので、実データを増やさずに document の形を試せる。

-}
all : { project : Slug } -> List ( Kind, Api.Request )
all args =
    [ ( Me, me "c1" |> Tuple.first )
    , ( Viewer, viewer "c2" args.project |> Tuple.first )
    , ( ContentTypes, contentTypes "c3" args.project |> Tuple.first )
    , ( Members, members "c4" args.project |> Tuple.first )
    , ( Invitations, invitations "c5" args.project |> Tuple.first )
    , ( OneContentType, contentType "c6" args.project "blogs" |> Tuple.first )
    , ( EntriesQuery, entries "c7" args.project { typeId = "1", search = "", stage = "", conditions = [], ids = [], order = "", first = 5, skip = 0 } |> Tuple.first )
    , ( OrgProjects, organizationProjects "c8" "1" |> Tuple.first )
    , ( AuditEvents, auditEvents "c9" args.project { first = 5, after = Nothing, actorKind = Nothing, action = Nothing, since = Nothing, until = Nothing } |> Tuple.first )
    , ( AuditEventsCount, auditEventsCount "c10" args.project { first = 5, after = Nothing, actorKind = Nothing, action = Nothing, since = Nothing, until = Nothing } |> Tuple.first )
    , ( LinkCardsQuery, linkCards "c11" args.project [ "https://example.com/" ] |> Tuple.first )
    , ( FetchLinkCardMutation, fetchLinkCard "c12" args.project "http://127.0.0.1/" |> Tuple.first )
    ]



-- Account API


me : String -> ( Api.Request, D.Decoder (Maybe Person) )
me id =
    Api.accountQuery { id = id, kind = "me" } (Api.Account.Query.me meSelection)


meSelection : SelectionSet Person Api.Account.Object.Me
meSelection =
    SS.map5 Person
        Me.id
        Me.email
        Me.name
        (Me.organizations orgSelection)
        (Me.projects projectSelection)


orgSelection : SelectionSet Org Api.Account.Object.OrganizationMembership
orgSelection =
    SS.map2 (\org role -> { id = org.id, name = org.name, role = OrgRole.toString role })
        (OrgMembership.organization (SS.map2 (\id name -> { id = id, name = name }) Organization.id Organization.name))
        OrgMembership.role


projectSelection : SelectionSet Model.Project Api.Account.Object.ProjectMembership
projectSelection =
    SS.map2
        (\project role ->
            { id = project.id
            , slug = project.slug
            , name = project.name
            , visibility = project.visibility
            , role = AccountRole.toString role
            }
        )
        (ProjectMembership.project
            (SS.map4 (\id slug name visibility -> { id = id, slug = slug, name = name, visibility = visibility })
                AccountProject.id
                AccountProject.slug
                AccountProject.name
                (AccountProject.visibility |> SS.map AccountVisibility.toString)
            )
        )
        ProjectMembership.role


createOrganization : String -> String -> ( Api.Request, D.Decoder Org )
createOrganization id name =
    Api.accountMutation { id = id, kind = "createOrganization" }
        (AccountMutation.createOrganization { name = name }
            (SS.map2 (\oid oname -> { id = oid, name = oname, role = "OWNER" }) Organization.id Organization.name)
        )


createProject : String -> { orgId : String, slug : String, name : String } -> ( Api.Request, D.Decoder Model.Project )
createProject id args =
    Api.accountMutation { id = id, kind = "createProject" }
        (AccountMutation.createProject
            { orgId = args.orgId, slug = args.slug, name = args.name }
            (SS.map4 (\pid slug name visibility -> { id = pid, slug = slug, name = name, visibility = AccountVisibility.toString visibility, role = "OWNER" })
                AccountProject.id
                AccountProject.slug
                AccountProject.name
                AccountProject.visibility
            )
        )



-- 管理 API


viewer : String -> Slug -> ( Api.Request, D.Decoder ViewerInfo )
viewer id project =
    Api.query { id = id, kind = "viewer", project = project }
        (Api.Admin.Query.viewer
            (SS.map2 (\name permissions -> { name = name, permissions = permissions })
                Viewer.name
                Viewer.permissions
            )
        )


contentTypes : String -> Slug -> ( Api.Request, D.Decoder (List ContentTypeSummary) )
contentTypes id project =
    Api.query { id = id, kind = "contentTypes", project = project }
        (Api.Admin.Query.contentTypes
            typeSummary
        )


{-| その組織の下にあるプロジェクトの id。

**`me.projects` は組織を持っていない**（SDL の `Project` に `organization` が無い）ので、
どのプロジェクトがどの組織の物かは組織側から引くしかない。
これが無いと、組織を 2 つ持つ人の画面に同じプロジェクトが両方に出る（実際に出た）。

-}
organizationProjects : String -> String -> ( Api.Request, D.Decoder { orgId : String, projectIds : List String } )
organizationProjects id orgId =
    Api.accountQuery { id = id, kind = "organizationProjects" }
        (Api.Account.Query.organization { id = orgId }
            (SS.map2 (\theId ids -> { orgId = theId, projectIds = ids })
                Organization.id
                (Organization.projects AccountProject.id)
            )
            |> SS.map (Maybe.withDefault { orgId = orgId, projectIds = [] })
        )


members : String -> Slug -> ( Api.Request, D.Decoder (List MemberRow) )
members id project =
    Api.query { id = id, kind = "members", project = project }
        (Api.Admin.Query.members
            (SS.map4 (\userId email name role -> { userId = userId, email = email, name = name, role = AdminRole.toString role })
                Member.userId
                Member.email
                Member.name
                Member.role
            )
        )


invitations : String -> Slug -> ( Api.Request, D.Decoder (List Invite) )
invitations id project =
    Api.query { id = id, kind = "invitations", project = project }
        (Api.Admin.Query.invitations
            (SS.map4 (\inviteId email role invitedAt -> { id = inviteId, email = email, role = AdminRole.toString role, invitedAt = invitedAt })
                Invitation.id
                Invitation.email
                Invitation.role
                Invitation.createdAt
            )
        )


inviteMember : String -> Slug -> { email : String, role : AdminRole.Role } -> ( Api.Request, D.Decoder Invite )
inviteMember id project args =
    Api.mutation { id = id, kind = "inviteMember", project = project }
        (AdminMutation.inviteMember { email = args.email, role = args.role }
            (SS.map4 (\inviteId email role invitedAt -> { id = inviteId, email = email, role = AdminRole.toString role, invitedAt = invitedAt })
                Invitation.id
                Invitation.email
                Invitation.role
                Invitation.createdAt
            )
        )


changeMemberRole : String -> Slug -> { userId : String, role : AdminRole.Role } -> ( Api.Request, D.Decoder MemberRow )
changeMemberRole id project args =
    Api.mutation { id = id, kind = "changeMemberRole", project = project }
        (AdminMutation.changeMemberRole { userId = args.userId, role = args.role }
            (SS.map4 (\userId email name role -> { userId = userId, email = email, name = name, role = AdminRole.toString role })
                Member.userId
                Member.email
                Member.name
                Member.role
            )
        )


removeMember : String -> Slug -> String -> ( Api.Request, D.Decoder String )
removeMember id project userId =
    Api.mutation { id = id, kind = "removeMember", project = project }
        (AdminMutation.removeMember { userId = userId })


cancelInvitation : String -> Slug -> String -> ( Api.Request, D.Decoder String )
cancelInvitation id project inviteId =
    Api.mutation { id = id, kind = "cancelInvitation", project = project }
        (AdminMutation.cancelInvitation { id = inviteId })


{-| 監査ログ。新しい順。`after` は前のページの最後の id、`action` は前方一致、
`since` / `until` は UTC の ISO 8601（since 以上 until 未満）。
-}
auditEvents : String -> Slug -> AuditQuery -> ( Api.Request, D.Decoder (List AuditRow) )
auditEvents id project args =
    Api.query { id = id, kind = "auditEvents", project = project }
        (Api.Admin.Query.auditEvents
            (\optional ->
                { optional
                    | first = Opt.Present args.first
                    , after = presentOr args.after
                    , actorKind = presentOr args.actorKind
                    , action = presentOr args.action
                    , since = presentOr args.since
                    , until = presentOr args.until
                }
            )
            auditRow
        )


{-| 絞り込みに当たる件数。引数は `auditEvents` と同じ（`first` / `after` は見ない）。
-}
auditEventsCount : String -> Slug -> AuditQuery -> ( Api.Request, D.Decoder Int )
auditEventsCount id project args =
    Api.query { id = id, kind = "auditEventsCount", project = project }
        (Api.Admin.Query.auditEventsCount
            (\optional ->
                { optional
                    | actorKind = presentOr args.actorKind
                    , action = presentOr args.action
                    , since = presentOr args.since
                    , until = presentOr args.until
                }
            )
        )


type alias AuditQuery =
    { first : Int
    , after : Maybe String
    , actorKind : Maybe ActorKind
    , action : Maybe String
    , since : Maybe String
    , until : Maybe String
    }


auditRow : SelectionSet AuditRow Api.Admin.Object.AuditEvent
auditRow =
    SS.succeed AuditRow
        |> SS.with AuditEvent.id
        |> SS.with (AuditEvent.actorKind |> SS.map ActorKind.toString)
        |> SS.with AuditEvent.actorId
        |> SS.with AuditEvent.actor
        |> SS.with AuditEvent.action
        |> SS.with AuditEvent.targetKind
        |> SS.with AuditEvent.targetId
        |> SS.with AuditEvent.detail
        |> SS.with AuditEvent.createdAt


{-| 型 1 つとそのフィールド。API スキーマの画面が使う。
-}
contentType : String -> Slug -> String -> ( Api.Request, D.Decoder (Maybe ContentTypeDetail) )
contentType id project apiId =
    Api.query { id = id, kind = "contentType", project = project }
        (Api.Admin.Query.contentType (\optional -> { optional | apiId = Opt.Present apiId })
            contentTypeDetail
        )


contentTypeDetail : SelectionSet ContentTypeDetail Api.Admin.Object.ContentType
contentTypeDetail =
    SS.succeed ContentTypeDetail
        |> SS.with ContentType.id
        |> SS.with ContentType.apiId
        |> SS.with ContentType.name
        |> SS.with (ContentType.kind |> SS.map TypeKind.toString)
        |> SS.with (ContentType.previewUrl |> SS.map (Maybe.withDefault ""))
        |> SS.with (ContentType.linkPath |> SS.map (Maybe.withDefault ""))
        |> SS.with ContentType.singular
        |> SS.with ContentType.icon
        |> SS.with (ContentType.fields fieldDef)


fieldDef : SelectionSet FieldDef Api.Admin.Object.FieldDef
fieldDef =
    SS.succeed FieldDef
        |> SS.with FieldDef.id
        |> SS.with FieldDef.apiId
        |> SS.with FieldDef.name
        |> SS.with (FieldDef.kind |> SS.map FieldKind.toString)
        |> SS.with FieldDef.many
        |> SS.with FieldDef.required
        |> SS.with FieldDef.unique
        |> SS.with FieldDef.localized
        |> SS.with FieldDef.targetTypeId
        |> SS.with (FieldDef.config fieldConfig)


fieldConfig : SelectionSet Model.FieldConfig Api.Admin.Object.FieldConfig
fieldConfig =
    SS.map6 Model.FieldConfig
        FieldConfig.maxLength
        FieldConfig.sourceField
        FieldConfig.min
        FieldConfig.max
        FieldConfig.integer
        (FieldConfig.options |> SS.map (Maybe.withDefault []))


{-| サイドバーに出す最小限。**kind を持つ**（アイコンが種類で変わる）。
-}
typeSummary : SelectionSet ContentTypeSummary Api.Admin.Object.ContentType
typeSummary =
    SS.map5 (\typeId apiId name kind icon -> { id = typeId, apiId = apiId, name = name, kind = kind, icon = icon })
        ContentType.id
        ContentType.apiId
        ContentType.name
        (ContentType.kind |> SS.map TypeKind.toString)
        ContentType.icon


{-| API（型）を作る。エンドポイントは後から変えられない。
-}
createContentType : String -> Slug -> { apiId : String, name : String, singleton : Bool } -> ( Api.Request, D.Decoder ContentTypeSummary )
createContentType id project args =
    Api.mutation { id = id, kind = "createContentType", project = project }
        (AdminMutation.createContentType
            { input =
                { apiId = args.apiId
                , name = args.name
                , kind =
                    Opt.Present
                        (if args.singleton then
                            TypeKind.Singleton

                         else
                            TypeKind.Collection
                        )
                , singular = Opt.Absent
                , plural = Opt.Absent
                , previewUrl = Opt.Absent
                , linkPath = Opt.Absent
                , icon = Opt.Absent
                }
            }
            typeSummary
        )


{-| フィールドを足す。

種類によって config が要る（SLUG は元にするフィールド、SELECT は選択肢、REFERENCE は参照先の型）。
足りないと CMS が INVALID で断る。

-}
type alias NewField =
    { typeId : String
    , apiId : String
    , name : String
    , kind : FieldKind
    , required : Bool
    , many : Bool
    , sourceField : String
    , options : List String
    , targetTypeId : String
    }


addField : String -> Slug -> NewField -> Maybe Model.SchemaImpact -> ( Api.Request, D.Decoder FieldDef )
addField id project args seen =
    Api.mutation { id = id, kind = "addField", project = project }
        (AdminMutation.addField
            (\optional -> { optional | expected = maybeExpected seen })
            { typeId = args.typeId
            , input = fieldInput args
            }
            fieldDef
        )


{-| フィールドを足すと既存のデータに何が起きるか。**書き込まない。**

WhyNot: 追加に影響は無い、としない。前に同じフィールド ID で消した値が DB に残っていると、
足した瞬間にその値が API へ戻る。CMS はそれを見ずに足す事を止める。

-}
addFieldImpact : String -> Slug -> NewField -> ( Api.Request, D.Decoder Model.SchemaImpact )
addFieldImpact id project args =
    Api.query { id = id, kind = "fieldImpact", project = project }
        (Api.Admin.Query.fieldImpact
            { input =
                { action = SchemaAction.AddField
                , fieldId = Opt.Absent
                , typeId = Opt.Present args.typeId
                , patch = Opt.Absent
                , field = Opt.Present (fieldInput args)
                }
            }
            schemaImpact
        )


fieldInput : NewField -> Input.FieldInput
fieldInput args =
    let
        input : Input.FieldInput
        input =
            { apiId = args.apiId
            , name = args.name
            , kind = args.kind
            , many = Opt.Present args.many
            , required = Opt.Present args.required
            , unique = Opt.Absent
            , localized = Opt.Absent
            , targetTypeId = presentIf (not (String.isEmpty args.targetTypeId)) args.targetTypeId
            , parentFieldId = Opt.Absent
            , config =
                if String.isEmpty args.sourceField && List.isEmpty args.options then
                    Opt.Absent

                else
                    Opt.Present
                        { maxLength = Opt.Absent
                        , sourceField = presentIf (not (String.isEmpty args.sourceField)) args.sourceField
                        , min = Opt.Absent
                        , max = Opt.Absent
                        , integer = Opt.Absent
                        , options = presentIf (not (List.isEmpty args.options)) args.options
                        }
            }
    in
    input


presentIf : Bool -> a -> Opt.OptionalArgument a
presentIf yes value =
    if yes then
        Opt.Present value

    else
        Opt.Absent


{-| フィールドの設定を直す。**config は丸ごと置き換わる**（CMS の決まり）ので、
画面は今の値を全部詰めて送る。触っていない項目を省くと消える。
-}
type alias FieldPatch =
    { fieldId : String
    , name : String
    , required : Bool
    , unique : Bool
    , localized : Bool
    , maxLength : Maybe Int
    , sourceField : String
    , min : Maybe Float
    , max : Maybe Float
    , integer : Maybe Bool
    , options : List String
    }


{-| フィールドを直す。`expected` は `updateFieldImpact` で見た影響。
影響が無い時も見た物（空）を送る。サーバは見た時より悪くなった時だけ止める。
-}
updateField : String -> Slug -> { patch : FieldPatch, expected : Model.SchemaImpact } -> ( Api.Request, D.Decoder FieldDef )
updateField id project args =
    Api.mutation { id = id, kind = "updateField", project = project }
        (AdminMutation.updateField
            (\optional -> { optional | expected = Opt.Present (expectedOf args.expected) })
            { id = args.patch.fieldId, input = fieldPatchInput args.patch }
            fieldDef
        )


{-| 直す内容を API の形にする。dry-run と本番で同じ物を送る（ずれると dry-run の答えが当てにならない）。
-}
fieldPatchInput : FieldPatch -> Input.FieldPatch
fieldPatchInput args =
    { name = Opt.Present args.name
    , required = Opt.Present args.required
    , unique = Opt.Present args.unique
    , localized = Opt.Present args.localized
    , config =
        Opt.Present
            { maxLength = presentOr args.maxLength
            , sourceField = presentIf (not (String.isEmpty args.sourceField)) args.sourceField
            , min = presentOr args.min
            , max = presentOr args.max
            , integer = presentOr args.integer
            , options = presentIf (not (List.isEmpty args.options)) args.options
            }
    }


presentOr : Maybe a -> Opt.OptionalArgument a
presentOr value =
    case value of
        Just present ->
            Opt.Present present

        Nothing ->
            Opt.Absent


{-| フィールドを消すと既存のデータに何が起きるか。**書き込まない。**

`safe` なら確認なしで押せる。押す時は `effects` から組んだ `expected` を渡す。

-}
removeFieldImpact : String -> Slug -> String -> ( Api.Request, D.Decoder Model.SchemaImpact )
removeFieldImpact id project fieldId =
    Api.query { id = id, kind = "fieldImpact", project = project }
        (Api.Admin.Query.fieldImpact
            { input =
                { action = SchemaAction.RemoveField
                , fieldId = Opt.Present fieldId
                , typeId = Opt.Absent
                , patch = Opt.Absent
                , field = Opt.Absent
                }
            }
            schemaImpact
        )


{-| フィールドを直す前に、当たるコンテンツを数える。patch は `updateField` に送る物と同じ。
-}
updateFieldImpact : String -> Slug -> FieldPatch -> ( Api.Request, D.Decoder Model.SchemaImpact )
updateFieldImpact id project args =
    Api.query { id = id, kind = "fieldImpact", project = project }
        (Api.Admin.Query.fieldImpact
            { input =
                { action = SchemaAction.UpdateField
                , fieldId = Opt.Present args.fieldId
                , typeId = Opt.Absent
                , patch = Opt.Present (fieldPatchInput args)
                , field = Opt.Absent
                }
            }
            schemaImpact
        )


{-| 押す前の影響。当たるコンテンツの見本は `entryRow` で読む（見出しを付けて別タブで開けるように）。
-}
schemaImpact : SelectionSet Model.SchemaImpact Api.Admin.Object.SchemaImpact
schemaImpact =
    SS.map2 Model.SchemaImpact
        SchemaImpact.safe
        (SchemaImpact.effects
            (SS.map5 Model.SchemaEffect
                (SchemaEffect.kind |> SS.map SchemaEffectKind.toString)
                SchemaEffect.field
                SchemaEffect.draft
                SchemaEffect.published
                (SchemaEffect.entries entryRow)
            )
        )


{-| フィールドを消す。`expected` は `removeFieldImpact` で見た影響。

見た時より種類が増えるか公開中の件数が増えていれば、サーバが止める。

-}
removeField : String -> Slug -> { fieldId : String, expected : Model.SchemaImpact } -> ( Api.Request, D.Decoder String )
removeField id project args =
    Api.mutation { id = id, kind = "removeField", project = project }
        (AdminMutation.removeField
            (\optional -> { optional | expected = Opt.Present (expectedOf args.expected) })
            { id = args.fieldId }
        )


{-| 見た影響を、押す時に送る形にする。まだ見ていなければ送らない（影響があれば CMS が止める）。
-}
maybeExpected : Maybe Model.SchemaImpact -> Opt.OptionalArgument Input.SchemaImpactInput
maybeExpected seen =
    case seen of
        Just impact ->
            Opt.Present (expectedOf impact)

        Nothing ->
            Opt.Absent


{-| 見た影響を、押す時に送る形にする。
-}
expectedOf : Model.SchemaImpact -> Input.SchemaImpactInput
expectedOf impact =
    { kinds = impact.effects |> List.map .kind |> List.filterMap kindOf
    , published = impact.effects |> List.map .published |> List.sum
    }


{-| 種類の名前を enum に戻す。読めない物は落とす（サーバが数え直すので、落ちても止まるだけ）。
-}
kindOf : String -> Maybe SchemaEffectKind.SchemaEffectKind
kindOf name =
    SchemaEffectKind.list |> List.filter (\kind -> SchemaEffectKind.toString kind == name) |> List.head


reorderFields : String -> Slug -> { typeId : String, ids : List String } -> ( Api.Request, D.Decoder ContentTypeDetail )
reorderFields id project args =
    Api.mutation { id = id, kind = "reorderFields", project = project }
        (AdminMutation.reorderFields { typeId = args.typeId, ids = args.ids } contentTypeDetail)


{-| コンテンツの一覧。search は下書きの中身に含む文字列。
-}
type alias EntryQuery =
    { typeId : String
    , search : String
    , stage : String

    {- 絞り込みの条件。**いくつでも足せる**（CMS は AND で結ぶ）。 -}
    , conditions : List Filter.Condition

    {- この id の物だけ。参照の見出しを引き直すのに使う（100 件の先読みをしない）。 -}
    , ids : List String
    , order : String
    , first : Int
    , skip : Int
    }


{-| id で名指しして引く時に、1 回で頼める id の数。CMS は first を 200 で丸める。
-}
idsPerCall : Int
idsPerCall =
    200


{-| 名指しの id を、1 回で頼める数ずつに分ける。

WhyNot: 何件あっても 1 回で頼む、にしない。丸められた分は黙って落ち、見出しを
引けなかった参照が 12 桁の id のまま画面に出る。

-}
chunkIds : List String -> List (List String)
chunkIds ids =
    if List.isEmpty ids then
        []

    else if List.length ids <= idsPerCall then
        [ ids ]

    else
        List.take idsPerCall ids :: chunkIds (List.drop idsPerCall ids)


entries : String -> Slug -> EntryQuery -> ( Api.Request, D.Decoder EntryList )
entries id project args =
    Api.query { id = id, kind = "entries", project = project }
        (Api.Admin.Query.entries
            (\optional ->
                { optional
                    | search = presentIf (not (String.isEmpty args.search)) args.search
                    , where_ = whereOf args
                    , orderBy = orderOf args.order
                    , first = Opt.Present args.first
                    , skip = Opt.Present args.skip
                }
            )
            { typeId = args.typeId }
            (SS.map2 EntryList (EntryPage.nodes entryRow) EntryPage.totalCount)
        )


{-| 公開状態・id・フィールドの絞り込み。空は全部。

**演算子はフィールドの種類で決まる**（`Filter.opsFor`）。ここは受けた物をそのまま写すだけで、
どの演算子が使えるかは知らない。

-}
whereOf : EntryQuery -> Opt.OptionalArgument Input.EntryWhere
whereOf args =
    let
        stageArg : Opt.OptionalArgument ContentStage.ContentStage
        stageArg =
            ContentStage.list
                |> List.filter (\value -> ContentStage.toString value == args.stage)
                |> List.head
                |> Maybe.map Opt.Present
                |> Maybe.withDefault Opt.Absent

        fieldConditions : List Filter.Condition
        fieldConditions =
            args.conditions |> List.filter (\condition -> not (Filter.isSystem condition.apiId))

        fields : Opt.OptionalArgument (List Input.EntryFieldCondition)
        fields =
            if List.isEmpty fieldConditions then
                Opt.Absent

            else
                Opt.Present (List.map conditionOf fieldConditions)

        idsArg : Opt.OptionalArgument (List ScalarCodecs.Id)
        idsArg =
            presentIf (not (List.isEmpty args.ids)) args.ids

        dates : String -> Opt.OptionalArgument Input.DateTimeFilter
        dates apiId =
            dateFilterOf apiId args.conditions
    in
    if stageArg == Opt.Absent && fields == Opt.Absent && idsArg == Opt.Absent && List.length fieldConditions == List.length args.conditions then
        Opt.Absent

    else
        Opt.Present
            { stage = stageArg
            , id_in = idsArg
            , fields = fields
            , createdAt = dates "createdAt"
            , updatedAt = dates "updatedAt"
            , publishedAt = dates "publishedAt"
            }


{-| どの型も持つ日時の条件。**`fields` ではなく `EntryWhere` の直下**で受ける
（列で比べるので索引が効く）。同じ項目に 2 つ足せば両方が入り、CMS は AND で結ぶ。

WhyNot: 読めない値をここで捨てない。CMS は読めない値を 0 件に倒すので、
落として全件に広げると「絞ったのに増えた」になる。

-}
dateFilterOf : String -> List Filter.Condition -> Opt.OptionalArgument Input.DateTimeFilter
dateFilterOf apiId conditions =
    let
        mine : List Filter.Condition
        mine =
            conditions |> List.filter (\condition -> condition.apiId == apiId)

        pick : String -> Opt.OptionalArgument String
        pick op =
            mine
                |> List.filter (\condition -> condition.op == op)
                |> List.head
                |> Maybe.map (.value >> Opt.Present)
                |> Maybe.withDefault Opt.Absent
    in
    if List.isEmpty mine then
        Opt.Absent

    else
        Opt.Present { gt = pick "GT", gte = pick "GTE", lt = pick "LT", lte = pick "LTE" }


{-| 条件 1 つ。`IS_NULL` は値を取らない（CMS は省くと true として読む）。
-}
conditionOf : Filter.Condition -> Input.EntryFieldCondition
conditionOf condition =
    { apiId = condition.apiId
    , op = opOf condition.op
    , value =
        if Filter.needsValue condition.op then
            Opt.Present (valueOf condition)

        else
            Opt.Absent
    }


{-| 値の JSON。**数と真偽は文字列で送ると断られる**（CMS が種類で型を見る）。
-}
valueOf : Filter.Condition -> E.Value
valueOf condition =
    case condition.op of
        "GT" ->
            numberOr condition.value

        "GTE" ->
            numberOr condition.value

        "LT" ->
            numberOr condition.value

        "LTE" ->
            numberOr condition.value

        _ ->
            if condition.value == "true" then
                E.bool True

            else if condition.value == "false" then
                E.bool False

            else
                numberOr condition.value


{-| 数に読めれば数、読めなければ文字列（日時は ISO 8601 の文字列で送る）。
-}
numberOr : String -> E.Value
numberOr raw =
    case String.toFloat raw of
        Just number ->
            E.float number

        Nothing ->
            E.string raw


opOf : String -> FieldOp.FieldConditionOp
opOf raw =
    FieldOp.list
        |> List.filter (\op -> FieldOp.toString op == raw)
        |> List.head
        |> Maybe.withDefault FieldOp.Eq


{-| 並び替え。`updatedAt:desc` の形で受ける。空は CMS の既定（更新が新しい順）。
-}
orderOf : String -> Opt.OptionalArgument (List Input.EntryOrderBy)
orderOf order =
    case String.split ":" order of
        [ field, direction ] ->
            if String.isEmpty field then
                Opt.Absent

            else
                Opt.Present
                    [ { field = field
                      , direction =
                            if direction == "asc" then
                                SortDirection.Asc

                            else
                                SortDirection.Desc
                      }
                    ]

        _ ->
            Opt.Absent


entryRow : SelectionSet EntryRow Api.Admin.Object.Entry
entryRow =
    SS.map6 EntryRow
        Entry.id
        Entry.version
        (Entry.stage |> SS.map EntryStage.toString)
        Entry.fields
        Entry.updatedAt
        Entry.path


{-| コンテンツ 1 件。編集の画面が使う。
-}
entry : String -> Slug -> String -> ( Api.Request, D.Decoder (Maybe EntryRow) )
entry id project entryId =
    Api.query { id = id, kind = "entry", project = project }
        (Api.Admin.Query.entry { id = entryId } entryRow)


createEntry : String -> Slug -> { typeId : String, fields : D.Value } -> ( Api.Request, D.Decoder EntryRow )
createEntry id project args =
    Api.mutation { id = id, kind = "createEntry", project = project }
        (AdminMutation.createEntry (\optional -> optional) { typeId = args.typeId, fields = args.fields } entryRow)


{-| 下書きを直す。`expectedVersion` が今の版と違えば CONFLICT。
-}
updateEntry : String -> Slug -> { entryId : String, fields : D.Value, expectedVersion : Int } -> ( Api.Request, D.Decoder EntryRow )
updateEntry id project args =
    Api.mutation { id = id, kind = "updateEntry", project = project }
        (AdminMutation.updateEntry
            { id = args.entryId, fields = args.fields, expectedVersion = args.expectedVersion }
            entryRow
        )


{-| 公開できるか。**書き込まない。** violations が空なら公開が通る。
-}
publishCheck : String -> Slug -> String -> ( Api.Request, D.Decoder Model.PublishReport )
publishCheck id project entryId =
    Api.query { id = id, kind = "publishCheck", project = project }
        (Api.Admin.Query.publishCheck { id = entryId }
            (SS.map3 Model.PublishReport
                PublishReport.ok
                (PublishReport.violations (SS.map2 Model.Violation Violation.path Violation.message))
                (PublishReport.unpublishedDependencies entryRow |> SS.map List.length)
            )
        )


{-| 本文の外部リンクのカードの OGP を表から引く。開いた時に doc に居る URL をまとめて。
-}
linkCards : String -> Slug -> List String -> ( Api.Request, D.Decoder (List Model.LinkCard) )
linkCards id project urls =
    Api.query { id = id, kind = "linkCards", project = project }
        (Api.Admin.Query.linkCards { urls = urls } linkCardSelection)


{-| 貼った瞬間に OGP を取りに行く。CMS が相手のページを読み、表に残して返す。
-}
fetchLinkCard : String -> Slug -> String -> ( Api.Request, D.Decoder Model.LinkCard )
fetchLinkCard id project url =
    Api.mutation { id = id, kind = "fetchLinkCard", project = project }
        (AdminMutation.fetchLinkCard { url = url } linkCardSelection)


linkCardSelection : SelectionSet Model.LinkCard Api.Admin.Object.LinkCard
linkCardSelection =
    SS.map7 Model.LinkCard
        LinkCard.url
        LinkCard.title
        LinkCard.description
        LinkCard.imageUrl
        LinkCard.siteName
        (LinkCard.fetchedAt |> SS.map Just)
        LinkCard.error


{-| このコンテンツを参照している物。

**`impact(action: DELETE)` を借りている。** 素の被リンクの口（`Entry.referrers`）が
CMS にまだ無く、DELETE の `breaks` が「公開側と下書き側の両方で参照している entry」
＝被リンクそのものだから。

WhyNot: ページングが無い（参照元が多いと全部返る）。CMS に口が入ったら差し替える。

-}
referrers : String -> Slug -> String -> ( Api.Request, D.Decoder (List Model.Referrer) )
referrers id project entryId =
    Api.query { id = id, kind = "referrers", project = project }
        (Api.Admin.Query.impact { id = entryId, action = ImpactAction.Delete }
            (Impact.breaks referrerRow)
        )


referrerRow : SelectionSet Model.Referrer Api.Admin.Object.Referrer
referrerRow =
    SS.map3
        (\from via stage -> { entryId = from.id, typeId = from.typeId, title = from.title, via = via, stage = stage })
        (Referrer.entry
            (SS.map3 (\theId typeId fields -> { id = theId, typeId = typeId, title = titleIn fields })
                Entry.id
                Entry.typeId
                Entry.fields
            )
        )
        Referrer.via
        (Referrer.stage |> SS.map ContentStage.toString)


{-| 参照元の見出し。**型が分からない**（一覧に混ざる）ので、中身から拾う決め方を使う。
-}
titleIn : D.Value -> String
titleIn fields =
    EntryLabel.forRow { id = "", version = 0, stage = "", fields = fields, updatedAt = "", path = Nothing }


publishEntry : String -> Slug -> { entryId : String, withDependencies : Bool } -> ( Api.Request, D.Decoder EntryRow )
publishEntry id project args =
    Api.mutation { id = id, kind = "publishEntry", project = project }
        (AdminMutation.publishEntry
            (\optional -> { optional | withDependencies = Opt.Present args.withDependencies })
            { id = args.entryId }
            entryRow
        )


{-| 公開を終える。下書きは残る。
-}
unpublishEntry : String -> Slug -> String -> ( Api.Request, D.Decoder EntryRow )
unpublishEntry id project entryId =
    Api.mutation { id = id, kind = "unpublishEntry", project = project }
        (AdminMutation.unpublishEntry { id = entryId } entryRow)


{-| 今の下書きを版として積む。**戻す前に呼ぶ**ので、戻した物も戻せる。
-}
saveVersion : String -> Slug -> String -> ( Api.Request, D.Decoder String )
saveVersion id project entryId =
    Api.mutation { id = id, kind = "saveVersion", project = project }
        (AdminMutation.saveVersion { id = entryId } EntryVersion.id)


{-| 版の中身を下書きに戻す。`expectedVersion` は下書きを直すのと同じ楽観ロック。
-}
restoreVersion : String -> Slug -> { entryId : String, versionId : String, expectedVersion : Int } -> ( Api.Request, D.Decoder EntryRow )
restoreVersion id project args =
    Api.mutation { id = id, kind = "restoreVersion", project = project }
        (AdminMutation.restoreVersion
            { id = args.entryId, versionId = args.versionId, expectedVersion = args.expectedVersion }
            entryRow
        )


{-| 変更履歴。新しい順に全件返る（ページングは無い）。
-}
versions : String -> Slug -> String -> ( Api.Request, D.Decoder (Maybe (List Model.EntryVersion)) )
versions id project entryId =
    Api.query { id = id, kind = "versions", project = project }
        (Api.Admin.Query.entry { id = entryId }
            (Entry.versions
                (SS.map5 Model.EntryVersion
                    EntryVersion.id
                    EntryVersion.version
                    (EntryVersion.reason |> SS.map VersionReason.toString)
                    EntryVersion.author
                    EntryVersion.createdAt
                )
            )
        )


{-| API キーの一覧（owner だけ）。生の値は出ない。
-}
apiKeys : String -> Slug -> ( Api.Request, D.Decoder (List Model.ApiKeyRow) )
apiKeys id project =
    Api.query { id = id, kind = "apiKeys", project = project }
        (Api.Admin.Query.apiKeys
            (SS.succeed Model.ApiKeyRow
                |> SS.with ApiKey.id
                |> SS.with ApiKey.name
                |> SS.with ApiKey.keyHint
                |> SS.with (ApiKey.scope |> SS.map ApiKeyScope.toString)
                |> SS.with (ApiKey.role |> SS.map (Maybe.map AdminRole.toString))
                |> SS.with ApiKey.createdAt
                |> SS.with ApiKey.expiresAt
                |> SS.with ApiKey.lastUsedAt
                |> SS.with ApiKey.revokedAt
            )
        )


{-| キーを発行する。**生の値はこの応答にしか出ない。**
-}
createApiKey : String -> Slug -> { name : String, scope : ApiKeyScope, role : Maybe AdminRole.Role, expiresAt : Maybe String } -> ( Api.Request, D.Decoder Model.IssuedKey )
createApiKey id project args =
    Api.mutation { id = id, kind = "createApiKey", project = project }
        (AdminMutation.createApiKey
            (\optional ->
                { optional
                    | role =
                        case args.role of
                            Just role ->
                                Opt.Present role

                            Nothing ->
                                Opt.Absent
                    , expiresAt = presentOr args.expiresAt
                }
            )
            { name = args.name, scope = args.scope }
            (SS.map3 Model.IssuedKey IssuedApiKey.id IssuedApiKey.name IssuedApiKey.key)
        )


revokeApiKey : String -> Slug -> String -> ( Api.Request, D.Decoder String )
revokeApiKey id project keyId =
    Api.mutation { id = id, kind = "revokeApiKey", project = project }
        (AdminMutation.revokeApiKey { id = keyId })


webhooks : String -> Slug -> ( Api.Request, D.Decoder (List Model.WebhookRow) )
webhooks id project =
    Api.query { id = id, kind = "webhooks", project = project }
        (Api.Admin.Query.webhooks webhookRow)


webhookRow : SelectionSet Model.WebhookRow Api.Admin.Object.Webhook
webhookRow =
    SS.map5 Model.WebhookRow
        Webhook.id
        Webhook.name
        Webhook.url
        (Webhook.events |> SS.map (List.map WebhookEvent.toString))
        Webhook.active


{-| Webhook を作る。secret はこの応答にしか出ない。
-}
createWebhook : String -> Slug -> { name : String, url : String, events : List WebhookEvent } -> ( Api.Request, D.Decoder Model.IssuedWebhook )
createWebhook id project args =
    Api.mutation { id = id, kind = "createWebhook", project = project }
        (AdminMutation.createWebhook
            { input = { name = args.name, url = args.url, events = args.events, active = Opt.Present True } }
            (SS.map2 Model.IssuedWebhook (IssuedWebhook.webhook webhookRow) IssuedWebhook.secret)
        )


deleteWebhook : String -> Slug -> String -> ( Api.Request, D.Decoder String )
deleteWebhook id project webhookId =
    Api.mutation { id = id, kind = "deleteWebhook", project = project }
        (AdminMutation.deleteWebhook { id = webhookId })


assets : String -> Slug -> { first : Int, skip : Int } -> ( Api.Request, D.Decoder Model.AssetList )
assets id project args =
    Api.query { id = id, kind = "assets", project = project }
        (Api.Admin.Query.assets
            (\optional -> { optional | first = Opt.Present args.first, skip = Opt.Present args.skip })
            (SS.map2 Model.AssetList (AssetPage.nodes assetRow) AssetPage.totalCount)
        )


assetRow : SelectionSet Model.AssetRow Api.Admin.Object.Asset
assetRow =
    SS.map7 Model.AssetRow
        Asset.id
        Asset.url
        Asset.fileName
        Asset.mime
        Asset.size
        Asset.alt
        (Asset.status |> SS.map AssetStatus.toString)


{-| 置き先を発行する。ブラウザがこの URL に PUT し、終わったら `confirmAsset`。
-}
createUploadUrl : String -> Slug -> { fileName : String, mime : String, size : Int } -> ( Api.Request, D.Decoder Model.Upload )
createUploadUrl id project args =
    Api.mutation { id = id, kind = "createUploadUrl", project = project }
        (AdminMutation.createUploadUrl
            { input = { fileName = args.fileName, mime = args.mime, size = args.size } }
            (SS.map2 Model.Upload (Upload.asset Asset.id) Upload.uploadUrl)
        )


confirmAsset : String -> Slug -> String -> ( Api.Request, D.Decoder Model.AssetRow )
confirmAsset id project assetId =
    Api.mutation { id = id, kind = "confirmAsset", project = project }
        (AdminMutation.confirmAsset (\optional -> optional) { id = assetId } assetRow)


updateAsset : String -> Slug -> { assetId : String, alt : String } -> ( Api.Request, D.Decoder Model.AssetRow )
updateAsset id project args =
    Api.mutation { id = id, kind = "updateAsset", project = project }
        (AdminMutation.updateAsset { id = args.assetId, input = { alt = args.alt } } assetRow)


deleteAsset : String -> Slug -> String -> ( Api.Request, D.Decoder String )
deleteAsset id project assetId =
    Api.mutation { id = id, kind = "deleteAsset", project = project }
        (AdminMutation.deleteAsset { id = assetId })


{-| 予約の一覧。プロジェクト全体か、entry 1 件分。
-}
schedules : String -> Slug -> Maybe String -> ( Api.Request, D.Decoder (List Model.ScheduleRow) )
schedules id project entryId =
    Api.query { id = id, kind = "schedules", project = project }
        (Api.Admin.Query.schedules
            (\optional ->
                { optional
                    | entryId =
                        case entryId of
                            Just chosen ->
                                Opt.Present chosen

                            Nothing ->
                                Opt.Absent
                    , first = Opt.Present 50
                }
            )
            (SS.map7 Model.ScheduleRow
                Schedule.id
                Schedule.entryId
                (Schedule.action |> SS.map ScheduleAction.toString)
                Schedule.runAt
                (Schedule.status |> SS.map ScheduleStatus.toString)
                Schedule.lastError
                Schedule.overdue
            )
        )


{-| 時刻を決めて公開する。同じ entry の未実行の予約は置き換わる。
-}
schedulePublish : String -> Slug -> { entryId : String, at : String } -> ( Api.Request, D.Decoder Model.ScheduleRow )
schedulePublish id project args =
    Api.mutation { id = id, kind = "schedulePublish", project = project }
        (AdminMutation.schedulePublish
            (\optional -> optional)
            { entryId = args.entryId, at = args.at }
            (SS.map7 Model.ScheduleRow
                Schedule.id
                Schedule.entryId
                (Schedule.action |> SS.map ScheduleAction.toString)
                Schedule.runAt
                (Schedule.status |> SS.map ScheduleStatus.toString)
                Schedule.lastError
                Schedule.overdue
            )
        )


cancelSchedule : String -> Slug -> String -> ( Api.Request, D.Decoder String )
cancelSchedule id project scheduleId =
    Api.mutation { id = id, kind = "cancelSchedule", project = project }
        (AdminMutation.cancelSchedule { id = scheduleId } Schedule.id)


{-| 自分の PAT の一覧。CLI と MCP で使う。
-}
personalTokens : String -> ( Api.Request, D.Decoder (Maybe (List Model.PatRow)) )
personalTokens id =
    Api.accountQuery { id = id, kind = "personalTokens" }
        (Api.Account.Query.me
            (Me.personalAccessTokens
                (SS.succeed Model.PatRow
                    |> SS.with Pat.id
                    |> SS.with Pat.name
                    |> SS.with (Pat.scope |> SS.map PatScope.toString)
                    |> SS.with Pat.createdAt
                    |> SS.with Pat.expiresAt
                    |> SS.with Pat.lastUsedAt
                    |> SS.with Pat.revokedAt
                )
            )
        )


{-| PAT を発行する。**生の値はこの応答にしか出ない。**
-}
createPersonalToken : String -> { name : String, write : Bool, ttlDays : Int } -> ( Api.Request, D.Decoder Model.IssuedPat )
createPersonalToken id args =
    Api.accountMutation { id = id, kind = "createPersonalAccessToken" }
        (AccountMutation.createPersonalAccessToken
            (\optional -> { optional | ttlDays = Opt.Present args.ttlDays })
            { name = args.name
            , scope =
                if args.write then
                    PatScope.Write

                else
                    PatScope.Read
            }
            (SS.map3 Model.IssuedPat IssuedPat.id IssuedPat.name IssuedPat.token)
        )


revokePersonalToken : String -> String -> ( Api.Request, D.Decoder Bool )
revokePersonalToken id tokenId =
    Api.accountMutation { id = id, kind = "revokePersonalAccessToken" }
        (AccountMutation.revokePersonalAccessToken { id = tokenId })


{-| 公開範囲。public は鍵なしで公開中を読める。private は鍵か役割が要る。
-}
updateProjectVisibility : String -> Slug -> Bool -> ( Api.Request, D.Decoder String )
updateProjectVisibility id slug isPublic =
    Api.mutation { id = id, kind = "updateProjectVisibility", project = slug }
        (AdminMutation.updateProjectVisibility
            { visibility =
                if isPublic then
                    Visibility.Public

                else
                    Visibility.Private
            }
            (AdminProject.visibility |> SS.map Visibility.toString)
        )


{-| 型の設定を直す。**エンドポイント（apiId）は変えられない。**
省いた項目は触らない（CMS の決まり）ので、アイコンだけ送りたい時も `name` は今の値を渡す。
-}
updateContentType : String -> Slug -> { typeId : String, name : String, previewUrl : String, linkPath : String, icon : String } -> ( Api.Request, D.Decoder ContentTypeSummary )
updateContentType id project args =
    Api.mutation { id = id, kind = "updateContentType", project = project }
        (AdminMutation.updateContentType
            { id = args.typeId
            , input =
                { name = Opt.Present args.name
                , singular = Opt.Absent
                , plural = Opt.Absent
                , previewUrl = presentIf (not (String.isEmpty args.previewUrl)) args.previewUrl
                , linkPath = Opt.Present args.linkPath
                , icon = presentIf (not (String.isEmpty args.icon)) args.icon
                }
            }
            typeSummary
        )


{-| 型を消す。**コンテンツが残っていれば CMS が断る。**
-}
deleteContentType : String -> Slug -> String -> ( Api.Request, D.Decoder String )
deleteContentType id project typeId =
    Api.mutation { id = id, kind = "deleteContentType", project = project }
        (AdminMutation.deleteContentType identity { id = typeId })
