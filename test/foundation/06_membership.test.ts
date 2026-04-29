import { describe, it, expect, afterAll } from 'vitest';
import { withRollback, createTestUser, createTestBusiness, asUser, closePool } from './setup';

describe('06 — Membership Access Control', () => {
  afterAll(async () => { await closePool(); });

  it('should allow active member to read business customers', async () => {
    await withRollback(async (client) => {
      const ownerId = await createTestUser(client, 'mem-owner@member.com');
      const opId = await createTestUser(client, 'mem-op@member.com');
      const bizId = await createTestBusiness(client, 'Member Biz', ownerId);

      // Add operator as member (owner already created by createTestBusiness)
      await client.query(
        `INSERT INTO business_memberships (business_id, user_id, role, is_active)
         VALUES ($1, $2, 'operator', true)`,
        [bizId, opId]
      );

      // Create a customer
      await client.query(
        `INSERT INTO customers (business_id, phone, name)
         VALUES ($1, '+111222333', 'Test Customer')`, [bizId]
      );

      // Operator should be able to read
      await asUser(client, opId);
      const res = await client.query(
        `SELECT id FROM customers WHERE business_id = $1`, [bizId]
      );
      expect(res.rows.length).toBe(1);
    });
  });

  it('should DENY access when membership is deactivated', async () => {
    await withRollback(async (client) => {
      const ownerId = await createTestUser(client, 'deact-owner@member.com');
      const opId = await createTestUser(client, 'deact-op@member.com');
      const bizId = await createTestBusiness(client, 'Deact Biz', ownerId);

      // Create operator membership, then deactivate it
      await client.query(
        `INSERT INTO business_memberships (business_id, user_id, role, is_active)
         VALUES ($1, $2, 'operator', true)`,
        [bizId, opId]
      );
      await client.query(
        `UPDATE business_memberships SET is_active = false
         WHERE business_id = $1 AND user_id = $2`,
        [bizId, opId]
      );

      // Create customer
      await client.query(
        `INSERT INTO customers (business_id, phone, name)
         VALUES ($1, '+444555666', 'Deact Customer')`, [bizId]
      );

      // Deactivated operator should NOT see customers
      await asUser(client, opId);
      const res = await client.query(
        `SELECT id FROM customers WHERE business_id = $1`, [bizId]
      );
      expect(res.rows.length).toBe(0);
    });
  });

  it('should DENY check_permission for inactive membership', async () => {
    await withRollback(async (client) => {
      const ownerId = await createTestUser(client, 'inact-owner@member.com');
      const opId = await createTestUser(client, 'inact-op@member.com');
      const bizId = await createTestBusiness(client, 'Inact Perm Biz', ownerId);

      // Create then deactivate membership
      await client.query(
        `INSERT INTO business_memberships (business_id, user_id, role, is_active)
         VALUES ($1, $2, 'operator', true)`,
        [bizId, opId]
      );
      await client.query(
        `UPDATE business_memberships SET is_active = false
         WHERE business_id = $1 AND user_id = $2`,
        [bizId, opId]
      );

      // Permission check should fail
      const res = await client.query(
        `SELECT check_permission($1, $2, 'conversation:read') as allowed`,
        [opId, bizId]
      );
      expect(res.rows[0].allowed).toBe(false);
    });
  });
});
