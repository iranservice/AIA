-- ============================================================
-- Migration 00015: Usage & Billing
-- Platform-level (Level A) billing meters and events.
--
-- CRITICAL: This is Level A billing only.
-- billing_events.platform_payment_reference uses the
-- platform's own payment gateway — completely isolated
-- from tenant order payments (Level B).
-- ============================================================

-- ── Usage Meters ────────────────────────────────────────────
-- Tracks resource consumption per business per billing period.

create table usage_meters (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references businesses(id) on delete cascade,
  meter_type      usage_meter_type not null,
  period_start    date not null,
  period_end      date not null,
  quantity        bigint not null default 0,
  created_at      timestamptz not null default now(),

  -- One meter per type per period per business
  constraint uq_usage_meter unique (business_id, meter_type, period_start)
);

create index idx_usage_meters_business on usage_meters(business_id, period_start desc);
create index idx_usage_meters_period on usage_meters(period_start, period_end);

-- ── Billing Events ──────────────────────────────────────────
-- Level A billing events (subscriptions, overages, credits).

create table billing_events (
  id                          uuid primary key default gen_random_uuid(),
  business_id                 uuid not null references businesses(id) on delete cascade,
  event_type                  billing_event_type not null,
  amount                      numeric(12,2) not null,
  currency                    text not null default 'USD',

  -- Platform payment reference — Level A gateway ONLY
  -- ⚠️ This MUST NOT reference a tenant payment gateway
  platform_payment_reference  text,

  -- Context
  description                 text,
  metadata                    jsonb not null default '{}',

  created_at                  timestamptz not null default now()
);

create index idx_billing_events_business on billing_events(business_id, created_at desc);
create index idx_billing_events_type on billing_events(event_type);

-- ── RPC: increment_usage_meter ──────────────────────────────
-- Atomically increments a usage meter for the current period.

create or replace function increment_usage_meter(
  p_business_id uuid,
  p_meter_type usage_meter_type,
  p_quantity bigint default 1
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period_start date;
  v_period_end date;
begin
  -- Current billing period (monthly)
  v_period_start := date_trunc('month', now())::date;
  v_period_end := (date_trunc('month', now()) + interval '1 month' - interval '1 day')::date;

  insert into usage_meters (business_id, meter_type, period_start, period_end, quantity)
  values (p_business_id, p_meter_type, v_period_start, v_period_end, p_quantity)
  on conflict (business_id, meter_type, period_start)
  do update set quantity = usage_meters.quantity + p_quantity;
end;
$$;
