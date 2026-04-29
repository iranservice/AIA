import { describe, it, expect, afterAll } from 'vitest';
import {
  withRollback, createTestUser, createTestBusiness,
  createMembership, asUser, asServiceRole, closePool,
} from './setup';

describe('12 — Order Confirmation Experience', () => {
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

  async function setupContext(client: import('pg').PoolClient, suffix: string) {
    const owner = await createTestUser(client, `conf_owner_${suffix}${Date.now()}@test.com`);
    const bizId = await createTestBusiness(client, `Conf Biz ${suffix}${Date.now()}`, owner);
    const chanId = await createChannel(client, bizId);
    const msg = await ingestAndGetIds(client, bizId, chanId, '+989121234567', 'Ali', 'Order please');
    return { owner, bizId, chanId, conversationId: msg.conversation_id, customerId: msg.customer_id };
  }

  const ITEMS = JSON.stringify([
    { item_name: 'Kabab Koobideh', quantity: 2, unit_price: 15.00, notes: 'Extra onion' },
    { item_name: 'Joojeh Kabab', quantity: 1, unit_price: 18.50 },
  ]);

  async function createDraftOrder(client: import('pg').PoolClient, bizId: string, custId: string, convId: string) {
    const res = await client.query(
      `SELECT create_order($1, $2, $3::jsonb, 'dine_in', $4) as result`,
      [bizId, custId, ITEMS, convId]
    );
    return res.rows[0].result.order_id as string;
  }

  // ─────────────────────────────────────────────────────────
  // CONFIRMATION PAYLOAD
  // ─────────────────────────────────────────────────────────

  it('payload returns correct order/items/total/status', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'payload');
      await asUser(client, owner);
      const orderId = await createDraftOrder(client, bizId, customerId, conversationId);

      const res = await client.query(
        `SELECT get_order_confirmation_payload($1) as result`, [orderId]
      );
      const p = res.rows[0].result;

      expect(p.error).toBeUndefined();
      expect(p.order_id).toBe(orderId);
      expect(p.order_number).toBeDefined();
      expect(p.business_id).toBe(bizId);
      expect(p.customer_id).toBe(customerId);
      expect(p.conversation_id).toBe(conversationId);
      expect(p.status).toBe('draft');
      expect(p.order_type).toBe('dine_in');
      expect(Number(p.total)).toBe(48.5);
      expect(Number(p.subtotal)).toBe(48.5);
      expect(p.currency).toBeDefined();
      expect(p.items).toBeDefined();
      expect(p.items.length).toBe(2);
      expect(p.items[0].item_name).toBe('Kabab Koobideh');
      expect(Number(p.items[0].quantity)).toBe(2);
      expect(Number(p.items[0].unit_price)).toBe(15);
      expect(Number(p.items[0].total)).toBe(30);
      expect(p.items[0].notes).toBe('Extra onion');
      expect(p.items[1].item_name).toBe('Joojeh Kabab');
    });
  });

  it('suggested_confirmation_text is generated correctly', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'conftext');
      await asUser(client, owner);
      const orderId = await createDraftOrder(client, bizId, customerId, conversationId);

      const res = await client.query(
        `SELECT get_order_confirmation_payload($1) as result`, [orderId]
      );
      const text = res.rows[0].result.suggested_confirmation_text as string;

      expect(text).toContain('2x Kabab Koobideh');
      expect(text).toContain('1x Joojeh Kabab');
      expect(text).toContain('48.50');
      expect(text).toContain('Is this correct?');
    });
  });

  // ─────────────────────────────────────────────────────────
  // AVAILABLE ACTIONS
  // ─────────────────────────────────────────────────────────

  it('available_actions correct for draft (with update permission)', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'act_draft');
      await asUser(client, owner);
      const orderId = await createDraftOrder(client, bizId, customerId, conversationId);

      const res = await client.query(
        `SELECT get_order_confirmation_payload($1) as result`, [orderId]
      );
      const actions = res.rows[0].result.available_actions as string[];

      expect(actions).toContain('view_order');
      expect(actions).toContain('confirm_order');
      expect(actions).toContain('cancel_order');
      expect(actions).toContain('request_customer_confirmation');
    });
  });

  it('available_actions correct for pending_confirmation', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'act_pend');
      await asUser(client, owner);
      const orderId = await createDraftOrder(client, bizId, customerId, conversationId);

      // Move to pending
      await client.query(`SELECT request_customer_confirmation($1)`, [orderId]);

      const res = await client.query(
        `SELECT get_order_confirmation_payload($1) as result`, [orderId]
      );
      const actions = res.rows[0].result.available_actions as string[];

      expect(actions).toContain('view_order');
      expect(actions).toContain('confirm_order');
      expect(actions).toContain('cancel_order');
      expect(actions).not.toContain('request_customer_confirmation');
    });
  });

  it('available_actions correct for confirmed', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'act_conf');
      await asUser(client, owner);
      const orderId = await createDraftOrder(client, bizId, customerId, conversationId);

      await client.query(`SELECT confirm_order($1)`, [orderId]);

      const res = await client.query(
        `SELECT get_order_confirmation_payload($1) as result`, [orderId]
      );
      const actions = res.rows[0].result.available_actions as string[];

      expect(actions).toContain('view_order');
      expect(actions).toContain('cancel_order');
      expect(actions).not.toContain('confirm_order');
      expect(actions).not.toContain('request_customer_confirmation');
    });
  });

  it('available_actions correct for cancelled (view only)', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'act_canc');
      await asUser(client, owner);
      const orderId = await createDraftOrder(client, bizId, customerId, conversationId);

      await client.query(`SELECT cancel_order($1, 'test')`, [orderId]);

      const res = await client.query(
        `SELECT get_order_confirmation_payload($1) as result`, [orderId]
      );
      const actions = res.rows[0].result.available_actions as string[];

      expect(actions).toEqual(['view_order']);
    });
  });

  // ─────────────────────────────────────────────────────────
  // REQUEST CUSTOMER CONFIRMATION
  // ─────────────────────────────────────────────────────────

  it('request_customer_confirmation moves draft → pending_confirmation', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'req_conf');
      await asUser(client, owner);
      const orderId = await createDraftOrder(client, bizId, customerId, conversationId);

      const res = await client.query(
        `SELECT request_customer_confirmation($1) as result`, [orderId]
      );
      const result = res.rows[0].result;

      expect(result.error).toBeUndefined();
      expect(result.status).toBe('pending_confirmation');
      expect(result.order_id).toBe(orderId);
      expect(result.available_actions).toContain('confirm_order');
      expect(result.available_actions).not.toContain('request_customer_confirmation');
    });
  });

  it('request_customer_confirmation creates audit log', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'req_audit');
      await asUser(client, owner);
      const orderId = await createDraftOrder(client, bizId, customerId, conversationId);

      await client.query(`SELECT request_customer_confirmation($1)`, [orderId]);

      await asServiceRole(client);
      const audit = await client.query(
        `SELECT action, severity, metadata FROM audit_log
         WHERE entity_id = $1 AND action = 'confirmation_requested'`,
        [orderId]
      );

      expect(audit.rows.length).toBe(1);
      expect(audit.rows[0].severity).toBe('info');
      expect(audit.rows[0].metadata.from_status).toBe('draft');
      expect(audit.rows[0].metadata.to_status).toBe('pending_confirmation');
    });
  });

  // ─────────────────────────────────────────────────────────
  // SECURITY
  // ─────────────────────────────────────────────────────────

  it('unauthorized user denied for payload', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'sec_unauth');
      await asUser(client, owner);
      const orderId = await createDraftOrder(client, bizId, customerId, conversationId);

      // Create outsider (must be done as service role to avoid RLS)
      await asServiceRole(client);
      const outsider = await createTestUser(client, `outsider_${Date.now()}@test.com`);
      const otherBiz = await createTestBusiness(client, `Other ${Date.now()}`, outsider);

      await asUser(client, outsider);
      const res = await client.query(
        `SELECT get_order_confirmation_payload($1) as result`, [orderId]
      );

      expect(res.rows[0].result.error).toBe('ACCESS_DENIED');
    });
  });

  it('inactive membership denied for confirmation request', async () => {
    await withRollback(async (client) => {
      const { bizId, customerId, conversationId, owner } = await setupContext(client, 'sec_inact');
      await asUser(client, owner);
      const orderId = await createDraftOrder(client, bizId, customerId, conversationId);

      await asServiceRole(client);
      const inactiveOp = await createTestUser(client, `inact_conf_${Date.now()}@test.com`);
      await createMembership(client, bizId, inactiveOp, 'operator', false);

      await asUser(client, inactiveOp);
      const res = await client.query(
        `SELECT request_customer_confirmation($1) as result`, [orderId]
      );

      expect(res.rows[0].result.error).toBe('PERMISSION_DENIED');
    });
  });

  it('cross-tenant order access denied', async () => {
    await withRollback(async (client) => {
      const ctx1 = await setupContext(client, 'sec_t1');
      const ctx2 = await setupContext(client, 'sec_t2');

      await asUser(client, ctx1.owner);
      const orderId = await createDraftOrder(client, ctx1.bizId, ctx1.customerId, ctx1.conversationId);

      // ctx2 owner tries to access ctx1's order
      await asUser(client, ctx2.owner);
      const res = await client.query(
        `SELECT get_order_confirmation_payload($1) as result`, [orderId]
      );

      expect(res.rows[0].result.error).toBe('ACCESS_DENIED');
    });
  });

  it('AI cannot finalize order without confirmation', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'sec_ai');
      await asUser(client, owner);
      const orderId = await createDraftOrder(client, bizId, customerId, conversationId);

      // Confirm flow requires operator auth — AI has no auth.uid()
      // Simulate no auth context
      await asServiceRole(client);
      await client.query(`SET LOCAL request.jwt.claims = '{}'`);
      await client.query(`SET LOCAL role = 'anon'`);

      const res = await client.query(
        `SELECT request_customer_confirmation($1) as result`, [orderId]
      );

      expect(res.rows[0].result.error).toBe('PERMISSION_DENIED');
    });
  });

  // ─────────────────────────────────────────────────────────
  // CONVERSATION INTEGRATION
  // ─────────────────────────────────────────────────────────

  it('conversation detail exposes order with available_actions', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'conv_act');
      await asUser(client, owner);
      await createDraftOrder(client, bizId, customerId, conversationId);

      const detail = await client.query(
        `SELECT get_conversation_detail($1) as result`, [conversationId]
      );
      const orders = detail.rows[0].result.orders;

      expect(orders.length).toBe(1);
      expect(orders[0].available_actions).toBeDefined();
      expect(orders[0].available_actions).toContain('view_order');
      expect(orders[0].available_actions).toContain('confirm_order');
      expect(orders[0].available_actions).toContain('request_customer_confirmation');
    });
  });

  it('viewer sees view_order only in conversation detail', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, customerId, conversationId } = await setupContext(client, 'conv_view');
      await asUser(client, owner);
      await createDraftOrder(client, bizId, customerId, conversationId);

      await asServiceRole(client);
      const viewer = await createTestUser(client, `viewer_conf_${Date.now()}@test.com`);
      await createMembership(client, bizId, viewer, 'viewer');

      await asUser(client, viewer);
      const detail = await client.query(
        `SELECT get_conversation_detail($1) as result`, [conversationId]
      );
      const orders = detail.rows[0].result.orders;

      expect(orders.length).toBe(1);
      expect(orders[0].available_actions).toEqual(['view_order']);
    });
  });
});
