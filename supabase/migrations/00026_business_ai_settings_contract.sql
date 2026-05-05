-- ============================================================
-- 00026 — Business AI Settings Contract
--
-- Phase: VIII-B
-- Depends: 00005_rbac (policy_rules, evaluate_policy),
--          00020_ai_reply_handoff (release_to_ai),
--          00025_release_to_ai_with_reply
--
-- Adds:
--   1. get_business_ai_settings(p_business_id) — Read AI config
--   2. update_business_ai_settings(p_business_id, p_settings) — Write AI config
--
-- Design:
--   - Uses existing policy_rules table (rule_type='ai_allowed')
--   - No new tables created
--   - Strict JSONB key allowlist for update
--   - provider_mode locked to 'mock_sql' only
--   - API key / secret fields actively rejected
--   - Compatible with evaluate_policy() used by release_to_ai()
--   - Audit log on every settings change
-- ============================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════
-- 1. get_business_ai_settings(p_business_id)
--
-- Returns the current AI configuration for a business.
-- Any active member can read. Non-members get empty result.
-- If no ai_allowed policy exists, returns safe defaults
-- with ai_enabled=false.
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_business_ai_settings(
  p_business_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_uid         UUID := auth.uid();
  v_is_member   BOOLEAN;
  v_rule        RECORD;
  v_config      JSONB;
BEGIN
  -- Auth: require authenticated user
  IF v_uid IS NULL THEN
    RETURN NULL;
  END IF;

  -- Platform admin bypass
  IF NOT is_platform_admin(v_uid) THEN
    SELECT EXISTS(
      SELECT 1 FROM business_memberships bm
      WHERE bm.user_id = v_uid
        AND bm.business_id = p_business_id
        AND bm.is_active = true
    ) INTO v_is_member;

    IF NOT v_is_member THEN
      RETURN NULL;  -- non-member: silent deny (empty result)
    END IF;
  END IF;

  -- Check business exists
  IF NOT EXISTS(SELECT 1 FROM businesses WHERE id = p_business_id) THEN
    RETURN jsonb_build_object('error', 'NOT_FOUND',
      'message', 'Business does not exist');
  END IF;

  -- Read policy_rules row for ai_allowed
  SELECT pr.id, pr.rule_config, pr.is_active, pr.updated_at
  INTO v_rule
  FROM policy_rules pr
  WHERE pr.business_id = p_business_id
    AND pr.rule_type = 'ai_allowed'
  LIMIT 1;

  -- If no row exists, return defaults (AI disabled)
  IF v_rule.id IS NULL THEN
    RETURN jsonb_build_object(
      'business_id', p_business_id,
      'ai_enabled', false,
      'provider_mode', 'mock_sql',
      'auto_reply_enabled', false,
      'require_human_approval', true,
      'max_context_messages', 20,
      'allowed_channels', '[]'::jsonb,
      'policy_rule_id', NULL,
      'updated_at', NULL
    );
  END IF;

  v_config := COALESCE(v_rule.rule_config, '{}'::jsonb);

  RETURN jsonb_build_object(
    'business_id', p_business_id,
    'ai_enabled', COALESCE(v_rule.is_active AND (v_config ->> 'enabled')::boolean, false),
    'provider_mode', COALESCE(v_config ->> 'provider_mode', 'mock_sql'),
    'auto_reply_enabled', COALESCE((v_config ->> 'auto_reply_enabled')::boolean, false),
    'require_human_approval', COALESCE((v_config ->> 'require_human_approval')::boolean, true),
    'max_context_messages', COALESCE((v_config ->> 'max_context_messages')::int, 20),
    'allowed_channels', COALESCE(v_config -> 'allowed_channels', '[]'::jsonb),
    'policy_rule_id', v_rule.id,
    'updated_at', v_rule.updated_at
  );
END;
$$;

-- ═══════════════════════════════════════════════════════════
-- 2. update_business_ai_settings(p_business_id, p_settings)
--
-- Enables/disables AI and updates configuration.
-- Owner or manager only. Validates strict key allowlist.
-- UPSERTs into policy_rules with rule_type='ai_allowed'.
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION update_business_ai_settings(
  p_business_id UUID,
  p_settings    JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_uid              UUID := auth.uid();
  v_role             membership_role;
  v_is_active        BOOLEAN;
  v_key              TEXT;
  v_ai_enabled       BOOLEAN;
  v_old_config       JSONB;
  v_new_config       JSONB;
  v_rule_id          UUID;
  v_allowed_keys     TEXT[] := ARRAY[
    'ai_enabled',
    'provider_mode',
    'auto_reply_enabled',
    'require_human_approval',
    'max_context_messages',
    'allowed_channels'
  ];
  v_forbidden_keys   TEXT[] := ARRAY[
    'api_key', 'secret', 'openai_api_key', 'anthropic_api_key',
    'token', 'password', 'service_role', 'credentials'
  ];
  v_max_ctx          INT;
  v_provider_mode    TEXT;
  v_valid_channels   TEXT[] := ARRAY[
    'whatsapp', 'web_chat', 'sms', 'email', 'voice', 'telegram'
  ];
  v_channel          TEXT;
BEGIN
  -- ──────────────────────────────────────────────────
  -- Step 1: Auth check
  -- ──────────────────────────────────────────────────
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'AUTH_REQUIRED',
      'message', 'Authentication required');
  END IF;

  IF NOT is_platform_admin(v_uid) THEN
    SELECT bm.role, bm.is_active INTO v_role, v_is_active
    FROM business_memberships bm
    WHERE bm.user_id = v_uid AND bm.business_id = p_business_id
    LIMIT 1;

    IF v_role IS NULL THEN
      RETURN jsonb_build_object('error', 'ACCESS_DENIED',
        'message', 'Not a member of this business');
    END IF;
    IF NOT v_is_active THEN
      RETURN jsonb_build_object('error', 'ACCESS_DENIED',
        'message', 'Membership is inactive');
    END IF;
    IF v_role NOT IN ('owner', 'manager') THEN
      RETURN jsonb_build_object('error', 'PERMISSION_DENIED',
        'message', 'Only owners and managers can update AI settings');
    END IF;
  END IF;

  -- Check business exists
  IF NOT EXISTS(SELECT 1 FROM businesses WHERE id = p_business_id) THEN
    RETURN jsonb_build_object('error', 'NOT_FOUND',
      'message', 'Business does not exist');
  END IF;

  -- ──────────────────────────────────────────────────
  -- Step 2: Validate input keys
  -- ──────────────────────────────────────────────────

  -- Reject forbidden keys (security)
  FOR v_key IN SELECT jsonb_object_keys(p_settings)
  LOOP
    IF v_key = ANY(v_forbidden_keys) THEN
      RETURN jsonb_build_object('error', 'FORBIDDEN_SETTING',
        'message', format('Setting "%s" is not allowed', v_key));
    END IF;
    IF NOT (v_key = ANY(v_allowed_keys)) THEN
      RETURN jsonb_build_object('error', 'INVALID_SETTING',
        'message', format('Unknown setting "%s"', v_key));
    END IF;
  END LOOP;

  -- ai_enabled is required
  IF NOT (p_settings ? 'ai_enabled') THEN
    RETURN jsonb_build_object('error', 'VALIDATION_ERROR',
      'message', 'ai_enabled is required');
  END IF;

  v_ai_enabled := (p_settings ->> 'ai_enabled')::boolean;

  -- Validate provider_mode (must be mock_sql or absent)
  IF p_settings ? 'provider_mode' THEN
    v_provider_mode := p_settings ->> 'provider_mode';
    IF v_provider_mode IS DISTINCT FROM 'mock_sql' THEN
      RETURN jsonb_build_object('error', 'INVALID_PROVIDER',
        'message', format('Provider mode "%s" is not supported. Only "mock_sql" is allowed.', v_provider_mode));
    END IF;
  END IF;

  -- Validate max_context_messages bounds
  IF p_settings ? 'max_context_messages' THEN
    v_max_ctx := (p_settings ->> 'max_context_messages')::int;
    IF v_max_ctx < 1 OR v_max_ctx > 50 THEN
      RETURN jsonb_build_object('error', 'VALIDATION_ERROR',
        'message', 'max_context_messages must be between 1 and 50');
    END IF;
  END IF;

  -- Validate allowed_channels
  IF p_settings ? 'allowed_channels' THEN
    IF jsonb_typeof(p_settings -> 'allowed_channels') != 'array' THEN
      RETURN jsonb_build_object('error', 'VALIDATION_ERROR',
        'message', 'allowed_channels must be an array');
    END IF;
    FOR v_channel IN SELECT jsonb_array_elements_text(p_settings -> 'allowed_channels')
    LOOP
      IF NOT (v_channel = ANY(v_valid_channels)) THEN
        RETURN jsonb_build_object('error', 'VALIDATION_ERROR',
          'message', format('Unknown channel "%s"', v_channel));
      END IF;
    END LOOP;
  END IF;

  -- ──────────────────────────────────────────────────
  -- Step 3: Capture old state
  -- ──────────────────────────────────────────────────
  SELECT pr.rule_config INTO v_old_config
  FROM policy_rules pr
  WHERE pr.business_id = p_business_id
    AND pr.rule_type = 'ai_allowed';

  -- ──────────────────────────────────────────────────
  -- Step 4: Build new config
  -- ──────────────────────────────────────────────────
  v_new_config := jsonb_build_object('enabled', v_ai_enabled);

  -- Merge optional settings
  IF p_settings ? 'provider_mode' THEN
    v_new_config := v_new_config || jsonb_build_object('provider_mode', p_settings ->> 'provider_mode');
  ELSE
    v_new_config := v_new_config || jsonb_build_object('provider_mode', 'mock_sql');
  END IF;

  IF p_settings ? 'auto_reply_enabled' THEN
    v_new_config := v_new_config || jsonb_build_object('auto_reply_enabled', (p_settings ->> 'auto_reply_enabled')::boolean);
  END IF;

  IF p_settings ? 'require_human_approval' THEN
    v_new_config := v_new_config || jsonb_build_object('require_human_approval', (p_settings ->> 'require_human_approval')::boolean);
  END IF;

  IF p_settings ? 'max_context_messages' THEN
    v_new_config := v_new_config || jsonb_build_object('max_context_messages', (p_settings ->> 'max_context_messages')::int);
  END IF;

  IF p_settings ? 'allowed_channels' THEN
    v_new_config := v_new_config || jsonb_build_object('allowed_channels', p_settings -> 'allowed_channels');
  END IF;

  -- ──────────────────────────────────────────────────
  -- Step 5: UPSERT into policy_rules
  -- ──────────────────────────────────────────────────
  INSERT INTO policy_rules (business_id, rule_type, rule_config, is_active)
  VALUES (p_business_id, 'ai_allowed', v_new_config, v_ai_enabled)
  ON CONFLICT (business_id, rule_type) DO UPDATE
  SET rule_config = v_new_config,
      is_active   = v_ai_enabled,
      updated_at  = now()
  RETURNING id INTO v_rule_id;

  -- ──────────────────────────────────────────────────
  -- Step 6: Audit log
  -- ──────────────────────────────────────────────────
  PERFORM log_audit(
    p_action      := 'ai_settings.updated',
    p_entity_type := 'policy_rule',
    p_entity_id   := v_rule_id,
    p_business_id := p_business_id,
    p_user_id     := v_uid,
    p_severity    := 'warning',
    p_old_values  := COALESCE(v_old_config, '{}'::jsonb),
    p_new_values  := v_new_config,
    p_metadata    := jsonb_build_object(
      'source', 'update_business_ai_settings',
      'ai_enabled', v_ai_enabled
    )
  );

  -- ──────────────────────────────────────────────────
  -- Step 7: Return updated settings
  -- ──────────────────────────────────────────────────
  RETURN get_business_ai_settings(p_business_id);
END;
$$;

COMMIT;
