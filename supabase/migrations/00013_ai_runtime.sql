-- ============================================================
-- Migration 00013: AI Runtime
-- Per-business AI agent configuration and interaction logging.
--
-- Design rule: AI runtime MUST go through policy evaluation
-- before executing any action. The policy_checks column in
-- interaction logs makes this traceable.
-- ============================================================

-- ── AI Agent Configs ────────────────────────────────────────
-- Per-business AI configuration. Each business can have
-- different models, prompts, and allowed actions.

create table ai_agent_configs (
  id                    uuid primary key default gen_random_uuid(),
  business_id           uuid not null references businesses(id) on delete cascade,
  provider_id           uuid not null references provider_registry(id),

  -- Model config
  model_name            text not null default 'gpt-4o',
  system_prompt         text,
  temperature           numeric(3,2) not null default 0.7
    check (temperature >= 0 and temperature <= 2),
  max_tokens            int not null default 4096
    check (max_tokens > 0),

  -- Allowed actions this AI agent can trigger
  allowed_actions       action_type[] not null default '{}',

  -- Knowledge base config (RAG, document retrieval, etc.)
  knowledge_base_config jsonb not null default '{}',

  -- Conversation behavior
  max_context_messages  int not null default 20, -- max messages to include in context
  window_summary_enabled boolean not null default true, -- use message window summaries

  -- Status
  is_active             boolean not null default true,

  -- Timestamps
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index idx_ai_configs_business on ai_agent_configs(business_id);
create index idx_ai_configs_active on ai_agent_configs(business_id) where is_active = true;

create trigger trg_ai_configs_updated_at
  before update on ai_agent_configs
  for each row
  execute function update_updated_at_column();

-- ── AI Interaction Logs ─────────────────────────────────────
-- Full audit of every AI request/response, including which
-- policies were checked and which actions were triggered.

create table ai_interaction_logs (
  id                    uuid primary key default gen_random_uuid(),
  business_id           uuid not null references businesses(id) on delete cascade,
  conversation_id       uuid not null references conversations(id) on delete cascade,
  agent_config_id       uuid not null references ai_agent_configs(id),

  -- Token usage
  prompt_tokens         int not null default 0,
  completion_tokens     int not null default 0,
  model_used            text not null,

  -- Request/response payloads (sanitized — no PII in logs)
  request_payload       jsonb not null default '{}',
  response_payload      jsonb not null default '{}',

  -- Actions the AI attempted or triggered
  actions_triggered     action_type[] not null default '{}',

  -- Policy evaluation trace — what policies were checked,
  -- and what decisions were made. This makes AI decisions
  -- fully traceable and auditable.
  policy_checks         jsonb not null default '[]',

  -- Performance
  latency_ms            int,

  -- Errors
  error                 text,

  -- Timestamp
  created_at            timestamptz not null default now()
);

create index idx_ai_logs_business on ai_interaction_logs(business_id, created_at desc);
create index idx_ai_logs_conversation on ai_interaction_logs(conversation_id, created_at desc);
create index idx_ai_logs_errors on ai_interaction_logs(business_id)
  where error is not null;

-- ── RPC: get_ai_config_for_business ─────────────────────────
-- Returns the active AI config for a business.

create or replace function get_ai_config_for_business(
  p_business_id uuid
)
returns table (
  config_id uuid,
  provider_id uuid,
  model_name text,
  system_prompt text,
  temperature numeric,
  max_tokens int,
  allowed_actions action_type[],
  knowledge_base_config jsonb,
  max_context_messages int,
  window_summary_enabled boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return query
    select
      ac.id,
      ac.provider_id,
      ac.model_name,
      ac.system_prompt,
      ac.temperature,
      ac.max_tokens,
      ac.allowed_actions,
      ac.knowledge_base_config,
      ac.max_context_messages,
      ac.window_summary_enabled
    from ai_agent_configs ac
    where ac.business_id = p_business_id
      and ac.is_active = true
    limit 1;
end;
$$;

-- ── RPC: log_ai_interaction ─────────────────────────────────
-- Records an AI interaction for audit and billing.

create or replace function log_ai_interaction(
  p_business_id uuid,
  p_conversation_id uuid,
  p_agent_config_id uuid,
  p_model_used text,
  p_prompt_tokens int,
  p_completion_tokens int,
  p_request_payload jsonb default '{}',
  p_response_payload jsonb default '{}',
  p_actions_triggered action_type[] default '{}',
  p_policy_checks jsonb default '[]',
  p_latency_ms int default null,
  p_error text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_log_id uuid;
begin
  insert into ai_interaction_logs (
    business_id, conversation_id, agent_config_id,
    model_used, prompt_tokens, completion_tokens,
    request_payload, response_payload,
    actions_triggered, policy_checks,
    latency_ms, error
  ) values (
    p_business_id, p_conversation_id, p_agent_config_id,
    p_model_used, p_prompt_tokens, p_completion_tokens,
    p_request_payload, p_response_payload,
    p_actions_triggered, p_policy_checks,
    p_latency_ms, p_error
  )
  returning id into v_log_id;

  return v_log_id;
end;
$$;
