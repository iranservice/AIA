-- ============================================================
-- Migration 00024: Fix RLS infinite recursion on business_memberships
--
-- Problem:
--   The "managers_manage_memberships" policy (FOR ALL) on business_memberships
--   contains a self-referencing subquery:
--
--     exists(select 1 from business_memberships bm where ...)
--
--   When PostgreSQL evaluates a SELECT on business_memberships, it must check
--   ALL applicable policies — including FOR ALL policies. The USING clause of
--   managers_manage_memberships queries business_memberships itself, which
--   triggers the same policy evaluation, creating infinite recursion.
--   PostgreSQL raises error 42P17: "infinite recursion detected in policy
--   for relation business_memberships".
--
-- Fix:
--   1. Create a SECURITY DEFINER helper function that bypasses RLS to check
--      if the current user is a manager or owner of the given business.
--   2. Drop the recursive FOR ALL policy.
--   3. Replace with three separate command-specific policies (INSERT, UPDATE,
--      DELETE) that use the SECURITY DEFINER helper. This avoids the recursion
--      because SECURITY DEFINER functions execute as the function owner
--      (superuser), which is not subject to RLS.
--   4. The existing "members_read_memberships" SELECT policy (which already
--      uses the SECURITY DEFINER function is_business_member()) covers reads.
--
-- Risk: Low. This is a surgical policy replacement with no schema changes.
-- Rollback: Re-create the original FOR ALL policy (will re-introduce bug).
-- ============================================================

-- ── Step 1: Create SECURITY DEFINER helper ─────────────────

CREATE OR REPLACE FUNCTION is_business_manager_or_owner(p_business_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS(
    SELECT 1 FROM business_memberships
    WHERE user_id = auth.uid()
      AND business_id = p_business_id
      AND role IN ('owner', 'manager')
      AND is_active = true
  );
END;
$$;

-- ── Step 2: Drop the recursive FOR ALL policy ──────────────

DROP POLICY IF EXISTS "managers_manage_memberships" ON business_memberships;

-- Also drop the runtime-patched policies if they exist from Phase VII-D
DROP POLICY IF EXISTS "managers_insert_memberships" ON business_memberships;
DROP POLICY IF EXISTS "managers_update_memberships" ON business_memberships;
DROP POLICY IF EXISTS "managers_delete_memberships" ON business_memberships;

-- ── Step 3: Create non-recursive command-specific policies ─

-- Owners/managers can INSERT new memberships
CREATE POLICY "managers_insert_memberships" ON business_memberships
  FOR INSERT
  WITH CHECK (is_business_manager_or_owner(business_id));

-- Owners/managers can UPDATE existing memberships
CREATE POLICY "managers_update_memberships" ON business_memberships
  FOR UPDATE
  USING (is_business_manager_or_owner(business_id));

-- Owners/managers can DELETE memberships
CREATE POLICY "managers_delete_memberships" ON business_memberships
  FOR DELETE
  USING (is_business_manager_or_owner(business_id));
