import { describe, it, expect, afterAll } from 'vitest';
import {
  withRollback, createTestUser, createTestBusiness,
  createMembership, asUser, asServiceRole, closePool,
} from './setup';
import { AiReplyService } from '../../src/domains/ai_runtime/service';
import { MockAiProvider } from '../../src/domains/ai_runtime/mock-provider';

const mockProvider = new MockAiProvider();
const aiService = new AiReplyService(mockProvider);

describe('10 — AI Reply + Handoff Control', () => {
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

  async function enableAiPolicy(client: import('pg').PoolClient, bizId: string) {
    await client.query(
      `INSERT INTO policy_rules (business_id, rule_type, rule_config, is_active, priority)
       VALUES ($1, 'ai_allowed', '{"enabled": true}'::jsonb, true, 1)`,
      [bizId]
    );
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

  /** Setup an AI-enabled conversation ready for AI processing */
  async function setupAiConversation(
    client: import('pg').PoolClient,
    customerMsg: string = 'Hello AI'
  ) {
    const owner = await createTestUser(client, `ai_owner_${Date.now()}@test.com`);
    const bizId = await createTestBusiness(client, `AI Biz ${Date.now()}`, owner);
    const chanId = await createChannel(client, bizId);
    await enableAiPolicy(client, bizId);

    const msg = await ingestMessage(client, bizId, chanId, '+989121234567', customerMsg);

    // Enable AI on the conversation
    await client.query(
      `UPDATE conversations SET ai_enabled = true WHERE id = $1`,
      [msg.conversation_id]
    );

    return { owner, bizId, chanId, conversationId: msg.conversation_id };
  }

  // ─────────────────────────────────────────────────────────
  // AI REPLY TESTS
  // ─────────────────────────────────────────────────────────

  it('AI can reply to unassigned AI-enabled conversation', async () => {
    await withRollback(async (client) => {
      const { conversationId } = await setupAiConversation(client, 'What is your menu?');

      const result = await aiService.processConversation(client, conversationId);

      expect(result.decision).toBe('replied');
      expect(result.message_id).toBeDefined();
      expect(result.delivery_status).toBe('queued');
    });
  });

  it('AI cannot reply when operator owns conversation', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client, 'Hello');
      const operator = await createTestUser(client, `op_ai_block_${Date.now()}@test.com`);
      await createMembership(client, bizId, operator, 'operator');

      // Assign to operator
      await asUser(client, owner);
      await client.query(
        `SELECT assign_conversation($1, $2)`, [conversationId, operator]
      );
      await asServiceRole(client);

      const result = await aiService.processConversation(client, conversationId);

      expect(result.decision).toBe('blocked');
      expect(result.reason_code).toBe('operator_owned');
    });
  });

  it('AI cannot reply to closed conversation', async () => {
    await withRollback(async (client) => {
      const { conversationId } = await setupAiConversation(client, 'Hello');

      await client.query(
        `UPDATE conversations SET status = 'closed', closed_at = now() WHERE id = $1`,
        [conversationId]
      );

      const result = await aiService.processConversation(client, conversationId);

      expect(result.decision).toBe('blocked');
      expect(result.reason_code).toBe('conversation_closed');
    });
  });

  it('AI cannot reply when ai_enabled=false', async () => {
    await withRollback(async (client) => {
      const { conversationId } = await setupAiConversation(client, 'Hello');

      // Disable AI on conversation
      await client.query(
        `UPDATE conversations SET ai_enabled = false WHERE id = $1`,
        [conversationId]
      );

      const result = await aiService.processConversation(client, conversationId);

      expect(result.decision).toBe('blocked');
      expect(result.reason_code).toBe('ai_disabled');
    });
  });

  // ─────────────────────────────────────────────────────────
  // AI MESSAGE PERSISTENCE
  // ─────────────────────────────────────────────────────────

  it('AI reply creates outbound message with sender_type=ai', async () => {
    await withRollback(async (client) => {
      const { conversationId } = await setupAiConversation(client, 'Tell me about prices');

      const result = await aiService.processConversation(client, conversationId);
      expect(result.decision).toBe('replied');

      // Check message
      const msgRes = await client.query(
        `SELECT direction, sender_type, delivery_status, content
         FROM messages WHERE id = $1`,
        [result.message_id]
      );
      expect(msgRes.rows[0].direction).toBe('outbound');
      expect(msgRes.rows[0].sender_type).toBe('ai');
      expect(msgRes.rows[0].delivery_status).toBe('queued');
      expect(msgRes.rows[0].content).toContain('[AI]');
    });
  });

  it('inbox latest message updates after AI reply', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client, 'Help me');

      await aiService.processConversation(client, conversationId);

      await asUser(client, owner);
      const inbox = await client.query(
        `SELECT get_inbox_list($1) as result`, [bizId]
      );
      const lastMsg = inbox.rows[0].result.conversations[0].last_message;
      expect(lastMsg.direction).toBe('outbound');
      expect(lastMsg.sender_type).toBe('ai');
    });
  });

  it('conversation detail shows AI message in correct order', async () => {
    await withRollback(async (client) => {
      const { owner, conversationId } = await setupAiConversation(client, 'What are your hours?');

      await aiService.processConversation(client, conversationId);

      await asUser(client, owner);
      const detail = await client.query(
        `SELECT get_conversation_detail($1) as result`, [conversationId]
      );
      const messages = detail.rows[0].result.messages;

      expect(messages.length).toBe(2);
      expect(messages[0].direction).toBe('inbound');
      expect(messages[0].sender_type).toBe('customer');
      expect(messages[1].direction).toBe('outbound');
      expect(messages[1].sender_type).toBe('ai');
      expect(messages[1].delivery_status).toBe('queued');
    });
  });

  // ─────────────────────────────────────────────────────────
  // AI HANDOFF
  // ─────────────────────────────────────────────────────────

  it('AI handoff creates handoff event and does not send message', async () => {
    await withRollback(async (client) => {
      const { conversationId } = await setupAiConversation(client, 'I need handoff please');

      const result = await aiService.processConversation(client, conversationId);

      expect(result.decision).toBe('handoff');
      expect(result.reason_code).toBe('customer_requested_human');
      expect(result.message_id).toBeUndefined();

      // Verify handoff event exists
      const events = await client.query(
        `SELECT event_type, from_owner_type, reason
         FROM handoff_events WHERE conversation_id = $1
         AND event_type = 'handoff_requested'`,
        [conversationId]
      );
      expect(events.rows.length).toBe(1);
      expect(events.rows[0].from_owner_type).toBe('ai');

      // Verify conversation state
      const convo = await client.query(
        `SELECT status, ai_enabled FROM conversations WHERE id = $1`,
        [conversationId]
      );
      expect(convo.rows[0].status).toBe('waiting');
      expect(convo.rows[0].ai_enabled).toBe(false);

      // No outbound AI message should exist
      const outbound = await client.query(
        `SELECT count(*) as cnt FROM messages
         WHERE conversation_id = $1 AND sender_type = 'ai'`,
        [conversationId]
      );
      expect(Number(outbound.rows[0].cnt)).toBe(0);
    });
  });

  // ─────────────────────────────────────────────────────────
  // AI BLOCKED
  // ─────────────────────────────────────────────────────────

  it('AI blocked decision is logged in interaction logs', async () => {
    await withRollback(async (client) => {
      const { conversationId } = await setupAiConversation(client, 'block this content');

      const result = await aiService.processConversation(client, conversationId);

      expect(result.decision).toBe('blocked');
      expect(result.reason_code).toBe('unsafe_content');

      // Check AI interaction log
      const logs = await client.query(
        `SELECT decision, reason_code, provider_name
         FROM ai_interaction_logs WHERE conversation_id = $1
         ORDER BY created_at DESC LIMIT 1`,
        [conversationId]
      );
      expect(logs.rows[0].decision).toBe('blocked');
      expect(logs.rows[0].reason_code).toBe('unsafe_content');
      expect(logs.rows[0].provider_name).toBe('mock');
    });
  });

  // ─────────────────────────────────────────────────────────
  // RELEASE TO AI
  // ─────────────────────────────────────────────────────────

  it('release-to-AI updates ownership/history', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client, 'Hi');
      const operator = await createTestUser(client, `op_release_${Date.now()}@test.com`);
      await createMembership(client, bizId, operator, 'operator');

      // Assign to operator first
      await asUser(client, owner);
      await client.query(
        `SELECT assign_conversation($1, $2)`, [conversationId, operator]
      );

      // Now release back to AI
      const result = await client.query(
        `SELECT release_to_ai($1) as result`, [conversationId]
      );
      const releaseResult = result.rows[0].result;

      expect(releaseResult.error).toBeUndefined();
      expect(releaseResult.ai_enabled).toBe(true);
      expect(releaseResult.status).toBe('open');
      expect(releaseResult.event_type).toBe('released_to_ai');

      // Verify conversation state
      await asServiceRole(client);
      const convo = await client.query(
        `SELECT status, assigned_to, ai_enabled FROM conversations WHERE id = $1`,
        [conversationId]
      );
      expect(convo.rows[0].status).toBe('open');
      expect(convo.rows[0].assigned_to).toBeNull();
      expect(convo.rows[0].ai_enabled).toBe(true);

      // Verify handoff event
      const events = await client.query(
        `SELECT event_type, to_owner_type FROM handoff_events
         WHERE conversation_id = $1 AND event_type = 'released_to_ai'`,
        [conversationId]
      );
      expect(events.rows.length).toBe(1);
      expect(events.rows[0].to_owner_type).toBe('ai');
    });
  });

  it('unauthorized release-to-AI is denied', async () => {
    await withRollback(async (client) => {
      const { bizId, conversationId } = await setupAiConversation(client, 'Hi');
      const viewer = await createTestUser(client, `viewer_release_${Date.now()}@test.com`);
      await createMembership(client, bizId, viewer, 'viewer');

      // Viewer cannot release to AI (lacks conversation:assign)
      await asUser(client, viewer);
      const result = await client.query(
        `SELECT release_to_ai($1) as result`, [conversationId]
      );

      expect(result.rows[0].result.error).toBe('PERMISSION_DENIED');
    });
  });

  // ─────────────────────────────────────────────────────────
  // AI INTERACTION LOGS
  // ─────────────────────────────────────────────────────────

  it('AI interaction log created for reply', async () => {
    await withRollback(async (client) => {
      const { conversationId } = await setupAiConversation(client, 'What do you serve?');

      const result = await aiService.processConversation(client, conversationId);
      expect(result.decision).toBe('replied');

      const logs = await client.query(
        `SELECT decision, provider_name, model_used, message_id,
                prompt_tokens, completion_tokens
         FROM ai_interaction_logs WHERE conversation_id = $1`,
        [conversationId]
      );
      expect(logs.rows.length).toBe(1);
      expect(logs.rows[0].decision).toBe('replied');
      expect(logs.rows[0].provider_name).toBe('mock');
      expect(logs.rows[0].model_used).toBe('mock-v1');
      expect(logs.rows[0].message_id).toBe(result.message_id);
      expect(logs.rows[0].prompt_tokens).toBe(15);
      expect(logs.rows[0].completion_tokens).toBe(25);
    });
  });

  it('AI interaction log created for handoff', async () => {
    await withRollback(async (client) => {
      const { conversationId } = await setupAiConversation(client, 'I want handoff now');

      await aiService.processConversation(client, conversationId);

      const logs = await client.query(
        `SELECT decision, reason_code, provider_name
         FROM ai_interaction_logs WHERE conversation_id = $1`,
        [conversationId]
      );
      expect(logs.rows.length).toBe(1);
      expect(logs.rows[0].decision).toBe('handoff');
      expect(logs.rows[0].reason_code).toBe('customer_requested_human');
      expect(logs.rows[0].provider_name).toBe('mock');
    });
  });

  // ─────────────────────────────────────────────────────────
  // MESSAGE WINDOW PROCESSED
  // ─────────────────────────────────────────────────────────

  it('message window can be marked as processed', async () => {
    await withRollback(async (client) => {
      const { conversationId } = await setupAiConversation(client, 'Test window');

      // Get the window created by ingest
      const windowRes = await client.query(
        `SELECT id FROM message_windows WHERE conversation_id = $1 LIMIT 1`,
        [conversationId]
      );
      const windowId = windowRes.rows[0].id;

      // Mark as processed
      await client.query(
        `UPDATE message_windows SET processed = true, processed_at = now()
         WHERE id = $1`,
        [windowId]
      );

      // Verify
      const updated = await client.query(
        `SELECT processed, processed_at FROM message_windows WHERE id = $1`,
        [windowId]
      );
      expect(updated.rows[0].processed).toBe(true);
      expect(updated.rows[0].processed_at).toBeDefined();
    });
  });
});
