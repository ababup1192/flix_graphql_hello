// auth.q: ユーザー・組織・役割・招待・API キー

// ---- users ----

query findUserByIdentity(issuer: String, subject: String) -> one {
    SELECT id, issuer, subject, email, name FROM users WHERE issuer = :issuer AND subject = :subject
}

query findUserById(id: Int64) -> one {
    SELECT id, issuer, subject, email, name FROM users WHERE id = :id
}

query insertUser(issuer: String, subject: String, email: String, name: String) -> one {
    INSERT INTO users (issuer, subject, email, name) VALUES (:issuer, :subject, :email, :name) RETURNING id
}

query updateUserProfile(id: Int64, email: String, name: String) -> exec {
    UPDATE users SET email = :email, name = :name WHERE id = :id
}

// ---- organizations ----

query findOrganization(id: Int64) -> one {
    SELECT id, name FROM organizations WHERE id = :id
}

query insertOrganization(name: String) -> one {
    INSERT INTO organizations (name) VALUES (:name) RETURNING id
}

// ユーザーが属する組織と役割
query listOrganizationsOfUser(userId: Int64) -> many {
    SELECT o.id, o.name, m.role
    FROM org_members AS m JOIN organizations AS o ON o.id = m.org_id
    WHERE m.user_id = :userId ORDER BY o.id
}

query findOrgRole(userId: Int64, orgId: Int64) -> one {
    SELECT role FROM org_members WHERE user_id = :userId AND org_id = :orgId
}

query countOrgOwners(orgId: Int64) -> one {
    SELECT count(*)::bigint AS total FROM org_members WHERE org_id = :orgId AND role = 'owner'
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
    SELECT id, slug, name, visibility FROM projects WHERE org_id = :orgId ORDER BY id
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
query listMembershipsOfUser(userId: Int64) -> many {
    SELECT p.id, p.slug, p.name, p.visibility, m.role
    FROM memberships AS m JOIN projects AS p ON p.id = m.project_id
    WHERE m.user_id = :userId ORDER BY p.id
}

query listMembers(projectId: Int64) -> many {
    SELECT u.id, u.email, u.name, m.role
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

query upsertInvitation(projectId: Int64, email: String, role: String, invitedBy: Int64) -> exec {
    INSERT INTO invitations (project_id, email, role, invited_by) VALUES (:projectId, :email, :role, :invitedBy)
    ON CONFLICT (project_id, email) DO UPDATE SET role = EXCLUDED.role, invited_by = EXCLUDED.invited_by
}

query listInvitations(projectId: Int64) -> many {
    SELECT id, email, role, created_at FROM invitations WHERE project_id = :projectId ORDER BY id
}

// この email 宛の招待（初回ログインで memberships に写す）
query listInvitationsForEmail(email: String) -> many {
    SELECT id, project_id, role FROM invitations WHERE email = :email
}

query deleteInvitation(id: Int64) -> exec {
    DELETE FROM invitations WHERE id = :id
}

// ---- api_keys ----

query insertApiKey(projectId: Int64, name: String, keyHash: String, pepperId: String, scope: String) -> one {
    INSERT INTO api_keys (project_id, name, key_hash, pepper_id, scope) VALUES (:projectId, :name, :keyHash, :pepperId, :scope) RETURNING id
}

// hash で引く。プロジェクトの一致は呼ぶ側が確かめる（鍵がプロジェクトを決めない）
query findApiKeyByHash(keyHash: String) -> one {
    SELECT id, project_id, name, scope, revoked_at FROM api_keys WHERE key_hash = :keyHash
}

query listApiKeys(projectId: Int64) -> many {
    SELECT id, name, scope, created_at, revoked_at FROM api_keys WHERE project_id = :projectId ORDER BY id
}

query revokeApiKey(id: Int64, projectId: Int64) -> exec {
    UPDATE api_keys SET revoked_at = now() WHERE id = :id AND project_id = :projectId AND revoked_at IS NULL
}
