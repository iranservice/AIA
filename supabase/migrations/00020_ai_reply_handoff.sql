-- ============================================================
-- 00020 — AI Reply + Handoff Control
--
-- Phase: 2C
-- Depends: 00019_operator_reply
--
-- Adds:
--   1. ai_interaction_logs — new columns (decision, reason_code, etc.)
--   2. message_windows — processed tracking
--   3. collect_ai_context() RPC
--   4. persist_ai_reply() RPC
--   5. persist_ai_handoff() RPC
--   6. log_ai_blocked() RPC
--   7. Upgrade release_to_ai() (void → JSONB, proper auth)
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. AI Interaction Logs — Add decision tracking columns
-- ────────────────────────────────────────────────────────────

ALTER TABLE ai_interaction_logs
  ADD COLUMN IF NOT EXISTS decision TEXT
    CHECK (decision IN ('replied', 'handoff', 'blocked', 'failed')),
  ADD COLUMN IF NOT EXISTS reason_code TEXT,
  ADD COLUMN IF NOT EXISTS trigger_type TEXT
    DEFAULT 'message_window'
    CHECK (trigger_type IN ('message_window', 'manual', 'system')),
  ADD COLUMN IF NOT EXISTS message_id UUID REFERENCES messages(id),
  ADD COLUMN IF NOT EXISTS provider_name TEXT DEFAULT 'mock';

-- Make agent_config_id optional (AI can run without formal config in Phase 2C)
ALTER TABLE ai_interaction_logs
  ALTER COLUMN agent_config_id DROP NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ai_interaction_logs_conversation
  ON ai_interaction_logs(conversation_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_interaction_logs_decision
  ON ai_interaction_logs(business_id, decision);

-- ────────────────────────────────────────────────────────────
-- 2. Message Windows — Processed tracking
-- ────────────────────────────────────────────────────────────

ALTER TABLE message_windows
  ADD COLUMN IF NOT EXISTS processed BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ;

-- Fix: add 'handoff_requested' to handoff_events event_type constraint
-- (was omitted in Phase 2B migration 00019)
ALTER TABLE handoff_events DROP CONSTRAINT IF EXISTS handoff_events_event_type_check;
ALTER TABLE handoff_events ADD CONSTRAINT handoff_events_event_type_check
  CHECK (event_type IN (
    'assigned', 'unassigned', 'transferred',
    'takeover', 'released_to_ai', 'auto_assigned',
    'handoff_requested'
  ));

-- ────────────────────────────────────────────────────────────
-- 3. collect_ai_context() — Gather everything AI needs
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION collect_ai_context(
  p_conversation_id UUID,
  p_max_messages    INTEGER DEFAULT 20
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_convo       RECORD;
  v_customer    RECORD;
  v_ai_policy   JSONB;
  v_messages    JSONB;
BEGIN
  -- Step 1: Get conversation
  SELECT c.id, c.business_id, c.customer_id, c.status,
         c.assigned_to, c.ai_enabled, c.channel_type,
         c.channel_id, c.message_count
  INTO v_convo
  FROM conversations c
  WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  -- Step 2: Safety checks
  IF v_convo.status IN ('closed', 'resolved') THEN
    RETURN jsonb_build_object(
      'error', 'CONVERSATION_CLOSED',
      'reason_code', 'conversation_closed'
    );
  END IF;

  IF v_convo.assigned_to IS NOT NULL THEN
    RETURN jsonb_build_object(
      'error', 'OPERATOR_OWNED',
      'reason_code', 'operator_owned',
      'assigned_to', v_convo.assigned_to
    );
  END IF;

  IF NOT v_convo.ai_enabled THEN
    RETURN jsonb_build_object(
      'error', 'AI_DISABLED',
      'reason_code', 'ai_disabled'
    );
  END IF;

  -- Step 3: Check AI policy
  v_ai_policy := evaluate_policy(v_convo.business_id, 'ai_allowed');
  IF v_ai_policy IS NULL OR (v_ai_policy ->> 'enabled')::boolean IS DISTINCT FROM true THEN
    RETURN jsonb_build_object(
      'error', 'AI_NOT_ALLOWED',
      'reason_code', 'policy_blocked'
    );
  END IF;

  -- Step 4: Get customer
  SELECT cu.id, cu.name, cu.phone, cu.email, cu.metadata
  INTO v_customer
  FROM customers cu
  WHERE cu.id = v_convo.customer_id;

  -- Step 5: Get latest messages
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', sub.id,
      'direction', sub.direction,
      'sender_type', sub.sender_type,
      'content', sub.content,
      'content_type', sub.content_type,
      'created_at', sub.created_at
    ) ORDER BY sub.created_at ASC
  ), '[]'::jsonb) INTO v_messages
  FROM (
    SELECT m.*
    FROM messages m
    WHERE m.conversation_id = p_conversation_id
      AND m.is_internal = false
    ORDER BY m.created_at DESC
    LIMIT p_max_messages
  ) sub;

  -- Step 6: Return context
  RETURN jsonb_build_object(
    'conversation', jsonb_build_object(
      'id', v_convo.id,
      'business_id', v_convo.business_id,
      'status', v_convo.status,
      'channel_type', v_convo.channel_type,
      'message_count', v_convo.message_count
    ),
    'customer', jsonb_build_object(
      'id', v_customer.id,
      'name', v_customer.name,
      'phone', v_customer.phone,
      'email', v_customer.email
    ),
    'messages', v_messages,
    'ai_policy', v_ai_policy,
    'safe', true
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 4. persist_ai_reply() — Store AI message + logs
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION persist_ai_reply(
  p_conversation_id UUID,
  p_content         TEXT,
  p_content_type    message_content_type DEFAULT 'text',
  p_provider_name   TEXT DEFAULT 'mock',
  p_model           TEXT DEFAULT NULL,
  p_tokens_in       INTEGER DEFAULT 0,
  p_tokens_out      INTEGER DEFAULT 0,
  p_latency_ms      INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_convo       RECORD;
  v_message_id  UUID;
BEGIN
  -- Defense-in-depth: re-validate ownership
  SELECT c.id, c.business_id, c.status, c.assigned_to,
         c.ai_enabled, c.channel_type
  INTO v_convo
  FROM conversations c
  WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  IF v_convo.status IN ('closed', 'resolved') THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_CLOSED');
  END IF;

  IF v_convo.assigned_to IS NOT NULL THEN
    RETURN jsonb_build_object('error', 'OPERATOR_OWNED');
  END IF;

  IF NOT v_convo.ai_enabled THEN
    RETURN jsonb_build_object('error', 'AI_DISABLED');
  END IF;

  -- Step 1: Insert AI outbound message
  INSERT INTO messages (
    conversation_id, direction, sender_type,
    content_type, content, delivery_status,
    created_at
  ) VALUES (
    p_conversation_id, 'outbound', 'ai',
    p_content_type, p_content, 'queued',
    clock_timestamp()
  )
  RETURNING id INTO v_message_id;

  -- Step 2: Update conversation counters
  UPDATE conversations
  SET message_count = message_count + 1,
      last_message_at = now(),
      updated_at = now()
  WHERE id = p_conversation_id;

  -- Step 3: AI interaction log
  INSERT INTO ai_interaction_logs (
    business_id, conversation_id,
    prompt_tokens, completion_tokens, model_used,
    request_payload, response_payload,
    latency_ms, decision, reason_code,
    trigger_type, message_id, provider_name
  ) VALUES (
    v_convo.business_id, p_conversation_id,
    p_tokens_in, p_tokens_out, COALESCE(p_model, 'unknown'),
    '{}'::jsonb,
    jsonb_build_object('content', LEFT(p_content, 200)),
    p_latency_ms, 'replied', NULL,
    'message_window', v_message_id, p_provider_name
  );

  -- Step 4: Outbound integration log
  INSERT INTO integration_logs (
    business_id, channel_type, direction, event_type,
    request_payload, processed
  ) VALUES (
    v_convo.business_id, v_convo.channel_type, 'outbound', 'ai_reply',
    jsonb_build_object(
      'message_id', v_message_id::text,
      'conversation_id', p_conversation_id::text,
      'provider', p_provider_name
    ),
    false
  );

  -- Step 5: Audit log
  INSERT INTO audit_log (
    business_id, action, entity_type, entity_id,
    severity, metadata
  ) VALUES (
    v_convo.business_id,
    'ai_reply', 'conversation', p_conversation_id,
    'info',
    jsonb_build_object(
      'message_id', v_message_id::text,
      'provider', p_provider_name,
      'model', COALESCE(p_model, 'unknown')
    )
  );

  RETURN jsonb_build_object(
    'message_id', v_message_id,
    'conversation_id', p_conversation_id,
    'delivery_status', 'queued',
    'decision', 'replied'
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 5. persist_ai_handoff() — AI requests human takeover
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION persist_ai_handoff(
  p_conversation_id UUID,
  p_reason_code     TEXT DEFAULT 'ai_uncertain',
  p_reason_text     TEXT DEFAULT NULL,
  p_provider_name   TEXT DEFAULT 'mock',
  p_model           TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_convo RECORD;
BEGIN
  SELECT c.id, c.business_id, c.status, c.assigned_to,
         c.ai_enabled, c.channel_type
  INTO v_convo
  FROM conversations c
  WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  -- Step 1: Update conversation — AI steps back
  UPDATE conversations
  SET ai_enabled = false,
      status = 'waiting',
      updated_at = now()
  WHERE id = p_conversation_id;

  -- Step 2: Handoff event
  INSERT INTO handoff_events (
    conversation_id, business_id, event_type,
    from_owner_type, to_owner_type,
    reason, metadata
  ) VALUES (
    p_conversation_id, v_convo.business_id, 'handoff_requested',
    'ai', 'unassigned',
    COALESCE(p_reason_text, p_reason_code),
    jsonb_build_object(
      'reason_code', p_reason_code,
      'provider', p_provider_name
    )
  );

  -- Step 3: AI interaction log
  INSERT INTO ai_interaction_logs (
    business_id, conversation_id,
    prompt_tokens, completion_tokens, model_used,
    request_payload, response_payload,
    decision, reason_code, trigger_type, provider_name
  ) VALUES (
    v_convo.business_id, p_conversation_id,
    0, 0, COALESCE(p_model, 'unknown'),
    '{}'::jsonb, '{}'::jsonb,
    'handoff', p_reason_code, 'message_window', p_provider_name
  );

  -- Step 4: Audit log
  INSERT INTO audit_log (
    business_id, action, entity_type, entity_id,
    severity, metadata
  ) VALUES (
    v_convo.business_id,
    'ai_handoff', 'conversation', p_conversation_id,
    'info',
    jsonb_build_object(
      'reason_code', p_reason_code,
      'reason_text', COALESCE(p_reason_text, ''),
      'provider', p_provider_name
    )
  );

  RETURN jsonb_build_object(
    'conversation_id', p_conversation_id,
    'decision', 'handoff',
    'reason_code', p_reason_code,
    'status', 'waiting'
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 6. log_ai_blocked() — Log blocked/failed AI attempt
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION log_ai_blocked(
  p_conversation_id UUID,
  p_reason_code     TEXT,
  p_decision        TEXT DEFAULT 'blocked',
  p_trigger_type    TEXT DEFAULT 'message_window',
  p_provider_name   TEXT DEFAULT 'mock'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_business_id UUID;
BEGIN
  SELECT c.business_id INTO v_business_id
  FROM conversations c
  WHERE c.id = p_conversation_id;

  IF v_business_id IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  -- AI interaction log
  INSERT INTO ai_interaction_logs (
    business_id, conversation_id,
    prompt_tokens, completion_tokens, model_used,
    request_payload, response_payload,
    decision, reason_code, trigger_type, provider_name
  ) VALUES (
    v_business_id, p_conversation_id,
    0, 0, 'none',
    '{}'::jsonb, '{}'::jsonb,
    p_decision, p_reason_code, p_trigger_type, p_provider_name
  );

  -- Audit log for security-sensitive blocks
  IF p_reason_code IN ('operator_owned', 'conversation_closed', 'policy_blocked') THEN
    INSERT INTO audit_log (
      business_id, action, entity_type, entity_id,
      severity, metadata
    ) VALUES (
      v_business_id,
      'ai_blocked', 'conversation', p_conversation_id,
      'warning',
      jsonb_build_object(
        'reason_code', p_reason_code,
        'decision', p_decision
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'conversation_id', p_conversation_id,
    'decision', p_decision,
    'reason_code', p_reason_code,
    'logged', true
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 7. Upgrade release_to_ai() — Proper auth, JSONB return
-- ────────────────────────────────────────────────────────────

-- Drop old void-returning stub
DROP FUNCTION IF EXISTS release_to_ai(UUID);

CREATE OR REPLACE FUNCTION release_to_ai(
  p_conversation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller_id   UUID;
  v_convo       RECORD;
  v_ai_policy   JSONB;
  v_prev_owner  UUID;
BEGIN
  v_caller_id := auth.uid();

  -- Step 1: Get conversation
  SELECT c.id, c.business_id, c.status, c.assigned_to, c.ai_enabled
  INTO v_convo
  FROM conversations c
  WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  -- Step 2: Permission check — caller must have assign permission
  IF NOT check_permission(v_caller_id, v_convo.business_id, 'conversation:assign') THEN
    RETURN jsonb_build_object('error', 'PERMISSION_DENIED',
      'message', 'Caller lacks conversation:assign permission');
  END IF;

  -- Step 3: Conversation must not be closed
  IF v_convo.status IN ('closed', 'resolved') THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_CLOSED');
  END IF;

  -- Step 4: Check AI policy
  v_ai_policy := evaluate_policy(v_convo.business_id, 'ai_allowed');
  IF v_ai_policy IS NULL OR (v_ai_policy ->> 'enabled')::boolean IS DISTINCT FROM true THEN
    RETURN jsonb_build_object('error', 'AI_NOT_ALLOWED',
      'message', 'AI is not enabled for this business');
  END IF;

  v_prev_owner := v_convo.assigned_to;

  -- Step 5: Update conversation
  UPDATE conversations
  SET assigned_to = NULL,
      assigned_at = NULL,
      status = 'open',
      ai_enabled = true,
      updated_at = now()
  WHERE id = p_conversation_id;

  -- Step 6: Handoff event
  INSERT INTO handoff_events (
    conversation_id, business_id, event_type,
    from_owner_type, from_owner_id,
    to_owner_type,
    triggered_by
  ) VALUES (
    p_conversation_id, v_convo.business_id, 'released_to_ai',
    CASE WHEN v_prev_owner IS NOT NULL THEN 'operator' ELSE 'unassigned' END,
    v_prev_owner,
    'ai',
    v_caller_id
  );

  -- Step 7: Audit log
  INSERT INTO audit_log (
    business_id, user_id, action, entity_type, entity_id,
    severity, metadata
  ) VALUES (
    v_convo.business_id, v_caller_id,
    'release_to_ai', 'conversation', p_conversation_id,
    'info',
    jsonb_build_object(
      'previous_owner', v_prev_owner::text,
      'ai_enabled', true
    )
  );

  RETURN jsonb_build_object(
    'conversation_id', p_conversation_id,
    'status', 'open',
    'ai_enabled', true,
    'event_type', 'released_to_ai'
  );
END;
$$;

COMMIT;
