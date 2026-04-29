-- ============================================================
-- Migration 00023: Business Settings & Members RPCs
-- Phase II-A backend contracts for frontend Business Settings
-- and Members pages.
-- ============================================================

-- ═══════════════════════════════════════════════════════════
-- 1. get_my_workspaces()
-- Returns businesses the current authenticated user can access.
-- Uses auth.uid() — never accepts arbitrary user_id.
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_my_workspaces()
RETURNS TABLE (
  business_id       uuid,
  business_slug     text,
  business_name     text,
  business_type     business_type,
  membership_id     uuid,
  membership_role   membership_role,
  membership_is_active boolean,
  is_owner_or_admin boolean,
  platform_role     platform_role,
  default_workspace boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_platform_role platform_role;
BEGIN
  IF v_uid IS NULL OR v_uid = '00000000-0000-0000-0000-000000000000'::uuid THEN
    RETURN;
  END IF;

  SELECT up.platform_role INTO v_platform_role
  FROM user_profiles up WHERE up.id = v_uid;

  RETURN QUERY
    SELECT
      b.id                    AS business_id,
      b.slug                  AS business_slug,
      b.name                  AS business_name,
      b.business_type         AS business_type,
      bm.id                   AS membership_id,
      bm.role                 AS membership_role,
      bm.is_active            AS membership_is_active,
      (bm.role IN ('owner', 'manager')) AS is_owner_or_admin,
      v_platform_role         AS platform_role,
      (ROW_NUMBER() OVER (ORDER BY bm.joined_at ASC) = 1) AS default_workspace
    FROM business_memberships bm
    JOIN businesses b ON b.id = bm.business_id
    WHERE bm.user_id = v_uid
      AND bm.is_active = true
      AND b.is_active = true
    ORDER BY bm.joined_at ASC;
END;
$$;

-- ═══════════════════════════════════════════════════════════
-- 2. get_my_platform_access()
-- Returns platform-level access info for current user.
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_my_platform_access()
RETURNS TABLE (
  user_id            uuid,
  platform_role      platform_role,
  is_platform_admin  boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role platform_role;
BEGIN
  IF v_uid IS NULL OR v_uid = '00000000-0000-0000-0000-000000000000'::uuid THEN
    RETURN QUERY SELECT
      '00000000-0000-0000-0000-000000000000'::uuid,
      NULL::platform_role,
      false;
    RETURN;
  END IF;

  SELECT up.platform_role INTO v_role
  FROM user_profiles up WHERE up.id = v_uid;

  RETURN QUERY SELECT
    v_uid,
    v_role,
    COALESCE(v_role IN ('super_admin', 'platform_admin'), false);
END;
$$;

-- ═══════════════════════════════════════════════════════════
-- 3. get_business_profile(p_business_id)
-- Returns tenant business profile for settings pages.
-- Caller must be active member or platform admin.
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_business_profile(p_business_id uuid)
RETURNS TABLE (
  business_id       uuid,
  slug              text,
  name              text,
  business_type     business_type,
  logo_url          text,
  phone             text,
  email             text,
  timezone          text,
  default_language  text,
  business_config   jsonb,
  subscription_tier text,
  is_active         boolean,
  created_at        timestamptz,
  updated_at        timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_is_member boolean;
BEGIN
  -- Platform admin bypass
  IF is_platform_admin(v_uid) THEN
    RETURN QUERY
      SELECT b.id, b.slug, b.name, b.business_type,
             (b.business_config->>'logo_url')::text,
             (b.business_config->>'phone')::text,
             (b.business_config->>'email')::text,
             b.timezone, b.default_language,
             b.business_config, b.subscription_tier,
             b.is_active, b.created_at, b.updated_at
      FROM businesses b WHERE b.id = p_business_id;
    RETURN;
  END IF;

  -- Check active membership
  SELECT EXISTS(
    SELECT 1 FROM business_memberships bm
    WHERE bm.user_id = v_uid AND bm.business_id = p_business_id AND bm.is_active = true
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RETURN; -- empty result = access denied
  END IF;

  RETURN QUERY
    SELECT b.id, b.slug, b.name, b.business_type,
           (b.business_config->>'logo_url')::text,
           (b.business_config->>'phone')::text,
           (b.business_config->>'email')::text,
           b.timezone, b.default_language,
           b.business_config, b.subscription_tier,
           b.is_active, b.created_at, b.updated_at
    FROM businesses b WHERE b.id = p_business_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════
-- 4. update_business_profile(...)
-- Allows owner/manager/platform_admin to update profile.
-- Writes audit log on success.
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION update_business_profile(
  p_business_id      uuid,
  p_name             text        DEFAULT NULL,
  p_logo_url         text        DEFAULT NULL,
  p_phone            text        DEFAULT NULL,
  p_email            text        DEFAULT NULL,
  p_timezone         text        DEFAULT NULL,
  p_default_language text        DEFAULT NULL,
  p_business_config  jsonb       DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role membership_role;
  v_is_active boolean;
  v_old jsonb;
  v_new jsonb;
BEGIN
  -- Platform admin bypass
  IF NOT is_platform_admin(v_uid) THEN
    SELECT bm.role, bm.is_active INTO v_role, v_is_active
    FROM business_memberships bm
    WHERE bm.user_id = v_uid AND bm.business_id = p_business_id
    LIMIT 1;

    IF v_role IS NULL THEN
      RAISE EXCEPTION 'ACCESS_DENIED: not a member of this business';
    END IF;
    IF NOT v_is_active THEN
      RAISE EXCEPTION 'ACCESS_DENIED: membership is inactive';
    END IF;
    IF v_role NOT IN ('owner', 'manager') THEN
      RAISE EXCEPTION 'ACCESS_DENIED: insufficient role (%)' , v_role;
    END IF;
  END IF;

  -- Capture old state
  SELECT jsonb_build_object(
    'name', b.name, 'timezone', b.timezone,
    'default_language', b.default_language,
    'business_config', b.business_config
  ) INTO v_old
  FROM businesses b WHERE b.id = p_business_id;

  IF v_old IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: business % does not exist', p_business_id;
  END IF;

  -- Apply updates
  UPDATE businesses SET
    name             = COALESCE(p_name, name),
    timezone         = COALESCE(p_timezone, timezone),
    default_language = COALESCE(p_default_language, default_language),
    business_config  = CASE
      WHEN p_business_config IS NOT NULL THEN business_config || p_business_config
      ELSE business_config
    END || jsonb_strip_nulls(jsonb_build_object(
      'logo_url', p_logo_url,
      'phone',    p_phone,
      'email',    p_email
    ))
  WHERE id = p_business_id;

  -- Capture new state
  SELECT jsonb_build_object(
    'name', b.name, 'timezone', b.timezone,
    'default_language', b.default_language,
    'business_config', b.business_config
  ) INTO v_new
  FROM businesses b WHERE b.id = p_business_id;

  -- Audit log
  PERFORM log_audit(
    p_action      := 'business.profile_updated',
    p_entity_type := 'business',
    p_entity_id   := p_business_id,
    p_business_id := p_business_id,
    p_user_id     := v_uid,
    p_severity    := 'info',
    p_old_values  := v_old,
    p_new_values  := v_new,
    p_metadata    := jsonb_build_object('source', 'update_business_profile')
  );

  RETURN v_new;
END;
$$;

-- ═══════════════════════════════════════════════════════════
-- 5. get_business_members(p_business_id)
-- Returns members for the Members page.
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_business_members(p_business_id uuid)
RETURNS TABLE (
  membership_id  uuid,
  user_id        uuid,
  display_name   text,
  email          text,
  phone          text,
  avatar_url     text,
  role           membership_role,
  is_active      boolean,
  joined_at      timestamptz,
  created_at     timestamptz,
  last_seen_at   timestamptz,
  status         text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_caller_role membership_role;
  v_caller_active boolean;
BEGIN
  -- Platform admin bypass
  IF NOT is_platform_admin(v_uid) THEN
    SELECT bm.role, bm.is_active INTO v_caller_role, v_caller_active
    FROM business_memberships bm
    WHERE bm.user_id = v_uid AND bm.business_id = p_business_id
    LIMIT 1;

    IF v_caller_role IS NULL THEN
      RETURN; -- not a member = empty
    END IF;
    IF NOT v_caller_active THEN
      RETURN; -- inactive = empty
    END IF;
    -- owner/manager can always list; operator/viewer denied
    IF v_caller_role NOT IN ('owner', 'manager') THEN
      RETURN;
    END IF;
  END IF;

  RETURN QUERY
    SELECT
      bm.id              AS membership_id,
      bm.user_id         AS user_id,
      up.display_name    AS display_name,
      up.email           AS email,
      up.phone           AS phone,
      up.avatar_url      AS avatar_url,
      bm.role            AS role,
      bm.is_active       AS is_active,
      bm.joined_at       AS joined_at,
      bm.created_at      AS created_at,
      up.last_seen_at    AS last_seen_at,
      CASE
        WHEN bm.is_active = false THEN 'inactive'
        ELSE 'active'
      END                AS status
    FROM business_memberships bm
    JOIN user_profiles up ON up.id = bm.user_id
    WHERE bm.business_id = p_business_id
    ORDER BY bm.role ASC, bm.joined_at ASC;
END;
$$;

-- ═══════════════════════════════════════════════════════════
-- 6. update_business_member_role(p_membership_id, p_new_role)
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION update_business_member_role(
  p_membership_id uuid,
  p_new_role      membership_role
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_target_biz uuid;
  v_target_user uuid;
  v_old_role membership_role;
  v_caller_role membership_role;
  v_caller_active boolean;
BEGIN
  -- Get target membership
  SELECT bm.business_id, bm.user_id, bm.role
  INTO v_target_biz, v_target_user, v_old_role
  FROM business_memberships bm WHERE bm.id = p_membership_id;

  IF v_target_biz IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: membership % does not exist', p_membership_id;
  END IF;

  -- Authz: platform admin or owner/manager of same business
  IF NOT is_platform_admin(v_uid) THEN
    SELECT bm.role, bm.is_active INTO v_caller_role, v_caller_active
    FROM business_memberships bm
    WHERE bm.user_id = v_uid AND bm.business_id = v_target_biz
    LIMIT 1;

    IF v_caller_role IS NULL OR NOT v_caller_active THEN
      RAISE EXCEPTION 'ACCESS_DENIED: not an active member';
    END IF;
    IF v_caller_role NOT IN ('owner', 'manager') THEN
      RAISE EXCEPTION 'ACCESS_DENIED: insufficient role';
    END IF;
    -- Manager cannot promote to owner
    IF v_caller_role = 'manager' AND p_new_role = 'owner' THEN
      RAISE EXCEPTION 'ACCESS_DENIED: managers cannot promote to owner';
    END IF;
  END IF;

  -- Apply
  UPDATE business_memberships SET role = p_new_role WHERE id = p_membership_id;

  -- Audit
  PERFORM log_audit(
    p_action      := 'member.role_updated',
    p_entity_type := 'business_membership',
    p_entity_id   := p_membership_id,
    p_business_id := v_target_biz,
    p_user_id     := v_uid,
    p_severity    := 'warning',
    p_old_values  := jsonb_build_object('role', v_old_role::text),
    p_new_values  := jsonb_build_object('role', p_new_role::text),
    p_metadata    := jsonb_build_object('target_user', v_target_user)
  );

  RETURN jsonb_build_object('membership_id', p_membership_id, 'new_role', p_new_role::text);
END;
$$;

-- ═══════════════════════════════════════════════════════════
-- 7. deactivate_business_member(p_membership_id)
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION deactivate_business_member(p_membership_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_target_biz uuid;
  v_target_user uuid;
  v_target_role membership_role;
  v_caller_role membership_role;
  v_caller_active boolean;
  v_owner_count int;
BEGIN
  -- Get target membership
  SELECT bm.business_id, bm.user_id, bm.role
  INTO v_target_biz, v_target_user, v_target_role
  FROM business_memberships bm WHERE bm.id = p_membership_id;

  IF v_target_biz IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: membership % does not exist', p_membership_id;
  END IF;

  -- Prevent deactivating last owner
  IF v_target_role = 'owner' THEN
    SELECT count(*) INTO v_owner_count
    FROM business_memberships
    WHERE business_id = v_target_biz AND role = 'owner' AND is_active = true;

    IF v_owner_count <= 1 THEN
      RAISE EXCEPTION 'BUSINESS_LOCKOUT: cannot deactivate the last owner';
    END IF;
  END IF;

  -- Authz
  IF NOT is_platform_admin(v_uid) THEN
    SELECT bm.role, bm.is_active INTO v_caller_role, v_caller_active
    FROM business_memberships bm
    WHERE bm.user_id = v_uid AND bm.business_id = v_target_biz
    LIMIT 1;

    IF v_caller_role IS NULL OR NOT v_caller_active THEN
      RAISE EXCEPTION 'ACCESS_DENIED: not an active member';
    END IF;
    IF v_caller_role NOT IN ('owner', 'manager') THEN
      RAISE EXCEPTION 'ACCESS_DENIED: insufficient role';
    END IF;
  END IF;

  -- Deactivate
  UPDATE business_memberships SET is_active = false WHERE id = p_membership_id;

  -- Audit
  PERFORM log_audit(
    p_action      := 'member.deactivated',
    p_entity_type := 'business_membership',
    p_entity_id   := p_membership_id,
    p_business_id := v_target_biz,
    p_user_id     := v_uid,
    p_severity    := 'warning',
    p_old_values  := jsonb_build_object('is_active', true, 'role', v_target_role::text),
    p_new_values  := jsonb_build_object('is_active', false),
    p_metadata    := jsonb_build_object('target_user', v_target_user)
  );

  RETURN jsonb_build_object('membership_id', p_membership_id, 'deactivated', true);
END;
$$;

-- ═══════════════════════════════════════════════════════════
-- 8. invite_business_member(...) — Foundation only
-- Creates invite record. No email sending.
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION invite_business_member(
  p_business_id uuid,
  p_email       text,
  p_role        membership_role DEFAULT 'operator'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_caller_role membership_role;
  v_caller_active boolean;
  v_existing_user uuid;
  v_existing_membership uuid;
  v_membership_id uuid;
BEGIN
  -- Authz
  IF NOT is_platform_admin(v_uid) THEN
    SELECT bm.role, bm.is_active INTO v_caller_role, v_caller_active
    FROM business_memberships bm
    WHERE bm.user_id = v_uid AND bm.business_id = p_business_id
    LIMIT 1;

    IF v_caller_role IS NULL OR NOT v_caller_active THEN
      RAISE EXCEPTION 'ACCESS_DENIED: not an active member';
    END IF;
    IF v_caller_role NOT IN ('owner', 'manager') THEN
      RAISE EXCEPTION 'ACCESS_DENIED: insufficient role to invite';
    END IF;
    IF v_caller_role = 'manager' AND p_role = 'owner' THEN
      RAISE EXCEPTION 'ACCESS_DENIED: managers cannot invite as owner';
    END IF;
  END IF;

  -- Check if user already exists by email
  SELECT up.id INTO v_existing_user
  FROM user_profiles up WHERE up.email = p_email LIMIT 1;

  IF v_existing_user IS NOT NULL THEN
    -- Check if already a member
    SELECT bm.id INTO v_existing_membership
    FROM business_memberships bm
    WHERE bm.user_id = v_existing_user AND bm.business_id = p_business_id
    LIMIT 1;

    IF v_existing_membership IS NOT NULL THEN
      RAISE EXCEPTION 'CONFLICT: user already has membership in this business';
    END IF;

    -- Create membership directly for existing user
    INSERT INTO business_memberships (business_id, user_id, role, is_active, invited_by)
    VALUES (p_business_id, v_existing_user, p_role, true, v_uid)
    RETURNING id INTO v_membership_id;
  ELSE
    -- No user yet — create a placeholder membership record
    -- This will be resolved when the user signs up with this email
    -- For now, we store the intent as metadata in audit
    v_membership_id := NULL;
  END IF;

  -- Audit
  PERFORM log_audit(
    p_action      := 'member.invited',
    p_entity_type := 'business_membership',
    p_entity_id   := v_membership_id,
    p_business_id := p_business_id,
    p_user_id     := v_uid,
    p_severity    := 'info',
    p_metadata    := jsonb_build_object(
      'invited_email', p_email,
      'invited_role', p_role::text,
      'existing_user', v_existing_user IS NOT NULL,
      'source', 'invite_business_member'
    )
  );

  RETURN jsonb_build_object(
    'business_id', p_business_id,
    'email', p_email,
    'role', p_role::text,
    'invited_by', v_uid,
    'membership_id', v_membership_id,
    'status', CASE WHEN v_existing_user IS NOT NULL THEN 'joined' ELSE 'pending_signup' END
  );
END;
$$;

-- ═══════════════════════════════════════════════════════════
-- 9. Teams Foundation
-- No teams table exists in current schema.
-- Documented as gap — placeholder function returns empty.
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_business_teams(p_business_id uuid)
RETURNS TABLE (
  team_id   uuid,
  team_name text,
  member_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- GAP: No teams table exists in current schema.
  -- This is a placeholder that returns empty until teams are implemented.
  RETURN;
END;
$$;
