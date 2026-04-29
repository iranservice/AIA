import { describe, it, expect, afterAll } from 'vitest';
import { withRollback, createTestUser, createTestBusiness, closePool } from './setup';

describe('03 — Tenancy Foundation', () => {
  afterAll(async () => { await closePool(); });

  it('should create a business', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'owner@tenancy.com');
      const bizId = await createTestBusiness(client, 'Test Restaurant', userId);

      const res = await client.query(
        `SELECT * FROM businesses WHERE id = $1`, [bizId]
      );
      expect(res.rows.length).toBe(1);
      expect(res.rows[0].name).toBe('Test Restaurant');
      expect(res.rows[0].business_type).toBe('restaurant');
      expect(res.rows[0].is_active).toBe(true);

      // Owner membership should exist (created by createTestBusiness)
      const memRes = await client.query(
        `SELECT * FROM business_memberships
         WHERE business_id = $1 AND user_id = $2 AND role = 'owner'`,
        [bizId, userId]
      );
      expect(memRes.rows.length).toBe(1);
    });
  });

  it('should create an operator membership', async () => {
    await withRollback(async (client) => {
      const ownerId = await createTestUser(client, 'biz-owner@tenancy.com');
      const opId = await createTestUser(client, 'operator@tenancy.com');
      const bizId = await createTestBusiness(client, 'Membership Test', ownerId);

      await client.query(
        `INSERT INTO business_memberships (business_id, user_id, role, is_active)
         VALUES ($1, $2, 'operator', true)`,
        [bizId, opId]
      );

      const res = await client.query(
        `SELECT * FROM business_memberships WHERE business_id = $1 AND user_id = $2`,
        [bizId, opId]
      );
      expect(res.rows.length).toBe(1);
      expect(res.rows[0].role).toBe('operator');
      expect(res.rows[0].is_active).toBe(true);
    });
  });

  it('should enforce unique slug per business', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'slug@tenancy.com');
      const fixedSlug = 'unique-slug-test';
      
      await client.query(
        `INSERT INTO businesses (name, slug, business_type)
         VALUES ('Slug Test', $1, 'restaurant')`,
        [fixedSlug]
      );

      // Same slug should fail
      await expect(
        client.query(
          `INSERT INTO businesses (name, slug, business_type)
           VALUES ('Slug Test 2', $1, 'restaurant')`,
          [fixedSlug]
        )
      ).rejects.toThrow();
    });
  });
});
