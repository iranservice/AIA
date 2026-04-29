import { describe, it, expect, afterAll } from 'vitest';
import { withRollback, createTestUser, createTestBusiness, closePool } from './setup';

describe('07 — Audit Foundation', () => {
  afterAll(async () => { await closePool(); });

  it('should create audit log via log_audit() RPC', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'audit@test.com');
      const bizId = await createTestBusiness(client, 'Audit Biz', userId);

      // Call log_audit RPC
      await client.query(
        `SELECT log_audit(
          p_action := 'test_action',
          p_entity_type := 'business',
          p_entity_id := $1,
          p_business_id := $2,
          p_user_id := $3,
          p_severity := 'info',
          p_old_values := '{"status":"draft"}'::jsonb,
          p_new_values := '{"status":"active"}'::jsonb,
          p_metadata := '{"source":"foundation_test"}'::jsonb
        )`,
        [bizId, bizId, userId]
      );

      // Verify audit log exists
      const res = await client.query(
        `SELECT * FROM audit_log
         WHERE entity_type = 'business' AND entity_id = $1`,
        [bizId]
      );
      expect(res.rows.length).toBe(1);

      const log = res.rows[0];
      expect(log.action).toBe('test_action');
      expect(log.entity_type).toBe('business');
      expect(log.entity_id).toBe(bizId);
      expect(log.business_id).toBe(bizId);
      expect(log.user_id).toBe(userId);
      expect(log.severity).toBe('info');
      expect(log.old_values).toEqual({ status: 'draft' });
      expect(log.new_values).toEqual({ status: 'active' });
      expect(log.metadata).toEqual({ source: 'foundation_test' });
      expect(log.created_at).toBeDefined();
    });
  });

  it('should record actor, timestamp, and target metadata', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'audit-meta@test.com');

      await client.query(
        `SELECT log_audit(
          p_action := 'user_login',
          p_entity_type := 'user',
          p_entity_id := $1,
          p_user_id := $1,
          p_severity := 'info',
          p_metadata := '{"ip":"127.0.0.1","user_agent":"vitest"}'::jsonb
        )`,
        [userId]
      );

      const res = await client.query(
        `SELECT * FROM audit_log WHERE action = 'user_login' AND user_id = $1`,
        [userId]
      );
      expect(res.rows.length).toBe(1);
      expect(res.rows[0].user_id).toBe(userId); // actor
      expect(res.rows[0].created_at).toBeDefined(); // timestamp
      expect(res.rows[0].entity_type).toBe('user'); // target type
      expect(res.rows[0].entity_id).toBe(userId); // target id
    });
  });

  it('should have RLS policies that prevent non-admin deletion of audit logs', async () => {
    await withRollback(async (client) => {
      // Check that audit_log has no DELETE policy for authenticated users
      const res = await client.query(
        `SELECT policyname, cmd FROM pg_policies 
         WHERE schemaname = 'public' AND tablename = 'audit_log'`
      );
      const policies = res.rows;

      // Verify audit table has RLS enabled
      const rlsRes = await client.query(
        `SELECT rowsecurity FROM pg_tables
         WHERE schemaname = 'public' AND tablename = 'audit_log'`
      );
      expect(rlsRes.rows[0].rowsecurity).toBe(true);

      // No DELETE policy should exist for regular users
      const deletePolicies = policies.filter(p => p.cmd === 'DELETE');
      expect(deletePolicies.length).toBe(0);
    });
  });
});
