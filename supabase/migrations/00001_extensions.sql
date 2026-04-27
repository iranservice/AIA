-- ============================================================
-- Migration 00001: Extensions
-- Enables required PostgreSQL extensions for AIA platform.
-- ============================================================

-- UUID generation
create extension if not exists "uuid-ossp" schema extensions;

-- Cryptographic functions (for hashing, token generation)
create extension if not exists "pgcrypto" schema extensions;

-- Trigram similarity for fuzzy text search (customer name search, etc.)
create extension if not exists "pg_trgm" schema public;

-- GiST index support for range exclusion constraints (reservation double-booking prevention)
create extension if not exists "btree_gist" schema public;
