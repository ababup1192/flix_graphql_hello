// auth.q: ユーザー・組織・役割・招待・API キー

// ---- users ----

query findUserByIdentity(issuer: String, subject: String) -> one {
    SELECT id, public_id, issuer, subject, email, name FROM users WHERE issuer = :issuer AND subject = :subject
}

query findUserById(id: Int64) -> one {
    SELECT id, public_id, issuer, subject, email, name FROM users WHERE id = :id
}

// 外向きの id（GraphQL の ID）から
query findUserByPublicId(publicId: String) -> one {
    SELECT id, public_id, issuer, subject, email, name FROM users WHERE public_id = :publicId
}

// email で引く。email は発行元をまたいで一意ではないので複数ありうる
query listUsersByEmail(email: String) -> many {
    SELECT id, public_id, issuer, subject, email, name FROM users WHERE email = :email ORDER BY id
}

query insertUser(publicId: String, issuer: String, subject: String, email: String, name: String) -> one {
    INSERT INTO users (public_id, issuer, subject, email, name) VALUES (:publicId, :issuer, :subject, :email, :name) RETURNING id
}

query updateUserProfile(id: Int64, email: String, name: String) -> exec {
    UPDATE users SET email = :email, name = :name WHERE id = :id
}

// ---- organizations ----

query findOrganization(id: Int64) -> one {
    SELECT id, public_id, name FROM organizations WHERE id = :id
}

query findOrganizationByPublicId(publicId: String) -> one {
    SELECT id, public_id, name FROM organizations WHERE public_id = :publicId
}

query insertOrganization(publicId: String, name: String) -> one {
    INSERT INTO organizations (public_id, name) VALUES (:publicId, :name) RETURNING id
}

// ユーザーが属する組織と役割
query listOrganizationsOfUser(userId: Int64) -> many {
    SELECT o.id, o.public_id, o.name, m.role
    FROM org_members AS m JOIN organizations AS o ON o.id = m.org_id
    WHERE m.user_id = :userId ORDER BY o.id
}

query findOrgRole(userId: Int64, orgId: Int64) -> one {
    SELECT role FROM org_members WHERE user_id = :userId AND org_id = :orgId
}

query countOrgOwners(orgId: Int64) -> one {
    SELECT count(*)::bigint AS total FROM org_members WHERE org_id = :orgId AND role = 'owner'
}

// 組織のメンバー
query listOrgMembers(orgId: Int64) -> many {
    SELECT u.id, u.public_id, u.email, u.name, m.role
    FROM org_members AS m JOIN users AS u ON u.id = m.user_id
    WHERE m.org_id = :orgId ORDER BY u.id
}

query deleteOrgMember(userId: Int64, orgId: Int64) -> exec {
    DELETE FROM org_members WHERE user_id = :userId AND org_id = :orgId
}

query upsertOrgMember(userId: Int64, orgId: Int64, role: String) -> exec {
    INSERT INTO org_members (user_id, org_id, role) VALUES (:userId, :orgId, :role)
    ON CONFLICT (user_id, org_id) DO UPDATE SET role = EXCLUDED.role
}

// ---- projects（役割の文脈）----

query findProjectOrg(projectId: Int64) -> one {
    SELECT org_id, visibility FROM projects WHERE id = :projectId
}

query listProjectsOfOrg(orgId: Int64) -> many {
    SELECT id, public_id, slug, name, visibility FROM projects WHERE org_id = :orgId ORDER BY id
}

query updateProjectVisibility(projectId: Int64, visibility: String) -> exec {
    UPDATE projects SET visibility = :visibility WHERE id = :projectId
}

// ---- memberships ----

// ユーザーがプロジェクトに直接持つ役割
query findMembership(userId: Int64, projectId: Int64) -> one {
    SELECT role FROM memberships WHERE user_id = :userId AND project_id = :projectId
}

// ユーザーが役割を持つプロジェクト（組織の owner として持つ物は Authz が足す）
// unscoped: 自分のプロジェクト一覧はプロジェクトを跨いで引く（ログイン後の切り替え候補）
query listMembershipsOfUser(userId: Int64) -> many {
    SELECT p.id, p.public_id, p.slug, p.name, p.visibility, m.role
    FROM memberships AS m JOIN projects AS p ON p.id = m.project_id
    WHERE m.user_id = :userId ORDER BY p.id
}

query listMembers(projectId: Int64) -> many {
    SELECT u.id, u.public_id, u.email, u.name, m.role
    FROM memberships AS m JOIN users AS u ON u.id = m.user_id
    WHERE m.project_id = :projectId ORDER BY u.id
}

query upsertMembership(userId: Int64, projectId: Int64, role: String) -> exec {
    INSERT INTO memberships (user_id, project_id, role) VALUES (:userId, :projectId, :role)
    ON CONFLICT (user_id, project_id) DO UPDATE SET role = EXCLUDED.role
}

query deleteMembership(userId: Int64, projectId: Int64) -> exec {
    DELETE FROM memberships WHERE user_id = :userId AND project_id = :projectId
}

query countProjectOwners(projectId: Int64) -> one {
    SELECT count(*)::bigint AS total FROM memberships WHERE project_id = :projectId AND role = 'owner'
}

// ---- invitations ----

// 同じ email に 2 度招待したら役割を上書きし、public_id は最初の物を残す
query upsertInvitation(publicId: String, projectId: Int64, email: String, role: String, invitedBy: Int64) -> exec {
    INSERT INTO invitations (public_id, project_id, email, role, invited_by) VALUES (:publicId, :projectId, :email, :role, :invitedBy)
    ON CONFLICT (project_id, email) DO UPDATE SET role = EXCLUDED.role, invited_by = EXCLUDED.invited_by
}

query listInvitations(projectId: Int64) -> many {
    SELECT id, public_id, email, role, created_at FROM invitations WHERE project_id = :projectId ORDER BY id
}

// この email 宛の招待（初回ログインで memberships に写す）
// unscoped: 招待の受け入れはログイン時にプロジェクトを跨いで行う
query listInvitationsForEmail(email: String) -> many {
    SELECT id, project_id, role FROM invitations WHERE email = :email
}

// unscoped: 受け入れた招待を消す時はプロジェクトを跨ぐ（listInvitationsForEmail で引いた id だけを渡す）
query deleteInvitation(id: Int64) -> exec {
    DELETE FROM invitations WHERE id = :id
}

query deleteInvitationByPublicId(publicId: String, projectId: Int64) -> exec {
    DELETE FROM invitations WHERE public_id = :publicId AND project_id = :projectId
}

// ---- api_keys ----

// role は write の鍵だけ。expiresAt が無ければ期限無し
query insertApiKey(publicId: String, projectId: Int64, name: String, keyHash: String, keyHint: String, pepperId: String, scope: String, role: Option[String], expiresAt: Option[Timestamp]) -> one {
    INSERT INTO api_keys (public_id, project_id, name, key_hash, key_hint, pepper_id, scope, role, expires_at)
    VALUES (:publicId, :projectId, :name, :keyHash, :keyHint, :pepperId, :scope, :role, :expiresAt)
    RETURNING id
}

// hash で引く。プロジェクトの一致は呼ぶ側が確かめる（鍵がプロジェクトを決めない）
// unscoped: 鍵はプロジェクトを知らないので hash で引き、呼ぶ側が project_id を照合する
query findApiKeyByHash(keyHash: String) -> one {
    SELECT id, project_id, name, scope, role, expires_at, revoked_at FROM api_keys WHERE key_hash = :keyHash
}

query listApiKeys(projectId: Int64) -> many {
    SELECT id, public_id, name, key_hint, scope, role, created_at, expires_at, last_used_at, revoked_at FROM api_keys WHERE project_id = :projectId ORDER BY id
}

query revokeApiKey(publicId: String, projectId: Int64) -> exec {
    UPDATE api_keys SET revoked_at = now() WHERE public_id = :publicId AND project_id = :projectId AND revoked_at IS NULL
}

// 最終使用時刻。前回から 60 秒より古い時だけ書く（リクエストごとに UPDATE しない）
query touchApiKey(id: Int64, projectId: Int64) -> exec {
    UPDATE api_keys SET last_used_at = now()
    WHERE id = :id AND project_id = :projectId AND (last_used_at IS NULL OR last_used_at < now() - interval '60 seconds')
}

// ---- personal_access_tokens ----

query insertPersonalToken(publicId: String, userId: Int64, name: String, tokenHash: String, pepperId: String, scope: String, expiresAt: Timestamp) -> one {
    INSERT INTO personal_access_tokens (public_id, user_id, name, token_hash, pepper_id, scope, expires_at)
    VALUES (:publicId, :userId, :name, :tokenHash, :pepperId, :scope, :expiresAt) RETURNING id
}

// hash で引く。RLS は app.token_hash の印（TenantQueries.stampTokenHash）でこの 1 行だけ見せる
query findPersonalTokenByHash(tokenHash: String) -> one {
    SELECT id, user_id, scope, expires_at, revoked_at FROM personal_access_tokens WHERE token_hash = :tokenHash
}

query listPersonalTokens(userId: Int64) -> many {
    SELECT id, public_id, name, scope, created_at, expires_at, last_used_at, revoked_at FROM personal_access_tokens WHERE user_id = :userId ORDER BY id
}

query revokePersonalToken(publicId: String, userId: Int64) -> exec {
    UPDATE personal_access_tokens SET revoked_at = now() WHERE public_id = :publicId AND user_id = :userId AND revoked_at IS NULL
}

// 最終使用時刻。前回から 60 秒より古い時だけ書く
query touchPersonalToken(id: Int64) -> exec {
    UPDATE personal_access_tokens SET last_used_at = now()
    WHERE id = :id AND (last_used_at IS NULL OR last_used_at < now() - interval '60 seconds')
}
