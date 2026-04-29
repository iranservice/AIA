import { describe, it, expect, afterAll } from 'vitest';
import {
  withRollback, createTestUser, createTestBusiness, asUser, closePool,
} from './setup';
import { validateInboundPayload } from '../../src/domains/channels/ingest';

describe('08 — Messaging & Inbox Core', () => {
  afterAll(async () => { await closePool(); });

  // ── Helper: create a test channel for a business ──────────
  async function createTestChannel(
    client: import('pg').PoolClient,
    businessId: string,
    channelType: string = 'whatsapp'
  ): Promise<string> {
    const res = await client.query(
      `INSERT INTO business_channels (business_id, channel_type, is_active, channel_config)
       VALUES ($1, $2, true, '{"test": true}'::jsonb)
       RETURNING id`,
      [businessId, channelType]
    );
    return res.rows[0].id;
  }

  // ── Helper: call ingest_inbound_message RPC ───────────────
  async function ingestMessage(
    client: import('pg').PoolClient,
    params: {
      business_id: string;
      channel_id: string;
      channel_type?: string;
      sender_identifier: string;
      sender_name?: string;
      content?: string;
      content_type?: string;
      external_message_id?: string;
      raw_payload?: object;
    }
  ) {
    const res = await client.query(
      `SELECT ingest_inbound_message(
        p_business_id := $1,
        p_channel_id := $2,
        p_channel_type := $3::channel_type,
        p_sender_identifier := $4,
        p_sender_name := $5,
        p_content := $6,
        p_content_type := $7::message_content_type,
        p_external_message_id := $8,
        p_raw_payload := $9::jsonb
      ) as result`,
      [
        params.business_id,
        params.channel_id,
        params.channel_type ?? 'whatsapp',
        params.sender_identifier,
        params.sender_name ?? null,
        params.content ?? 'Hello',
        params.content_type ?? 'text',
        params.external_message_id ?? null,
        JSON.stringify(params.raw_payload ?? { test: true }),
      ]
    );
    return res.rows[0].result;
  }

  // ─────────────────────────────────────────────────────────
  // TEST 1: Inbound message creates customer
  // ─────────────────────────────────────────────────────────
  it('should create a customer from an inbound message', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'inbox1@test.com');
      const bizId = await createTestBusiness(client, 'Inbox Biz 1', userId);
      const chanId = await createTestChannel(client, bizId);

      const result = await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989121234567',
        sender_name: 'Ali',
        content: 'Hello, I need help',
      });

      expect(result.is_new_customer).toBe(true);
      expect(result.customer_id).toBeDefined();
      expect(result.conversation_id).toBeDefined();
      expect(result.message_id).toBeDefined();
      expect(result.is_duplicate).toBe(false);

      // Verify customer exists in DB
      const custRes = await client.query(
        `SELECT * FROM customers WHERE id = $1`, [result.customer_id]
      );
      expect(custRes.rows.length).toBe(1);
      expect(custRes.rows[0].business_id).toBe(bizId);
    });
  });

  // ─────────────────────────────────────────────────────────
  // TEST 2: Inbound message creates conversation
  // ─────────────────────────────────────────────────────────
  it('should create a conversation from an inbound message', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'inbox2@test.com');
      const bizId = await createTestBusiness(client, 'Inbox Biz 2', userId);
      const chanId = await createTestChannel(client, bizId);

      const result = await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989129999999',
        content: 'First message',
      });

      expect(result.is_new_conversation).toBe(true);

      // Verify conversation
      const convoRes = await client.query(
        `SELECT * FROM conversations WHERE id = $1`, [result.conversation_id]
      );
      expect(convoRes.rows.length).toBe(1);
      expect(convoRes.rows[0].business_id).toBe(bizId);
      expect(convoRes.rows[0].status).toBe('open');
      expect(convoRes.rows[0].message_count).toBe(1);
    });
  });

  // ─────────────────────────────────────────────────────────
  // TEST 3: Second message reuses customer
  // ─────────────────────────────────────────────────────────
  it('should reuse customer for second message from same identity', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'inbox3@test.com');
      const bizId = await createTestBusiness(client, 'Inbox Biz 3', userId);
      const chanId = await createTestChannel(client, bizId);

      const r1 = await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989121111111',
        content: 'First msg',
      });

      const r2 = await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989121111111',
        content: 'Second msg',
      });

      expect(r1.customer_id).toBe(r2.customer_id);
      expect(r2.is_new_customer).toBe(false);
    });
  });

  // ─────────────────────────────────────────────────────────
  // TEST 4: Second message reuses open conversation
  // ─────────────────────────────────────────────────────────
  it('should reuse open conversation for second message', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'inbox4@test.com');
      const bizId = await createTestBusiness(client, 'Inbox Biz 4', userId);
      const chanId = await createTestChannel(client, bizId);

      const r1 = await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989122222222',
        content: 'First',
      });

      const r2 = await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989122222222',
        content: 'Second',
      });

      expect(r1.conversation_id).toBe(r2.conversation_id);
      expect(r2.is_new_conversation).toBe(false);

      // Message count should be 2
      const convoRes = await client.query(
        `SELECT message_count FROM conversations WHERE id = $1`,
        [r1.conversation_id]
      );
      expect(convoRes.rows[0].message_count).toBe(2);
    });
  });

  // ─────────────────────────────────────────────────────────
  // TEST 5: Duplicate external_message_id is deduped
  // ─────────────────────────────────────────────────────────
  it('should not duplicate message when external_message_id matches', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'inbox5@test.com');
      const bizId = await createTestBusiness(client, 'Inbox Biz 5', userId);
      const chanId = await createTestChannel(client, bizId);

      const r1 = await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989123333333',
        content: 'Hello!',
        external_message_id: 'ext-msg-001',
      });

      expect(r1.is_duplicate).toBe(false);

      const r2 = await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989123333333',
        content: 'Hello!',
        external_message_id: 'ext-msg-001',
      });

      expect(r2.is_duplicate).toBe(true);
      expect(r2.message_id).toBe(r1.message_id);

      // Only 1 message in DB
      const msgCount = await client.query(
        `SELECT count(*) as cnt FROM messages WHERE conversation_id = $1`,
        [r1.conversation_id]
      );
      expect(Number(msgCount.rows[0].cnt)).toBe(1);
    });
  });

  // ─────────────────────────────────────────────────────────
  // TEST 6: Cross-tenant inbox access denied
  // ─────────────────────────────────────────────────────────
  it('should deny cross-tenant inbox access via RLS', async () => {
    await withRollback(async (client) => {
      const userA = await createTestUser(client, 'inbox6a@test.com');
      const userB = await createTestUser(client, 'inbox6b@test.com');
      const bizA = await createTestBusiness(client, 'Inbox Biz A', userA);
      const bizB = await createTestBusiness(client, 'Inbox Biz B', userB);
      const chanA = await createTestChannel(client, bizA);

      // Ingest message into Business A
      await ingestMessage(client, {
        business_id: bizA,
        channel_id: chanA,
        sender_identifier: '+989124444444',
        content: 'Biz A message',
      });

      // User B tries to query Business A inbox
      await asUser(client, userB);

      const inboxRes = await client.query(
        `SELECT get_inbox_list($1) as result`, [bizA]
      );
      const inbox = inboxRes.rows[0].result;

      // Should get empty — RLS denies cross-tenant
      expect(inbox.conversations.length).toBe(0);
      expect(inbox.total).toBe(0);
    });
  });

  // ─────────────────────────────────────────────────────────
  // TEST 7: Malformed payload handled cleanly
  // ─────────────────────────────────────────────────────────
  it('should handle malformed payload with structured error', async () => {
    // TypeScript-level validation
    const errors = validateInboundPayload({});
    expect(errors.length).toBeGreaterThanOrEqual(4);
    expect(errors.map(e => e.field)).toContain('business_id');
    expect(errors.map(e => e.field)).toContain('channel_id');
    expect(errors.map(e => e.field)).toContain('channel_type');
    expect(errors.map(e => e.field)).toContain('sender_identifier');
  });

  it('should return error for non-existent channel', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'inbox7@test.com');
      const bizId = await createTestBusiness(client, 'Inbox Biz 7', userId);

      const result = await ingestMessage(client, {
        business_id: bizId,
        channel_id: '00000000-0000-0000-0000-000000000099',
        sender_identifier: '+989125555555',
        content: 'Test',
      });

      expect(result.error).toBe('CHANNEL_NOT_FOUND');
    });
  });

  // ─────────────────────────────────────────────────────────
  // TEST 8: Integration log created
  // ─────────────────────────────────────────────────────────
  it('should create integration log for inbound message', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'inbox8@test.com');
      const bizId = await createTestBusiness(client, 'Inbox Biz 8', userId);
      const chanId = await createTestChannel(client, bizId);

      await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989126666666',
        content: 'Logged message',
        raw_payload: { webhook: 'test', timestamp: '2026-01-01' },
      });

      const logRes = await client.query(
        `SELECT * FROM integration_logs
         WHERE business_id = $1 AND direction = 'inbound'
         ORDER BY created_at DESC LIMIT 1`,
        [bizId]
      );
      expect(logRes.rows.length).toBe(1);
      expect(logRes.rows[0].processed).toBe(true);
      expect(logRes.rows[0].sender_identifier).toBe('+989126666666');
      expect(logRes.rows[0].request_payload).toEqual({ webhook: 'test', timestamp: '2026-01-01' });
      expect(logRes.rows[0].response_payload).toBeDefined();
    });
  });

  // ─────────────────────────────────────────────────────────
  // TEST 9: Message window created or updated
  // ─────────────────────────────────────────────────────────
  it('should create message window and extend on second message', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'inbox9@test.com');
      const bizId = await createTestBusiness(client, 'Inbox Biz 9', userId);
      const chanId = await createTestChannel(client, bizId);

      const r1 = await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989127777777',
        content: 'Window test 1',
      });

      // Window should be created
      expect(r1.window_id).toBeDefined();

      const w1 = await client.query(
        `SELECT * FROM message_windows WHERE id = $1`, [r1.window_id]
      );
      expect(w1.rows.length).toBe(1);
      expect(w1.rows[0].message_count).toBe(1);

      // Second message should extend window (within 15s)
      const r2 = await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989127777777',
        content: 'Window test 2',
      });

      // Same window should be extended
      const w2 = await client.query(
        `SELECT * FROM message_windows WHERE id = $1`, [r1.window_id]
      );
      expect(w2.rows[0].message_count).toBe(2);
    });
  });

  // ─────────────────────────────────────────────────────────
  // TEST 10: Conversation detail returns ordered messages
  // ─────────────────────────────────────────────────────────
  it('should return ordered messages in conversation detail', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'inbox10@test.com');
      const bizId = await createTestBusiness(client, 'Inbox Biz 10', userId);
      const chanId = await createTestChannel(client, bizId);

      // Ingest 3 messages
      const r1 = await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989128888888',
        content: 'Message 1',
      });
      await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989128888888',
        content: 'Message 2',
      });
      await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989128888888',
        content: 'Message 3',
      });

      // Query conversation detail — must be authenticated as business member
      await asUser(client, userId);

      const detailRes = await client.query(
        `SELECT get_conversation_detail($1) as result`,
        [r1.conversation_id]
      );
      const detail = detailRes.rows[0].result;

      // Conversation metadata
      expect(detail.conversation.id).toBe(r1.conversation_id);
      expect(detail.conversation.business_id).toBe(bizId);
      expect(detail.conversation.status).toBe('open');

      // Customer
      expect(detail.customer.id).toBe(r1.customer_id);

      // Messages ordered ASC (oldest first)
      expect(detail.messages.length).toBe(3);
      expect(detail.messages[0].content).toBe('Message 1');
      expect(detail.messages[1].content).toBe('Message 2');
      expect(detail.messages[2].content).toBe('Message 3');
      expect(detail.message_total).toBe(3);

      // Verify ordering
      const t1 = new Date(detail.messages[0].created_at).getTime();
      const t2 = new Date(detail.messages[1].created_at).getTime();
      const t3 = new Date(detail.messages[2].created_at).getTime();
      expect(t1).toBeLessThanOrEqual(t2);
      expect(t2).toBeLessThanOrEqual(t3);
    });
  });

  // ─────────────────────────────────────────────────────────
  // TEST 11: Inbox list returns correct summaries
  // ─────────────────────────────────────────────────────────
  it('should return correct inbox list summaries', async () => {
    await withRollback(async (client) => {
      const userId = await createTestUser(client, 'inbox11@test.com');
      const bizId = await createTestBusiness(client, 'Inbox Biz 11', userId);
      const chanId = await createTestChannel(client, bizId);

      // Create 2 conversations from different senders
      await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989130001111',
        sender_name: 'Customer A',
        content: 'Hello from A',
      });
      await ingestMessage(client, {
        business_id: bizId,
        channel_id: chanId,
        sender_identifier: '+989130002222',
        sender_name: 'Customer B',
        content: 'Hello from B',
      });

      // Query inbox as the business owner
      await asUser(client, userId);

      const inboxRes = await client.query(
        `SELECT get_inbox_list($1) as result`, [bizId]
      );
      const inbox = inboxRes.rows[0].result;

      expect(inbox.total).toBe(2);
      expect(inbox.conversations.length).toBe(2);

      // Most recent first
      const first = inbox.conversations[0];
      expect(first.customer).toBeDefined();
      expect(first.last_message).toBeDefined();
      expect(first.last_message.content).toBeDefined();
      expect(first.unread_count).toBeGreaterThanOrEqual(1);
      expect(first.status).toBe('open');
    });
  });
});
