module Model exposing (ApiKeyRow, AssetList, AssetRow, ContentTypeDetail, ContentTypeSummary, EntryList, EntryRow, EntryVersion, FieldConfig, FieldDef, Invite, IssuedKey, IssuedPat, IssuedWebhook, LinkCandidate, MemberRow, Org, PatRow, Person, Project, PublishReport, Referrer, ScheduleRow, SchemaEffect, SchemaImpact, Slug, Upload, ViewerInfo, Violation, WebhookRow)

{-| API から来る値の形。Html を作らない。

`Queries` と各ページが同じ形を見るために、ここに置く。

-}

import Json.Decode


{-| プロジェクト slug。URL に出る人が読む名前で、プロジェクト id とは別物。
-}
type alias Slug =
    String


type alias Person =
    { id : String
    , email : String
    , name : String
    , organizations : List Org
    , projects : List Project
    }


type alias Org =
    { id : String
    , name : String
    , role : String
    }


type alias Project =
    { id : String
    , slug : Slug
    , name : String
    , visibility : String
    , role : String
    }


type alias ViewerInfo =
    { name : String
    , permissions : List String
    }


type alias ContentTypeSummary =
    { id : String
    , apiId : String
    , name : String

    {- COLLECTION（何件も持つ）か SINGLETON（1 件だけ）か。 -}
    , kind : String

    {- 人が選んだアイコンの名前（`book` / `tag` など）。CMS が既定を入れるので必ず値がある。 -}
    , icon : String
    }


type alias MemberRow =
    { userId : String
    , email : String
    , name : String
    , role : String
    }


type alias Invite =
    { id : String
    , email : String
    , role : String
    }


{-| スキーマを変えると既存のデータに何が起きるか 1 つ。

`field` は効くフィールドの apiId。型ごとの影響（entry ごと消える）なら `Nothing`。

-}
type alias SchemaEffect =
    { kind : String
    , field : Maybe String
    , draft : Int
    , published : Int

    {- 当たるコンテンツの見本。先頭 5 件（更新の新しい順）。残りの数は draft / published から引く。 -}
    , entries : List EntryRow
    }


{-| 押す前に見た影響。`safe` なら確認なしで押せる。

押す時はこの `effects` から `expected` を組んで送る。見た時より種類が増えるか
公開中の件数が増えていれば、サーバが止める。

-}
type alias SchemaImpact =
    { safe : Bool
    , effects : List SchemaEffect
    }


{-| 型 1 つの中身。API スキーマの画面が使う。
-}
type alias ContentTypeDetail =
    { id : String
    , apiId : String
    , name : String
    , kind : String
    , previewUrl : String
    , linkPath : String
    , singular : String
    , icon : String
    , fields : List FieldDef
    }


type alias FieldDef =
    { id : String
    , apiId : String
    , name : String
    , kind : String
    , many : Bool
    , required : Bool
    , unique : Bool
    , localized : Bool
    , targetTypeId : Maybe String
    , config : FieldConfig
    }


{-| 種類ごとの設定。入力の形（選択肢、上限、範囲）を決める。
-}
type alias FieldConfig =
    { maxLength : Maybe Int
    , sourceField : Maybe String
    , min : Maybe Float
    , max : Maybe Float
    , integer : Maybe Bool
    , options : List String
    }


{-| コンテンツ 1 件。`fields` は apiId → 値の JSON（中身の形は型が決める）。
-}
type alias EntryRow =
    { id : String
    , version : Int
    , stage : String
    , fields : Json.Decode.Value
    , updatedAt : String
    , path : Maybe String
    }


type alias EntryList =
    { nodes : List EntryRow
    , totalCount : Int
    }


{-| 本文からリンクを張る時の候補。型をまたいで並ぶので、型の名前も持つ。
-}
type alias LinkCandidate =
    { id : String
    , title : String
    , typeName : String
    , stage : String
    , path : Maybe String
    }


{-| この entry を参照している 1 つ。**どのフィールド経由か**まで分かる。
-}
type alias Referrer =
    { entryId : String
    , typeId : String
    , title : String
    , via : String
    , stage : String
    }


{-| 公開前の確認の結果。`unpublished` は未公開の参照先の数。
-}
type alias PublishReport =
    { ok : Bool
    , violations : List Violation
    , unpublished : Int
    }


type alias Violation =
    { path : String
    , message : String
    }


{-| 変更履歴の 1 件。`author` は表示名の文字列（CMS は userId を返さない）。
-}
type alias EntryVersion =
    { id : String
    , version : Int
    , reason : String
    , author : String
    , createdAt : String
    }


{-| API キー。生の値は発行の応答にしか出ない。
-}
type alias ApiKeyRow =
    { id : String
    , name : String

    {- 末尾 4 文字。.env に入れた鍵と一覧の行を突き合わせる目印。古い鍵は空。 -}
    , keyHint : String
    , scope : String
    , role : Maybe String
    , createdAt : String
    , expiresAt : Maybe String
    , lastUsedAt : Maybe String
    , revokedAt : Maybe String
    }


{-| 発行したばかりのキー。`key` はこの 1 回しか見えない。
-}
type alias IssuedKey =
    { id : String
    , name : String
    , key : String
    }


type alias WebhookRow =
    { id : String
    , name : String
    , url : String
    , events : List String
    , active : Bool
    }


{-| 作った Webhook と、署名の鍵。鍵はこの時しか見えない。
-}
type alias IssuedWebhook =
    { webhook : WebhookRow
    , secret : String
    }


{-| メディア 1 件。`status` が PENDING はアップロードの途中。
-}
type alias AssetRow =
    { id : String
    , url : String
    , fileName : String
    , mime : String
    , size : Int
    , alt : String
    , status : String
    }


type alias AssetList =
    { nodes : List AssetRow
    , totalCount : Int
    }


{-| 置き先。ブラウザがこの URL に PUT して、終わったら confirmAsset を呼ぶ。
-}
type alias Upload =
    { assetId : String
    , uploadUrl : String
    }


{-| 予約。`overdue` は時刻を過ぎても実行されていない印。
-}
type alias ScheduleRow =
    { id : String
    , entryId : String
    , action : String
    , runAt : String
    , status : String
    , lastError : String
    , overdue : Bool
    }


{-| Personal Access Token。生の値は発行の応答にしか出ない。
-}
type alias PatRow =
    { id : String
    , name : String
    , scope : String
    , expiresAt : String
    , lastUsedAt : Maybe String
    , revokedAt : Maybe String
    }


type alias IssuedPat =
    { id : String
    , name : String
    , token : String
    }
