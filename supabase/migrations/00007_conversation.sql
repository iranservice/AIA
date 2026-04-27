-- ============================================================
-- Migration 00007: Conversation & Messaging Core
-- Conversations, messages, message windows, and routing RPCs.
-- ============================================================

-- ── Conversations ───────────────────────────────────────────

create table conversations (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references businesses(id) on delete cascade,
  customer_id     uuid not null references customers(id) on delete cascade,

  -- Channel info
  channel_type    channel_type not null,
  channel_id      uuid references business_channels(id),

  -- Status & assignment
  status          conversation_status not null default 'open',
  assigned_to     uuid references user_profiles(id),
  assigned_at     timestamptz,
  ai_enabled      boolean not null default false,

  -- Context
  subject         text,
  metadata        jsonb not null default '{}',

  -- Denormalized counters
  last_message_at timestamptz,
  message_count   int not null default 0,

  -- Lifecycle timestamps
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  resolved_at     timestamptz,
  closed_at       timestamptz
);

create index idx_conversations_business on conversations(business_id);
create index idx_conversations_customer on conversations(customer_id);
create index idx_conversations_status on conversations(business_id, status);
create index idx_conversations_assigned on conversations(assigned_to) where assigned_to is not null;
create index idx_conversations_last_msg on conversations(business_id, last_message_at desc nulls last);
create index idx_conversations_open on conversations(business_id, status, last_message_at desc)
  where status in ('open', 'assigned', 'waiting');

create trigger trg_conversations_updated_at
  before update on conversations
  for each row
  execute function update_updated_at_column();

-- ── Messages ────────────────────────────────────────────────

create table messages (
  id                uuid primary key default gen_random_uuid(),
  conversation_id   uuid not null references conversations(id) on delete cascade,
  direction         message_direction not null,
  sender_type       message_sender_type not null,

  -- Polymorphic sender: user_id for operator, customer_id for customer,
  -- NULL for ai/system
  sender_id         uuid,

  -- Content
  content_type      message_content_type not null default 'text',
  content           text, -- text body (nullable for media-only messages)
  content_metadata  jsonb not null default '{}', -- media URLs, template params, etc.

  -- Internal notes (visible only to operators, hidden from customer)
  is_internal       boolean not null default false,

  -- Threading
  reply_to_id       uuid references messages(id),

  -- Delivery tracking
  delivered_at      timestamptz,
  read_at           timestamptz,

  -- Timestamps
  created_at        timestamptz not null default now()
);

-- Primary message retrieval: conversation timeline
create index idx_messages_conversation_time on messages(conversation_id, created_at);

-- For windowing: recent messages in a conversation
create index idx_messages_conversation_recent on messages(conversation_id, created_at desc);

-- Sender lookups
create index idx_messages_sender on messages(sender_id) where sender_id is not null;

-- ── Message Windows ─────────────────────────────────────────
-- Fragmented conversation windows for AI context management.
-- When a conversation is long, we summarize older windows to
-- keep AI context within token limits.

create table message_windows (
  id                uuid primary key default gen_random_uuid(),
  conversation_id   uuid not null references conversations(id) on delete cascade,
  window_start      timestamptz not null,
  window_end        timestamptz not null,
  message_count     int not null default 0,
  summary           text, -- AI-generated summary of this window
  tokens_used       int,  -- token count of the summary
  created_at        timestamptz not null default now()
);

create index idx_message_windows_conversation on message_windows(conversation_id, window_start);

-- ── RPC: create_conversation ────────────────────────────────

create or replace function create_conversation(
  p_business_id uuid,
  p_customer_id uuid,
  p_channel_type channel_type,
  p_channel_id uuid default null,
  p_subject text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conversation_id uuid;
  v_ai_policy jsonb;
begin
  -- Check if AI is enabled for this channel via policy
  v_ai_policy := evaluate_policy(p_business_id, 'ai_allowed');

  insert into conversations (
    business_id,
    customer_id,
    channel_type,
    channel_id,
    subject,
    ai_enabled
  ) values (
    p_business_id,
    p_customer_id,
    p_channel_type,
    p_channel_id,
    p_subject,
    -- Enable AI if the policy allows it for this channel
    coalesce(
      v_ai_policy is not null
      and (v_ai_policy ->> 'enabled')::boolean = true
      and (
        v_ai_policy -> 'channels' is null
        or v_ai_policy -> 'channels' @> to_jsonb(p_channel_type::text)
      ),
      false
    )
  )
  returning id into v_conversation_id;

  return v_conversation_id;
end;
$$;

-- ── RPC: send_message ───────────────────────────────────────
-- Persists a message and updates conversation counters.

create or replace function send_message(
  p_conversation_id uuid,
  p_direction message_direction,
  p_sender_type message_sender_type,
  p_sender_id uuid default null,
  p_content text default null,
  p_content_type message_content_type default 'text',
  p_content_metadata jsonb default '{}',
  p_is_internal boolean default false,
  p_reply_to_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_message_id uuid;
  v_business_id uuid;
  v_customer_id uuid;
begin
  -- Get conversation context
  select c.business_id, c.customer_id
  into v_business_id, v_customer_id
  from conversations c
  where c.id = p_conversation_id;

  if v_business_id is null then
    raise exception 'Conversation not found: %', p_conversation_id;
  end if;

  -- Insert message
  insert into messages (
    conversation_id,
    direction,
    sender_type,
    sender_id,
    content,
    content_type,
    content_metadata,
    is_internal,
    reply_to_id
  ) values (
    p_conversation_id,
    p_direction,
    p_sender_type,
    p_sender_id,
    p_content,
    p_content_type,
    p_content_metadata,
    p_is_internal,
    p_reply_to_id
  )
  returning id into v_message_id;

  -- Update conversation counters
  update conversations
  set
    last_message_at = now(),
    message_count = message_count + 1,
    -- Re-open if resolved/closed and customer sends new message
    status = case
      when p_direction = 'inbound' and p_sender_type = 'customer'
        and status in ('resolved', 'closed')
      then 'open'::conversation_status
      else status
    end
  where id = p_conversation_id;

  -- Update customer last_seen
  update customers
  set last_seen_at = now()
  where id = v_customer_id;

  return v_message_id;
end;
$$;

-- ── RPC: assign_conversation ────────────────────────────────
-- Assigns a conversation to an operator.

create or replace function assign_conversation(
  p_conversation_id uuid,
  p_operator_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id uuid;
begin
  select c.business_id into v_business_id
  from conversations c
  where c.id = p_conversation_id;

  -- Verify operator has permission
  if not check_permission(p_operator_id, v_business_id, 'conversation:assign') then
    raise exception 'Permission denied: conversation:assign';
  end if;

  update conversations
  set
    assigned_to = p_operator_id,
    assigned_at = now(),
    status = 'assigned',
    ai_enabled = false -- AI steps back when operator takes over
  where id = p_conversation_id;
end;
$$;

-- ── RPC: release_to_ai ─────────────────────────────────────
-- Operator releases conversation back to AI control.

create or replace function release_to_ai(
  p_conversation_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id uuid;
  v_ai_policy jsonb;
begin
  select c.business_id into v_business_id
  from conversations c
  where c.id = p_conversation_id;

  -- Check AI policy allows it
  v_ai_policy := evaluate_policy(v_business_id, 'ai_allowed');
  if v_ai_policy is null or (v_ai_policy ->> 'enabled')::boolean != true then
    raise exception 'AI is not enabled for this business';
  end if;

  update conversations
  set
    assigned_to = null,
    assigned_at = null,
    status = 'open',
    ai_enabled = true
  where id = p_conversation_id;

  -- Log the handoff as a system message
  perform send_message(
    p_conversation_id := p_conversation_id,
    p_direction := 'outbound',
    p_sender_type := 'system',
    p_content := 'Conversation released to AI',
    p_content_type := 'system_event',
    p_is_internal := true
  );
end;
$$;

-- ── RPC: handoff_to_operator ────────────────────────────────
-- AI or system requests human operator takeover with a reason.

create or replace function handoff_to_operator(
  p_conversation_id uuid,
  p_operator_id uuid default null,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update conversations
  set
    assigned_to = p_operator_id,
    assigned_at = case when p_operator_id is not null then now() end,
    status = case
      when p_operator_id is not null then 'assigned'::conversation_status
      else 'open'::conversation_status -- Unassigned, waiting for pickup
    end,
    ai_enabled = false
  where id = p_conversation_id;

  -- Log the handoff
  perform send_message(
    p_conversation_id := p_conversation_id,
    p_direction := 'outbound',
    p_sender_type := 'system',
    p_content := coalesce('Handoff to operator: ' || p_reason, 'Handoff to operator'),
    p_content_type := 'system_event',
    p_is_internal := true
  );
end;
$$;

-- ── RPC: takeover_conversation ──────────────────────────────
-- Manager overrides current assignment.

create or replace function takeover_conversation(
  p_conversation_id uuid,
  p_operator_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id uuid;
  v_old_assigned uuid;
begin
  select c.business_id, c.assigned_to
  into v_business_id, v_old_assigned
  from conversations c
  where c.id = p_conversation_id;

  -- Verify takeover permission (manager level)
  if not check_permission(p_operator_id, v_business_id, 'conversation:takeover') then
    raise exception 'Permission denied: conversation:takeover';
  end if;

  update conversations
  set
    assigned_to = p_operator_id,
    assigned_at = now(),
    status = 'assigned',
    ai_enabled = false
  where id = p_conversation_id;

  -- Log the takeover
  perform send_message(
    p_conversation_id := p_conversation_id,
    p_direction := 'outbound',
    p_sender_type := 'system',
    p_content := format('Conversation taken over from %s', coalesce(v_old_assigned::text, 'AI')),
    p_content_type := 'system_event',
    p_is_internal := true
  );
end;
$$;
