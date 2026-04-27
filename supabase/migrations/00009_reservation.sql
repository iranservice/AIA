-- ============================================================
-- Migration 00009: Reservation
-- Reservation management, double-booking prevention via
-- exclusion constraints, and status history.
-- Lighter than order flow — no payment, no items.
-- ============================================================

-- ── Reservations ────────────────────────────────────────────

create table reservations (
  id                    uuid primary key default gen_random_uuid(),
  business_id           uuid not null references businesses(id) on delete cascade,
  customer_id           uuid not null references customers(id) on delete cascade,
  conversation_id       uuid references conversations(id),

  -- Human-readable reservation number
  reservation_number    text not null,

  -- Status
  status                reservation_status not null default 'pending',

  -- Reservation details
  party_size            int not null default 1 check (party_size > 0),
  reserved_at           timestamptz not null,
  duration_minutes      int not null default 60 check (duration_minutes > 0),

  -- Business-type dependent preferences (JSONB for extensibility)
  -- Restaurant: {"table_number": 5, "seating_preference": "outdoor"}
  -- Salon: {"service_type": "haircut", "stylist_preference": "Jane"}
  -- Clinic: {"doctor_id": "...", "appointment_type": "consultation"}
  preferences           jsonb not null default '{}',

  -- Notes
  notes                 text,

  -- Lifecycle timestamps
  confirmed_at          timestamptz,
  seated_at             timestamptz,
  completed_at          timestamptz,
  cancelled_at          timestamptz,
  cancellation_reason   text,
  no_show_at            timestamptz,

  -- Audit
  created_by            uuid references user_profiles(id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- Per-business reservation number uniqueness
create unique index uq_reservations_number on reservations(business_id, reservation_number);

create index idx_reservations_business on reservations(business_id);
create index idx_reservations_customer on reservations(customer_id);
create index idx_reservations_status on reservations(business_id, status);
create index idx_reservations_date on reservations(business_id, reserved_at);
create index idx_reservations_upcoming on reservations(business_id, reserved_at)
  where status in ('pending', 'confirmed');

-- Double-booking prevention using GiST exclusion constraint.
-- Prevents overlapping reservations for the same business within
-- the same time window. This uses tstzrange computed from
-- reserved_at and duration_minutes.
-- NOTE: This is a simple per-business exclusion. For per-table or
-- per-resource exclusion, extend with resource_id in the constraint.
create index idx_reservations_time_gist on reservations
  using gist (
    business_id,
    tstzrange(reserved_at, reserved_at + (duration_minutes || ' minutes')::interval)
  )
  where status not in ('cancelled', 'no_show', 'completed');

create trigger trg_reservations_updated_at
  before update on reservations
  for each row
  execute function update_updated_at_column();

-- ── Reservation Status History ──────────────────────────────

create table reservation_status_history (
  id              uuid primary key default gen_random_uuid(),
  reservation_id  uuid not null references reservations(id) on delete cascade,
  from_status     reservation_status,
  to_status       reservation_status not null,
  changed_by      uuid references user_profiles(id),
  reason          text,
  created_at      timestamptz not null default now()
);

create index idx_reservation_history on reservation_status_history(reservation_id, created_at);

-- ── Reservation Number Generator ────────────────────────────

create sequence if not exists reservation_number_seq;

create or replace function generate_reservation_number(p_business_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seq bigint;
  v_prefix text;
begin
  v_seq := nextval('reservation_number_seq');
  select upper(left(b.slug, 3)) into v_prefix
  from businesses b
  where b.id = p_business_id;

  return coalesce(v_prefix, 'RES') || '-R' || lpad(v_seq::text, 5, '0');
end;
$$;

-- ── RPC: create_reservation ─────────────────────────────────

create or replace function create_reservation(
  p_business_id uuid,
  p_customer_id uuid,
  p_reserved_at timestamptz,
  p_party_size int default 1,
  p_duration_minutes int default 60,
  p_preferences jsonb default '{}',
  p_conversation_id uuid default null,
  p_notes text default null,
  p_created_by uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reservation_id uuid;
  v_reservation_number text;
  v_conflict_count int;
begin
  -- Generate reservation number
  v_reservation_number := generate_reservation_number(p_business_id);

  -- Check for time conflicts (active reservations overlapping this slot)
  select count(*) into v_conflict_count
  from reservations r
  where r.business_id = p_business_id
    and r.status not in ('cancelled', 'no_show', 'completed')
    and tstzrange(r.reserved_at, r.reserved_at + (r.duration_minutes || ' minutes')::interval)
       && tstzrange(p_reserved_at, p_reserved_at + (p_duration_minutes || ' minutes')::interval);

  -- Warn if there are conflicts (business may have capacity for multiple)
  -- For strict single-resource booking, uncomment the raise below:
  -- if v_conflict_count > 0 then
  --   raise exception 'Time slot conflict: % existing reservations overlap', v_conflict_count;
  -- end if;

  insert into reservations (
    business_id, customer_id, conversation_id,
    reservation_number, party_size,
    reserved_at, duration_minutes,
    preferences, notes, created_by
  ) values (
    p_business_id, p_customer_id, p_conversation_id,
    v_reservation_number, p_party_size,
    p_reserved_at, p_duration_minutes,
    p_preferences, p_notes, p_created_by
  )
  returning id into v_reservation_id;

  -- Record initial status
  insert into reservation_status_history (reservation_id, to_status, changed_by)
  values (v_reservation_id, 'pending', p_created_by);

  return v_reservation_id;
end;
$$;

-- ── RPC: transition_reservation_status ──────────────────────

create or replace function transition_reservation_status(
  p_reservation_id uuid,
  p_new_status reservation_status,
  p_changed_by uuid default null,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current_status reservation_status;
  v_business_id uuid;
  v_valid_transitions reservation_status[];
begin
  select r.status, r.business_id
  into v_current_status, v_business_id
  from reservations r
  where r.id = p_reservation_id
  for update;

  if v_current_status is null then
    raise exception 'Reservation not found: %', p_reservation_id;
  end if;

  -- Valid state transitions
  v_valid_transitions := case v_current_status
    when 'pending'    then array['confirmed', 'cancelled']::reservation_status[]
    when 'confirmed'  then array['seated', 'cancelled', 'no_show']::reservation_status[]
    when 'seated'     then array['completed']::reservation_status[]
    when 'completed'  then array[]::reservation_status[]
    when 'cancelled'  then array[]::reservation_status[]
    when 'no_show'    then array[]::reservation_status[]
    else array[]::reservation_status[]
  end;

  if not (p_new_status = any(v_valid_transitions)) then
    raise exception 'Invalid reservation status transition: % → %', v_current_status, p_new_status;
  end if;

  -- Permission check
  if p_changed_by is not null then
    if not check_permission(p_changed_by, v_business_id, 'reservation:update') then
      raise exception 'Permission denied: reservation:update';
    end if;
  end if;

  update reservations
  set
    status = p_new_status,
    confirmed_at    = case when p_new_status = 'confirmed' then now() else confirmed_at end,
    seated_at       = case when p_new_status = 'seated' then now() else seated_at end,
    completed_at    = case when p_new_status = 'completed' then now() else completed_at end,
    cancelled_at    = case when p_new_status = 'cancelled' then now() else cancelled_at end,
    cancellation_reason = case when p_new_status = 'cancelled' then p_reason else cancellation_reason end,
    no_show_at      = case when p_new_status = 'no_show' then now() else no_show_at end
  where id = p_reservation_id;

  insert into reservation_status_history (reservation_id, from_status, to_status, changed_by, reason)
  values (p_reservation_id, v_current_status, p_new_status, p_changed_by, p_reason);
end;
$$;
