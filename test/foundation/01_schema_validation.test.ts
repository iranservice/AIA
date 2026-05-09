import { describe, it, expect, afterAll } from 'vitest';
import { getServiceClient, closePool } from './setup';

describe('01 — Schema Validation', () => {
  afterAll(async () => { await closePool(); });

  it('should have all 33 expected tables', async () => {
    const client = await getServiceClient();
    try {
      const res = await client.query(
        `SELECT table_name FROM information_schema.tables
         WHERE table_schema = 'public'
         ORDER BY table_name`
      );
      const tables = res.rows.map(r => r.table_name);

      const expected = [
        'action_definitions', 'action_executions',
        'ai_agent_configs', 'ai_capability_registry', 'ai_interaction_logs',
        'ai_model_bindings', 'ai_model_catalog', 'ai_usage_ledger',
        'audit_log',
        'billing_events', 'business_channels', 'business_memberships',
        'business_operating_hours', 'businesses',
        'conversations', 'customer_identities', 'customers',
        'handoff_events',
        'integration_logs',
        'message_windows', 'messages',
        'order_items', 'order_status_history', 'orders',
        'permissions', 'policy_rules', 'provider_registry',
        'reservation_status_history', 'reservations',
        'role_permissions',
        'tickets',
        'usage_meters', 'user_profiles',
      ];

      for (const t of expected) {
        expect(tables, `Missing table: ${t}`).toContain(t);
      }
      expect(tables.length).toBe(33);
    } finally {
      client.release();
    }
  });

  it('should have all 23 enum types', async () => {
    const client = await getServiceClient();
    try {
      const res = await client.query(
        `SELECT t.typname FROM pg_type t
         JOIN pg_namespace n ON t.typnamespace = n.oid
         WHERE n.nspname = 'public' AND t.typtype = 'e'
         ORDER BY t.typname`
      );
      expect(res.rows.length).toBe(23);
    } finally {
      client.release();
    }
  });

  it('should have RLS enabled on all domain tables', async () => {
    const client = await getServiceClient();
    try {
      const res = await client.query(
        `SELECT tablename FROM pg_tables
         WHERE schemaname = 'public' AND rowsecurity = true
         ORDER BY tablename`
      );
      const rlsTables = res.rows.map(r => r.tablename);
      // Core domain tables that MUST have RLS
      const mustHaveRls = [
        'businesses', 'business_memberships', 'business_channels',
        'customers', 'customer_identities',
        'conversations', 'messages',
        'orders', 'reservations', 'tickets',
        'audit_log',
      ];
      for (const t of mustHaveRls) {
        expect(rlsTables, `RLS missing on: ${t}`).toContain(t);
      }
    } finally {
      client.release();
    }
  });

  it('should have RLS policies created', async () => {
    const client = await getServiceClient();
    try {
      const res = await client.query(
        `SELECT count(*) as cnt FROM pg_policies WHERE schemaname = 'public'`
      );
      expect(Number(res.rows[0].cnt)).toBeGreaterThan(30);
    } finally {
      client.release();
    }
  });

  it('should have key RPC functions', async () => {
    const client = await getServiceClient();
    try {
      const res = await client.query(
        `SELECT DISTINCT routine_name FROM information_schema.routines
         WHERE routine_schema = 'public'
         ORDER BY routine_name`
      );
      const fns = res.rows.map(r => r.routine_name);
      const expected = [
        'check_permission',
        'evaluate_policy',
        'resolve_or_create_customer',
        'create_order',
        'transition_order_status',
        'create_reservation',
        'transition_reservation_status',
        'create_ticket',
        'request_action',
        'log_audit',
        'increment_usage_meter',
        'ingest_inbound_message',
        'get_inbox_list',
        'get_conversation_detail',
        'assign_conversation',
        'unassign_conversation',
        'transfer_conversation',
        'operator_reply',
        'collect_ai_context',
        'persist_ai_reply',
        'persist_ai_handoff',
        'log_ai_blocked',
        'release_to_ai',
        'confirm_order',
        'cancel_order',
        'execute_create_order_action',
        'get_order_confirmation_payload',
        'request_customer_confirmation',
        'get_order_available_actions',
        'build_confirmation_text',
        'resolve_ai_capability_binding',
        'check_ai_budget',
        'record_ai_usage',
        'get_business_ai_usage_summary',
      ];
      for (const f of expected) {
        expect(fns, `Missing function: ${f}`).toContain(f);
      }
    } finally {
      client.release();
    }
  });
});
