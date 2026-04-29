import { describe, it, expect, afterAll } from 'vitest';
import {
  withRollback, createTestUser, createTestBusiness,
  createMembership, asUser, asServiceRole, closePool,
} from './setup';

describe('11 — Order from Conversation', () => {
  afterAll(async () => { await closePool(); });

  // ── Helpers ─────────────────────────────────────────────────

  async function createChannel(client: import('pg').PoolClient, bizId: string) {
    const res = await client.query(
      `INSERT INTO business_channels (business_id, channel_type, is_active, channel_config)
       VALUES ($1, 'whatsapp', true, '{"test":true}'::jsonb) RETURNING id`,
      [bizId]
    );
    return res.rows[0].id;
  }

  async function ingestAndGetIds(
    client: import('pg').PoolClient,
    bizId: string, chanId: string,
    phone: string, name: string, content: string
  ) {
    const res = await client.query(
      `SELECT ingest_inbound_message($1,$2,'whatsapp'::channel_type,$3,$4,$5) as result`,
      [bizId, chanId, phone, name, content]
    );
    return res.rows[0].result as {
      conversation_id: string;
      customer_id: string;
      message_id: string;
    };
  }

  /** Setup business + channel + conversation + customer */
  async function setupOrderContext(
    client: import('pg').PoolClient,
    suffix: string = ''
  ) {
    const owner = await createTestUser(client, `ord_owner_${suffix}${Date.now()}@test.com`);
    const bizId = await createTestBusiness(client, `Order Biz ${suffix}${Date.now()}`, owner);
    const chanId = await createChannel(client, bizId);

    // Seed action definition for create_order
    await client.query(
      `INSERT INTO action_definitions (business_id, action_type, name, requires_approval, is_active)
       VALUES ($1, 'create_order', 'Create Order', false, true)
       ON CONFLICT DO NOTHING`,
      [bizId]
    );

    const msg = await ingestAndGetIds(client, bizId, chanId, '+989121234567', 'Ali', 'I want to order');

    return {
      owner,
      bizId,
      chanId,
      conversationId: msg.conversation_id,
      customerId: msg.customer_id,
    };
  }

  const VALID_ITEMS = JSON.stringify([
    { item_name: 'Kabab Koobideh', quantity: 2, unit_price: 15.00, notes: 'Extra onion' },
    { item_name: 'Joojeh Kabab', quantity: 1, unit_price: 18.50 },
  ]);

  // ─────────────────────────────────────────────────────────
  // ORDER CREATION
  // ─────────────────────────────────────────────────────────

  it('create order from valid conversation/customer succeeds', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId, customerId } = await setupOrderContext(client, 'valid');

      await asUser(client, owner);
      const res = await client.query(
        `SELECT create_order($1, $2, $3::jsonb, 'dine_in', $4) as result`,
        [bizId, customerId, VALID_ITEMS, conversationId]
      );
      const result = res.rows[0].result;

      expect(result.error).toBeUndefined();
      expect(result.order_id).toBeDefined();
      expect(result.order_number).toBeDefined();
      expect(result.status).toBe('draft');
      expect(result.total).toBe(48.5);
      expect(result.item_count).toBe(2);
      expect(result.has_pricing).toBe(true);
    });
  });

  it('create order with missing items returns missing_fields', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId } = await setupOrderContext(client, 'noitems');

      await asUser(client, owner);
      const res = await client.query(
        `SELECT create_order($1, $2, '[]'::jsonb) as result`,
        [bizId, customerId]
      );
      const result = res.rows[0].result;

      expect(result.error).toBe('MISSING_REQUIRED_FIELDS');
      expect(result.missing_fields).toContain('items');
    });
  });

  it('create order delivery without address returns missing_fields', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId } = await setupOrderContext(client, 'noaddr');

      await asUser(client, owner);
      const res = await client.query(
        `SELECT create_order($1, $2, $3::jsonb, 'delivery') as result`,
        [bizId, customerId, VALID_ITEMS]
      );
      const result = res.rows[0].result;

      expect(result.error).toBe('MISSING_REQUIRED_FIELDS');
      expect(result.missing_fields).toContain('delivery_address');
    });
  });

  // ─────────────────────────────────────────────────────────
  // SECURITY
  // ─────────────────────────────────────────────────────────

  it('cross-tenant customer/conversation is denied', async () => {
    await withRollback(async (client) => {
      const ctx1 = await setupOrderContext(client, 'tenant1');
      const ctx2 = await setupOrderContext(client, 'tenant2');

      // A: Try to create order in biz1 with biz2's customer
      await asUser(client, ctx1.owner);
      const res1 = await client.query(
        `SELECT create_order($1, $2, $3::jsonb) as result`,
        [ctx1.bizId, ctx2.customerId, VALID_ITEMS]
      );
      expect(res1.rows[0].result.error).toBe('CUSTOMER_NOT_FOUND');

      // B: Try to create order in biz1 with biz1's customer but biz2's conversation
      //    (pass conversation_id directly — defense-in-depth test)
      const res2 = await client.query(
        `SELECT create_order($1, $2, $3::jsonb, 'dine_in', $4) as result`,
        [ctx1.bizId, ctx1.customerId, VALID_ITEMS, ctx2.conversationId]
      );
      expect(res2.rows[0].result.error).toBe('CONVERSATION_NOT_FOUND');
    });
  });

  it('unauthorized operator cannot create order', async () => {
    await withRollback(async (client) => {
      const { bizId, customerId } = await setupOrderContext(client, 'unauth');
      const viewer = await createTestUser(client, `viewer_ord_${Date.now()}@test.com`);
      await createMembership(client, bizId, viewer, 'viewer');

      await asUser(client, viewer);
      const res = await client.query(
        `SELECT create_order($1, $2, $3::jsonb) as result`,
        [bizId, customerId, VALID_ITEMS]
      );

      expect(res.rows[0].result.error).toBe('PERMISSION_DENIED');
    });
  });

  it('inactive membership cannot create order', async () => {
    await withRollback(async (client) => {
      const { bizId, customerId } = await setupOrderContext(client, 'inactive');
      const inactiveOp = await createTestUser(client, `inactive_ord_${Date.now()}@test.com`);
      await createMembership(client, bizId, inactiveOp, 'operator', false);

      await asUser(client, inactiveOp);
      const res = await client.query(
        `SELECT create_order($1, $2, $3::jsonb) as result`,
        [bizId, customerId, VALID_ITEMS]
      );

      expect(res.rows[0].result.error).toBe('PERMISSION_DENIED');
    });
  });

  // ─────────────────────────────────────────────────────────
  // ORDER ITEMS & CALCULATION
  // ─────────────────────────────────────────────────────────

  it('order items persist correctly in order_items table', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupOrderContext(client, 'items');

      await asUser(client, owner);
      const res = await client.query(
        `SELECT create_order($1, $2, $3::jsonb, 'dine_in', $4) as result`,
        [bizId, customerId, VALID_ITEMS, conversationId]
      );
      const orderId = res.rows[0].result.order_id;

      await asServiceRole(client);
      const items = await client.query(
        `SELECT item_name, quantity, unit_price, total, notes, sort_order
         FROM order_items WHERE order_id = $1 ORDER BY sort_order`,
        [orderId]
      );

      expect(items.rows.length).toBe(2);
      expect(items.rows[0].item_name).toBe('Kabab Koobideh');
      expect(Number(items.rows[0].quantity)).toBe(2);
      expect(Number(items.rows[0].unit_price)).toBe(15);
      expect(Number(items.rows[0].total)).toBe(30);
      expect(items.rows[0].notes).toBe('Extra onion');
      expect(items.rows[1].item_name).toBe('Joojeh Kabab');
      expect(Number(items.rows[1].total)).toBe(18.5);
    });
  });

  it('order total calculation works when prices exist', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId } = await setupOrderContext(client, 'total');

      await asUser(client, owner);
      const res = await client.query(
        `SELECT create_order($1, $2, $3::jsonb) as result`,
        [bizId, customerId, VALID_ITEMS]
      );

      // 2×15 + 1×18.50 = 48.50
      expect(res.rows[0].result.subtotal).toBe(48.5);
      expect(res.rows[0].result.total).toBe(48.5);
    });
  });

  it('order with missing prices creates draft', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId } = await setupOrderContext(client, 'noprice');
      const noPriceItems = JSON.stringify([
        { item_name: 'Special Dish', quantity: 1 },
        { item_name: 'Chef Surprise', quantity: 2 },
      ]);

      await asUser(client, owner);
      const res = await client.query(
        `SELECT create_order($1, $2, $3::jsonb, 'dine_in', NULL, NULL, NULL, 'operator', 'pending_confirmation') as result`,
        [bizId, customerId, noPriceItems]
      );
      const result = res.rows[0].result;

      // Should be draft even though pending_confirmation was requested — no pricing
      expect(result.status).toBe('draft');
      expect(result.has_pricing).toBe(false);
      expect(result.total).toBe(0);
    });
  });

  // ─────────────────────────────────────────────────────────
  // ORDER STATUS LIFECYCLE
  // ─────────────────────────────────────────────────────────

  it('pending_customer_confirmation status works', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId } = await setupOrderContext(client, 'pending');

      await asUser(client, owner);
      const res = await client.query(
        `SELECT create_order($1, $2, $3::jsonb, 'dine_in', NULL, NULL, NULL, 'operator', 'pending_confirmation') as result`,
        [bizId, customerId, VALID_ITEMS]
      );

      expect(res.rows[0].result.status).toBe('pending_confirmation');
    });
  });

  it('confirm_order changes status correctly', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId } = await setupOrderContext(client, 'confirm');

      await asUser(client, owner);
      const createRes = await client.query(
        `SELECT create_order($1, $2, $3::jsonb) as result`,
        [bizId, customerId, VALID_ITEMS]
      );
      const orderId = createRes.rows[0].result.order_id;

      const confirmRes = await client.query(
        `SELECT confirm_order($1) as result`, [orderId]
      );
      const result = confirmRes.rows[0].result;

      expect(result.error).toBeUndefined();
      expect(result.from_status).toBe('draft');
      expect(result.to_status).toBe('confirmed');

      // Verify in DB
      await asServiceRole(client);
      const order = await client.query(
        `SELECT status, confirmed_at FROM orders WHERE id = $1`, [orderId]
      );
      expect(order.rows[0].status).toBe('confirmed');
      expect(order.rows[0].confirmed_at).toBeDefined();
    });
  });

  it('cancel_order changes status correctly', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId } = await setupOrderContext(client, 'cancel');

      await asUser(client, owner);
      const createRes = await client.query(
        `SELECT create_order($1, $2, $3::jsonb) as result`,
        [bizId, customerId, VALID_ITEMS]
      );
      const orderId = createRes.rows[0].result.order_id;

      const cancelRes = await client.query(
        `SELECT cancel_order($1, 'Customer changed mind') as result`, [orderId]
      );
      const result = cancelRes.rows[0].result;

      expect(result.error).toBeUndefined();
      expect(result.from_status).toBe('draft');
      expect(result.to_status).toBe('cancelled');

      await asServiceRole(client);
      const order = await client.query(
        `SELECT status, cancelled_at, cancellation_reason FROM orders WHERE id = $1`, [orderId]
      );
      expect(order.rows[0].status).toBe('cancelled');
      expect(order.rows[0].cancellation_reason).toBe('Customer changed mind');
    });
  });

  // ─────────────────────────────────────────────────────────
  // ACTION ENGINE
  // ─────────────────────────────────────────────────────────

  it('execute_create_order_action creates order through handler', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupOrderContext(client, 'action');

      await asUser(client, owner);
      const res = await client.query(
        `SELECT execute_create_order_action($1, $2, $3::jsonb, 'dine_in', $4) as result`,
        [bizId, customerId, VALID_ITEMS, conversationId]
      );
      const result = res.rows[0].result;

      expect(result.execution_id).toBeDefined();
      expect(result.order).toBeDefined();
      expect(result.order.order_id).toBeDefined();
      expect(result.order.status).toBe('draft');
    });
  });

  it('action execution log created for create_order', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupOrderContext(client, 'execlog');

      await asUser(client, owner);
      const res = await client.query(
        `SELECT execute_create_order_action($1, $2, $3::jsonb, 'dine_in', $4) as result`,
        [bizId, customerId, VALID_ITEMS, conversationId]
      );
      const executionId = res.rows[0].result.execution_id;

      await asServiceRole(client);
      const exec = await client.query(
        `SELECT triggered_by, approval_status, output_data, executed_at
         FROM action_executions WHERE id = $1`,
        [executionId]
      );

      expect(exec.rows.length).toBe(1);
      expect(exec.rows[0].triggered_by).toBe('operator');
      expect(exec.rows[0].approval_status).toBe('approved');
      expect(exec.rows[0].executed_at).toBeDefined();
      expect(exec.rows[0].output_data.order_id).toBeDefined();
    });
  });

  // ─────────────────────────────────────────────────────────
  // CONVERSATION INTEGRATION
  // ─────────────────────────────────────────────────────────

  it('conversation detail exposes linked order summary', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupOrderContext(client, 'detail');

      await asUser(client, owner);
      await client.query(
        `SELECT create_order($1, $2, $3::jsonb, 'dine_in', $4) as result`,
        [bizId, customerId, VALID_ITEMS, conversationId]
      );

      const detail = await client.query(
        `SELECT get_conversation_detail($1) as result`, [conversationId]
      );
      const orders = detail.rows[0].result.orders;

      expect(orders).toBeDefined();
      expect(orders.length).toBe(1);
      expect(orders[0].order_number).toBeDefined();
      expect(orders[0].status).toBe('draft');
      expect(Number(orders[0].total)).toBe(48.5);
      expect(orders[0].item_count).toBe(2);
    });
  });

  // ─────────────────────────────────────────────────────────
  // AUDIT & HISTORY
  // ─────────────────────────────────────────────────────────

  it('audit log for order created', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId } = await setupOrderContext(client, 'audit1');

      await asUser(client, owner);
      const res = await client.query(
        `SELECT create_order($1, $2, $3::jsonb) as result`,
        [bizId, customerId, VALID_ITEMS]
      );
      const orderId = res.rows[0].result.order_id;

      await asServiceRole(client);
      const audit = await client.query(
        `SELECT action, severity, metadata FROM audit_log
         WHERE entity_id = $1 AND action = 'order_created'`,
        [orderId]
      );

      expect(audit.rows.length).toBe(1);
      expect(audit.rows[0].severity).toBe('info');
      expect(audit.rows[0].metadata.source).toBe('operator');
      expect(audit.rows[0].metadata.item_count).toBe(2);
    });
  });

  it('audit log for order confirmed', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId } = await setupOrderContext(client, 'audit2');

      await asUser(client, owner);
      const createRes = await client.query(
        `SELECT create_order($1, $2, $3::jsonb) as result`,
        [bizId, customerId, VALID_ITEMS]
      );
      const orderId = createRes.rows[0].result.order_id;

      await client.query(`SELECT confirm_order($1)`, [orderId]);

      await asServiceRole(client);
      const audit = await client.query(
        `SELECT action, metadata FROM audit_log
         WHERE entity_id = $1 AND action = 'order_status_changed'`,
        [orderId]
      );

      expect(audit.rows.length).toBe(1);
      expect(audit.rows[0].metadata.from_status).toBe('draft');
      expect(audit.rows[0].metadata.to_status).toBe('confirmed');
    });
  });

  it('order status history is tracked', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId } = await setupOrderContext(client, 'history');

      await asUser(client, owner);
      const createRes = await client.query(
        `SELECT create_order($1, $2, $3::jsonb) as result`,
        [bizId, customerId, VALID_ITEMS]
      );
      const orderId = createRes.rows[0].result.order_id;

      await client.query(`SELECT confirm_order($1)`, [orderId]);

      await asServiceRole(client);
      const history = await client.query(
        `SELECT from_status, to_status FROM order_status_history
         WHERE order_id = $1 ORDER BY created_at`,
        [orderId]
      );

      expect(history.rows.length).toBe(2);
      expect(history.rows[0].from_status).toBeNull(); // initial draft
      expect(history.rows[0].to_status).toBe('draft');
      expect(history.rows[1].from_status).toBe('draft');
      expect(history.rows[1].to_status).toBe('confirmed');
    });
  });
});
