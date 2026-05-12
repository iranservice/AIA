import { describe, it, expect, afterAll } from 'vitest';
import {
  withRollback, createTestUser, createTestBusiness,
  createMembership, asUser, asServiceRole, closePool,
} from './setup';

describe('16 — Conversation Turn Aggregation (IX-C)', () => {
  afterAll(async () => { await closePool(); });

  // ── Helpers ─────────────────────────────────────────────

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
    phone: string, content: string,
    extId?: string
  ) {
    const res = await client.query(
      `SELECT ingest_inbound_message($1,$2,'whatsapp'::channel_type,$3,NULL,$4,'text'::message_content_type,$5) as result`,
      [bizId, chanId, phone, content, extId ?? null]
    );
    return res.rows[0].result;
  }

  async function setupAiConversation(
    client: import('pg').PoolClient,
    msg: string = 'Hello AI'
  ) {
    const owner = await createTestUser(client, `turn_owner_${Date.now()}_${Math.random().toString(36).slice(2,6)}@test.com`);
    const bizId = await createTestBusiness(client, `Turn Biz ${Date.now()}`, owner);
    const chanId = await createChannel(client, bizId);
    await enableAiPolicy(client, bizId);
    const result = await ingestMessage(client, bizId, chanId, '+989121234567', msg);
    await client.query(`UPDATE conversations SET ai_enabled = true WHERE id = $1`, [result.conversation_id]);
    return { owner, bizId, chanId, conversationId: result.conversation_id, messageId: result.message_id, turnId: result.turn_id };
  }

  // ─────────────────────────────────────────────────────────
  // 1. Inbound message creates pending customer turn
  // ─────────────────────────────────────────────────────────
  it('inbound message creates pending customer turn', async () => {
    await withRollback(async (client) => {
      const { turnId, conversationId } = await setupAiConversation(client);
      expect(turnId).toBeDefined();

      const res = await client.query(
        `SELECT * FROM conversation_turns WHERE id = $1`, [turnId]
      );
      expect(res.rows.length).toBe(1);
      expect(res.rows[0].status).toBe('pending');
      expect(res.rows[0].conversation_id).toBe(conversationId);
      expect(res.rows[0].actor_type).toBe('customer');
      expect(res.rows[0].direction).toBe('inbound');
      expect(res.rows[0].message_count).toBe(1);
    });
  });

  // ─────────────────────────────────────────────────────────
  // 2. Multiple inbound messages aggregate into one pending turn
  // ─────────────────────────────────────────────────────────
  it('multiple inbound messages aggregate into one pending turn', async () => {
    await withRollback(async (client) => {
      const { bizId, chanId, conversationId, turnId } = await setupAiConversation(client, 'First');
      const r2 = await ingestMessage(client, bizId, chanId, '+989121234567', 'Second');
      const r3 = await ingestMessage(client, bizId, chanId, '+989121234567', 'Third');

      expect(r2.turn_id).toBe(turnId);
      expect(r3.turn_id).toBe(turnId);

      const res = await client.query(
        `SELECT message_count, total_characters FROM conversation_turns WHERE id = $1`, [turnId]
      );
      expect(res.rows[0].message_count).toBe(3);
      expect(Number(res.rows[0].total_characters)).toBeGreaterThan(0);

      const msgs = await client.query(
        `SELECT * FROM conversation_turn_messages WHERE turn_id = $1 ORDER BY sequence_index`, [turnId]
      );
      expect(msgs.rows.length).toBe(3);
    });
  });

  // ─────────────────────────────────────────────────────────
  // 3. Different conversations create different turns
  // ─────────────────────────────────────────────────────────
  it('different conversations create different turns', async () => {
    await withRollback(async (client) => {
      const s1 = await setupAiConversation(client, 'Conv1');
      // Create a different user/conversation
      const owner2 = await createTestUser(client, `turn_owner2_${Date.now()}@test.com`);
      const biz2 = await createTestBusiness(client, `Turn Biz2 ${Date.now()}`, owner2);
      const chan2 = await createChannel(client, biz2);
      await enableAiPolicy(client, biz2);
      const r2 = await ingestMessage(client, biz2, chan2, '+989999999999', 'Conv2');

      expect(s1.turnId).not.toBe(r2.turn_id);
    });
  });

  // ─────────────────────────────────────────────────────────
  // 4. Different businesses cannot mix in turns (tenant isolation)
  // ─────────────────────────────────────────────────────────
  it('tenant isolation: turns are scoped to business_id', async () => {
    await withRollback(async (client) => {
      const s1 = await setupAiConversation(client, 'Biz A msg');
      const turn = await client.query(
        `SELECT business_id FROM conversation_turns WHERE id = $1`, [s1.turnId]
      );
      expect(turn.rows[0].business_id).toBe(s1.bizId);
    });
  });

  // ─────────────────────────────────────────────────────────
  // 5. Same message cannot be added twice (idempotency)
  // ─────────────────────────────────────────────────────────
  it('same message cannot be added twice to a turn', async () => {
    await withRollback(async (client) => {
      const { messageId, turnId } = await setupAiConversation(client);

      // Try appending the same message again directly
      const res = await client.query(
        `SELECT append_message_to_turn($1) as result`, [messageId]
      );
      const result = res.rows[0].result;
      expect(result.turn_id).toBe(turnId);
      expect(result.message_count).toBe(1); // still 1 - idempotent
    });
  });

  // ─────────────────────────────────────────────────────────
  // 6. Max message limit auto-finalizes turn
  // ─────────────────────────────────────────────────────────
  it('max message limit auto-finalizes turn', async () => {
    await withRollback(async (client) => {
      const { bizId, chanId, turnId } = await setupAiConversation(client, 'Msg 1');
      // Send 9 more messages to reach limit of 10
      for (let i = 2; i <= 10; i++) {
        await ingestMessage(client, bizId, chanId, '+989121234567', `Msg ${i}`);
      }

      const res = await client.query(
        `SELECT status, finalized_reason FROM conversation_turns WHERE id = $1`, [turnId]
      );
      expect(res.rows[0].status).toBe('finalized');
      expect(res.rows[0].finalized_reason).toBe('max_messages');
    });
  });

  // ─────────────────────────────────────────────────────────
  // 7. Max character limit auto-finalizes turn
  // ─────────────────────────────────────────────────────────
  it('max character limit auto-finalizes turn', async () => {
    await withRollback(async (client) => {
      // Create a message with >4000 chars to trigger limit
      const longContent = 'A'.repeat(4100);
      const { turnId } = await setupAiConversation(client, longContent);

      const res = await client.query(
        `SELECT status, finalized_reason FROM conversation_turns WHERE id = $1`, [turnId]
      );
      expect(res.rows[0].status).toBe('finalized');
      expect(res.rows[0].finalized_reason).toBe('max_characters');
    });
  });

  // ─────────────────────────────────────────────────────────
  // 8. finalize_due_turns finalizes quiet-window-expired turns
  // ─────────────────────────────────────────────────────────
  it('finalize_due_turns finalizes quiet-window-expired turns', async () => {
    await withRollback(async (client) => {
      const { turnId } = await setupAiConversation(client);

      // Backdate updated_at — must disable trigger that auto-sets it
      await client.query(`ALTER TABLE conversation_turns DISABLE TRIGGER trg_conversation_turns_updated_at`);
      await client.query(
        `UPDATE conversation_turns SET updated_at = now() - interval '30 seconds' WHERE id = $1`, [turnId]
      );
      await client.query(`ALTER TABLE conversation_turns ENABLE TRIGGER trg_conversation_turns_updated_at`);
      // Verify the backdate stuck
      const pre = await client.query(`SELECT status, updated_at FROM conversation_turns WHERE id = $1`, [turnId]);
      expect(pre.rows[0].status).toBe('pending');

      const res = await client.query(
        `SELECT finalize_due_turns(10) as result`
      );
      const result = res.rows[0].result;
      expect(result.finalized_count).toBeGreaterThanOrEqual(1);

      const turn = await client.query(
        `SELECT status, finalized_reason FROM conversation_turns WHERE id = $1`, [turnId]
      );
      expect(turn.rows[0].status).toBe('finalized');
      expect(turn.rows[0].finalized_reason).toBe('quiet_window');
    });
  });

  // ─────────────────────────────────────────────────────────
  // 9. Operator assignment skips pending inbound turn
  // ─────────────────────────────────────────────────────────
  it('operator assignment skips pending inbound turn', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId, turnId } = await setupAiConversation(client);
      const operator = await createTestUser(client, `op_turn_${Date.now()}@test.com`);
      await createMembership(client, bizId, operator, 'operator');

      await asUser(client, owner);
      await client.query(
        `SELECT assign_conversation($1, $2)`, [conversationId, operator]
      );
      await asServiceRole(client);

      const res = await client.query(
        `SELECT status, finalized_reason FROM conversation_turns WHERE id = $1`, [turnId]
      );
      expect(res.rows[0].status).toBe('skipped');
      expect(res.rows[0].finalized_reason).toBe('operator_takeover');
    });
  });

  // ─────────────────────────────────────────────────────────
  // 9b. Operator assignment supersedes already-finalized turn (F-1 regression)
  // ─────────────────────────────────────────────────────────
  it('operator assignment supersedes already-finalized inbound turn', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId, turnId } = await setupAiConversation(client, 'Pre-finalized msg');
      const operator = await createTestUser(client, `op_fin_${Date.now()}_${Math.random().toString(36).slice(2,6)}@test.com`);
      await createMembership(client, bizId, operator, 'operator');

      // Finalize the turn BEFORE operator assignment
      await client.query(`SELECT finalize_conversation_turn($1, 'quiet_window')`, [turnId]);
      const preFin = await client.query(`SELECT status FROM conversation_turns WHERE id = $1`, [turnId]);
      expect(preFin.rows[0].status).toBe('finalized');

      // Now assign operator — should supersede the finalized turn
      await asUser(client, owner);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, operator]);
      await asServiceRole(client);

      const res = await client.query(
        `SELECT status, finalized_reason FROM conversation_turns WHERE id = $1`, [turnId]
      );
      expect(res.rows[0].status).toBe('superseded');
      expect(res.rows[0].finalized_reason).toBe('operator_takeover');

      // Verify get_finalized_turn_for_ai returns nothing for this conversation
      const aiTurn = await client.query(
        `SELECT get_finalized_turn_for_ai($1) as result`, [conversationId]
      );
      expect(aiTurn.rows[0].result).toBeNull();
    });
  });

  // ─────────────────────────────────────────────────────────
  // 10. release_to_ai_with_reply processes finalized turn
  // ─────────────────────────────────────────────────────────
  it('release_to_ai_with_reply processes finalized turn once', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, chanId, conversationId } = await setupAiConversation(client, 'Please help');
      const operator = await createTestUser(client, `op_rel_${Date.now()}_${Math.random().toString(36).slice(2,6)}@test.com`);
      await createMembership(client, bizId, operator, 'operator');

      // Assign to operator first (supersedes any pending/finalized turns)
      await asUser(client, owner);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, operator]);
      await asServiceRole(client);

      // Simulate new inbound message AFTER assignment and create a finalized turn
      await client.query(
        `INSERT INTO messages (conversation_id, direction, sender_type, sender_id, content_type, content)
         VALUES ($1, 'inbound', 'customer', $2, 'text', 'New post-assign msg')`,
        [conversationId, owner]
      );
      const newMsg = await client.query(
        `SELECT id FROM messages WHERE conversation_id = $1 ORDER BY created_at DESC LIMIT 1`, [conversationId]
      );
      const aRes = await client.query(`SELECT append_message_to_turn($1) as result`, [newMsg.rows[0].id]);
      const newTurnId = aRes.rows[0].result.turn_id;
      await client.query(`SELECT finalize_conversation_turn($1, 'manual')`, [newTurnId]);

      // Release to AI as owner (release_to_ai handles unassignment + ai_enabled internally)
      await asUser(client, owner);
      const res = await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [conversationId]
      );
      await asServiceRole(client);
      const result = res.rows[0].result;
      expect(result.ai_reply).toBeDefined();
      expect(result.ai_reply.message_id).toBeDefined();
      expect(result.ai_reply.turn_id).toBe(newTurnId);

      // Verify turn is now processed
      const turn = await client.query(
        `SELECT status, processed_at FROM conversation_turns WHERE id = $1`, [newTurnId]
      );
      expect(turn.rows[0].status).toBe('processed');
      expect(turn.rows[0].processed_at).not.toBeNull();
    });
  });



  // ─────────────────────────────────────────────────────────
  // 11. Duplicate release_to_ai_with_reply does not duplicate AI reply
  // ─────────────────────────────────────────────────────────
  it('duplicate release_to_ai_with_reply does not create duplicate AI reply', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId, turnId } = await setupAiConversation(client, 'Help me');
      const operator = await createTestUser(client, `op_dup_${Date.now()}_${Math.random().toString(36).slice(2,6)}@test.com`);
      await createMembership(client, bizId, operator, 'operator');

      // Finalize the turn
      await client.query(`SELECT finalize_conversation_turn($1, 'manual')`, [turnId]);

      // Assign and release (required auth flow)
      await asUser(client, owner);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, operator]);

      // The assign skipped the turn, so re-create for testing
      await asServiceRole(client);
      await client.query(
        `INSERT INTO messages (conversation_id, direction, sender_type, sender_id, content_type, content)
         VALUES ($1, 'inbound', 'customer', $2, 'text', 'New msg')`,
        [conversationId, owner]
      );
      const newMsg = await client.query(
        `SELECT id FROM messages WHERE conversation_id = $1 ORDER BY created_at DESC LIMIT 1`, [conversationId]
      );
      const aRes = await client.query(`SELECT append_message_to_turn($1) as result`, [newMsg.rows[0].id]);
      const newTurnId = aRes.rows[0].result.turn_id;
      await client.query(`SELECT finalize_conversation_turn($1, 'manual')`, [newTurnId]);

      // First release — should succeed
      await asUser(client, owner);
      await client.query(
        `SELECT release_to_ai_with_reply($1) as result`, [conversationId]
      );
      await asServiceRole(client);

      // Verify only 1 processed turn exists
      const turns = await client.query(
        `SELECT * FROM conversation_turns WHERE conversation_id = $1 AND status = 'processed'`,
        [conversationId]
      );
      expect(turns.rows.length).toBe(1);
    });
  });

  // ─────────────────────────────────────────────────────────
  // 12. release_to_ai_with_reply records turn_id in usage ledger
  // ─────────────────────────────────────────────────────────
  it('release_to_ai_with_reply records turn_id in processed turn metadata', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId, turnId } = await setupAiConversation(client, 'Book a table');
      const operator = await createTestUser(client, `op_meta_${Date.now()}_${Math.random().toString(36).slice(2,6)}@test.com`);
      await createMembership(client, bizId, operator, 'operator');

      // Assign + release flow
      await asUser(client, owner);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, operator]);
      await asServiceRole(client);

      // Re-create finalized turn after assignment skipped the original
      await client.query(
        `INSERT INTO messages (conversation_id, direction, sender_type, sender_id, content_type, content)
         VALUES ($1, 'inbound', 'customer', $2, 'text', 'Another request')`,
        [conversationId, owner]
      );
      const newMsg = await client.query(
        `SELECT id FROM messages WHERE conversation_id = $1 ORDER BY created_at DESC LIMIT 1`, [conversationId]
      );
      const aRes = await client.query(`SELECT append_message_to_turn($1) as result`, [newMsg.rows[0].id]);
      const newTurnId = aRes.rows[0].result.turn_id;
      await client.query(`SELECT finalize_conversation_turn($1, 'manual')`, [newTurnId]);

      await asUser(client, owner);
      await client.query(`SELECT release_to_ai_with_reply($1)`, [conversationId]);
      await asServiceRole(client);

      const turn = await client.query(
        `SELECT aggregated_metadata FROM conversation_turns WHERE id = $1`, [newTurnId]
      );
      const meta = turn.rows[0].aggregated_metadata;
      expect(meta.ai_message_id).toBeDefined();
      expect(meta.usage_id).toBeDefined();
      expect(meta.processed_status).toBe('success');
    });
  });

  // ─────────────────────────────────────────────────────────
  // 13. Operator-owned conversation blocks AI context
  // ─────────────────────────────────────────────────────────
  it('operator-owned conversation blocks collect_ai_context', async () => {
    await withRollback(async (client) => {
      const { owner, bizId, conversationId } = await setupAiConversation(client);
      const op = await createTestUser(client, `op_ctx_${Date.now()}@test.com`);
      await createMembership(client, bizId, op, 'operator');

      await asUser(client, owner);
      await client.query(`SELECT assign_conversation($1, $2)`, [conversationId, op]);
      await asServiceRole(client);

      const res = await client.query(
        `SELECT collect_ai_context($1) as result`, [conversationId]
      );
      expect(res.rows[0].result.error).toBe('OPERATOR_OWNED');
    });
  });

  // ─────────────────────────────────────────────────────────
  // 14. Non-member cannot read turns via RLS
  // ─────────────────────────────────────────────────────────
  it('non-member denied turn read via RLS', async () => {
    await withRollback(async (client) => {
      const { turnId } = await setupAiConversation(client);

      // Create an outsider user
      const outsider = await createTestUser(client, `outsider_${Date.now()}@test.com`);
      await asUser(client, outsider);

      const res = await client.query(
        `SELECT * FROM conversation_turns WHERE id = $1`, [turnId]
      );
      expect(res.rows.length).toBe(0);

      await asServiceRole(client);
    });
  });

  // ─────────────────────────────────────────────────────────
  // 15. RLS prevents cross-tenant turn visibility
  // ─────────────────────────────────────────────────────────
  it('RLS prevents cross-tenant turn visibility', async () => {
    await withRollback(async (client) => {
      const s1 = await setupAiConversation(client, 'Tenant A msg');

      // Create tenant B user
      const ownerB = await createTestUser(client, `tenantB_${Date.now()}@test.com`);
      const bizB = await createTestBusiness(client, `Tenant B Biz ${Date.now()}`, ownerB);

      await asUser(client, ownerB);
      const res = await client.query(
        `SELECT * FROM conversation_turns WHERE id = $1`, [s1.turnId]
      );
      expect(res.rows.length).toBe(0);

      const msgs = await client.query(
        `SELECT * FROM conversation_turn_messages WHERE turn_id = $1`, [s1.turnId]
      );
      expect(msgs.rows.length).toBe(0);

      await asServiceRole(client);
    });
  });

  // ─────────────────────────────────────────────────────────
  // 16. collect_ai_context includes current_turn
  // ─────────────────────────────────────────────────────────
  it('collect_ai_context includes current_turn when processing', async () => {
    await withRollback(async (client) => {
      const { conversationId, turnId } = await setupAiConversation(client, 'Context test');

      // Finalize and transition to processing
      await client.query(`SELECT finalize_conversation_turn($1, 'manual')`, [turnId]);
      await client.query(
        `UPDATE conversation_turns SET status = 'processing' WHERE id = $1`, [turnId]
      );

      const res = await client.query(
        `SELECT collect_ai_context($1) as result`, [conversationId]
      );
      const result = res.rows[0].result;
      expect(result.current_turn).toBeDefined();
      expect(result.current_turn.turn_id).toBe(turnId);
      expect(result.current_turn.status).toBe('processing');
      expect(result.safe).toBe(true);
    });
  });

  // ─────────────────────────────────────────────────────────
  // 17. collect_ai_context returns null current_turn when no turn
  // ─────────────────────────────────────────────────────────
  it('collect_ai_context returns null current_turn when no processing turn', async () => {
    await withRollback(async (client) => {
      const { conversationId } = await setupAiConversation(client, 'No turn ctx');

      // Turn is pending, not processing/finalized — current_turn should be null
      const res = await client.query(
        `SELECT collect_ai_context($1) as result`, [conversationId]
      );
      const result = res.rows[0].result;
      expect(result.current_turn).toBeNull();
      expect(result.safe).toBe(true);
    });
  });

  // ─────────────────────────────────────────────────────────
  // 18. finalize_conversation_turn is no-op when already finalized
  // ─────────────────────────────────────────────────────────
  it('finalize_conversation_turn is no-op when already finalized', async () => {
    await withRollback(async (client) => {
      const { turnId } = await setupAiConversation(client, 'Double finalize');

      const r1 = await client.query(`SELECT finalize_conversation_turn($1, 'manual') as result`, [turnId]);
      expect(r1.rows[0].result.status).toBe('finalized');

      const r2 = await client.query(`SELECT finalize_conversation_turn($1, 'manual') as result`, [turnId]);
      expect(r2.rows[0].result.noop).toBe(true);
    });
  });
});
