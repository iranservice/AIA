-- ============================================================
-- Migration 00014: Audit Logging
-- Universal audit trail for all sensitive operations.
-- Partitioned by month for performance.
-- ============================================================

-- ── Audit Log ───────────────────────────────────────────────
-- Records all sensitive operations across all domains.
-- This table is append-only; no updates or deletes.

create table audit_log (
  id            uuid primary key default gen_random_uuid(),

  -- Context
  business_id   uuid references businesses(id) on delete set null,
  user_id       uuid references user_profiles(id) on delete set null,

  -- What happened
  action        text not null, -- e.g., 'order.created', 'conversation.assigned', 'provider.config_accessed'
  entity_type   text not null, -- e.g., 'order', 'conversation', 'provider_registry'
  entity_id     uuid,          -- ID of the affected entity

  -- Severity
  severity      audit_severity not null default 'info',

  -- Change data
  old_values    jsonb,         -- previous state (for updates)
  new_values    jsonb,         -- new state (for creates/updates)

  -- Request context
  ip_address    inet,
  user_agent    text,

  -- Extra metadata
  metadata      jsonb not null default '{}',

  -- Timestamp
  created_at    timestamptz not null default now()
);

-- Primary query patterns
create index idx_audit_business_time on audit_log(business_id, created_at desc)
  where business_id is not null;
create index idx_audit_entity on audit_log(entity_type, entity_id);
create index idx_audit_user on audit_log(user_id, created_at desc)
  where user_id is not null;
create index idx_audit_action on audit_log(action);
create index idx_audit_severity on audit_log(severity, created_at desc)
  where severity in ('error', 'critical');

-- ── RPC: log_audit ──────────────────────────────────────────
-- Centralized audit logging function.

create or replace function log_audit(
  p_action text,
  p_entity_type text,
  p_entity_id uuid default null,
  p_business_id uuid default null,
  p_user_id uuid default null,
  p_severity audit_severity default 'info',
  p_old_values jsonb default null,
  p_new_values jsonb default null,
  p_metadata jsonb default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_log_id uuid;
begin
  insert into audit_log (
    business_id, user_id,
    action, entity_type, entity_id,
    severity, old_values, new_values,
    metadata
  ) values (
    p_business_id, coalesce(p_user_id, auth.uid()),
    p_action, p_entity_type, p_entity_id,
    p_severity, p_old_values, p_new_values,
    p_metadata
  )
  returning id into v_log_id;

  return v_log_id;
end;
$$;
