-- ============================================================
-- Migration 00012: Provider Registry
-- External integration provider management.
-- Strictly separates Level A (platform) and Level B (tenant)
-- providers.
--
-- CRITICAL RULE:
-- - Level A providers: business_id IS NULL, scope = 'platform'
-- - Level B providers: business_id IS NOT NULL, scope = 'tenant'
-- - Order payment MUST use scope = 'tenant' providers only.
-- ============================================================

create table provider_registry (
  id                  uuid primary key default gen_random_uuid(),

  -- NULL = platform-level (Level A), set = tenant-level (Level B)
  business_id         uuid references businesses(id) on delete cascade,

  -- Provider classification
  provider_type       provider_type not null,
  provider_scope      provider_scope not null,
  provider_name       text not null, -- e.g., 'openai', 'twilio', 'zarinpal', 'stripe'

  -- Connection config (API keys, endpoints, etc.)
  -- ⚠️ Sensitive — must be encrypted at rest.
  -- Never exposed via PostgREST directly; only through secure RPCs.
  api_config          jsonb not null default '{}',

  -- Status
  is_active           boolean not null default true,
  health_status       provider_health_status not null default 'unknown',
  last_health_check_at timestamptz,

  -- Timestamps
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index idx_providers_business on provider_registry(business_id) where business_id is not null;
create index idx_providers_platform on provider_registry(provider_type) where business_id is null;
create index idx_providers_type on provider_registry(business_id, provider_type);
create index idx_providers_active on provider_registry(is_active) where is_active = true;

create trigger trg_providers_updated_at
  before update on provider_registry
  for each row
  execute function update_updated_at_column();

-- ── Constraint: scope consistency ───────────────────────────
-- Platform providers must have NULL business_id.
-- Tenant providers must have a business_id.

alter table provider_registry
  add constraint chk_provider_scope_consistency check (
    (provider_scope = 'platform' and business_id is null)
    or
    (provider_scope = 'tenant' and business_id is not null)
  );

-- ── Add deferred FK from orders to provider_registry ────────
-- Now that provider_registry exists, add the FK for order payments.

alter table orders
  add constraint fk_orders_payment_gateway
  foreign key (payment_gateway_id)
  references provider_registry(id);

-- ── Add deferred FK from business_channels to provider_registry

alter table business_channels
  add constraint fk_channels_provider
  foreign key (provider_id)
  references provider_registry(id);

-- ── RPC: get_provider_config ────────────────────────────────
-- Secure access to provider API config. Only accessible to
-- business owner or platform admin. Never exposed via PostgREST.

create or replace function get_provider_config(
  p_provider_id uuid,
  p_requesting_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id uuid;
  v_config jsonb;
begin
  select pr.business_id, pr.api_config
  into v_business_id, v_config
  from provider_registry pr
  where pr.id = p_provider_id;

  if v_config is null then
    raise exception 'Provider not found: %', p_provider_id;
  end if;

  -- Platform providers: only platform admins
  if v_business_id is null then
    if not is_platform_admin(p_requesting_user_id) then
      raise exception 'Permission denied: platform provider access requires platform admin';
    end if;
    return v_config;
  end if;

  -- Tenant providers: only business owner
  if not check_permission(p_requesting_user_id, v_business_id, 'provider:manage') then
    raise exception 'Permission denied: provider:manage';
  end if;

  return v_config;
end;
$$;

-- ── RPC: validate_order_payment_provider ────────────────────
-- Ensures an order's payment gateway is the tenant's own (Level B).
-- Called before processing payment.

create or replace function validate_order_payment_provider(
  p_order_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_order_business_id uuid;
  v_gateway_id uuid;
  v_provider_scope provider_scope;
  v_provider_business_id uuid;
begin
  select o.business_id, o.payment_gateway_id
  into v_order_business_id, v_gateway_id
  from orders o
  where o.id = p_order_id;

  -- No gateway set yet — payment not initiated
  if v_gateway_id is null then
    return true;
  end if;

  -- Verify the gateway is tenant-scoped and belongs to this business
  select pr.provider_scope, pr.business_id
  into v_provider_scope, v_provider_business_id
  from provider_registry pr
  where pr.id = v_gateway_id;

  if v_provider_scope != 'tenant' then
    raise exception 'SECURITY VIOLATION: Order payment must use tenant gateway, not platform gateway';
  end if;

  if v_provider_business_id != v_order_business_id then
    raise exception 'SECURITY VIOLATION: Payment gateway does not belong to this business';
  end if;

  return true;
end;
$$;
