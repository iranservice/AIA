-- ============================================================
-- Migration 00008: Order Domain
-- Orders, order status history, state machine enforcement,
-- and customer confirmation flow.
--
-- CRITICAL: order payment MUST use tenant's own payment gateway
-- (Level B). Never routed through platform payment (Level A).
-- ============================================================

-- ── Orders ──────────────────────────────────────────────────

create table orders (
  id                    uuid primary key default gen_random_uuid(),
  business_id           uuid not null references businesses(id) on delete cascade,
  customer_id           uuid not null references customers(id) on delete cascade,
  conversation_id       uuid references conversations(id),

  -- Human-readable order number (per-business sequential)
  order_number          text not null,

  -- Status
  status                order_status not null default 'draft',
  order_type            order_type not null default 'dine_in',

  -- Items (JSONB array of order line items)
  -- Schema: [{"name": "...", "quantity": 1, "unit_price": 10.00, "total": 10.00, "notes": "..."}]
  items                 jsonb not null default '[]',

  -- Pricing (all amounts in smallest currency unit or decimal)
  subtotal              numeric(12,2) not null default 0,
  tax                   numeric(12,2) not null default 0,
  delivery_fee          numeric(12,2) not null default 0,
  discount              numeric(12,2) not null default 0,
  total                 numeric(12,2) not null default 0,
  currency              text not null default 'USD',

  -- Payment — MUST reference tenant's own gateway (Level B)
  payment_status        payment_status not null default 'unpaid',
  payment_gateway_id    uuid, -- FK added after provider_registry exists
  payment_reference     text,

  -- Delivery (nullable for dine_in/takeaway)
  delivery_address      jsonb,

  -- Notes & timing
  notes                 text,
  estimated_ready_at    timestamptz,

  -- Lifecycle timestamps
  confirmed_at          timestamptz,
  ready_at              timestamptz,
  delivered_at          timestamptz,
  cancelled_at          timestamptz,
  cancellation_reason   text,

  -- Audit
  created_by            uuid references user_profiles(id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- Per-business order number uniqueness
create unique index uq_orders_number on orders(business_id, order_number);

create index idx_orders_business on orders(business_id);
create index idx_orders_customer on orders(customer_id);
create index idx_orders_status on orders(business_id, status);
create index idx_orders_conversation on orders(conversation_id) where conversation_id is not null;
create index idx_orders_created on orders(business_id, created_at desc);

create trigger trg_orders_updated_at
  before update on orders
  for each row
  execute function update_updated_at_column();

-- ── Order Status History ────────────────────────────────────
-- Full audit trail of every status transition.

create table order_status_history (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references orders(id) on delete cascade,
  from_status   order_status,
  to_status     order_status not null,
  changed_by    uuid references user_profiles(id),
  reason        text,
  created_at    timestamptz not null default now()
);

create index idx_order_history_order on order_status_history(order_id, created_at);

-- ── Order Number Generator ──────────────────────────────────
-- Generates sequential, human-readable order numbers per business.

create sequence if not exists order_number_seq;

create or replace function generate_order_number(p_business_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seq bigint;
  v_prefix text;
begin
  v_seq := nextval('order_number_seq');
  -- Get first 3 chars of business slug for prefix
  select upper(left(b.slug, 3)) into v_prefix
  from businesses b
  where b.id = p_business_id;

  return coalesce(v_prefix, 'ORD') || '-' || lpad(v_seq::text, 6, '0');
end;
$$;

-- ── RPC: create_order ───────────────────────────────────────
-- Creates an order with server-side total calculation.

create or replace function create_order(
  p_business_id uuid,
  p_customer_id uuid,
  p_items jsonb,
  p_order_type order_type default 'dine_in',
  p_conversation_id uuid default null,
  p_delivery_address jsonb default null,
  p_notes text default null,
  p_created_by uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_order_number text;
  v_subtotal numeric(12,2);
  v_total numeric(12,2);
begin
  -- Generate order number
  v_order_number := generate_order_number(p_business_id);

  -- Calculate subtotal from items
  select coalesce(sum((item ->> 'total')::numeric), 0)
  into v_subtotal
  from jsonb_array_elements(p_items) as item;

  v_total := v_subtotal; -- Tax, delivery fee, discount applied later via update

  insert into orders (
    business_id, customer_id, conversation_id,
    order_number, order_type, items,
    subtotal, total,
    delivery_address, notes, created_by
  ) values (
    p_business_id, p_customer_id, p_conversation_id,
    v_order_number, p_order_type, p_items,
    v_subtotal, v_total,
    p_delivery_address, p_notes, p_created_by
  )
  returning id into v_order_id;

  -- Record initial status
  insert into order_status_history (order_id, to_status, changed_by)
  values (v_order_id, 'draft', p_created_by);

  -- Update customer order count
  update customers
  set order_count = order_count + 1
  where id = p_customer_id;

  return v_order_id;
end;
$$;

-- ── RPC: transition_order_status ────────────────────────────
-- Validates and executes order status transitions server-side.
-- This is the ONLY way to change order status.

create or replace function transition_order_status(
  p_order_id uuid,
  p_new_status order_status,
  p_changed_by uuid default null,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current_status order_status;
  v_business_id uuid;
  v_customer_id uuid;
  v_valid_transitions order_status[];
begin
  -- Get current state
  select o.status, o.business_id, o.customer_id
  into v_current_status, v_business_id, v_customer_id
  from orders o
  where o.id = p_order_id
  for update; -- Lock row during transition

  if v_current_status is null then
    raise exception 'Order not found: %', p_order_id;
  end if;

  -- Define valid state transitions
  v_valid_transitions := case v_current_status
    when 'draft'                then array['pending_confirmation', 'cancelled']::order_status[]
    when 'pending_confirmation' then array['confirmed', 'cancelled']::order_status[]
    when 'confirmed'            then array['preparing', 'cancelled']::order_status[]
    when 'preparing'            then array['ready', 'cancelled']::order_status[]
    when 'ready'                then array['delivering', 'delivered', 'cancelled']::order_status[]
    when 'delivering'           then array['delivered', 'cancelled']::order_status[]
    when 'delivered'            then array['refunded']::order_status[]
    when 'cancelled'            then array['refunded']::order_status[]
    when 'refunded'             then array[]::order_status[]
    else array[]::order_status[]
  end;

  -- Validate transition
  if not (p_new_status = any(v_valid_transitions)) then
    raise exception 'Invalid order status transition: % → %', v_current_status, p_new_status;
  end if;

  -- Check permission for status change
  if p_changed_by is not null then
    if not check_permission(p_changed_by, v_business_id, 'order:update') then
      raise exception 'Permission denied: order:update';
    end if;
  end if;

  -- Apply transition
  update orders
  set
    status = p_new_status,
    confirmed_at    = case when p_new_status = 'confirmed' then now() else confirmed_at end,
    ready_at        = case when p_new_status = 'ready' then now() else ready_at end,
    delivered_at    = case when p_new_status = 'delivered' then now() else delivered_at end,
    cancelled_at    = case when p_new_status = 'cancelled' then now() else cancelled_at end,
    cancellation_reason = case when p_new_status = 'cancelled' then p_reason else cancellation_reason end
  where id = p_order_id;

  -- Record history
  insert into order_status_history (order_id, from_status, to_status, changed_by, reason)
  values (p_order_id, v_current_status, p_new_status, p_changed_by, p_reason);

  -- Update customer total_spent on delivery
  if p_new_status = 'delivered' then
    update customers
    set total_spent = total_spent + (
      select total from orders where id = p_order_id
    )
    where id = v_customer_id;
  end if;
end;
$$;

-- ── RPC: confirm_order_by_customer ──────────────────────────
-- Customer-facing confirmation. Moves from pending_confirmation to confirmed.

create or replace function confirm_order_by_customer(
  p_order_id uuid,
  p_customer_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_customer_id uuid;
  v_status order_status;
begin
  select o.customer_id, o.status
  into v_order_customer_id, v_status
  from orders o
  where o.id = p_order_id;

  -- Verify customer owns the order
  if v_order_customer_id != p_customer_id then
    raise exception 'Permission denied: not your order';
  end if;

  -- Must be in pending_confirmation state
  if v_status != 'pending_confirmation' then
    raise exception 'Order is not pending confirmation (current: %)', v_status;
  end if;

  perform transition_order_status(p_order_id, 'confirmed', null, 'Confirmed by customer');
end;
$$;
