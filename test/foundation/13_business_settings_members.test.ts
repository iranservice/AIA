import { describe, it, expect, afterAll } from 'vitest';
import {
  withRollback,
  createTestUser,
  createTestBusiness,
  createMembership,
  asUser,
  asServiceRole,
  closePool,
} from './setup';

describe('13 — Phase II-A: Business Settings & Members Contracts', () => {
  afterAll(async () => { await closePool(); });

  // ═════════════════════════════════════════════════════════
  // 1. get_my_workspaces()
  // ═════════════════════════════════════════════════════════

  describe('get_my_workspaces', () => {
    it('should return only active workspaces for authenticated user', async () => {
      await withRollback(async (client) => {
        const userId = await createTestUser(client, 'ws-owner@test.com');
        const bizId = await createTestBusiness(client, 'WS Biz 1', userId);

        await asUser(client, userId);
        const res = await client.query(`SELECT * FROM get_my_workspaces()`);

        expect(res.rows.length).toBeGreaterThanOrEqual(1);
        const row = res.rows.find((r: any) => r.business_id === bizId);
        expect(row).toBeDefined();
        expect(row.business_slug).toBeTruthy();
        expect(row.membership_role).toBe('owner');
        expect(row.membership_is_active).toBe(true);
        expect(row.is_owner_or_admin).toBe(true);
      });
    });

    it('should exclude inactive memberships', async () => {
      await withRollback(async (client) => {
        const userId = await createTestUser(client, 'ws-inactive@test.com');
        const ownerId = await createTestUser(client, 'ws-other-owner@test.com');
        const bizId = await createTestBusiness(client, 'Inactive WS', ownerId);

        // Create inactive membership
        await createMembership(client, bizId, userId, 'operator', false);

        await asUser(client, userId);
        const res = await client.query(`SELECT * FROM get_my_workspaces()`);
        const row = res.rows.find((r: any) => r.business_id === bizId);
        expect(row).toBeUndefined();
      });
    });

    it('should not return cross-tenant workspaces', async () => {
      await withRollback(async (client) => {
        const userA = await createTestUser(client, 'ws-userA@test.com');
        const userB = await createTestUser(client, 'ws-userB@test.com');
        const bizA = await createTestBusiness(client, 'WS Biz A', userA);
        await createTestBusiness(client, 'WS Biz B', userB);

        await asUser(client, userB);
        const res = await client.query(`SELECT * FROM get_my_workspaces()`);
        const row = res.rows.find((r: any) => r.business_id === bizA);
        expect(row).toBeUndefined();
      });
    });
  });

  // ═════════════════════════════════════════════════════════
  // 2. get_my_platform_access()
  // ═════════════════════════════════════════════════════════

  describe('get_my_platform_access', () => {
    it('should return is_platform_admin=true for platform admin', async () => {
      await withRollback(async (client) => {
        const adminId = await createTestUser(client, 'platform-admin@test.com');
        // Set platform role
        await client.query(
          `UPDATE user_profiles SET platform_role = 'platform_admin' WHERE id = $1`,
          [adminId]
        );

        await asUser(client, adminId);
        const res = await client.query(`SELECT * FROM get_my_platform_access()`);

        expect(res.rows.length).toBe(1);
        expect(res.rows[0].is_platform_admin).toBe(true);
        expect(res.rows[0].platform_role).toBe('platform_admin');
      });
    });

    it('should return is_platform_admin=false for normal user, not null', async () => {
      await withRollback(async (client) => {
        const userId = await createTestUser(client, 'normal-user@test.com');

        await asUser(client, userId);
        const res = await client.query(`SELECT * FROM get_my_platform_access()`);

        expect(res.rows.length).toBe(1);
        expect(res.rows[0].is_platform_admin).toBe(false);
        expect(res.rows[0].platform_role).toBeNull();
      });
    });
  });

  // ═════════════════════════════════════════════════════════
  // 3. get_business_profile()
  // ═════════════════════════════════════════════════════════

  describe('get_business_profile', () => {
    it('should allow business admin to read own profile', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'bp-owner@test.com');
        const bizId = await createTestBusiness(client, 'Profile Biz', ownerId);

        await asUser(client, ownerId);
        const res = await client.query(
          `SELECT * FROM get_business_profile($1)`, [bizId]
        );

        expect(res.rows.length).toBe(1);
        expect(res.rows[0].name).toBe('Profile Biz');
        expect(res.rows[0].business_type).toBe('restaurant');
        expect(res.rows[0].timezone).toBeTruthy();
      });
    });

    it('should allow operator to read business profile', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'bp-owner2@test.com');
        const opId = await createTestUser(client, 'bp-op@test.com');
        const bizId = await createTestBusiness(client, 'Op Profile Biz', ownerId);
        await createMembership(client, bizId, opId, 'operator', true);

        // Operators CAN read profile (active member check)
        await asUser(client, opId);
        const res = await client.query(
          `SELECT * FROM get_business_profile($1)`, [bizId]
        );
        expect(res.rows.length).toBe(1);
      });
    });

    it('should deny cross-tenant profile read', async () => {
      await withRollback(async (client) => {
        const ownerA = await createTestUser(client, 'bp-ownerA@test.com');
        const ownerB = await createTestUser(client, 'bp-ownerB@test.com');
        const bizA = await createTestBusiness(client, 'Profile Biz A', ownerA);
        await createTestBusiness(client, 'Profile Biz B', ownerB);

        await asUser(client, ownerB);
        const res = await client.query(
          `SELECT * FROM get_business_profile($1)`, [bizA]
        );
        expect(res.rows.length).toBe(0);
      });
    });

    it('should deny inactive membership from reading profile', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'bp-inact-owner@test.com');
        const managerId = await createTestUser(client, 'bp-inact-mgr@test.com');
        const bizId = await createTestBusiness(client, 'Inact Profile Biz', ownerId);
        await createMembership(client, bizId, managerId, 'manager', false);

        await asUser(client, managerId);
        const res = await client.query(
          `SELECT * FROM get_business_profile($1)`, [bizId]
        );
        expect(res.rows.length).toBe(0);
      });
    });

    it('should allow platform admin to read any business profile', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'bp-pa-owner@test.com');
        const adminId = await createTestUser(client, 'bp-pa-admin@test.com');
        const bizId = await createTestBusiness(client, 'PA Profile Biz', ownerId);

        await client.query(
          `UPDATE user_profiles SET platform_role = 'platform_admin' WHERE id = $1`,
          [adminId]
        );

        await asUser(client, adminId);
        const res = await client.query(
          `SELECT * FROM get_business_profile($1)`, [bizId]
        );
        expect(res.rows.length).toBe(1);
        expect(res.rows[0].name).toBe('PA Profile Biz');
      });
    });
  });

  // ═════════════════════════════════════════════════════════
  // 4. update_business_profile()
  // ═════════════════════════════════════════════════════════

  describe('update_business_profile', () => {
    it('should allow business admin to update profile fields', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'up-owner@test.com');
        const bizId = await createTestBusiness(client, 'Update Biz', ownerId);

        await asUser(client, ownerId);
        const res = await client.query(
          `SELECT update_business_profile(
            p_business_id := $1,
            p_name := 'Updated Name',
            p_timezone := 'Asia/Tehran'
          )`, [bizId]
        );

        expect(res.rows.length).toBe(1);
        const result = res.rows[0].update_business_profile;
        expect(result.name).toBe('Updated Name');
        expect(result.timezone).toBe('Asia/Tehran');
      });
    });

    it('should deny operator from updating profile', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'up-owner2@test.com');
        const opId = await createTestUser(client, 'up-op@test.com');
        const bizId = await createTestBusiness(client, 'Op Update Biz', ownerId);
        await createMembership(client, bizId, opId, 'operator', true);

        await asUser(client, opId);
        await expect(
          client.query(
            `SELECT update_business_profile(p_business_id := $1, p_name := 'Hacked')`,
            [bizId]
          )
        ).rejects.toThrow(/ACCESS_DENIED/);
      });
    });

    it('should deny viewer from updating profile', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'up-owner3@test.com');
        const viewerId = await createTestUser(client, 'up-viewer@test.com');
        const bizId = await createTestBusiness(client, 'Viewer Update Biz', ownerId);
        await createMembership(client, bizId, viewerId, 'viewer', true);

        await asUser(client, viewerId);
        await expect(
          client.query(
            `SELECT update_business_profile(p_business_id := $1, p_name := 'Hacked')`,
            [bizId]
          )
        ).rejects.toThrow(/ACCESS_DENIED/);
      });
    });

    it('should deny inactive membership from updating', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'up-owner4@test.com');
        const managerId = await createTestUser(client, 'up-mgr@test.com');
        const bizId = await createTestBusiness(client, 'Inactive Update', ownerId);
        await createMembership(client, bizId, managerId, 'manager', false);

        await asUser(client, managerId);
        await expect(
          client.query(
            `SELECT update_business_profile(p_business_id := $1, p_name := 'Hacked')`,
            [bizId]
          )
        ).rejects.toThrow(/ACCESS_DENIED/);
      });
    });

    it('should create audit log on profile update', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'up-audit@test.com');
        const bizId = await createTestBusiness(client, 'Audit Update', ownerId);

        await asUser(client, ownerId);
        await client.query(
          `SELECT update_business_profile(p_business_id := $1, p_name := 'Audited Name')`,
          [bizId]
        );

        // Switch to service role to read audit
        await asServiceRole(client);
        const audit = await client.query(
          `SELECT * FROM audit_log WHERE action = 'business.profile_updated' AND entity_id = $1`,
          [bizId]
        );
        expect(audit.rows.length).toBe(1);
        expect(audit.rows[0].user_id).toBe(ownerId);
        expect(audit.rows[0].business_id).toBe(bizId);
        expect(audit.rows[0].old_values).toBeDefined();
        expect(audit.rows[0].new_values).toBeDefined();
      });
    });
  });

  // ═════════════════════════════════════════════════════════
  // 5. get_business_members()
  // ═════════════════════════════════════════════════════════

  describe('get_business_members', () => {
    it('should allow business admin to list members', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'mem-owner@test.com');
        const opId = await createTestUser(client, 'mem-op@test.com');
        const bizId = await createTestBusiness(client, 'Members Biz', ownerId);
        await createMembership(client, bizId, opId, 'operator', true);

        await asUser(client, ownerId);
        const res = await client.query(
          `SELECT * FROM get_business_members($1)`, [bizId]
        );

        expect(res.rows.length).toBe(2); // owner + operator
        const roles = res.rows.map((r: any) => r.role);
        expect(roles).toContain('owner');
        expect(roles).toContain('operator');
      });
    });

    it('should deny cross-tenant member listing', async () => {
      await withRollback(async (client) => {
        const ownerA = await createTestUser(client, 'mem-ownerA@test.com');
        const ownerB = await createTestUser(client, 'mem-ownerB@test.com');
        const bizA = await createTestBusiness(client, 'Members A', ownerA);
        await createTestBusiness(client, 'Members B', ownerB);

        await asUser(client, ownerB);
        const res = await client.query(
          `SELECT * FROM get_business_members($1)`, [bizA]
        );
        expect(res.rows.length).toBe(0);
      });
    });

    it('should deny operator from listing members', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'mem-owner2@test.com');
        const opId = await createTestUser(client, 'mem-op2@test.com');
        const bizId = await createTestBusiness(client, 'Members Op Biz', ownerId);
        await createMembership(client, bizId, opId, 'operator', true);

        await asUser(client, opId);
        const res = await client.query(
          `SELECT * FROM get_business_members($1)`, [bizId]
        );
        expect(res.rows.length).toBe(0); // operators denied
      });
    });

    it('should allow platform admin to list members across tenants', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'mem-pa-owner@test.com');
        const adminId = await createTestUser(client, 'mem-pa-admin@test.com');
        const bizId = await createTestBusiness(client, 'PA Members Biz', ownerId);

        await client.query(
          `UPDATE user_profiles SET platform_role = 'platform_admin' WHERE id = $1`,
          [adminId]
        );

        await asUser(client, adminId);
        const res = await client.query(
          `SELECT * FROM get_business_members($1)`, [bizId]
        );
        expect(res.rows.length).toBe(1); // owner member
        expect(res.rows[0].role).toBe('owner');
      });
    });
  });

  // ═════════════════════════════════════════════════════════
  // 6. update_business_member_role()
  // ═════════════════════════════════════════════════════════

  describe('update_business_member_role', () => {
    it('should allow business admin to update member role', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'role-owner@test.com');
        const opId = await createTestUser(client, 'role-op@test.com');
        const bizId = await createTestBusiness(client, 'Role Biz', ownerId);
        const memId = await createMembership(client, bizId, opId, 'operator', true);

        await asUser(client, ownerId);
        const res = await client.query(
          `SELECT update_business_member_role($1, 'manager')`, [memId]
        );

        const result = res.rows[0].update_business_member_role;
        expect(result.new_role).toBe('manager');
      });
    });

    it('should deny unauthorized role update', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'role-owner2@test.com');
        const opId = await createTestUser(client, 'role-op2@test.com');
        const viewerId = await createTestUser(client, 'role-viewer@test.com');
        const bizId = await createTestBusiness(client, 'Unauth Role', ownerId);
        const memId = await createMembership(client, bizId, opId, 'operator', true);
        await createMembership(client, bizId, viewerId, 'viewer', true);

        // Viewer tries to update
        await asUser(client, viewerId);
        await expect(
          client.query(`SELECT update_business_member_role($1, 'manager')`, [memId])
        ).rejects.toThrow(/ACCESS_DENIED/);
      });
    });

    it('should deny manager from promoting to owner', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'role-esc-owner@test.com');
        const managerId = await createTestUser(client, 'role-esc-mgr@test.com');
        const opId = await createTestUser(client, 'role-esc-op@test.com');
        const bizId = await createTestBusiness(client, 'Escalation Biz', ownerId);
        await createMembership(client, bizId, managerId, 'manager', true);
        const opMemId = await createMembership(client, bizId, opId, 'operator', true);

        // Manager tries to promote operator to owner
        await asUser(client, managerId);
        await expect(
          client.query(`SELECT update_business_member_role($1, 'owner')`, [opMemId])
        ).rejects.toThrow(/ACCESS_DENIED/);
      });
    });

    it('should create audit log for role change', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'role-audit@test.com');
        const opId = await createTestUser(client, 'role-aud-op@test.com');
        const bizId = await createTestBusiness(client, 'Audit Role Biz', ownerId);
        const memId = await createMembership(client, bizId, opId, 'operator', true);

        await asUser(client, ownerId);
        await client.query(
          `SELECT update_business_member_role($1, 'manager')`, [memId]
        );

        await asServiceRole(client);
        const audit = await client.query(
          `SELECT * FROM audit_log WHERE action = 'member.role_updated' AND entity_id = $1`,
          [memId]
        );
        expect(audit.rows.length).toBe(1);
        expect(audit.rows[0].old_values).toEqual({ role: 'operator' });
        expect(audit.rows[0].new_values).toEqual({ role: 'manager' });
      });
    });
  });

  // ═════════════════════════════════════════════════════════
  // 7. deactivate_business_member()
  // ═════════════════════════════════════════════════════════

  describe('deactivate_business_member', () => {
    it('should allow business admin to deactivate member', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'deact-owner@test.com');
        const opId = await createTestUser(client, 'deact-op@test.com');
        const bizId = await createTestBusiness(client, 'Deact Biz', ownerId);
        const memId = await createMembership(client, bizId, opId, 'operator', true);

        await asUser(client, ownerId);
        const res = await client.query(
          `SELECT deactivate_business_member($1)`, [memId]
        );
        expect(res.rows[0].deactivate_business_member.deactivated).toBe(true);

        // Verify deactivated
        await asServiceRole(client);
        const check = await client.query(
          `SELECT is_active FROM business_memberships WHERE id = $1`, [memId]
        );
        expect(check.rows[0].is_active).toBe(false);
      });
    });

    it('should prevent deactivating last owner', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'last-owner@test.com');
        const bizId = await createTestBusiness(client, 'Last Owner Biz', ownerId);

        // Get owner membership ID
        const memRes = await client.query(
          `SELECT id FROM business_memberships WHERE business_id = $1 AND user_id = $2`,
          [bizId, ownerId]
        );
        const ownerMemId = memRes.rows[0].id;

        await asUser(client, ownerId);
        await expect(
          client.query(`SELECT deactivate_business_member($1)`, [ownerMemId])
        ).rejects.toThrow(/BUSINESS_LOCKOUT/);
      });
    });

    it('should lose access after deactivation', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'access-owner@test.com');
        const opId = await createTestUser(client, 'access-op@test.com');
        const bizId = await createTestBusiness(client, 'Access Biz', ownerId);
        const memId = await createMembership(client, bizId, opId, 'operator', true);

        // Deactivate
        await asUser(client, ownerId);
        await client.query(`SELECT deactivate_business_member($1)`, [memId]);

        // Deactivated member tries to read business
        await asUser(client, opId);
        const res = await client.query(
          `SELECT id FROM businesses WHERE id = $1`, [bizId]
        );
        expect(res.rows.length).toBe(0); // RLS denies
      });
    });

    it('should create audit log for deactivation', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'deact-audit@test.com');
        const opId = await createTestUser(client, 'deact-aud-op@test.com');
        const bizId = await createTestBusiness(client, 'Deact Audit Biz', ownerId);
        const memId = await createMembership(client, bizId, opId, 'operator', true);

        await asUser(client, ownerId);
        await client.query(`SELECT deactivate_business_member($1)`, [memId]);

        await asServiceRole(client);
        const audit = await client.query(
          `SELECT * FROM audit_log WHERE action = 'member.deactivated' AND entity_id = $1`,
          [memId]
        );
        expect(audit.rows.length).toBe(1);
      });
    });
  });

  // ═════════════════════════════════════════════════════════
  // 8. invite_business_member()
  // ═════════════════════════════════════════════════════════

  describe('invite_business_member', () => {
    it('should create invite record safely (no email sent)', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'inv-owner@test.com');
        const bizId = await createTestBusiness(client, 'Invite Biz', ownerId);

        await asUser(client, ownerId);
        const res = await client.query(
          `SELECT invite_business_member($1, 'newuser@example.com', 'operator')`,
          [bizId]
        );

        const result = res.rows[0].invite_business_member;
        expect(result.email).toBe('newuser@example.com');
        expect(result.role).toBe('operator');
        expect(result.status).toBe('pending_signup');
      });
    });

    it('should deny unauthorized invite', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'inv-owner2@test.com');
        const viewerId = await createTestUser(client, 'inv-viewer@test.com');
        const bizId = await createTestBusiness(client, 'Inv Deny Biz', ownerId);
        await createMembership(client, bizId, viewerId, 'viewer', true);

        await asUser(client, viewerId);
        await expect(
          client.query(
            `SELECT invite_business_member($1, 'hack@example.com', 'operator')`,
            [bizId]
          )
        ).rejects.toThrow(/ACCESS_DENIED/);
      });
    });

    it('should create audit log for invite', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'inv-audit@test.com');
        const bizId = await createTestBusiness(client, 'Inv Audit Biz', ownerId);

        await asUser(client, ownerId);
        await client.query(
          `SELECT invite_business_member($1, 'invited@example.com', 'operator')`,
          [bizId]
        );

        await asServiceRole(client);
        const audit = await client.query(
          `SELECT * FROM audit_log WHERE action = 'member.invited' AND business_id = $1`,
          [bizId]
        );
        expect(audit.rows.length).toBe(1);
        expect(audit.rows[0].metadata.invited_email).toBe('invited@example.com');
      });
    });
  });

  // ═════════════════════════════════════════════════════════
  // 9. get_business_teams() — Placeholder
  // ═════════════════════════════════════════════════════════

  describe('get_business_teams', () => {
    it('should return empty (teams not yet implemented)', async () => {
      await withRollback(async (client) => {
        const ownerId = await createTestUser(client, 'teams-owner@test.com');
        const bizId = await createTestBusiness(client, 'Teams Biz', ownerId);

        const res = await client.query(
          `SELECT * FROM get_business_teams($1)`, [bizId]
        );
        expect(res.rows.length).toBe(0);
      });
    });
  });
});
