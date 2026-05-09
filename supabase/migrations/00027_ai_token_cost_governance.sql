-- ============================================================
-- 00027 — AI Token/Cost Governance + Capability Router
-- Phase: IX-A
-- Depends: 00005, 00015, 00020, 00024, 00025, 00026
-- ============================================================
BEGIN;

-- ── 1. ai_capability_registry ──────────────────────────────
CREATE TABLE ai_capability_registry (
  code            TEXT PRIMARY KEY,
  display_name    TEXT NOT NULL,
  description     TEXT,
  risk_level      TEXT NOT NULL DEFAULT 'low' CHECK (risk_level IN ('low','medium','high','critical')),
  enabled_default BOOLEAN NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO ai_capability_registry (code, display_name, description, risk_level) VALUES
  ('reply_drafter','Reply Drafter','Primary AI reply generation','medium'),
  ('intent_classifier','Intent Classifier','Classify customer intent','low'),
  ('handoff_decider','Handoff Decider','Decide if human handoff needed','medium'),
  ('order_extractor','Order Extractor','Extract order details from conversation','medium'),
  ('appointment_extractor','Appointment Extractor','Extract appointment/reservation details','medium'),
  ('summarizer','Summarizer','Summarize conversation','low'),
  ('translator','Translator','Translate message content','low');

-- ── 2. ai_model_catalog ────────────────────────────────────
CREATE TABLE ai_model_catalog (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_mode     TEXT NOT NULL,
  model_code        TEXT NOT NULL UNIQUE,
  display_name      TEXT NOT NULL,
  supports_text     BOOLEAN NOT NULL DEFAULT true,
  supports_json     BOOLEAN NOT NULL DEFAULT false,
  supports_vision   BOOLEAN NOT NULL DEFAULT false,
  supports_audio    BOOLEAN NOT NULL DEFAULT false,
  input_token_cost  NUMERIC(12,8) NOT NULL DEFAULT 0,
  output_token_cost NUMERIC(12,8) NOT NULL DEFAULT 0,
  max_input_tokens  INT NOT NULL DEFAULT 4096,
  max_output_tokens INT NOT NULL DEFAULT 4096,
  is_active         BOOLEAN NOT NULL DEFAULT true,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO ai_model_catalog (provider_mode, model_code, display_name, input_token_cost, output_token_cost, is_active) VALUES
  ('mock_sql','mock-sql-v1','Mock SQL Provider v1',0,0,true),
  ('openai','gpt-4o','GPT-4o',0.0000025,0.00001,false),
  ('anthropic','claude-3-5-sonnet','Claude 3.5 Sonnet',0.000003,0.000015,false);

-- ── 3. ai_model_bindings ───────────────────────────────────
CREATE TABLE ai_model_bindings (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  capability_code   TEXT NOT NULL REFERENCES ai_capability_registry(code),
  model_id          UUID NOT NULL REFERENCES ai_model_catalog(id),
  fallback_model_id UUID REFERENCES ai_model_catalog(id),
  is_enabled        BOOLEAN NOT NULL DEFAULT true,
  max_input_tokens  INT,
  max_output_tokens INT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_binding UNIQUE (business_id, capability_code)
);

CREATE INDEX idx_bindings_business ON ai_model_bindings(business_id);

CREATE TRIGGER trg_bindings_updated_at
  BEFORE UPDATE ON ai_model_bindings
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── 4. ai_usage_ledger ─────────────────────────────────────
CREATE TABLE ai_usage_ledger (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  conversation_id    UUID REFERENCES conversations(id) ON DELETE SET NULL,
  message_id         UUID REFERENCES messages(id) ON DELETE SET NULL,
  user_id            UUID,
  capability_code    TEXT NOT NULL REFERENCES ai_capability_registry(code),
  provider_mode      TEXT NOT NULL,
  model_code         TEXT NOT NULL,
  status             TEXT NOT NULL CHECK (status IN ('completed','failed','blocked','budget_exceeded')),
  input_tokens       INT NOT NULL DEFAULT 0,
  output_tokens      INT NOT NULL DEFAULT 0,
  total_tokens       INT NOT NULL DEFAULT 0,
  estimated_cost_usd NUMERIC(12,6) NOT NULL DEFAULT 0,
  actual_cost_usd    NUMERIC(12,6),
  latency_ms         INT,
  error_code         TEXT,
  metadata           JSONB NOT NULL DEFAULT '{}',
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_usage_business_date ON ai_usage_ledger(business_id, created_at DESC);
CREATE INDEX idx_usage_business_daily ON ai_usage_ledger(business_id, created_at);
CREATE INDEX idx_usage_conversation ON ai_usage_ledger(conversation_id) WHERE conversation_id IS NOT NULL;
CREATE INDEX idx_usage_status ON ai_usage_ledger(business_id, status);
CREATE INDEX idx_usage_user ON ai_usage_ledger(user_id) WHERE user_id IS NOT NULL;

-- ── 5. RLS ─────────────────────────────────────────────────
ALTER TABLE ai_model_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_usage_ledger ENABLE ROW LEVEL SECURITY;

CREATE POLICY "members_read_bindings" ON ai_model_bindings
  FOR SELECT USING (is_business_member(business_id));
CREATE POLICY "managers_write_bindings" ON ai_model_bindings
  FOR INSERT WITH CHECK (is_business_manager_or_owner(business_id));
CREATE POLICY "managers_update_bindings" ON ai_model_bindings
  FOR UPDATE USING (is_business_manager_or_owner(business_id));
CREATE POLICY "managers_delete_bindings" ON ai_model_bindings
  FOR DELETE USING (is_business_manager_or_owner(business_id));

CREATE POLICY "managers_read_usage" ON ai_usage_ledger
  FOR SELECT USING (is_business_manager_or_owner(business_id));

-- ── 6. Backfill default bindings for existing businesses ───
INSERT INTO ai_model_bindings (business_id, capability_code, model_id)
SELECT b.id, 'reply_drafter', m.id
FROM businesses b
CROSS JOIN ai_model_catalog m
WHERE m.model_code = 'mock-sql-v1'
  AND NOT EXISTS (
    SELECT 1 FROM ai_model_bindings amb
    WHERE amb.business_id = b.id AND amb.capability_code = 'reply_drafter'
  );

-- ── 7. resolve_ai_capability_binding ───────────────────────
CREATE OR REPLACE FUNCTION resolve_ai_capability_binding(
  p_business_id UUID, p_capability_code TEXT
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_cap   RECORD;
  v_bind  RECORD;
  v_model RECORD;
BEGIN
  SELECT * INTO v_cap FROM ai_capability_registry WHERE code = p_capability_code;
  IF v_cap.code IS NULL THEN
    RETURN jsonb_build_object('error','UNKNOWN_CAPABILITY','message',format('Unknown capability: %s',p_capability_code));
  END IF;

  SELECT amb.*, amc.provider_mode AS m_provider_mode, amc.model_code AS m_model_code,
         amc.is_active AS m_active, amc.input_token_cost, amc.output_token_cost,
         amc.max_input_tokens AS m_max_in, amc.max_output_tokens AS m_max_out, amc.display_name AS m_name
  INTO v_bind
  FROM ai_model_bindings amb
  JOIN ai_model_catalog amc ON amc.id = amb.model_id
  WHERE amb.business_id = p_business_id AND amb.capability_code = p_capability_code AND amb.is_enabled = true;

  IF v_bind.id IS NULL THEN
    SELECT * INTO v_model FROM ai_model_catalog WHERE model_code = 'mock-sql-v1';
    RETURN jsonb_build_object(
      'capability_code', p_capability_code, 'model_code', 'mock-sql-v1',
      'provider_mode', 'mock_sql', 'display_name', v_model.display_name,
      'input_token_cost', v_model.input_token_cost, 'output_token_cost', v_model.output_token_cost,
      'max_input_tokens', v_model.max_input_tokens, 'max_output_tokens', v_model.max_output_tokens,
      'is_default', true);
  END IF;

  IF NOT v_bind.m_active THEN
    RETURN jsonb_build_object('error','MODEL_INACTIVE','message',format('Model %s is inactive',v_bind.m_model_code));
  END IF;

  RETURN jsonb_build_object(
    'capability_code', p_capability_code, 'model_code', v_bind.m_model_code,
    'provider_mode', v_bind.m_provider_mode, 'display_name', v_bind.m_name,
    'input_token_cost', v_bind.input_token_cost, 'output_token_cost', v_bind.output_token_cost,
    'max_input_tokens', COALESCE(v_bind.max_input_tokens, v_bind.m_max_in),
    'max_output_tokens', COALESCE(v_bind.max_output_tokens, v_bind.m_max_out),
    'is_default', false);
END; $$;

-- ── 8. check_ai_budget ─────────────────────────────────────
CREATE OR REPLACE FUNCTION check_ai_budget(
  p_business_id UUID, p_capability_code TEXT, p_estimated_tokens INT DEFAULT 0,
  p_conversation_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_policy      JSONB;
  v_daily_tokens  BIGINT;
  v_monthly_tokens BIGINT;
  v_daily_cost    NUMERIC;
  v_monthly_cost  NUMERIC;
  v_daily_token_limit   INT;
  v_monthly_token_limit INT;
  v_daily_cost_limit    NUMERIC;
  v_monthly_cost_limit  NUMERIC;
  v_conv_token_limit    INT;
  v_conv_tokens         BIGINT;
BEGIN
  v_policy := evaluate_policy(p_business_id, 'ai_budget');
  IF v_policy IS NULL THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'no_budget_policy');
  END IF;

  v_daily_token_limit   := (v_policy ->> 'daily_token_limit')::int;
  v_monthly_token_limit := (v_policy ->> 'monthly_token_limit')::int;
  v_daily_cost_limit    := (v_policy ->> 'daily_cost_limit_usd')::numeric;
  v_monthly_cost_limit  := (v_policy ->> 'monthly_cost_limit_usd')::numeric;
  v_conv_token_limit    := (v_policy ->> 'per_conversation_token_limit')::int;

  SELECT COALESCE(SUM(total_tokens),0), COALESCE(SUM(estimated_cost_usd),0)
  INTO v_daily_tokens, v_daily_cost
  FROM ai_usage_ledger
  WHERE business_id = p_business_id AND status = 'completed' AND created_at::date = CURRENT_DATE;

  SELECT COALESCE(SUM(total_tokens),0), COALESCE(SUM(estimated_cost_usd),0)
  INTO v_monthly_tokens, v_monthly_cost
  FROM ai_usage_ledger
  WHERE business_id = p_business_id AND status = 'completed'
    AND created_at >= date_trunc('month', now());

  -- Per-conversation limit (only when conversation_id is provided)
  IF v_conv_token_limit IS NOT NULL AND p_conversation_id IS NOT NULL THEN
    SELECT COALESCE(SUM(total_tokens),0) INTO v_conv_tokens
    FROM ai_usage_ledger
    WHERE business_id = p_business_id AND conversation_id = p_conversation_id AND status = 'completed';
    IF (v_conv_tokens + p_estimated_tokens) > v_conv_token_limit THEN
      RETURN jsonb_build_object('allowed',false,'reason','per_conversation_token_limit_exceeded',
        'conversation_used',v_conv_tokens,'conversation_limit',v_conv_token_limit,
        'daily_used',v_daily_tokens,'daily_limit',v_daily_token_limit,'monthly_used',v_monthly_tokens,'monthly_limit',v_monthly_token_limit);
    END IF;
  END IF;

  IF v_daily_token_limit IS NOT NULL AND (v_daily_tokens + p_estimated_tokens) > v_daily_token_limit THEN
    RETURN jsonb_build_object('allowed',false,'reason','daily_token_limit_exceeded',
      'daily_used',v_daily_tokens,'daily_limit',v_daily_token_limit,'monthly_used',v_monthly_tokens,'monthly_limit',v_monthly_token_limit);
  END IF;
  IF v_monthly_token_limit IS NOT NULL AND (v_monthly_tokens + p_estimated_tokens) > v_monthly_token_limit THEN
    RETURN jsonb_build_object('allowed',false,'reason','monthly_token_limit_exceeded',
      'daily_used',v_daily_tokens,'daily_limit',v_daily_token_limit,'monthly_used',v_monthly_tokens,'monthly_limit',v_monthly_token_limit);
  END IF;
  IF v_daily_cost_limit IS NOT NULL AND v_daily_cost > v_daily_cost_limit THEN
    RETURN jsonb_build_object('allowed',false,'reason','daily_cost_limit_exceeded',
      'daily_used',v_daily_tokens,'daily_limit',v_daily_token_limit,'monthly_used',v_monthly_tokens,'monthly_limit',v_monthly_token_limit);
  END IF;
  IF v_monthly_cost_limit IS NOT NULL AND v_monthly_cost > v_monthly_cost_limit THEN
    RETURN jsonb_build_object('allowed',false,'reason','monthly_cost_limit_exceeded',
      'daily_used',v_daily_tokens,'daily_limit',v_daily_token_limit,'monthly_used',v_monthly_tokens,'monthly_limit',v_monthly_token_limit);
  END IF;

  RETURN jsonb_build_object('allowed',true,'reason','within_budget',
    'daily_used',v_daily_tokens,'daily_limit',v_daily_token_limit,'monthly_used',v_monthly_tokens,'monthly_limit',v_monthly_token_limit);
END; $$;

-- ── 9. record_ai_usage ─────────────────────────────────────
CREATE OR REPLACE FUNCTION record_ai_usage(
  p_business_id UUID, p_conversation_id UUID, p_message_id UUID,
  p_capability_code TEXT, p_provider_mode TEXT, p_model_code TEXT,
  p_status TEXT, p_input_tokens INT DEFAULT 0, p_output_tokens INT DEFAULT 0,
  p_latency_ms INT DEFAULT NULL, p_error_code TEXT DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_total    INT;
  v_cost     NUMERIC(12,6);
  v_model    RECORD;
  v_uid      UUID;
  v_entry_id UUID;
BEGIN
  v_total := p_input_tokens + p_output_tokens;
  v_uid := auth.uid();

  SELECT input_token_cost, output_token_cost INTO v_model
  FROM ai_model_catalog WHERE model_code = p_model_code LIMIT 1;

  IF v_model IS NULL THEN
    v_cost := 0;
  ELSE
    v_cost := (p_input_tokens * v_model.input_token_cost) + (p_output_tokens * v_model.output_token_cost);
  END IF;

  INSERT INTO ai_usage_ledger (
    business_id, conversation_id, message_id, user_id, capability_code,
    provider_mode, model_code, status, input_tokens, output_tokens,
    total_tokens, estimated_cost_usd, latency_ms, error_code, metadata
  ) VALUES (
    p_business_id, p_conversation_id, p_message_id, v_uid, p_capability_code,
    p_provider_mode, p_model_code, p_status, p_input_tokens, p_output_tokens,
    v_total, v_cost, p_latency_ms, p_error_code, p_metadata
  ) RETURNING id INTO v_entry_id;

  IF p_status = 'completed' AND v_total > 0 THEN
    PERFORM increment_usage_meter(p_business_id, 'ai_tokens'::usage_meter_type, v_total::bigint);
  END IF;

  RETURN v_entry_id;
END; $$;

-- ── 10. get_business_ai_usage_summary ──────────────────────
CREATE OR REPLACE FUNCTION get_business_ai_usage_summary(
  p_business_id UUID, p_period TEXT DEFAULT 'monthly'
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_uid       UUID := auth.uid();
  v_since     TIMESTAMPTZ;
  v_result    JSONB;
  v_by_cap    JSONB;
  v_by_status JSONB;
  v_budget    JSONB;
BEGIN
  IF v_uid IS NULL THEN RETURN NULL; END IF;
  IF NOT is_platform_admin(v_uid) THEN
    IF NOT is_business_manager_or_owner(p_business_id) THEN RETURN NULL; END IF;
  END IF;

  IF p_period = 'daily' THEN v_since := CURRENT_DATE::timestamptz;
  ELSE v_since := date_trunc('month', now()); END IF;

  SELECT jsonb_build_object(
    'total_tokens', COALESCE(SUM(total_tokens),0),
    'total_cost', COALESCE(SUM(estimated_cost_usd),0),
    'total_calls', COUNT(*),
    'completed_calls', COUNT(*) FILTER (WHERE status='completed')
  ) INTO v_result
  FROM ai_usage_ledger WHERE business_id = p_business_id AND created_at >= v_since;

  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_by_cap FROM (
    SELECT capability_code, SUM(total_tokens) as tokens, SUM(estimated_cost_usd) as cost, COUNT(*) as calls
    FROM ai_usage_ledger WHERE business_id = p_business_id AND created_at >= v_since
    GROUP BY capability_code
  ) t;

  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_by_status FROM (
    SELECT status, COUNT(*) as calls, SUM(total_tokens) as tokens
    FROM ai_usage_ledger WHERE business_id = p_business_id AND created_at >= v_since
    GROUP BY status
  ) t;

  v_budget := check_ai_budget(p_business_id, 'reply_drafter', 0);

  RETURN v_result || jsonb_build_object(
    'period', p_period, 'since', v_since,
    'by_capability', v_by_cap, 'by_status', v_by_status, 'budget', v_budget);
END; $$;

-- ── 11. Modified release_to_ai_with_reply ──────────────────
CREATE OR REPLACE FUNCTION release_to_ai_with_reply(p_conversation_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_release_result JSONB;
  v_context        JSONB;
  v_reply_content  TEXT;
  v_reply_result   JSONB;
  v_customer_name  TEXT;
  v_biz_id         UUID;
  v_binding        JSONB;
  v_budget         JSONB;
  v_usage_id       UUID;
BEGIN
  -- Step 1: release_to_ai for state transition
  v_release_result := release_to_ai(p_conversation_id);
  IF v_release_result ? 'error' THEN RETURN v_release_result; END IF;

  -- Get business_id
  SELECT business_id INTO v_biz_id FROM conversations WHERE id = p_conversation_id;

  -- Step 2: resolve capability binding
  v_binding := resolve_ai_capability_binding(v_biz_id, 'reply_drafter');
  IF v_binding ? 'error' THEN
    RETURN jsonb_build_object('conversation_id',p_conversation_id,'status','open',
      'ai_enabled',true,'event_type','released_to_ai',
      'ai_reply',jsonb_build_object('skipped',true,'reason',v_binding->>'error'));
  END IF;

  -- Step 3: budget preflight (includes per-conversation limit)
  v_budget := check_ai_budget(v_biz_id, 'reply_drafter', 25, p_conversation_id);
  IF NOT (v_budget->>'allowed')::boolean THEN
    PERFORM record_ai_usage(v_biz_id, p_conversation_id, NULL,
      'reply_drafter', v_binding->>'provider_mode', v_binding->>'model_code',
      'budget_exceeded', 0, 0, NULL, v_budget->>'reason');
    RETURN jsonb_build_object('conversation_id',p_conversation_id,
      'error','BUDGET_EXCEEDED','reason',v_budget->>'reason',
      'budget',v_budget);
  END IF;

  -- Step 4: collect context
  v_context := collect_ai_context(p_conversation_id);
  IF v_context ? 'error' THEN
    RETURN jsonb_build_object('conversation_id',p_conversation_id,'status','open',
      'ai_enabled',true,'event_type','released_to_ai',
      'ai_reply',jsonb_build_object('skipped',true,'reason',v_context->>'error'));
  END IF;

  -- Step 5: generate stub reply
  v_customer_name := COALESCE(v_context->'customer'->>'name','valued customer');
  v_reply_content := format(
    '[AI Assistant] Thank you for your message, %s. I''ve noted your request and our team is ready to help. How can I assist you further?',
    v_customer_name);

  -- Step 6: persist reply
  v_reply_result := persist_ai_reply(
    p_conversation_id, v_reply_content, 'text'::message_content_type,
    'mock-sql', 'mock-sql-v1', 5, 20, 1);

  IF v_reply_result ? 'error' THEN
    PERFORM record_ai_usage(v_biz_id, p_conversation_id, NULL,
      'reply_drafter', v_binding->>'provider_mode', v_binding->>'model_code',
      'failed', 5, 20, 1, 'persist_failed');
    RETURN jsonb_build_object('conversation_id',p_conversation_id,'status','open',
      'ai_enabled',true,'event_type','released_to_ai',
      'ai_reply',jsonb_build_object('skipped',true,'reason',v_reply_result->>'error'));
  END IF;

  -- Step 7: record successful usage
  v_usage_id := record_ai_usage(v_biz_id, p_conversation_id,
    (v_reply_result->>'message_id')::uuid,
    'reply_drafter', v_binding->>'provider_mode', v_binding->>'model_code',
    'completed', 5, 20, 1);

  -- Step 8: return success
  RETURN jsonb_build_object(
    'conversation_id',p_conversation_id,'status','open','ai_enabled',true,
    'event_type','released_to_ai',
    'ai_reply',jsonb_build_object(
      'message_id',v_reply_result->>'message_id',
      'delivery_status',v_reply_result->>'delivery_status',
      'decision',v_reply_result->>'decision',
      'provider','mock-sql',
      'usage_id',v_usage_id));
END; $$;

-- ── 12. Extended update_business_ai_settings ────────────────
CREATE OR REPLACE FUNCTION update_business_ai_settings(
  p_business_id UUID, p_settings JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_uid            UUID := auth.uid();
  v_role           membership_role;
  v_is_active      BOOLEAN;
  v_key            TEXT;
  v_ai_enabled     BOOLEAN;
  v_old_config     JSONB;
  v_new_config     JSONB;
  v_rule_id        UUID;
  v_allowed_keys   TEXT[] := ARRAY[
    'ai_enabled','provider_mode','auto_reply_enabled','require_human_approval',
    'max_context_messages','allowed_channels',
    'daily_token_limit','monthly_token_limit','daily_cost_limit_usd',
    'monthly_cost_limit_usd','per_conversation_token_limit','hard_limit_enabled'
  ];
  v_forbidden_keys TEXT[] := ARRAY[
    'api_key','secret','openai_api_key','anthropic_api_key',
    'token','password','service_role','credentials'
  ];
  v_max_ctx        INT;
  v_provider_mode  TEXT;
  v_valid_channels TEXT[] := ARRAY['whatsapp','web_chat','sms','email','voice','telegram'];
  v_channel        TEXT;
  v_budget_config  JSONB;
  v_num_val        NUMERIC;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error','AUTH_REQUIRED','message','Authentication required');
  END IF;
  IF NOT is_platform_admin(v_uid) THEN
    SELECT bm.role, bm.is_active INTO v_role, v_is_active
    FROM business_memberships bm WHERE bm.user_id = v_uid AND bm.business_id = p_business_id LIMIT 1;
    IF v_role IS NULL THEN
      RETURN jsonb_build_object('error','ACCESS_DENIED','message','Not a member of this business');
    END IF;
    IF NOT v_is_active THEN
      RETURN jsonb_build_object('error','ACCESS_DENIED','message','Membership is inactive');
    END IF;
    IF v_role NOT IN ('owner','manager') THEN
      RETURN jsonb_build_object('error','PERMISSION_DENIED','message','Only owners and managers can update AI settings');
    END IF;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM businesses WHERE id = p_business_id) THEN
    RETURN jsonb_build_object('error','NOT_FOUND','message','Business does not exist');
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_settings) LOOP
    IF v_key = ANY(v_forbidden_keys) THEN
      RETURN jsonb_build_object('error','FORBIDDEN_SETTING','message',format('Setting "%s" is not allowed',v_key));
    END IF;
    IF NOT (v_key = ANY(v_allowed_keys)) THEN
      RETURN jsonb_build_object('error','INVALID_SETTING','message',format('Unknown setting "%s"',v_key));
    END IF;
  END LOOP;

  IF NOT (p_settings ? 'ai_enabled') THEN
    RETURN jsonb_build_object('error','VALIDATION_ERROR','message','ai_enabled is required');
  END IF;
  v_ai_enabled := (p_settings->>'ai_enabled')::boolean;

  IF p_settings ? 'provider_mode' THEN
    v_provider_mode := p_settings->>'provider_mode';
    IF v_provider_mode IS DISTINCT FROM 'mock_sql' THEN
      RETURN jsonb_build_object('error','INVALID_PROVIDER','message',format('Provider mode "%s" is not supported. Only "mock_sql" is allowed.',v_provider_mode));
    END IF;
  END IF;
  IF p_settings ? 'max_context_messages' THEN
    v_max_ctx := (p_settings->>'max_context_messages')::int;
    IF v_max_ctx < 1 OR v_max_ctx > 50 THEN
      RETURN jsonb_build_object('error','VALIDATION_ERROR','message','max_context_messages must be between 1 and 50');
    END IF;
  END IF;
  IF p_settings ? 'allowed_channels' THEN
    IF jsonb_typeof(p_settings->'allowed_channels') != 'array' THEN
      RETURN jsonb_build_object('error','VALIDATION_ERROR','message','allowed_channels must be an array');
    END IF;
    FOR v_channel IN SELECT jsonb_array_elements_text(p_settings->'allowed_channels') LOOP
      IF NOT (v_channel = ANY(v_valid_channels)) THEN
        RETURN jsonb_build_object('error','VALIDATION_ERROR','message',format('Unknown channel "%s"',v_channel));
      END IF;
    END LOOP;
  END IF;

  -- Validate budget keys
  IF p_settings ? 'daily_token_limit' THEN
    v_num_val := (p_settings->>'daily_token_limit')::numeric;
    IF v_num_val <= 0 THEN RETURN jsonb_build_object('error','VALIDATION_ERROR','message','daily_token_limit must be positive'); END IF;
  END IF;
  IF p_settings ? 'monthly_token_limit' THEN
    v_num_val := (p_settings->>'monthly_token_limit')::numeric;
    IF v_num_val <= 0 THEN RETURN jsonb_build_object('error','VALIDATION_ERROR','message','monthly_token_limit must be positive'); END IF;
  END IF;
  IF p_settings ? 'daily_cost_limit_usd' THEN
    v_num_val := (p_settings->>'daily_cost_limit_usd')::numeric;
    IF v_num_val <= 0 THEN RETURN jsonb_build_object('error','VALIDATION_ERROR','message','daily_cost_limit_usd must be positive'); END IF;
  END IF;
  IF p_settings ? 'monthly_cost_limit_usd' THEN
    v_num_val := (p_settings->>'monthly_cost_limit_usd')::numeric;
    IF v_num_val <= 0 THEN RETURN jsonb_build_object('error','VALIDATION_ERROR','message','monthly_cost_limit_usd must be positive'); END IF;
  END IF;
  IF p_settings ? 'per_conversation_token_limit' THEN
    v_num_val := (p_settings->>'per_conversation_token_limit')::numeric;
    IF v_num_val <= 0 THEN RETURN jsonb_build_object('error','VALIDATION_ERROR','message','per_conversation_token_limit must be positive'); END IF;
  END IF;

  SELECT pr.rule_config INTO v_old_config FROM policy_rules pr
  WHERE pr.business_id = p_business_id AND pr.rule_type = 'ai_allowed';

  v_new_config := jsonb_build_object('enabled', v_ai_enabled);
  IF p_settings ? 'provider_mode' THEN v_new_config := v_new_config || jsonb_build_object('provider_mode',p_settings->>'provider_mode');
  ELSE v_new_config := v_new_config || jsonb_build_object('provider_mode','mock_sql'); END IF;
  IF p_settings ? 'auto_reply_enabled' THEN v_new_config := v_new_config || jsonb_build_object('auto_reply_enabled',(p_settings->>'auto_reply_enabled')::boolean); END IF;
  IF p_settings ? 'require_human_approval' THEN v_new_config := v_new_config || jsonb_build_object('require_human_approval',(p_settings->>'require_human_approval')::boolean); END IF;
  IF p_settings ? 'max_context_messages' THEN v_new_config := v_new_config || jsonb_build_object('max_context_messages',(p_settings->>'max_context_messages')::int); END IF;
  IF p_settings ? 'allowed_channels' THEN v_new_config := v_new_config || jsonb_build_object('allowed_channels',p_settings->'allowed_channels'); END IF;

  -- Handle budget settings via separate policy_rules row
  v_budget_config := '{}'::jsonb;
  IF p_settings ? 'daily_token_limit' THEN v_budget_config := v_budget_config || jsonb_build_object('daily_token_limit',(p_settings->>'daily_token_limit')::int); END IF;
  IF p_settings ? 'monthly_token_limit' THEN v_budget_config := v_budget_config || jsonb_build_object('monthly_token_limit',(p_settings->>'monthly_token_limit')::int); END IF;
  IF p_settings ? 'daily_cost_limit_usd' THEN v_budget_config := v_budget_config || jsonb_build_object('daily_cost_limit_usd',(p_settings->>'daily_cost_limit_usd')::numeric); END IF;
  IF p_settings ? 'monthly_cost_limit_usd' THEN v_budget_config := v_budget_config || jsonb_build_object('monthly_cost_limit_usd',(p_settings->>'monthly_cost_limit_usd')::numeric); END IF;
  IF p_settings ? 'per_conversation_token_limit' THEN v_budget_config := v_budget_config || jsonb_build_object('per_conversation_token_limit',(p_settings->>'per_conversation_token_limit')::int); END IF;
  IF p_settings ? 'hard_limit_enabled' THEN v_budget_config := v_budget_config || jsonb_build_object('hard_limit_enabled',(p_settings->>'hard_limit_enabled')::boolean); END IF;

  IF v_budget_config != '{}'::jsonb THEN
    INSERT INTO policy_rules (business_id, rule_type, rule_config, is_active)
    VALUES (p_business_id, 'ai_budget', v_budget_config, true)
    ON CONFLICT (business_id, rule_type) DO UPDATE
    SET rule_config = policy_rules.rule_config || v_budget_config, updated_at = now();
  END IF;

  INSERT INTO policy_rules (business_id, rule_type, rule_config, is_active)
  VALUES (p_business_id, 'ai_allowed', v_new_config, v_ai_enabled)
  ON CONFLICT (business_id, rule_type) DO UPDATE
  SET rule_config = v_new_config, is_active = v_ai_enabled, updated_at = now()
  RETURNING id INTO v_rule_id;

  PERFORM log_audit(
    p_action := 'ai_settings.updated', p_entity_type := 'policy_rule',
    p_entity_id := v_rule_id, p_business_id := p_business_id,
    p_user_id := v_uid, p_severity := 'warning',
    p_old_values := COALESCE(v_old_config,'{}'::jsonb), p_new_values := v_new_config,
    p_metadata := jsonb_build_object('source','update_business_ai_settings','ai_enabled',v_ai_enabled));

  RETURN get_business_ai_settings(p_business_id);
END; $$;

COMMIT;
