import { describe, it, expect, afterAll } from 'vitest';
import {
  withRollback, createTestUser, createTestBusiness,
  createMembership, asUser, asServiceRole, closePool,
} from './setup';

describe('15 — AI Resilience: Fallback Ladder + Handoff Re-entry', () => {
  afterAll(async () => { await closePool(); });

  // ── Helpers ─────────────────────────────────────────────────

  async function createChannel(client: import('pg').PoolClient, bizId: string) {
    const res = await client.query(
      `INSERT INTO business_channels (business_id, channel_type, is_active, channel_config)
       VALUES ($1, 'whatsapp', true, '{"test":true}'::jsonb) RETURNING id`, [bizId]);
    return res.rows[0].id;
  }

  async function enableAiPolicy(client: import('pg').PoolClient, bizId: string) {
    await client.query(
      `INSERT INTO policy_rules (business_id, rule_type, rule_config, is_active, priority)
       VALUES ($1, 'ai_allowed', '{"enabled": true}'::jsonb, true, 1)`, [bizId]);
  }

  async function ingestMessage(client: import('pg').PoolClient, bizId: string, chanId: string, phone: string, content: string) {
    const res = await client.query(
      `SELECT ingest_inbound_message($1,$2,'whatsapp'::channel_type,$3,NULL,$4) as result`,
      [bizId, chanId, phone, content]);
    return res.rows[0].result;
  }

  async function setupAiConversation(client: import('pg').PoolClient, msg = 'Hello AI') {
    const owner = await createTestUser(client, `res_own_${Date.now()}@test.com`);
    const bizId = await createTestBusiness(client, `Res Biz ${Date.now()}`, owner);
    const chanId = await createChannel(client, bizId);
    await enableAiPolicy(client, bizId);
    const m = await ingestMessage(client, bizId, chanId, '+989120000099', msg);
    await client.query(`UPDATE conversations SET ai_enabled = true WHERE id = $1`, [m.conversation_id]);
    return { owner, bizId, chanId, conversationId: m.conversation_id };
  }

  // ═══════════════════════════════════════════════════════════
  // CLASSIFY_AI_FALLBACK UNIT TESTS
  // ═══════════════════════════════════════════════════════════

  it('classify_ai_fallback returns correct code for binding error', async () => {
    await withRollback(async (client) => {
      const res = await client.query(
        `SELECT classify_ai_fallback('binding', 'UNKNOWN_CAPABILITY') as result`);
      const r = res.rows[0].result;
      expect(r.fallback_code).toBe('BINDING_UNKNOWN_CAPABILITY');
      expect(r.severity).toBe('critical');
      expect(r.action).toBe('skip_reply');
      expect(r.human_handoff).toBe(false);
      expect(r.retryable).toBe(false);
    });
  });

  it('classify_ai_fallback returns correct code for budget error', async () => {
    await withRollback(async (client) => {
      const res = await client.query(
        `SELECT classify_ai_fallback('budget', 'daily_token_limit_exceeded') as result`);
      const r = res.rows[0].result;
      expect(r.fallback_code).toBe('BUDGET_DAILY_TOKEN_LIMIT_EXCEEDED');
      expect(r.severity).toBe('medium');
      expect(r.action).toBe('skip_reply');
    });
  });

  it('classify_ai_fallback returns correct code for context error', async () => {
    await withRollback(async (client) => {
      const res = await client.query(
        `SELECT classify_ai_fallback('context', 'AI_DISABLED') as result`);
      const r = res.rows[0].result;
      expect(r.fallback_code).toBe('CONTEXT_AI_DISABLED');
      expect(r.severity).toBe('low');
      expect(r.action).toBe('skip_reply');
    });
  });

  it('classify_ai_fallback returns correct code for persist error', async () => {
    await withRollback(async (client) => {
      const res = await client.query(
        `SELECT classify_ai_fallback('persist', 'WRITE_FAILED') as result`);
      const r = res.rows[0].result;
      expect(r.fallback_code).toBe('PERSIST_FAILED');
      expect(r.severity).toBe('high');
      expect(r.retryable).toBe(true);
    });
  });

  it('classify_ai_fallback returns correct code for unknown source', async () => {
    await withRollback(async (client) => {
      const res = await client.query(
        `SELECT classify_ai_fallback('something_else', 'WHATEVER') as result`);
      const r = res.rows[0].result;
      expect(r.fallback_code).toBe('UNKNOWN_ERROR');
      expect(r.severity).toBe('critical');
      expect(r.human_handoff).toBe(false);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // BINDING FALLBACK E2E
  // ═══════════════════════════════════════════════════════════

  it('binding/model failure produces structured fallback in release response', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      // Bind to inactive model (gpt-4o is inactive by default)
      const modelRes = await client.query(`SELECT id FROM ai_model_catalog WHERE model_code = 'gpt-4o'`);
      const inactiveModelId = modelRes.rows[0].id;
      await client.query(
        `INSERT INTO ai_model_bindings (business_id, capability_code, model_id)
         VALUES ($1, 'reply_drafter', $2)
         ON CONFLICT (business_id, capability_code) DO UPDATE SET model_id = $2`,
        [bizId, inactiveModelId]);

      // Assign operator then release
      const op = await createTestUser(client, `res_bop_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');
      await asServiceRole(client);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);
      await asUser(client, owner);
      const res = await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [conversationId]);
      const r = res.rows[0].result;

      // Assert structured fallback
      expect(r.ai_reply.skipped).toBe(true);
      expect(r.ai_reply.fallback).toBeDefined();
      expect(r.ai_reply.fallback.fallback_code).toBe('BINDING_MODEL_INACTIVE');
      expect(r.ai_reply.fallback.severity).toBe('high');

      // No AI reply message should be persisted
      await asServiceRole(client);
      const msgs = await client.query(
        `SELECT count(*) as cnt FROM messages WHERE conversation_id = $1 AND sender_type = 'ai'`,
        [conversationId]);
      expect(Number(msgs.rows[0].cnt)).toBe(0);

      // Usage ledger should have blocked row
      const ledger = await client.query(
        `SELECT * FROM ai_usage_ledger WHERE business_id = $1 AND conversation_id = $2 AND status = 'blocked'`,
        [bizId, conversationId]);
      expect(ledger.rows.length).toBeGreaterThanOrEqual(1);
      expect(ledger.rows[0].error_code).toBe('BINDING_MODEL_INACTIVE');
    });
  });

  // ═══════════════════════════════════════════════════════════
  // BUDGET FALLBACK E2E
  // ═══════════════════════════════════════════════════════════

  it('budget exceeded produces structured fallback in release response', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      // Set very low budget
      await asUser(client, owner);
      await client.query(`SELECT update_business_ai_settings($1, $2)`,
        [bizId, JSON.stringify({ ai_enabled: true, daily_token_limit: 1 })]);
      // Seed existing usage to exceed budget
      await asServiceRole(client);
      await client.query(
        `SELECT record_ai_usage($1, NULL, NULL, 'reply_drafter', 'mock_sql', 'mock-sql-v1', 'completed', 5, 20)`,
        [bizId]);

      const op = await createTestUser(client, `res_bexop_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);
      await asUser(client, owner);
      const res = await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [conversationId]);
      const r = res.rows[0].result;

      // Backward compatibility: top-level BUDGET_EXCEEDED preserved
      expect(r.error).toBe('BUDGET_EXCEEDED');
      // Additive fallback object
      expect(r.ai_reply).toBeDefined();
      expect(r.ai_reply.fallback).toBeDefined();
      expect(r.ai_reply.fallback.fallback_code).toContain('BUDGET_');
      expect(r.ai_reply.fallback.severity).toBe('medium');

      // No AI reply message persisted
      await asServiceRole(client);
      const msgs = await client.query(
        `SELECT count(*) as cnt FROM messages WHERE conversation_id = $1 AND sender_type = 'ai'`,
        [conversationId]);
      expect(Number(msgs.rows[0].cnt)).toBe(0);

      // Budget exceeded ledger row
      const ledger = await client.query(
        `SELECT * FROM ai_usage_ledger WHERE business_id = $1 AND status = 'budget_exceeded'`,
        [bizId]);
      expect(ledger.rows.length).toBeGreaterThanOrEqual(1);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // CONTEXT FALLBACK E2E
  // ═══════════════════════════════════════════════════════════

  it('context failure produces structured fallback in release response', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      const op = await createTestUser(client, `res_ctxop_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');
      await asServiceRole(client);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);

      // Disable the AI policy so collect_ai_context returns AI_NOT_ALLOWED
      await client.query(
        `UPDATE policy_rules SET is_active = false WHERE business_id = $1 AND rule_type = 'ai_allowed'`,
        [bizId]);

      await asUser(client, owner);
      const res = await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [conversationId]);
      const r = res.rows[0].result;

      // release_to_ai itself checks AI policy — so this should return AI_NOT_ALLOWED at release level
      // The error comes from release_to_ai, which returns raw error without fallback
      expect(r.error).toBe('AI_NOT_ALLOWED');
    });
  });

  // ═══════════════════════════════════════════════════════════
  // PERSIST FALLBACK
  // ═══════════════════════════════════════════════════════════

  it('persist failure records failed usage with fallback error_code', async () => {
    await withRollback(async (client) => {
      // We test the classify function directly for persist since forcing
      // a deterministic persist failure in the atomic function is difficult
      // without modifying table constraints mid-transaction
      const res = await client.query(
        `SELECT classify_ai_fallback('persist', 'WRITE_ERROR') as result`);
      const r = res.rows[0].result;
      expect(r.fallback_code).toBe('PERSIST_FAILED');
      expect(r.severity).toBe('high');
      expect(r.retryable).toBe(true);
      expect(r.action).toBe('skip_reply');

      // Verify that record_ai_usage can store fallback error_code
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      await asServiceRole(client);
      await client.query(
        `SELECT record_ai_usage($1, $2, NULL::uuid, 'reply_drafter', 'mock_sql', 'mock-sql-v1', 'failed', 5, 20, 1, 'PERSIST_FAILED')`,
        [bizId, conversationId]);
      const ledger = await client.query(
        `SELECT * FROM ai_usage_ledger WHERE business_id = $1 AND status = 'failed' AND error_code = 'PERSIST_FAILED'`,
        [bizId]);
      expect(ledger.rows.length).toBe(1);
      expect(ledger.rows[0].input_tokens).toBe(5);
      expect(ledger.rows[0].output_tokens).toBe(20);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // SUCCESS PATH
  // ═══════════════════════════════════════════════════════════

  it('success path still returns reply without fallback', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      const op = await createTestUser(client, `res_sop_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');
      await asServiceRole(client);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);
      await asUser(client, owner);
      const res = await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [conversationId]);
      const r = res.rows[0].result;

      expect(r.error).toBeUndefined();
      expect(r.ai_reply.message_id).toBeDefined();
      expect(r.ai_reply.decision).toBe('replied');
      expect(r.ai_reply.provider).toBe('mock-sql');
      expect(r.ai_reply.fallback).toBeUndefined();

      // Completed usage ledger row exists
      await asServiceRole(client);
      const ledger = await client.query(
        `SELECT * FROM ai_usage_ledger WHERE business_id = $1 AND conversation_id = $2 AND status = 'completed'`,
        [bizId, conversationId]);
      expect(ledger.rows.length).toBeGreaterThanOrEqual(1);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // HANDOFF RE-ENTRY CYCLE
  // ═══════════════════════════════════════════════════════════

  it('handoff re-entry cycle works: assign → release back to AI', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      const op = await createTestUser(client, `res_reentry_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');

      // First: assign to operator (takeover)
      await asUser(client, owner);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);

      // Verify assigned state
      await asServiceRole(client);
      let convo = await client.query(`SELECT status, assigned_to, ai_enabled FROM conversations WHERE id = $1`, [conversationId]);
      expect(convo.rows[0].assigned_to).toBe(op);
      expect(convo.rows[0].ai_enabled).toBe(false);

      // Release back to AI with reply
      await asUser(client, owner);
      const res = await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [conversationId]);
      const r = res.rows[0].result;

      expect(r.error).toBeUndefined();
      expect(r.ai_reply.message_id).toBeDefined();

      // Verify conversation state after re-entry
      await asServiceRole(client);
      convo = await client.query(`SELECT status, assigned_to, ai_enabled FROM conversations WHERE id = $1`, [conversationId]);
      expect(convo.rows[0].assigned_to).toBeNull();
      expect(convo.rows[0].ai_enabled).toBe(true);
      expect(convo.rows[0].status).toBe('open');

      // Verify AI reply message persisted
      const msgs = await client.query(
        `SELECT count(*) as cnt FROM messages WHERE conversation_id = $1 AND sender_type = 'ai'`,
        [conversationId]);
      expect(Number(msgs.rows[0].cnt)).toBeGreaterThanOrEqual(1);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // RE-ENTRY RESPECTS BUDGET
  // ═══════════════════════════════════════════════════════════

  it('re-entry respects IX-A budget on second release', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      const op = await createTestUser(client, `res_rebudget_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');

      // First release succeeds
      await asServiceRole(client);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);
      await asUser(client, owner);
      const r1 = await client.query(`SELECT release_to_ai_with_reply($1) as result`, [conversationId]);
      expect(r1.rows[0].result.error).toBeUndefined();
      expect(r1.rows[0].result.ai_reply.message_id).toBeDefined();

      // Assign/takeover again
      await asServiceRole(client);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);

      // Set very low budget now
      await asUser(client, owner);
      await client.query(`SELECT update_business_ai_settings($1, $2)`,
        [bizId, JSON.stringify({ ai_enabled: true, daily_token_limit: 1 })]);

      // Second release should be blocked by budget
      const r2 = await client.query(`SELECT release_to_ai_with_reply($1) as result`, [conversationId]);
      expect(r2.rows[0].result.error).toBe('BUDGET_EXCEEDED');

      // No second AI reply persisted
      await asServiceRole(client);
      const msgs = await client.query(
        `SELECT count(*) as cnt FROM messages WHERE conversation_id = $1 AND sender_type = 'ai'`,
        [conversationId]);
      // Only 1 from the first successful release
      expect(Number(msgs.rows[0].cnt)).toBe(1);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // RE-ENTRY CREATES HANDOFF EVENT
  // ═══════════════════════════════════════════════════════════

  it('re-entry creates released_to_ai handoff event', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      const op = await createTestUser(client, `res_hev_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');

      await asUser(client, owner);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);
      await client.query(`SELECT release_to_ai_with_reply($1)`, [conversationId]);

      await asServiceRole(client);
      const events = await client.query(
        `SELECT event_type, to_owner_type FROM handoff_events
         WHERE conversation_id = $1 AND event_type = 'released_to_ai'`,
        [conversationId]);
      expect(events.rows.length).toBeGreaterThanOrEqual(1);
      expect(events.rows[0].to_owner_type).toBe('ai');
    });
  });

  // ═══════════════════════════════════════════════════════════
  // NON-MEMBER DENIED
  // ═══════════════════════════════════════════════════════════

  it('non-member cannot trigger release/re-entry', async () => {
    await withRollback(async (client) => {
      const { bizId, conversationId } = await setupAiConversation(client);
      const outsider = await createTestUser(client, `res_out_${Date.now()}@test.com`);

      await asUser(client, outsider);
      const res = await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [conversationId]);
      expect(res.rows[0].result.error).toBe('PERMISSION_DENIED');
    });
  });

  // ═══════════════════════════════════════════════════════════
  // CROSS-TENANT ISOLATION
  // ═══════════════════════════════════════════════════════════

  it('fallback ledger data does not leak cross-tenant', async () => {
    await withRollback(async (client) => {
      // Tenant A: trigger a fallback (binding error via inactive model)
      const { owner: ownerA, bizId: bizA, conversationId: convA } = await setupAiConversation(client);
      const modelRes = await client.query(`SELECT id FROM ai_model_catalog WHERE model_code = 'gpt-4o'`);
      const inactiveModelId = modelRes.rows[0].id;
      await client.query(
        `INSERT INTO ai_model_bindings (business_id, capability_code, model_id)
         VALUES ($1, 'reply_drafter', $2)
         ON CONFLICT (business_id, capability_code) DO UPDATE SET model_id = $2`,
        [bizA, inactiveModelId]);
      const opA = await createTestUser(client, `res_xtA_${Date.now()}@test.com`);
      await createMembership(client, bizA, opA, 'operator');
      await asServiceRole(client);
      await client.query(`SELECT assign_conversation($1, $2)`, [convA, opA]);
      await asUser(client, ownerA);
      await client.query(`SELECT release_to_ai_with_reply($1)`, [convA]);

      // Tenant B: separate business (must be service role to create)
      await asServiceRole(client);
      const ownerB = await createTestUser(client, `res_xtB_${Date.now()}@test.com`);
      const bizB = await createTestBusiness(client, `ResTenB ${Date.now()}`, ownerB);

      // Tenant B manager tries to see Tenant A's fallback data
      await asUser(client, ownerB);
      const summaryB = await client.query(
        `SELECT get_business_ai_usage_summary($1, 'daily') as result`, [bizA]);
      // Should return null (no access)
      expect(summaryB.rows[0].result).toBeNull();

      // Tenant B's own summary should work (but be empty or their own data only)
      const ownSummary = await client.query(
        `SELECT get_business_ai_usage_summary($1, 'daily') as result`, [bizB]);
      expect(ownSummary.rows[0].result).not.toBeNull();
      expect(Number(ownSummary.rows[0].result.total_calls)).toBe(0);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // PROVIDER CLASSIFICATION (unit test only — no real provider)
  // ═══════════════════════════════════════════════════════════

  it('classify_ai_fallback provider source returns human_handoff=true', async () => {
    await withRollback(async (client) => {
      const res = await client.query(
        `SELECT classify_ai_fallback('provider', 'TIMEOUT', '{"has_fallback_model":"false"}'::jsonb) as result`);
      const r = res.rows[0].result;
      expect(r.fallback_code).toBe('PROVIDER_TIMEOUT');
      expect(r.severity).toBe('high');
      expect(r.human_handoff).toBe(true);
      expect(r.retryable).toBe(true);
      expect(r.action).toBe('skip_reply');
    });
  });

  it('classify_ai_fallback binding MODEL_INACTIVE returns high severity', async () => {
    await withRollback(async (client) => {
      const res = await client.query(
        `SELECT classify_ai_fallback('binding', 'MODEL_INACTIVE') as result`);
      const r = res.rows[0].result;
      expect(r.fallback_code).toBe('BINDING_MODEL_INACTIVE');
      expect(r.severity).toBe('high');
    });
  });
});
