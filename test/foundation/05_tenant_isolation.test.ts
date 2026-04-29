import { describe, it, expect, afterAll } from 'vitest';
import { withRollback, createTestUser, createTestBusiness, asUser, closePool } from './setup';

describe('05 — Tenant Isolation (RLS)', () => {
  afterAll(async () => { await closePool(); });

  it('should allow user to read their own business', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'iso-owner@rls.com');
      const bizId = await createTestBusiness(client, 'My Business', userId);
      // createTestBusiness already creates 'owner' membership

      // Switch to authenticated user context
      await asUser(client, userId);

      const res = await client.query(
        `SELECT id FROM businesses WHERE id = $1`, [bizId]
      );
      expect(res.rows.length).toBe(1);
    });
  });

  it('should DENY cross-tenant business read', async () => {
    await withRollback(async (client) => {
      const userA = await createTestUser(client, 'userA@rls.com');
      const userB = await createTestUser(client, 'userB@rls.com');
      const bizA = await createTestBusiness(client, 'Business A', userA);
      const bizB = await createTestBusiness(client, 'Business B', userB);

      // User B tries to read Business A's data
      await asUser(client, userB);

      const res = await client.query(
        `SELECT id FROM businesses WHERE id = $1`, [bizA]
      );
      // RLS should filter out Business A for User B
      expect(res.rows.length).toBe(0);
    });
  });

  it('should DENY cross-tenant customer read', async () => {
    await withRollback(async (client) => {
      const userA = await createTestUser(client, 'custA@rls.com');
      const userB = await createTestUser(client, 'custB@rls.com');
      const bizA = await createTestBusiness(client, 'Cust Business A', userA);
      await createTestBusiness(client, 'Cust Business B', userB);

      // Create a customer in Business A (as service role — aia_user bypasses RLS)
      await client.query(
        `INSERT INTO customers (business_id, phone, name)
         VALUES ($1, '+1234567890', 'Customer A')`,
        [bizA]
      );

      // User B tries to read Business A's customers
      await asUser(client, userB);

      const res = await client.query(`SELECT id FROM customers WHERE business_id = $1`, [bizA]);
      expect(res.rows.length).toBe(0);
    });
  });

  it('should DENY cross-tenant conversation read', async () => {
    await withRollback(async (client) => {
      const userA = await createTestUser(client, 'convA@rls.com');
      const userB = await createTestUser(client, 'convB@rls.com');
      const bizA = await createTestBusiness(client, 'Conv Business A', userA);
      await createTestBusiness(client, 'Conv Business B', userB);

      // Create customer and conversation in Business A
      const custRes = await client.query(
        `INSERT INTO customers (business_id, phone, name)
         VALUES ($1, '+9876543210', 'Conv Customer')
         RETURNING id`, [bizA]
      );
      await client.query(
        `INSERT INTO conversations (business_id, customer_id, channel_type, status)
         VALUES ($1, $2, 'whatsapp', 'open')`,
        [bizA, custRes.rows[0].id]
      );

      // User B should NOT see Business A's conversations
      await asUser(client, userB);
      const res = await client.query(
        `SELECT id FROM conversations WHERE business_id = $1`, [bizA]
      );
      expect(res.rows.length).toBe(0);
    });
  });
});
