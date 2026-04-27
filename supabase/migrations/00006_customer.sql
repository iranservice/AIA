-- ============================================================
-- Migration 00006: Customer & CRM Foundations
-- End-customers of tenant businesses.
-- Multi-channel identity resolution.
-- ============================================================

-- ── Customers ───────────────────────────────────────────────

create table customers (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references businesses(id) on delete cascade,

  -- Optional external ID from POS/CRM sync
  external_id       text,

  -- Core identity
  phone             text,
  email             text,
  name              text,

  -- Extensible metadata: tags, preferences, dietary info, notes, etc.
  metadata          jsonb not null default '{}',

  -- CRM aggregates (denormalized for performance, updated via triggers)
  first_seen_at     timestamptz not null default now(),
  last_seen_at      timestamptz not null default now(),
  conversation_count int not null default 0,
  order_count       int not null default 0,
  total_spent       numeric(12,2) not null default 0,

  -- Timestamps
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- Unique customer per phone within a business
create unique index uq_customers_phone
  on customers(business_id, phone)
  where phone is not null;

-- Unique customer per email within a business
create unique index uq_customers_email
  on customers(business_id, email)
  where email is not null;

create index idx_customers_business on customers(business_id);
create index idx_customers_name_trgm on customers using gin (name gin_trgm_ops);
create index idx_customers_last_seen on customers(business_id, last_seen_at desc);

create trigger trg_customers_updated_at
  before update on customers
  for each row
  execute function update_updated_at_column();

-- ── Customer Identities ─────────────────────────────────────
-- Maps a customer to multiple channel identifiers for identity resolution.
-- Example: customer #123 → WhatsApp +971501234567, email john@example.com

create table customer_identities (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null references customers(id) on delete cascade,
  channel_type        channel_type not null,
  channel_identifier  text not null,  -- phone number, email, WhatsApp ID, etc.
  is_primary          boolean not null default false,
  verified_at         timestamptz,
  created_at          timestamptz not null default now()
);

-- Unique identity per channel per business (via customer's business_id)
create unique index uq_customer_identity_channel
  on customer_identities(customer_id, channel_type, channel_identifier);

create index idx_customer_identities_lookup
  on customer_identities(channel_type, channel_identifier);

create index idx_customer_identities_customer
  on customer_identities(customer_id);

-- ── RPC: resolve_or_create_customer ─────────────────────────
-- Finds an existing customer by channel identifier, or creates a new one.
-- This is the primary entry point for inbound message handling.

create or replace function resolve_or_create_customer(
  p_business_id uuid,
  p_channel_type channel_type,
  p_identifier text,
  p_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
begin
  -- Try to find existing customer by channel identity
  select ci.customer_id into v_customer_id
  from customer_identities ci
  join customers c on c.id = ci.customer_id
  where ci.channel_type = p_channel_type
    and ci.channel_identifier = p_identifier
    and c.business_id = p_business_id
  limit 1;

  -- Found: update last_seen and return
  if v_customer_id is not null then
    update customers
    set last_seen_at = now()
    where id = v_customer_id;

    return v_customer_id;
  end if;

  -- Not found: create new customer
  insert into customers (
    business_id,
    phone,
    email,
    name
  ) values (
    p_business_id,
    case when p_channel_type in ('sms', 'whatsapp', 'voice') then p_identifier end,
    case when p_channel_type = 'email' then p_identifier end,
    p_name
  )
  returning id into v_customer_id;

  -- Create the identity mapping
  insert into customer_identities (
    customer_id,
    channel_type,
    channel_identifier,
    is_primary
  ) values (
    v_customer_id,
    p_channel_type,
    p_identifier,
    true
  );

  return v_customer_id;
end;
$$;
