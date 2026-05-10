-- ============================================================
-- 00028 — AI Resilience: Fallback Ladder + Handoff Re-entry
--
-- Phase: IX-B
-- Depends: 00027_ai_token_cost_governance (IX-A)
--
-- Adds:
--   1. classify_ai_fallback() — pure deterministic fallback
--      classification function (IMMUTABLE, no table reads)
--   2. Extended handoff_events event_type constraint (+ai_fallback)
--   3. Modified release_to_ai_with_reply() — all failure paths
--      now use classify_ai_fallback() for structured responses
--
-- Does NOT add:
--   - New tables
--   - Real provider calls or API keys
--   - Runtime rate limiting / circuit breaker
--   - Frontend references
--   - Web Chat / WhatsApp / Voice / Outbox / Turn Aggregation
--   - Content Policy / Payment / POS / Delivery
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. classify_ai_fallback() — Pure fallback classification
--
-- Maps any AI runtime error to a standardized fallback code,
-- severity, recommended action, and metadata.
-- IMMUTABLE: pure function, no state, no table reads.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION classify_ai_fallback(
  p_error_source TEXT,    -- 'binding', 'budget', 'context', 'persist', 'provider'
  p_error_code   TEXT,    -- the raw error code from the source function
  p_metadata     JSONB DEFAULT '{}'
) RETURNS JSONB LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN CASE p_error_source
    WHEN 'binding' THEN
      jsonb_build_object(
        'fallback_code', 'BINDING_' || UPPER(COALESCE(p_error_code, 'UNKNOWN')),
        'severity', CASE p_error_code
          WHEN 'UNKNOWN_CAPABILITY' THEN 'critical'
          WHEN 'MODEL_INACTIVE' THEN 'high'
          ELSE 'medium' END,
        'action', 'skip_reply',
        'human_handoff', false,
        'retryable', false,
        'message', 'AI capability binding unavailable')
    WHEN 'budget' THEN
      jsonb_build_object(
        'fallback_code', 'BUDGET_' || UPPER(COALESCE(p_error_code, 'EXCEEDED')),
        'severity', 'medium',
        'action', 'skip_reply',
        'human_handoff', false,
        'retryable', false,
        'message', 'AI budget limit reached')
    WHEN 'context' THEN
      jsonb_build_object(
        'fallback_code', 'CONTEXT_' || UPPER(COALESCE(p_error_code, 'UNKNOWN')),
        'severity', CASE p_error_code
          WHEN 'CONVERSATION_CLOSED' THEN 'low'
          WHEN 'OPERATOR_OWNED' THEN 'low'
          WHEN 'AI_DISABLED' THEN 'low'
          WHEN 'AI_NOT_ALLOWED' THEN 'medium'
          ELSE 'medium' END,
        'action', 'skip_reply',
        'human_handoff', false,
        'retryable', false,
        'message', 'AI context collection failed: ' || COALESCE(p_error_code, 'unknown'))
    WHEN 'persist' THEN
      jsonb_build_object(
        'fallback_code', 'PERSIST_FAILED',
        'severity', 'high',
        'action', 'skip_reply',
        'human_handoff', false,
        'retryable', true,
        'message', 'AI reply could not be saved')
    WHEN 'provider' THEN
      jsonb_build_object(
        'fallback_code', 'PROVIDER_' || UPPER(COALESCE(p_error_code, 'ERROR')),
        'severity', 'high',
        'action', CASE
          WHEN p_metadata->>'has_fallback_model' = 'true' THEN 'try_fallback_model'
          ELSE 'skip_reply' END,
        'human_handoff', true,
        'retryable', true,
        'message', 'AI provider error')
    ELSE
      jsonb_build_object(
        'fallback_code', 'UNKNOWN_ERROR',
        'severity', 'critical',
        'action', 'skip_reply',
        'human_handoff', false,
        'retryable', false,
        'message', 'Unclassified AI failure')
  END;
END; $$;

-- ────────────────────────────────────────────────────────────
-- 2. Extend handoff_events event_type CHECK constraint
--    Add 'ai_fallback' for provider/future fallback events
-- ────────────────────────────────────────────────────────────

ALTER TABLE handoff_events DROP CONSTRAINT IF EXISTS handoff_events_event_type_check;
ALTER TABLE handoff_events ADD CONSTRAINT handoff_events_event_type_check
  CHECK (event_type IN (
    'assigned', 'unassigned', 'transferred',
    'takeover', 'released_to_ai', 'auto_assigned',
    'handoff_requested', 'ai_fallback'
  ));

-- ────────────────────────────────────────────────────────────
-- 3. Modified release_to_ai_with_reply()
--
-- Signature preserved: (p_conversation_id UUID) RETURNS JSONB
-- Success path: unchanged (no fallback object)
-- Failure paths: all use classify_ai_fallback() for structured
--   fallback response in ai_reply.fallback
--
-- Backward compatibility:
--   - Top-level response keys preserved
--   - ai_reply.skipped=true pattern preserved
--   - Budget exceeded: error='BUDGET_EXCEEDED' preserved
--   - ai_reply.fallback is additive (new field)
-- ────────────────────────────────────────────────────────────

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
  v_fallback       JSONB;
  v_error_code     TEXT;
BEGIN
  -- Step 1: release_to_ai for state transition
  v_release_result := release_to_ai(p_conversation_id);
  IF v_release_result ? 'error' THEN
    -- Preserve existing return from release_to_ai to avoid breaking auth/state behavior
    RETURN v_release_result;
  END IF;

  -- Get business_id
  SELECT business_id INTO v_biz_id FROM conversations WHERE id = p_conversation_id;

  -- Step 2: resolve capability binding
  v_binding := resolve_ai_capability_binding(v_biz_id, 'reply_drafter');
  IF v_binding ? 'error' THEN
    v_error_code := v_binding->>'error';
    v_fallback := classify_ai_fallback('binding', v_error_code);

    -- Record blocked usage with fallback error_code
    PERFORM record_ai_usage(v_biz_id, p_conversation_id, NULL,
      'reply_drafter', 'unknown', 'unknown',
      'blocked', 0, 0, NULL, v_fallback->>'fallback_code');

    RETURN jsonb_build_object(
      'conversation_id', p_conversation_id,
      'status', 'open',
      'ai_enabled', true,
      'event_type', 'released_to_ai',
      'ai_reply', jsonb_build_object(
        'skipped', true,
        'reason', v_error_code,
        'fallback', v_fallback
      )
    );
  END IF;

  -- Step 3: budget preflight (includes per-conversation limit)
  v_budget := check_ai_budget(v_biz_id, 'reply_drafter', 25, p_conversation_id);
  IF NOT (v_budget->>'allowed')::boolean THEN
    -- IX-A already records budget_exceeded in the ledger via this call
    PERFORM record_ai_usage(v_biz_id, p_conversation_id, NULL,
      'reply_drafter', v_binding->>'provider_mode', v_binding->>'model_code',
      'budget_exceeded', 0, 0, NULL, v_budget->>'reason');

    v_fallback := classify_ai_fallback('budget', v_budget->>'reason');

    -- Preserve top-level error='BUDGET_EXCEEDED' for backward compatibility
    RETURN jsonb_build_object(
      'conversation_id', p_conversation_id,
      'error', 'BUDGET_EXCEEDED',
      'reason', v_budget->>'reason',
      'budget', v_budget,
      'ai_reply', jsonb_build_object(
        'skipped', true,
        'reason', v_budget->>'reason',
        'fallback', v_fallback
      )
    );
  END IF;

  -- Step 4: collect context
  v_context := collect_ai_context(p_conversation_id);
  IF v_context ? 'error' THEN
    v_error_code := v_context->>'error';
    v_fallback := classify_ai_fallback('context', v_error_code);

    -- Record blocked usage with fallback error_code
    PERFORM record_ai_usage(v_biz_id, p_conversation_id, NULL,
      'reply_drafter', v_binding->>'provider_mode', v_binding->>'model_code',
      'blocked', 0, 0, NULL, v_fallback->>'fallback_code');

    RETURN jsonb_build_object(
      'conversation_id', p_conversation_id,
      'status', 'open',
      'ai_enabled', true,
      'event_type', 'released_to_ai',
      'ai_reply', jsonb_build_object(
        'skipped', true,
        'reason', v_error_code,
        'fallback', v_fallback
      )
    );
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
    v_error_code := v_reply_result->>'error';
    v_fallback := classify_ai_fallback('persist', v_error_code);

    -- Record failed usage with fallback error_code (5 input / 20 output as mock estimates)
    PERFORM record_ai_usage(v_biz_id, p_conversation_id, NULL,
      'reply_drafter', v_binding->>'provider_mode', v_binding->>'model_code',
      'failed', 5, 20, 1, v_fallback->>'fallback_code');

    -- If fallback recommends human_handoff, create ai_fallback handoff event
    IF (v_fallback->>'human_handoff')::boolean = true THEN
      INSERT INTO handoff_events (
        conversation_id, business_id, event_type,
        from_owner_type, to_owner_type,
        reason, metadata
      ) VALUES (
        p_conversation_id, v_biz_id, 'ai_fallback',
        'ai', 'unassigned',
        v_fallback->>'message',
        jsonb_build_object(
          'fallback_code', v_fallback->>'fallback_code',
          'severity', v_fallback->>'severity',
          'error_source', 'persist'
        )
      );
    END IF;

    RETURN jsonb_build_object(
      'conversation_id', p_conversation_id,
      'status', 'open',
      'ai_enabled', true,
      'event_type', 'released_to_ai',
      'ai_reply', jsonb_build_object(
        'skipped', true,
        'reason', v_error_code,
        'fallback', v_fallback
      )
    );
  END IF;

  -- Step 7: record successful usage (no fallback on success)
  v_usage_id := record_ai_usage(v_biz_id, p_conversation_id,
    (v_reply_result->>'message_id')::uuid,
    'reply_drafter', v_binding->>'provider_mode', v_binding->>'model_code',
    'completed', 5, 20, 1);

  -- Step 8: return success (no fallback object)
  RETURN jsonb_build_object(
    'conversation_id', p_conversation_id,
    'status', 'open',
    'ai_enabled', true,
    'event_type', 'released_to_ai',
    'ai_reply', jsonb_build_object(
      'message_id', v_reply_result->>'message_id',
      'delivery_status', v_reply_result->>'delivery_status',
      'decision', v_reply_result->>'decision',
      'provider', 'mock-sql',
      'usage_id', v_usage_id));
END; $$;

COMMIT;
