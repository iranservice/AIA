import { describe, it, expect, afterAll } from 'vitest';
import { withRollback, createTestUser, createTestBusiness, closePool } from './setup';

describe('04 — Authz Foundation', () => {
  afterAll(async () => { await closePool(); });

  it('should have 34 seed permissions', async () => {
    await withRollback(async (client) => {
      const res = await client.query(`SELECT count(*) as cnt FROM permissions`);
      expect(Number(res.rows[0].cnt)).toBe(34);
    });
  });

  it('should have role-permission mappings for manager/operator/viewer', async () => {
    await withRollback(async (client) => {
      // Owner bypasses role_permissions (implicit full access)
      // Manager, operator, viewer have explicit mappings
      const res = await client.query(
        `SELECT role, count(*) as cnt FROM role_permissions GROUP BY role ORDER BY role`
      );
      expect(res.rows.length).toBeGreaterThanOrEqual(3);
      const roles = res.rows.map(r => r.role);
      expect(roles).toContain('manager');
      expect(roles).toContain('operator');
      expect(roles).toContain('viewer');
    });
  });

  it('should grant permission via check_permission() for owner', async () => {
    await withRollback(async (client) => {
      const ownerId = await createTestUser(client, 'perm-owner@authz.com');
      const bizId = await createTestBusiness(client, 'Perm Test', ownerId);
      // createTestBusiness already creates 'owner' membership

      const res = await client.query(
        `SELECT check_permission($1, $2, 'order:create') as allowed`,
        [ownerId, bizId]
      );
      expect(res.rows[0].allowed).toBe(true);
    });
  });

  it('should deny permission for unpermitted role', async () => {
    await withRollback(async (client) => {
      const ownerId = await createTestUser(client, 'viewer-owner@authz.com');
      const viewerId = await createTestUser(client, 'viewer@authz.com');
      const bizId = await createTestBusiness(client, 'Viewer Perm Test', ownerId);

      // Add viewer membership
      await client.query(
        `INSERT INTO business_memberships (business_id, user_id, role, is_active)
         VALUES ($1, $2, 'viewer', true)`,
        [bizId, viewerId]
      );

      const res = await client.query(
        `SELECT check_permission($1, $2, 'order:create') as allowed`,
        [viewerId, bizId]
      );
      expect(res.rows[0].allowed).toBe(false);
    });
  });

  it('should deny permission for non-member', async () => {
    await withRollback(async (client) => {
      const ownerId = await createTestUser(client, 'nomem-owner@authz.com');
      const outsiderId = await createTestUser(client, 'outsider@authz.com');
      const bizId = await createTestBusiness(client, 'Non-member Test', ownerId);

      const res = await client.query(
        `SELECT check_permission($1, $2, 'order:create') as allowed`,
        [outsiderId, bizId]
      );
      expect(res.rows[0].allowed).toBe(false);
    });
  });
});
