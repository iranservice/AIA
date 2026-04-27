-- ============================================================
-- Migration 00005: RBAC & Policy Engine
-- Permission system, role-permission mapping, and configurable
-- business policy rules.
-- ============================================================

-- ── Permissions ─────────────────────────────────────────────
-- Enumerated permission codes. Domain-scoped (e.g., 'order:create').

create table permissions (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  description text,
  domain      text not null, -- e.g., 'conversation', 'order', 'customer'
  created_at  timestamptz not null default now()
);

-- ── Role-Permission Mapping ─────────────────────────────────
-- Which roles get which permissions.
-- Optional business_type filter for type-specific permission overrides.

create table role_permissions (
  id              uuid primary key default gen_random_uuid(),
  role            membership_role not null,
  permission_id   uuid not null references permissions(id) on delete cascade,

  -- NULL = applies to all business types
  -- Set = only applies to that business type
  business_type   business_type,

  created_at      timestamptz not null default now(),

  -- Prevent duplicate mappings
  constraint uq_role_permission unique (role, permission_id, business_type)
);

create index idx_role_permissions_role on role_permissions(role);
create index idx_role_permissions_type on role_permissions(business_type) where business_type is not null;

-- ── Policy Rules ────────────────────────────────────────────
-- Configurable business rules per tenant.
-- Examples:
--   rule_type = 'auto_assign':       {"strategy": "round_robin", "roles": ["operator"]}
--   rule_type = 'ai_allowed':        {"enabled": true, "channels": ["whatsapp", "web_chat"]}
--   rule_type = 'approval_required': {"order_amount_threshold": 100, "roles": ["manager"]}
--   rule_type = 'working_hours':     {"enforce": true, "auto_reply_outside": true}

create table policy_rules (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id) on delete cascade,
  rule_type     text not null,
  rule_config   jsonb not null default '{}',
  is_active     boolean not null default true,
  priority      int not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  -- One active rule per type per business (deactivate to override)
  constraint uq_policy_rule unique (business_id, rule_type) 
);

create index idx_policy_rules_business on policy_rules(business_id);
create index idx_policy_rules_type on policy_rules(rule_type);

create trigger trg_policy_rules_updated_at
  before update on policy_rules
  for each row
  execute function update_updated_at_column();

-- ── RPC: check_permission ───────────────────────────────────
-- Server-side permission check. Returns true if user has the
-- given permission for the given business.

create or replace function check_permission(
  p_user_id uuid,
  p_business_id uuid,
  p_permission_code text
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role membership_role;
  v_is_active boolean;
  v_business_type business_type;
  v_has_permission boolean;
begin
  -- Platform admins bypass permission checks
  if is_platform_admin(p_user_id) then
    return true;
  end if;

  -- Get user's role in this business
  select bm.role, bm.is_active into v_role, v_is_active
  from business_memberships bm
  where bm.user_id = p_user_id
    and bm.business_id = p_business_id
  limit 1;

  -- No membership or inactive = no access
  if v_role is null or v_is_active = false then
    return false;
  end if;

  -- Owner has all permissions
  if v_role = 'owner' then
    return true;
  end if;

  -- Get business type for type-specific permission check
  select b.business_type into v_business_type
  from businesses b
  where b.id = p_business_id;

  -- Check if role has the permission (generic or type-specific)
  select exists(
    select 1
    from role_permissions rp
    join permissions p on p.id = rp.permission_id
    where rp.role = v_role
      and p.code = p_permission_code
      and (rp.business_type is null or rp.business_type = v_business_type)
  ) into v_has_permission;

  return v_has_permission;
end;
$$;

-- ── RPC: get_user_permissions ───────────────────────────────
-- Returns all permission codes for a user in a business.

create or replace function get_user_permissions(
  p_user_id uuid,
  p_business_id uuid
)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role membership_role;
  v_is_active boolean;
  v_business_type business_type;
  v_permissions text[];
begin
  -- Platform admins: return special marker
  if is_platform_admin(p_user_id) then
    return array['*'];
  end if;

  -- Get membership
  select bm.role, bm.is_active into v_role, v_is_active
  from business_memberships bm
  where bm.user_id = p_user_id
    and bm.business_id = p_business_id
  limit 1;

  if v_role is null or v_is_active = false then
    return array[]::text[];
  end if;

  -- Owner gets all permissions
  if v_role = 'owner' then
    select array_agg(p.code) into v_permissions
    from permissions p;
    return coalesce(v_permissions, array[]::text[]);
  end if;

  -- Get business type
  select b.business_type into v_business_type
  from businesses b
  where b.id = p_business_id;

  -- Get role-specific permissions
  select array_agg(distinct p.code) into v_permissions
  from role_permissions rp
  join permissions p on p.id = rp.permission_id
  where rp.role = v_role
    and (rp.business_type is null or rp.business_type = v_business_type);

  return coalesce(v_permissions, array[]::text[]);
end;
$$;

-- ── RPC: evaluate_policy ────────────────────────────────────
-- Evaluates a policy rule for a business given a context.
-- Returns the rule_config if active, NULL if no matching rule.

create or replace function evaluate_policy(
  p_business_id uuid,
  p_rule_type text,
  p_context jsonb default '{}'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_config jsonb;
begin
  select pr.rule_config into v_config
  from policy_rules pr
  where pr.business_id = p_business_id
    and pr.rule_type = p_rule_type
    and pr.is_active = true
  order by pr.priority desc
  limit 1;

  return v_config;
end;
$$;
