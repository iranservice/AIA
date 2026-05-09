import { describe, it, expect, afterAll } from 'vitest';
import {
  withRollback, createTestUser, createTestBusiness,
  createMembership, asUser, asServiceRole, closePool,
} from './setup';

describe('14 — AI Token/Cost Governance + Capability Router', () => {
  afterAll(async () => { await closePool(); });

  // ── Helpers ──────────────────────────────────────────────
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
    const owner = await createTestUser(client, `gov_own_${Date.now()}@test.com`);
    const bizId = await createTestBusiness(client, `Gov Biz ${Date.now()}`, owner);
    const chanId = await createChannel(client, bizId);
    await enableAiPolicy(client, bizId);
    const m = await ingestMessage(client, bizId, chanId, '+989120000001', msg);
    await client.query(`UPDATE conversations SET ai_enabled = true WHERE id = $1`, [m.conversation_id]);
    return { owner, bizId, chanId, conversationId: m.conversation_id };
  }

  // ── 1. Default capabilities exist ──────────────────────
  it('default capabilities exist after migration', async () => {
    await withRollback(async (client) => {
      const res = await client.query(`SELECT code FROM ai_capability_registry ORDER BY code`);
      expect(res.rows.length).toBeGreaterThanOrEqual(7);
      const codes = res.rows.map((r: any) => r.code);
      expect(codes).toContain('reply_drafter');
      expect(codes).toContain('intent_classifier');
      expect(codes).toContain('translator');
    });
  });

  // ── 2. mock-sql-v1 model exists ────────────────────────
  it('mock-sql-v1 model exists and is active', async () => {
    await withRollback(async (client) => {
      const res = await client.query(
        `SELECT * FROM ai_model_catalog WHERE model_code = 'mock-sql-v1'`);
      expect(res.rows.length).toBe(1);
      expect(res.rows[0].is_active).toBe(true);
      expect(res.rows[0].provider_mode).toBe('mock_sql');
    });
  });

  // ── 3. Default binding resolves ────────────────────────
  it('default reply_drafter binding resolves for business', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, `bind_${Date.now()}@test.com`);
      const bizId = await createTestBusiness(client, `Bind Biz ${Date.now()}`, owner);
      const res = await client.query(
        `SELECT resolve_ai_capability_binding($1, 'reply_drafter') as result`, [bizId]);
      const r = res.rows[0].result;
      expect(r.error).toBeUndefined();
      expect(r.model_code).toBe('mock-sql-v1');
      expect(r.provider_mode).toBe('mock_sql');
    });
  });

  // ── 4. Owner can read usage summary ────────────────────
  it('owner can read usage summary', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, `usum_own_${Date.now()}@test.com`);
      const bizId = await createTestBusiness(client, `USumBiz ${Date.now()}`, owner);
      await asServiceRole(client);
      await client.query(
        `SELECT record_ai_usage($1, NULL, NULL, 'reply_drafter', 'mock_sql', 'mock-sql-v1', 'completed', 5, 20)`,
        [bizId]);
      await asUser(client, owner);
      const res = await client.query(
        `SELECT get_business_ai_usage_summary($1, 'daily') as result`, [bizId]);
      expect(res.rows[0].result).not.toBeNull();
      expect(Number(res.rows[0].result.total_tokens)).toBe(25);
    });
  });

  // ── 5. Manager can read usage summary ──────────────────
  it('manager can read usage summary', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, `usum_mown_${Date.now()}@test.com`);
      const bizId = await createTestBusiness(client, `USumMBiz ${Date.now()}`, owner);
      const mgr = await createTestUser(client, `usum_mgr_${Date.now()}@test.com`);
      await createMembership(client, bizId, mgr, 'manager');
      await asUser(client, mgr);
      const res = await client.query(
        `SELECT get_business_ai_usage_summary($1, 'daily') as result`, [bizId]);
      expect(res.rows[0].result).not.toBeNull();
    });
  });

  // ── 6. Non-member denied usage summary ─────────────────
  it('non-member denied usage summary', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, `usum_nmown_${Date.now()}@test.com`);
      const bizId = await createTestBusiness(client, `USumNMBiz ${Date.now()}`, owner);
      const outsider = await createTestUser(client, `usum_out_${Date.now()}@test.com`);
      await asUser(client, outsider);
      const res = await client.query(
        `SELECT get_business_ai_usage_summary($1, 'daily') as result`, [bizId]);
      expect(res.rows[0].result).toBeNull();
    });
  });

  // ── 7. Operator denied usage summary ───────────────────
  it('operator cannot read usage summary', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, `usum_opown_${Date.now()}@test.com`);
      const bizId = await createTestBusiness(client, `USumOpBiz ${Date.now()}`, owner);
      const op = await createTestUser(client, `usum_op_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');
      await asUser(client, op);
      const res = await client.query(
        `SELECT get_business_ai_usage_summary($1, 'daily') as result`, [bizId]);
      expect(res.rows[0].result).toBeNull();
    });
  });

  // ── 8. Operator cannot update budget ───────────────────
  it('operator cannot update budget/model binding', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, `bud_opown_${Date.now()}@test.com`);
      const bizId = await createTestBusiness(client, `BudOpBiz ${Date.now()}`, owner);
      const op = await createTestUser(client, `bud_op_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');
      await asUser(client, op);
      const res = await client.query(
        `SELECT update_business_ai_settings($1, $2) as result`,
        [bizId, JSON.stringify({ ai_enabled: true, daily_token_limit: 1000 })]);
      expect(res.rows[0].result.error).toBe('PERMISSION_DENIED');
    });
  });

  // ── 9. Manager can update budget ───────────────────────
  it('manager can update budget policy', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, `bud_mown_${Date.now()}@test.com`);
      const bizId = await createTestBusiness(client, `BudMBiz ${Date.now()}`, owner);
      const mgr = await createTestUser(client, `bud_mgr_${Date.now()}@test.com`);
      await createMembership(client, bizId, mgr, 'manager');
      await asUser(client, mgr);
      const res = await client.query(
        `SELECT update_business_ai_settings($1, $2) as result`,
        [bizId, JSON.stringify({ ai_enabled: true, daily_token_limit: 5000, monthly_token_limit: 100000 })]);
      expect(res.rows[0].result.error).toBeUndefined();
      await asServiceRole(client);
      const pr = await client.query(
        `SELECT rule_config FROM policy_rules WHERE business_id = $1 AND rule_type = 'ai_budget'`, [bizId]);
      expect(pr.rows.length).toBe(1);
      expect(pr.rows[0].rule_config.daily_token_limit).toBe(5000);
    });
  });

  // ── 10. Budget exceeded blocks release ─────────────────
  it('budget exceeded blocks release_to_ai_with_reply', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, chanId, conversationId } = await setupAiConversation(client);
      await asUser(client, owner);
      await client.query(`SELECT update_business_ai_settings($1, $2)`,
        [bizId, JSON.stringify({ ai_enabled: true, daily_token_limit: 1 })]);
      await asServiceRole(client);
      await client.query(
        `SELECT record_ai_usage($1, NULL, NULL, 'reply_drafter', 'mock_sql', 'mock-sql-v1', 'completed', 5, 20)`,
        [bizId]);
      const op = await createTestUser(client, `bex_op_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);
      await asUser(client, owner);
      const res = await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [conversationId]);
      expect(res.rows[0].result.error).toBe('BUDGET_EXCEEDED');
    });
  });

  // ── 11. Budget allowed permits release ─────────────────
  it('budget allowed permits release_to_ai_with_reply', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      await asUser(client, owner);
      await client.query(`SELECT update_business_ai_settings($1, $2)`,
        [bizId, JSON.stringify({ ai_enabled: true, daily_token_limit: 999999 })]);
      const op = await createTestUser(client, `bal_op_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');
      await asServiceRole(client);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);
      await asUser(client, owner);
      const res = await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [conversationId]);
      const r = res.rows[0].result;
      expect(r.error).toBeUndefined();
      expect(r.ai_reply).toBeDefined();
      expect(r.ai_reply.provider).toBe('mock-sql');
    });
  });

  // ── 12. release records usage ledger entry ─────────────
  it('release_to_ai_with_reply records ai_usage_ledger entry', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      const op = await createTestUser(client, `rec_op_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');
      await asServiceRole(client);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);
      await asUser(client, owner);
      await client.query(`SELECT release_to_ai_with_reply($1)`, [conversationId]);
      await asServiceRole(client);
      const res = await client.query(
        `SELECT * FROM ai_usage_ledger WHERE business_id = $1 AND capability_code = 'reply_drafter'`, [bizId]);
      expect(res.rows.length).toBeGreaterThanOrEqual(1);
      const row = res.rows.find((r: any) => r.status === 'completed');
      expect(row).toBeDefined();
      expect(row.total_tokens).toBe(25);
      expect(row.model_code).toBe('mock-sql-v1');
    });
  });

  // ── 13. Usage summary aggregates correctly ─────────────
  it('usage summary aggregates correctly', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, `agg_own_${Date.now()}@test.com`);
      const bizId = await createTestBusiness(client, `AggBiz ${Date.now()}`, owner);
      await asServiceRole(client);
      await client.query(`SELECT record_ai_usage($1,NULL,NULL,'reply_drafter','mock_sql','mock-sql-v1','completed',10,30)`, [bizId]);
      await client.query(`SELECT record_ai_usage($1,NULL,NULL,'summarizer','mock_sql','mock-sql-v1','completed',5,15)`, [bizId]);
      await client.query(`SELECT record_ai_usage($1,NULL,NULL,'reply_drafter','mock_sql','mock-sql-v1','budget_exceeded',0,0)`, [bizId]);
      await asUser(client, owner);
      const res = await client.query(`SELECT get_business_ai_usage_summary($1,'daily') as result`, [bizId]);
      const r = res.rows[0].result;
      expect(Number(r.total_tokens)).toBe(60);
      expect(Number(r.total_calls)).toBe(3);
      expect(Number(r.completed_calls)).toBe(2);
    });
  });

  // ── 14. Unknown capability rejected ────────────────────
  it('unknown capability code is rejected', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, `unk_${Date.now()}@test.com`);
      const bizId = await createTestBusiness(client, `UnkBiz ${Date.now()}`, owner);
      const res = await client.query(
        `SELECT resolve_ai_capability_binding($1, 'nonexistent_capability') as result`, [bizId]);
      expect(res.rows[0].result.error).toBe('UNKNOWN_CAPABILITY');
    });
  });

  // ── 15. Inactive model cannot be bound ─────────────────
  it('inactive model cannot be used in binding resolution', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, `inact_${Date.now()}@test.com`);
      const bizId = await createTestBusiness(client, `InactBiz ${Date.now()}`, owner);
      const modelRes = await client.query(`SELECT id FROM ai_model_catalog WHERE model_code = 'gpt-4o'`);
      const inactiveModelId = modelRes.rows[0].id;
      await client.query(
        `INSERT INTO ai_model_bindings (business_id, capability_code, model_id)
         VALUES ($1, 'reply_drafter', $2)
         ON CONFLICT (business_id, capability_code) DO UPDATE SET model_id = $2`,
        [bizId, inactiveModelId]);
      const res = await client.query(
        `SELECT resolve_ai_capability_binding($1, 'reply_drafter') as result`, [bizId]);
      expect(res.rows[0].result.error).toBe('MODEL_INACTIVE');
    });
  });

  // ── 16. No secret columns in new tables ────────────────
  it('no API key/secret/password columns in new AI governance tables', async () => {
    await withRollback(async (client) => {
      const res = await client.query(`
        SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name IN ('ai_capability_registry','ai_model_catalog','ai_model_bindings','ai_usage_ledger')
          AND column_name IN ('api_key','secret','password','openai_api_key','anthropic_api_key','credentials','token')
      `);
      expect(res.rows.length).toBe(0);
    });
  });

  // ── 17. Per-conversation token limit blocks release ────
  it('per_conversation_token_limit blocks release_to_ai_with_reply', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      await asUser(client, owner);
      // Set high daily limit but very low per-conversation limit
      await client.query(`SELECT update_business_ai_settings($1, $2)`,
        [bizId, JSON.stringify({ ai_enabled: true, daily_token_limit: 999999, per_conversation_token_limit: 10 })]);
      // Seed existing usage for this conversation to exceed limit
      await asServiceRole(client);
      await client.query(
        `SELECT record_ai_usage($1, $2, NULL, 'reply_drafter', 'mock_sql', 'mock-sql-v1', 'completed', 5, 20)`,
        [bizId, conversationId]);
      // Assign so release works
      const op = await createTestUser(client, `pcl_op_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);
      await asUser(client, owner);
      const res = await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [conversationId]);
      expect(res.rows[0].result.error).toBe('BUDGET_EXCEEDED');
      expect(res.rows[0].result.reason).toBe('per_conversation_token_limit_exceeded');
      // Verify budget_exceeded usage row recorded
      await asServiceRole(client);
      const ledger = await client.query(
        `SELECT * FROM ai_usage_ledger WHERE business_id = $1 AND conversation_id = $2 AND status = 'budget_exceeded'`,
        [bizId, conversationId]);
      expect(ledger.rows.length).toBeGreaterThanOrEqual(1);
    });
  });

  // ── 18. Per-conversation limit does not affect other conversations
  it('per_conversation_token_limit does not bleed into another conversation', async () => {
    await withRollback(async (client) => {
      const owner = await createTestUser(client, `pcl2_own_${Date.now()}@test.com`);
      const bizId = await createTestBusiness(client, `PCL2Biz ${Date.now()}`, owner);
      const chanId = await createChannel(client, bizId);
      await enableAiPolicy(client, bizId);
      // Set per-conversation limit
      await asUser(client, owner);
      await client.query(`SELECT update_business_ai_settings($1, $2)`,
        [bizId, JSON.stringify({ ai_enabled: true, daily_token_limit: 999999, per_conversation_token_limit: 50 })]);
      // Ingest conversation A and seed heavy usage on it
      await asServiceRole(client);
      const mA = await ingestMessage(client, bizId, chanId, '+989120000010', 'Conv A msg');
      await client.query(`UPDATE conversations SET ai_enabled = true WHERE id = $1`, [mA.conversation_id]);
      await client.query(
        `SELECT record_ai_usage($1, $2, NULL, 'reply_drafter', 'mock_sql', 'mock-sql-v1', 'completed', 50, 50)`,
        [bizId, mA.conversation_id]);
      // Ingest conversation B (fresh, no usage)
      const mB = await ingestMessage(client, bizId, chanId, '+989120000020', 'Conv B msg');
      await client.query(`UPDATE conversations SET ai_enabled = true WHERE id = $1`, [mB.conversation_id]);
      // Assign & release conversation B — should succeed
      const op = await createTestUser(client, `pcl2_op_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');
      await client.query(`SELECT assign_conversation($1, $2)`, [mB.conversation_id, op]);
      await asUser(client, owner);
      const res = await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [mB.conversation_id]);
      const r = res.rows[0].result;
      expect(r.error).toBeUndefined();
      expect(r.ai_reply).toBeDefined();
      expect(r.ai_reply.provider).toBe('mock-sql');
    });
  });
});
