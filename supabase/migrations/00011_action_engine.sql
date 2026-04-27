-- ============================================================
-- Migration 00011: Action Engine
-- Action definitions, execution log, and approval flow.
--
-- Design principle: Actions ORCHESTRATE, they don't OWN
-- business domain logic. An action calls the domain's RPC,
-- it doesn't contain domain logic itself.
-- ============================================================

-- ── Action Definitions ──────────────────────────────────────
-- Registered action types. business_id NULL = platform-level.

create table action_definitions (
  id                uuid primary key default gen_random_uuid(),

  -- NULL = platform-wide action, set = tenant-specific action
  business_id       uuid references businesses(id) on delete cascade,

  action_type       action_type not null,
  name              text not null,
  description       text,

  -- JSON Schema for validating action inputs
  input_schema      jsonb not null default '{}',

  -- Approval requirements
  requires_approval boolean not null default false,
  approval_roles    membership_role[] not null default '{}',

  -- Status
  is_active         boolean not null default true,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index idx_action_defs_business on action_definitions(business_id);
create index idx_action_defs_type on action_definitions(action_type);
create index idx_action_defs_platform on action_definitions(action_type) where business_id is null;

create trigger trg_action_defs_updated_at
  before update on action_definitions
  for each row
  execute function update_updated_at_column();

-- ── Action Executions ───────────────────────────────────────
-- Log of every action execution — who triggered it, input/output, approval.

create table action_executions (
  id                    uuid primary key default gen_random_uuid(),
  action_definition_id  uuid not null references action_definitions(id) on delete cascade,
  business_id           uuid not null references businesses(id) on delete cascade,
  conversation_id       uuid references conversations(id),

  -- Who or what triggered this action
  triggered_by          action_trigger_source not null,
  trigger_user_id       uuid references user_profiles(id), -- set if triggered by operator

  -- Input & output
  input_data            jsonb not null default '{}',
  output_data           jsonb,

  -- Approval workflow
  approval_status       approval_status not null default 'approved', -- default approved if no approval required
  approved_by           uuid references user_profiles(id),
  approved_at           timestamptz,
  rejection_reason      text,

  -- Execution timing
  executed_at           timestamptz,
  error                 text,

  created_at            timestamptz not null default now()
);

create index idx_action_exec_business on action_executions(business_id);
create index idx_action_exec_conversation on action_executions(conversation_id) where conversation_id is not null;
create index idx_action_exec_pending on action_executions(business_id, approval_status)
  where approval_status = 'pending';
create index idx_action_exec_created on action_executions(business_id, created_at desc);

-- ── RPC: request_action ─────────────────────────────────────
-- Submits an action for execution. If approval is required,
-- it stays in 'pending' status until approved.

create or replace function request_action(
  p_action_type action_type,
  p_business_id uuid,
  p_input_data jsonb,
  p_triggered_by action_trigger_source,
  p_trigger_user_id uuid default null,
  p_conversation_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_def_id uuid;
  v_requires_approval boolean;
  v_execution_id uuid;
begin
  -- Find the action definition (business-specific or platform-level)
  select ad.id, ad.requires_approval
  into v_def_id, v_requires_approval
  from action_definitions ad
  where ad.action_type = p_action_type
    and ad.is_active = true
    and (ad.business_id = p_business_id or ad.business_id is null)
  order by ad.business_id nulls last -- prefer business-specific over platform
  limit 1;

  if v_def_id is null then
    raise exception 'No active action definition found for type: %', p_action_type;
  end if;

  -- Check approval policy override
  declare
    v_policy jsonb;
  begin
    v_policy := evaluate_policy(p_business_id, 'approval_required');
    if v_policy is not null then
      -- Policy can override definition-level approval requirement
      v_requires_approval := coalesce((v_policy ->> p_action_type::text)::boolean, v_requires_approval);
    end if;
  end;

  insert into action_executions (
    action_definition_id, business_id, conversation_id,
    triggered_by, trigger_user_id,
    input_data,
    approval_status,
    executed_at
  ) values (
    v_def_id, p_business_id, p_conversation_id,
    p_triggered_by, p_trigger_user_id,
    p_input_data,
    case when v_requires_approval then 'pending'::approval_status else 'approved'::approval_status end,
    case when not v_requires_approval then now() end
  )
  returning id into v_execution_id;

  return v_execution_id;
end;
$$;

-- ── RPC: approve_action ─────────────────────────────────────

create or replace function approve_action(
  p_execution_id uuid,
  p_approver_id uuid,
  p_approved boolean,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id uuid;
  v_current_status approval_status;
begin
  select ae.business_id, ae.approval_status
  into v_business_id, v_current_status
  from action_executions ae
  where ae.id = p_execution_id;

  if v_current_status != 'pending' then
    raise exception 'Action is not pending approval (current: %)', v_current_status;
  end if;

  -- Check approver has permission
  if not check_permission(p_approver_id, v_business_id, 'action:approve') then
    raise exception 'Permission denied: action:approve';
  end if;

  update action_executions
  set
    approval_status = case when p_approved then 'approved'::approval_status else 'rejected'::approval_status end,
    approved_by = p_approver_id,
    approved_at = now(),
    rejection_reason = case when not p_approved then p_reason end,
    executed_at = case when p_approved then now() end
  where id = p_execution_id;
end;
$$;
