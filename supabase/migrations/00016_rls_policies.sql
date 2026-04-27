-- ============================================================
-- Migration 00016: Row-Level Security Policies
-- Comprehensive RLS for every tenant-scoped table.
--
-- Security model:
-- - Platform admins bypass tenant isolation
-- - Business owners have full access to their business
-- - Other roles governed by RBAC permissions
-- - No cross-tenant data leakage
-- - Provider secrets only via RPCs, never direct
-- ============================================================

-- ── Enable RLS on all tables ────────────────────────────────

alter table user_profiles enable row level security;
alter table businesses enable row level security;
alter table business_memberships enable row level security;
alter table business_channels enable row level security;
alter table business_operating_hours enable row level security;
alter table permissions enable row level security;
alter table role_permissions enable row level security;
alter table policy_rules enable row level security;
alter table customers enable row level security;
alter table customer_identities enable row level security;
alter table conversations enable row level security;
alter table messages enable row level security;
alter table message_windows enable row level security;
alter table orders enable row level security;
alter table order_status_history enable row level security;
alter table reservations enable row level security;
alter table reservation_status_history enable row level security;
alter table tickets enable row level security;
alter table action_definitions enable row level security;
alter table action_executions enable row level security;
alter table provider_registry enable row level security;
alter table ai_agent_configs enable row level security;
alter table ai_interaction_logs enable row level security;
alter table audit_log enable row level security;
alter table usage_meters enable row level security;
alter table billing_events enable row level security;

-- ═══════════════════════════════════════════════════════════
-- Helper: Check if current user is member of a business
-- ═══════════════════════════════════════════════════════════

create or replace function is_business_member(p_business_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return exists(
    select 1 from business_memberships
    where user_id = auth.uid()
      and business_id = p_business_id
      and is_active = true
  );
end;
$$;

-- ═══════════════════════════════════════════════════════════
-- USER PROFILES
-- ═══════════════════════════════════════════════════════════

-- Users can read their own profile
create policy "users_read_own_profile" on user_profiles
  for select using (id = auth.uid());

-- Users can update their own profile
create policy "users_update_own_profile" on user_profiles
  for update using (id = auth.uid());

-- Platform admins can read all profiles
create policy "platform_admins_read_profiles" on user_profiles
  for select using (is_platform_admin(auth.uid()));

-- ═══════════════════════════════════════════════════════════
-- BUSINESSES
-- ═══════════════════════════════════════════════════════════

-- Members can read their businesses
create policy "members_read_businesses" on businesses
  for select using (is_business_member(id));

-- Platform admins can read all businesses
create policy "platform_admins_read_businesses" on businesses
  for select using (is_platform_admin(auth.uid()));

-- Only owners can update their business
create policy "owners_update_businesses" on businesses
  for update using (
    exists(
      select 1 from business_memberships
      where user_id = auth.uid()
        and business_id = businesses.id
        and role = 'owner'
        and is_active = true
    )
  );

-- Platform admins can update any business
create policy "platform_admins_update_businesses" on businesses
  for update using (is_platform_admin(auth.uid()));

-- ═══════════════════════════════════════════════════════════
-- BUSINESS MEMBERSHIPS
-- ═══════════════════════════════════════════════════════════

-- Members can read memberships within their business
create policy "members_read_memberships" on business_memberships
  for select using (is_business_member(business_id));

-- Owners/managers can manage memberships
create policy "managers_manage_memberships" on business_memberships
  for all using (
    exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = business_memberships.business_id
        and bm.role in ('owner', 'manager')
        and bm.is_active = true
    )
  );

-- Platform admins can read all memberships
create policy "platform_admins_read_memberships" on business_memberships
  for select using (is_platform_admin(auth.uid()));

-- ═══════════════════════════════════════════════════════════
-- BUSINESS CHANNELS
-- ═══════════════════════════════════════════════════════════

-- Members can read channels
create policy "members_read_channels" on business_channels
  for select using (is_business_member(business_id));

-- Owners/managers can manage channels
create policy "managers_manage_channels" on business_channels
  for all using (
    exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = business_channels.business_id
        and bm.role in ('owner', 'manager')
        and bm.is_active = true
    )
  );

-- ═══════════════════════════════════════════════════════════
-- BUSINESS OPERATING HOURS
-- ═══════════════════════════════════════════════════════════

create policy "members_read_hours" on business_operating_hours
  for select using (is_business_member(business_id));

create policy "managers_manage_hours" on business_operating_hours
  for all using (
    exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = business_operating_hours.business_id
        and bm.role in ('owner', 'manager')
        and bm.is_active = true
    )
  );

-- ═══════════════════════════════════════════════════════════
-- PERMISSIONS & ROLE PERMISSIONS
-- ═══════════════════════════════════════════════════════════

-- Permissions are read-only for all authenticated users
create policy "authenticated_read_permissions" on permissions
  for select using (auth.uid() is not null);

create policy "authenticated_read_role_permissions" on role_permissions
  for select using (auth.uid() is not null);

-- Only platform admins can modify permissions
create policy "platform_admins_manage_permissions" on permissions
  for all using (is_platform_admin(auth.uid()));

create policy "platform_admins_manage_role_permissions" on role_permissions
  for all using (is_platform_admin(auth.uid()));

-- ═══════════════════════════════════════════════════════════
-- POLICY RULES
-- ═══════════════════════════════════════════════════════════

create policy "members_read_policy_rules" on policy_rules
  for select using (is_business_member(business_id));

create policy "owners_manage_policy_rules" on policy_rules
  for all using (
    exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = policy_rules.business_id
        and bm.role in ('owner', 'manager')
        and bm.is_active = true
    )
  );

-- ═══════════════════════════════════════════════════════════
-- CUSTOMERS
-- ═══════════════════════════════════════════════════════════

create policy "members_read_customers" on customers
  for select using (is_business_member(business_id));

create policy "operators_manage_customers" on customers
  for all using (
    check_permission(auth.uid(), business_id, 'customer:write')
  );

-- ═══════════════════════════════════════════════════════════
-- CUSTOMER IDENTITIES
-- ═══════════════════════════════════════════════════════════

create policy "members_read_customer_identities" on customer_identities
  for select using (
    exists(
      select 1 from customers c
      where c.id = customer_identities.customer_id
        and is_business_member(c.business_id)
    )
  );

-- ═══════════════════════════════════════════════════════════
-- CONVERSATIONS
-- ═══════════════════════════════════════════════════════════

create policy "members_read_conversations" on conversations
  for select using (is_business_member(business_id));

create policy "operators_manage_conversations" on conversations
  for update using (
    check_permission(auth.uid(), business_id, 'conversation:write')
  );

-- ═══════════════════════════════════════════════════════════
-- MESSAGES
-- ═══════════════════════════════════════════════════════════

-- Members can read non-internal messages
create policy "members_read_messages" on messages
  for select using (
    exists(
      select 1 from conversations c
      where c.id = messages.conversation_id
        and is_business_member(c.business_id)
    )
    and (
      is_internal = false
      or exists(
        select 1 from conversations c
        join business_memberships bm on bm.business_id = c.business_id
        where c.id = messages.conversation_id
          and bm.user_id = auth.uid()
          and bm.role in ('owner', 'manager', 'operator')
          and bm.is_active = true
      )
    )
  );

-- ═══════════════════════════════════════════════════════════
-- MESSAGE WINDOWS
-- ═══════════════════════════════════════════════════════════

create policy "members_read_message_windows" on message_windows
  for select using (
    exists(
      select 1 from conversations c
      where c.id = message_windows.conversation_id
        and is_business_member(c.business_id)
    )
  );

-- ═══════════════════════════════════════════════════════════
-- ORDERS
-- ═══════════════════════════════════════════════════════════

create policy "members_read_orders" on orders
  for select using (is_business_member(business_id));

-- Order mutations only through RPCs (transition_order_status, etc.)
-- No direct update policy for regular users

-- ═══════════════════════════════════════════════════════════
-- ORDER STATUS HISTORY
-- ═══════════════════════════════════════════════════════════

create policy "members_read_order_history" on order_status_history
  for select using (
    exists(
      select 1 from orders o
      where o.id = order_status_history.order_id
        and is_business_member(o.business_id)
    )
  );

-- ═══════════════════════════════════════════════════════════
-- RESERVATIONS
-- ═══════════════════════════════════════════════════════════

create policy "members_read_reservations" on reservations
  for select using (is_business_member(business_id));

-- ═══════════════════════════════════════════════════════════
-- RESERVATION STATUS HISTORY
-- ═══════════════════════════════════════════════════════════

create policy "members_read_reservation_history" on reservation_status_history
  for select using (
    exists(
      select 1 from reservations r
      where r.id = reservation_status_history.reservation_id
        and is_business_member(r.business_id)
    )
  );

-- ═══════════════════════════════════════════════════════════
-- TICKETS
-- ═══════════════════════════════════════════════════════════

create policy "members_read_tickets" on tickets
  for select using (is_business_member(business_id));

create policy "operators_manage_tickets" on tickets
  for update using (
    check_permission(auth.uid(), business_id, 'ticket:write')
  );

-- ═══════════════════════════════════════════════════════════
-- ACTION DEFINITIONS
-- ═══════════════════════════════════════════════════════════

-- Platform-level actions: all authenticated users can read
create policy "read_platform_actions" on action_definitions
  for select using (business_id is null and auth.uid() is not null);

-- Business-level actions: members can read
create policy "members_read_business_actions" on action_definitions
  for select using (business_id is not null and is_business_member(business_id));

-- Owners can manage business-level actions
create policy "owners_manage_actions" on action_definitions
  for all using (
    business_id is not null and exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = action_definitions.business_id
        and bm.role = 'owner'
        and bm.is_active = true
    )
  );

-- ═══════════════════════════════════════════════════════════
-- ACTION EXECUTIONS
-- ═══════════════════════════════════════════════════════════

create policy "members_read_action_executions" on action_executions
  for select using (is_business_member(business_id));

-- ═══════════════════════════════════════════════════════════
-- PROVIDER REGISTRY
-- ═══════════════════════════════════════════════════════════

-- Members can see provider names/status (NOT api_config)
-- api_config is only accessible through get_provider_config RPC
create policy "members_read_providers" on provider_registry
  for select using (
    business_id is not null and is_business_member(business_id)
  );

-- Platform admins can read platform providers
create policy "platform_admins_read_providers" on provider_registry
  for select using (is_platform_admin(auth.uid()));

-- Owners can manage tenant providers
create policy "owners_manage_providers" on provider_registry
  for all using (
    business_id is not null and exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = provider_registry.business_id
        and bm.role = 'owner'
        and bm.is_active = true
    )
  );

-- ═══════════════════════════════════════════════════════════
-- AI AGENT CONFIGS
-- ═══════════════════════════════════════════════════════════

create policy "managers_read_ai_configs" on ai_agent_configs
  for select using (
    exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = ai_agent_configs.business_id
        and bm.role in ('owner', 'manager')
        and bm.is_active = true
    )
  );

create policy "owners_manage_ai_configs" on ai_agent_configs
  for all using (
    exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = ai_agent_configs.business_id
        and bm.role = 'owner'
        and bm.is_active = true
    )
  );

-- ═══════════════════════════════════════════════════════════
-- AI INTERACTION LOGS
-- ═══════════════════════════════════════════════════════════

create policy "managers_read_ai_logs" on ai_interaction_logs
  for select using (
    exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = ai_interaction_logs.business_id
        and bm.role in ('owner', 'manager')
        and bm.is_active = true
    )
  );

-- ═══════════════════════════════════════════════════════════
-- AUDIT LOG
-- ═══════════════════════════════════════════════════════════

-- Business owner/manager can read their business audit logs
create policy "managers_read_audit" on audit_log
  for select using (
    business_id is not null and exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = audit_log.business_id
        and bm.role in ('owner', 'manager')
        and bm.is_active = true
    )
  );

-- Platform admins can read all audit logs
create policy "platform_admins_read_audit" on audit_log
  for select using (is_platform_admin(auth.uid()));

-- ═══════════════════════════════════════════════════════════
-- USAGE METERS
-- ═══════════════════════════════════════════════════════════

create policy "owners_read_usage" on usage_meters
  for select using (
    exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = usage_meters.business_id
        and bm.role = 'owner'
        and bm.is_active = true
    )
  );

create policy "platform_admins_read_usage" on usage_meters
  for select using (is_platform_admin(auth.uid()));

-- ═══════════════════════════════════════════════════════════
-- BILLING EVENTS
-- ═══════════════════════════════════════════════════════════

create policy "owners_read_billing" on billing_events
  for select using (
    exists(
      select 1 from business_memberships bm
      where bm.user_id = auth.uid()
        and bm.business_id = billing_events.business_id
        and bm.role = 'owner'
        and bm.is_active = true
    )
  );

create policy "platform_admins_read_billing" on billing_events
  for select using (is_platform_admin(auth.uid()));
