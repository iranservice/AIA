-- ============================================================
-- Migration 00010: Tickets & Callbacks
-- Support tickets with callback scheduling.
-- ============================================================

create table tickets (
  id                    uuid primary key default gen_random_uuid(),
  business_id           uuid not null references businesses(id) on delete cascade,
  customer_id           uuid not null references customers(id) on delete cascade,
  conversation_id       uuid references conversations(id),

  -- Human-readable ticket number
  ticket_number         text not null,

  -- Status & priority
  status                ticket_status not null default 'open',
  priority              ticket_priority not null default 'medium',

  -- Content
  subject               text not null,
  description           text,

  -- Assignment
  assigned_to           uuid references user_profiles(id),

  -- Callback request
  callback_requested    boolean not null default false,
  callback_phone        text,
  callback_scheduled_at timestamptz,
  callback_completed_at timestamptz,

  -- Lifecycle
  resolved_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- Per-business ticket number uniqueness
create unique index uq_tickets_number on tickets(business_id, ticket_number);

create index idx_tickets_business on tickets(business_id);
create index idx_tickets_customer on tickets(customer_id);
create index idx_tickets_status on tickets(business_id, status);
create index idx_tickets_priority on tickets(business_id, priority, status);
create index idx_tickets_assigned on tickets(assigned_to) where assigned_to is not null;
create index idx_tickets_callback on tickets(business_id, callback_scheduled_at)
  where callback_requested = true and callback_completed_at is null;

create trigger trg_tickets_updated_at
  before update on tickets
  for each row
  execute function update_updated_at_column();

-- ── Ticket Number Generator ─────────────────────────────────

create sequence if not exists ticket_number_seq;

create or replace function generate_ticket_number(p_business_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seq bigint;
  v_prefix text;
begin
  v_seq := nextval('ticket_number_seq');
  select upper(left(b.slug, 3)) into v_prefix
  from businesses b
  where b.id = p_business_id;

  return coalesce(v_prefix, 'TKT') || '-T' || lpad(v_seq::text, 5, '0');
end;
$$;

-- ── RPC: create_ticket ──────────────────────────────────────

create or replace function create_ticket(
  p_business_id uuid,
  p_customer_id uuid,
  p_subject text,
  p_description text default null,
  p_priority ticket_priority default 'medium',
  p_conversation_id uuid default null,
  p_callback_requested boolean default false,
  p_callback_phone text default null,
  p_callback_scheduled_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket_id uuid;
  v_ticket_number text;
begin
  v_ticket_number := generate_ticket_number(p_business_id);

  insert into tickets (
    business_id, customer_id, conversation_id,
    ticket_number, subject, description,
    priority, callback_requested,
    callback_phone, callback_scheduled_at
  ) values (
    p_business_id, p_customer_id, p_conversation_id,
    v_ticket_number, p_subject, p_description,
    p_priority, p_callback_requested,
    p_callback_phone, p_callback_scheduled_at
  )
  returning id into v_ticket_id;

  return v_ticket_id;
end;
$$;
