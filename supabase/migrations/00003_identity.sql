-- ============================================================
-- Migration 00003: Identity
-- User profiles extending Supabase auth.users.
-- Trigger for automatic profile creation on signup.
-- ============================================================

-- ── User Profiles ───────────────────────────────────────────

create table user_profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  display_name  text,
  phone         text,
  email         text,
  avatar_url    text,

  -- Preferences
  preferred_language text default 'en',
  timezone           text default 'UTC',

  -- Platform-level role (NULL = regular user, not a platform operator)
  platform_role platform_role,

  -- Status
  is_active     boolean not null default true,
  last_seen_at  timestamptz,

  -- Timestamps
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Index for phone/email lookups
create index idx_user_profiles_phone on user_profiles(phone) where phone is not null;
create index idx_user_profiles_email on user_profiles(email) where email is not null;
create index idx_user_profiles_platform_role on user_profiles(platform_role) where platform_role is not null;

-- ── Auto-create profile on signup ───────────────────────────

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into user_profiles (
    id,
    display_name,
    phone,
    email
  ) values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      split_part(new.email, '@', 1)
    ),
    coalesce(new.phone, new.raw_user_meta_data ->> 'phone'),
    new.email
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function handle_new_user();

-- ── Updated-at trigger ──────────────────────────────────────

create or replace function update_updated_at_column()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_user_profiles_updated_at
  before update on user_profiles
  for each row
  execute function update_updated_at_column();
