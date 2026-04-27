-- ============================================================
-- Migration 00004: Tenancy
-- Business (tenant) entities, memberships, channels, and
-- operating hours.
-- ============================================================

-- ── Businesses (Tenants) ────────────────────────────────────

create table businesses (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  slug              text not null unique,
  business_type     business_type not null default 'general',

  -- Type-specific configuration stored as JSONB.
  -- Schema validated per business_type at application layer.
  -- Example (restaurant): {"menu_url": "...", "delivery_enabled": true, "delivery_radius_km": 5}
  -- Example (clinic): {"specialties": [...], "appointment_duration_min": 30}
  business_config   jsonb not null default '{}',

  -- Defaults
  timezone          text not null default 'UTC',
  default_language  text not null default 'en',

  -- Subscription
  subscription_tier text not null default 'free',

  -- Status
  is_active         boolean not null default true,

  -- Timestamps
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index idx_businesses_slug on businesses(slug);
create index idx_businesses_type on businesses(business_type);
create index idx_businesses_active on businesses(is_active) where is_active = true;

create trigger trg_businesses_updated_at
  before update on businesses
  for each row
  execute function update_updated_at_column();

-- ── Business Memberships ────────────────────────────────────
-- Links users to businesses with a role.

create table business_memberships (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references user_profiles(id) on delete cascade,
  business_id   uuid not null references businesses(id) on delete cascade,
  role          membership_role not null default 'viewer',
  is_active     boolean not null default true,
  invited_by    uuid references user_profiles(id),
  joined_at     timestamptz not null default now(),
  created_at    timestamptz not null default now(),

  -- A user can only have one membership per business
  constraint uq_membership_user_business unique (user_id, business_id)
);

create index idx_memberships_user on business_memberships(user_id);
create index idx_memberships_business on business_memberships(business_id);
create index idx_memberships_active on business_memberships(is_active) where is_active = true;

-- ── Business Channels ───────────────────────────────────────
-- Channel connections per business (WhatsApp, SMS, etc.)

create table business_channels (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references businesses(id) on delete cascade,
  channel_type    channel_type not null,

  -- Reference to external provider (populated after provider_registry migration)
  provider_id     uuid,

  -- Channel-specific config (API keys, webhook URLs, phone numbers, etc.)
  -- Sensitive values should be encrypted at rest.
  channel_config  jsonb not null default '{}',

  -- Status
  is_active       boolean not null default true,
  verified_at     timestamptz,

  -- Timestamps
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index idx_channels_business on business_channels(business_id);
create index idx_channels_type on business_channels(business_id, channel_type);

create trigger trg_channels_updated_at
  before update on business_channels
  for each row
  execute function update_updated_at_column();

-- ── Business Operating Hours ────────────────────────────────
-- Weekly schedule. 0 = Sunday, 6 = Saturday.

create table business_operating_hours (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id) on delete cascade,
  day_of_week   smallint not null check (day_of_week between 0 and 6),
  open_time     time,
  close_time    time,
  is_closed     boolean not null default false,
  created_at    timestamptz not null default now(),

  -- One entry per day per business
  constraint uq_operating_hours_day unique (business_id, day_of_week),
  -- If not closed, times must be set
  constraint chk_times_when_open check (
    is_closed = true or (open_time is not null and close_time is not null)
  )
);

create index idx_operating_hours_business on business_operating_hours(business_id);

-- ── Helper: Get user's business membership ──────────────────

create or replace function get_user_membership(
  p_user_id uuid,
  p_business_id uuid
)
returns table (
  membership_id uuid,
  role membership_role,
  is_active boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return query
    select bm.id, bm.role, bm.is_active
    from business_memberships bm
    where bm.user_id = p_user_id
      and bm.business_id = p_business_id
    limit 1;
end;
$$;

-- ── Helper: Check if user is platform admin ─────────────────

create or replace function is_platform_admin(p_user_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role platform_role;
begin
  select up.platform_role into v_role
  from user_profiles up
  where up.id = p_user_id;

  return v_role in ('super_admin', 'platform_admin');
end;
$$;
