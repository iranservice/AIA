-- ============================================================
-- 00000 — Auth Mock for Local Testing
--
-- Simulates Supabase auth schema for local PostgreSQL testing.
-- In production Supabase, this schema is provided natively.
-- This file is ONLY applied to local test databases.
-- ============================================================

-- Create auth schema (Supabase provides this natively)
CREATE SCHEMA IF NOT EXISTS auth;

-- Minimal auth.users table matching Supabase structure
CREATE TABLE IF NOT EXISTS auth.users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email         TEXT UNIQUE,
  phone         TEXT,
  raw_user_meta_data JSONB DEFAULT '{}'::jsonb,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

-- Supabase RLS helper: auth.uid()
-- Reads from request.jwt.claims set via SET LOCAL
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS UUID
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')::uuid,
    '00000000-0000-0000-0000-000000000000'::uuid
  );
$$;

-- Supabase RLS helper: auth.jwt()
CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS JSONB
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    current_setting('request.jwt.claims', true)::jsonb,
    '{}'::jsonb
  );
$$;

-- Supabase RLS helper: auth.role()
CREATE OR REPLACE FUNCTION auth.role()
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    current_setting('request.jwt.claims', true)::jsonb ->> 'role',
    'anon'
  );
$$;

-- Create roles that Supabase normally provides
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END $$;

-- Grant schema usage
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

-- Grant on auth tables
GRANT ALL ON ALL TABLES IN SCHEMA auth TO anon, authenticated, service_role;

-- Default privileges: any table/seq/func created by aia_user in public schema
-- will automatically be accessible by these roles.
-- This must run BEFORE domain migrations so grants cascade to all new tables.
ALTER DEFAULT PRIVILEGES FOR ROLE aia_user IN SCHEMA public
  GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE aia_user IN SCHEMA public
  GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE aia_user IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
