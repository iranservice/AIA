import { describe, it, expect, afterAll } from 'vitest';
import {
  withRollback, createTestUser, createTestBusiness,
  createMembership, asUser, asServiceRole, closePool,
} from './setup';

describe('09 — Operator Reply + Assignment', () => {
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

  async function ingestMessage(
    client: import('pg').PoolClient,
    bizId: string, chanId: string,
    phone: string, content: string
  ) {
    const res = await client.query(
      `SELECT ingest_inbound_message($1,$2,'whatsapp'::channel_type,$3,NULL,$4) as result`,
      [bizId, chanId, phone, content]
    );
    return res.rows[0].result;
  }

  async function assignConvo(client: import('pg').PoolClient, convoId: string, opId: string) {
    const res = await client.query(
      `SELECT assign_conversation($1, $2) as result`, [convoId, opId]
    );
    return res.rows[0].result;
  }

  async function unassignConvo(client: import('pg').PoolClient, convoId: string) {
    const res = await client.query(
      `SELECT unassign_conversation($1) as result`, [convoId]
    );
    return res.rows[0].result;
  }

  async function transferConvo(
    client: import('pg').PoolClient,
    convoId: string, toOpId: string, reason?: string
  ) {
    const res = await client.query(
      `SELECT transfer_conversation($1, $2, $3) as result`,
      [convoId, toOpId, reason ?? null]
    );
    return res.rows[0].result;
  }

  async function operatorReply(
    client: import('pg').PoolClient,
    convoId: string, content: string
  ) {
    const res = await client.query(
      `SELECT operator_reply($1, $2) as result`, [convoId, content]
    );
    return res.rows[0].result;
  }

  // ─────────────────────────────────────────────────────────
  // SECURITY PATCH TESTS
  // ─────────────────────────────────────────────────────────

  it('is_platform_admin() returns false for non-platform user', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'regular@test.com');
      const res = await client.query(
        `SELECT is_platform_admin($1) as result`, [userId]
      );
      expect(res.rows[0].result).toBe(false);
    });
  });

  it('is_platform_admin() returns false for NULL/missing user', async () => {
    await withRollback(async (client) => {
      const res = await client.query(
        `SELECT is_platform_admin('00000000-0000-0000-0000-000000000099') as result`
      );
      expect(res.rows[0].result).toBe(false);
    });
  });

  it('is_platform_admin() returns true for platform_admin', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'admin@test.com');
      await client.query(
        `UPDATE user_profiles SET platform_role = 'platform_admin' WHERE id = $1`,
        [userId]
      );
      const res = await client.query(
        `SELECT is_platform_admin($1) as result`, [userId]
      );
      expect(res.rows[0].result).toBe(true);
    });
  });

  // ─────────────────────────────────────────────────────────
  // ASSIGNMENT TESTS
  // ─────────────────────────────────────────────────────────

  it('assign conversation to active operator succeeds', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_assign@test.com');
      const operator = await createTestUser(client, 'op_assign@test.com');
      const bizId = await createTestBusiness(client, 'Assign Biz', owner);
      await createMembership(client, bizId, operator, 'operator');
      const chanId = await createChannel(client, bizId);

      const msg = await ingestMessage(client, bizId, chanId, '+989120001111', 'Hi');

      await asUser(client, owner);
      const result = await assignConvo(client, msg.conversation_id, operator);

      expect(result.error).toBeUndefined();
      expect(result.assigned_to).toBe(operator);
      expect(result.status).toBe('assigned');
      expect(result.event_type).toBe('assigned');

      // Verify conversation state
      const convo = await client.query(
        `SELECT status, assigned_to FROM conversations WHERE id = $1`,
        [msg.conversation_id]
      );
      expect(convo.rows[0].status).toBe('assigned');
      expect(convo.rows[0].assigned_to).toBe(operator);
    });
  });

  it('assign conversation to user outside business fails', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_deny@test.com');
      const outsider = await createTestUser(client, 'outsider@test.com');
      const bizId = await createTestBusiness(client, 'Deny Biz', owner);
      const chanId = await createChannel(client, bizId);
      // outsider has NO membership

      const msg = await ingestMessage(client, bizId, chanId, '+989120002222', 'Hi');

      await asUser(client, owner);
      const result = await assignConvo(client, msg.conversation_id, outsider);

      expect(result.error).toBe('INVALID_OPERATOR');
    });
  });

  it('assign to inactive member fails', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_inactive@test.com');
      const inactive = await createTestUser(client, 'inactive_op@test.com');
      const bizId = await createTestBusiness(client, 'Inactive Biz', owner);
      // Create inactive membership
      await client.query(
        `INSERT INTO business_memberships (business_id, user_id, role, is_active)
         VALUES ($1, $2, 'operator', false)`,
        [bizId, inactive]
      );
      const chanId = await createChannel(client, bizId);

      const msg = await ingestMessage(client, bizId, chanId, '+989120003333', 'Hi');

      await asUser(client, owner);
      const result = await assignConvo(client, msg.conversation_id, inactive);

      expect(result.error).toBe('INVALID_OPERATOR');
    });
  });

  it('unassign conversation succeeds', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_unassign@test.com');
      const operator = await createTestUser(client, 'op_unassign@test.com');
      const bizId = await createTestBusiness(client, 'Unassign Biz', owner);
      await createMembership(client, bizId, operator, 'operator');
      const chanId = await createChannel(client, bizId);

      const msg = await ingestMessage(client, bizId, chanId, '+989120004444', 'Hi');

      await asUser(client, owner);
      await assignConvo(client, msg.conversation_id, operator);
      const result = await unassignConvo(client, msg.conversation_id);

      expect(result.error).toBeUndefined();
      expect(result.status).toBe('open');
      expect(result.event_type).toBe('unassigned');
    });
  });

  it('transfer conversation succeeds', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_transfer@test.com');
      const op1 = await createTestUser(client, 'op1_transfer@test.com');
      const op2 = await createTestUser(client, 'op2_transfer@test.com');
      const bizId = await createTestBusiness(client, 'Transfer Biz', owner);
      await createMembership(client, bizId, op1, 'operator');
      await createMembership(client, bizId, op2, 'operator');
      const chanId = await createChannel(client, bizId);

      const msg = await ingestMessage(client, bizId, chanId, '+989120005555', 'Hi');

      await asUser(client, owner);
      await assignConvo(client, msg.conversation_id, op1);
      const result = await transferConvo(client, msg.conversation_id, op2, 'Shift change');

      expect(result.error).toBeUndefined();
      expect(result.assigned_to).toBe(op2);
      expect(result.event_type).toBe('transferred');

      // Verify handoff history
      await asServiceRole(client);
      const events = await client.query(
        `SELECT event_type, to_owner_id, reason FROM handoff_events
         WHERE conversation_id = $1 ORDER BY created_at, id`,
        [msg.conversation_id]
      );
      expect(events.rows.length).toBe(2); // assigned + transferred
      const eventTypes = events.rows.map((r: { event_type: string }) => r.event_type);
      expect(eventTypes).toContain('assigned');
      expect(eventTypes).toContain('transferred');
      const transferEvent = events.rows.find((r: { event_type: string }) => r.event_type === 'transferred');
      expect(transferEvent.reason).toBe('Shift change');
    });
  });

  // ─────────────────────────────────────────────────────────
  // OPERATOR REPLY TESTS
  // ─────────────────────────────────────────────────────────

  it('assigned operator can reply', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_reply@test.com');
      const operator = await createTestUser(client, 'op_reply@test.com');
      const bizId = await createTestBusiness(client, 'Reply Biz', owner);
      await createMembership(client, bizId, operator, 'operator');
      const chanId = await createChannel(client, bizId);

      const msg = await ingestMessage(client, bizId, chanId, '+989120006666', 'Help');

      // Assign then reply
      await asUser(client, owner);
      await assignConvo(client, msg.conversation_id, operator);

      await asUser(client, operator);
      const result = await operatorReply(client, msg.conversation_id, 'How can I help?');

      expect(result.error).toBeUndefined();
      expect(result.message_id).toBeDefined();
      expect(result.delivery_status).toBe('queued');

      // Verify message in DB
      await asServiceRole(client);
      const msgRow = await client.query(
        `SELECT * FROM messages WHERE id = $1`, [result.message_id]
      );
      expect(msgRow.rows[0].direction).toBe('outbound');
      expect(msgRow.rows[0].sender_type).toBe('operator');
      expect(msgRow.rows[0].sender_id).toBe(operator);
      expect(msgRow.rows[0].delivery_status).toBe('queued');
    });
  });

  it('unassigned operator cannot reply', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_noreply@test.com');
      const operator = await createTestUser(client, 'op_noreply@test.com');
      const bizId = await createTestBusiness(client, 'NoReply Biz', owner);
      await createMembership(client, bizId, operator, 'operator');
      const chanId = await createChannel(client, bizId);

      const msg = await ingestMessage(client, bizId, chanId, '+989120007777', 'Help');

      // operator tries to reply without being assigned
      await asUser(client, operator);
      const result = await operatorReply(client, msg.conversation_id, 'Unauthorized reply');

      expect(result.error).toBe('NOT_ASSIGNED_TO_YOU');
    });
  });

  it('business owner can reply (owner bypass)', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_bypass@test.com');
      const bizId = await createTestBusiness(client, 'Owner Reply Biz', owner);
      const chanId = await createChannel(client, bizId);

      const msg = await ingestMessage(client, bizId, chanId, '+989120008888', 'Help');

      // Owner replies without formal assignment
      await asUser(client, owner);
      const result = await operatorReply(client, msg.conversation_id, 'Owner here to help');

      expect(result.error).toBeUndefined();
      expect(result.message_id).toBeDefined();
      expect(result.delivery_status).toBe('queued');

      // Owner should be auto-assigned
      const convo = await client.query(
        `SELECT assigned_to, status FROM conversations WHERE id = $1`,
        [msg.conversation_id]
      );
      expect(convo.rows[0].assigned_to).toBe(owner);
      expect(convo.rows[0].status).toBe('assigned');
    });
  });

  it('reply to closed conversation is denied', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_closed@test.com');
      const bizId = await createTestBusiness(client, 'Closed Biz', owner);
      const chanId = await createChannel(client, bizId);

      const msg = await ingestMessage(client, bizId, chanId, '+989120009999', 'Help');

      // Close the conversation
      await client.query(
        `UPDATE conversations SET status = 'closed', closed_at = now() WHERE id = $1`,
        [msg.conversation_id]
      );

      await asUser(client, owner);
      const result = await operatorReply(client, msg.conversation_id, 'Too late');

      expect(result.error).toBe('CONVERSATION_CLOSED');
    });
  });

  it('cross-tenant reply is denied', async () => {
    await withRollback(async (client) => {
      const ownerA = await createTestUser(client, 'ownerA_xtenant@test.com');
      const ownerB = await createTestUser(client, 'ownerB_xtenant@test.com');
      const bizA = await createTestBusiness(client, 'XTenant A', ownerA);
      const bizB = await createTestBusiness(client, 'XTenant B', ownerB);
      const chanA = await createChannel(client, bizA);

      const msg = await ingestMessage(client, bizA, chanA, '+989121110000', 'Help');

      // Owner B tries to reply to Biz A conversation
      await asUser(client, ownerB);
      const result = await operatorReply(client, msg.conversation_id, 'Cross-tenant attack');

      expect(result.error).toBe('PERMISSION_DENIED');
    });
  });

  // ─────────────────────────────────────────────────────────
  // INBOX + DETAIL INTEGRATION
  // ─────────────────────────────────────────────────────────

  it('inbox shows latest outbound message after reply', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_inbox@test.com');
      const bizId = await createTestBusiness(client, 'Inbox Reply Biz', owner);
      const chanId = await createChannel(client, bizId);

      await ingestMessage(client, bizId, chanId, '+989122220000', 'Customer msg');

      await asUser(client, owner);

      // Get convo id from inbox
      const inboxBefore = await client.query(
        `SELECT get_inbox_list($1) as result`, [bizId]
      );
      const convoId = inboxBefore.rows[0].result.conversations[0].id;

      // Owner replies
      await operatorReply(client, convoId, 'Thanks for reaching out!');

      // Check inbox shows latest outbound message
      const inboxAfter = await client.query(
        `SELECT get_inbox_list($1) as result`, [bizId]
      );
      const lastMsg = inboxAfter.rows[0].result.conversations[0].last_message;
      expect(lastMsg.direction).toBe('outbound');
      expect(lastMsg.sender_type).toBe('operator');
      expect(lastMsg.content).toBe('Thanks for reaching out!');
    });
  });

  it('conversation detail shows inbound and outbound in correct order', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_detail@test.com');
      const bizId = await createTestBusiness(client, 'Detail Reply Biz', owner);
      const chanId = await createChannel(client, bizId);

      const msg = await ingestMessage(client, bizId, chanId, '+989123330000', 'Hello');

      await asUser(client, owner);
      await operatorReply(client, msg.conversation_id, 'Hi there!');

      const detail = await client.query(
        `SELECT get_conversation_detail($1) as result`, [msg.conversation_id]
      );
      const messages = detail.rows[0].result.messages;

      expect(messages.length).toBe(2);
      expect(messages[0].direction).toBe('inbound');
      expect(messages[0].sender_type).toBe('customer');
      expect(messages[0].content).toBe('Hello');
      expect(messages[1].direction).toBe('outbound');
      expect(messages[1].sender_type).toBe('operator');
      expect(messages[1].content).toBe('Hi there!');
      expect(messages[1].delivery_status).toBe('queued');

      // message_total should be 2
      expect(detail.rows[0].result.message_total).toBe(2);
    });
  });

  // ─────────────────────────────────────────────────────────
  // AUDIT
  // ─────────────────────────────────────────────────────────

  it('audit logs created for assignment and reply', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, 'owner_audit@test.com');
      const operator = await createTestUser(client, 'op_audit@test.com');
      const bizId = await createTestBusiness(client, 'Audit Biz', owner);
      await createMembership(client, bizId, operator, 'operator');
      const chanId = await createChannel(client, bizId);

      const msg = await ingestMessage(client, bizId, chanId, '+989124440000', 'Help');

      await asUser(client, owner);
      await assignConvo(client, msg.conversation_id, operator);

      await asUser(client, operator);
      await operatorReply(client, msg.conversation_id, 'On it!');

      // Check audit logs
      await asServiceRole(client);
      const logs = await client.query(
        `SELECT action, user_id, entity_type FROM audit_log
         WHERE entity_id = $1 AND action IN (
           'conversation_assigned', 'operator_reply',
           'conversation_auto_created', 'customer_auto_created'
         )
         ORDER BY created_at`,
        [msg.conversation_id]
      );

      const actions = logs.rows.map((r: { action: string }) => r.action);
      expect(actions).toContain('conversation_auto_created');
      expect(actions).toContain('conversation_assigned');
      expect(actions).toContain('operator_reply');

      // Assignment audit should show the owner as actor
      const assignLog = logs.rows.find((r: { action: string }) => r.action === 'conversation_assigned');
      expect(assignLog.user_id).toBe(owner);

      // Reply audit should show the operator as actor
      const replyLog = logs.rows.find((r: { action: string }) => r.action === 'operator_reply');
      expect(replyLog.user_id).toBe(operator);
    });
  });
});
