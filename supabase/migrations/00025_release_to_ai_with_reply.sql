-- ============================================================
-- 00025 — Release to AI with Immediate Stub Reply
--
-- Phase: VIII-A
-- Depends: 00020_ai_reply_handoff
--
-- Adds:
--   1. release_to_ai_with_reply() — Atomically releases a
--      conversation to AI control AND generates an immediate
--      deterministic stub reply using the mock-sql provider.
--
-- Design:
--   - Reuses release_to_ai() for state transition (DRY)
--   - Reuses persist_ai_reply() for message persistence (DRY)
--   - Stub reply is clearly labeled [AI Assistant]
--   - Provider name: 'mock-sql' (distinguishes from TS mock)
--   - No external network calls, no API keys
--   - When a real AI provider replaces this, the function
--     signature stays the same — only the reply generation
--     logic changes (or moves to an Edge Function).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION release_to_ai_with_reply(
  p_conversation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_release_result  JSONB;
  v_context         JSONB;
  v_reply_content   TEXT;
  v_reply_result    JSONB;
  v_customer_name   TEXT;
BEGIN
  -- ──────────────────────────────────────────────────
  -- Step 1: Execute release_to_ai() for state transition
  -- This handles: permission check, conversation validation,
  -- AI policy check, state update, handoff event, audit log
  -- ──────────────────────────────────────────────────
  v_release_result := release_to_ai(p_conversation_id);

  -- If release failed, return the error immediately
  IF v_release_result ? 'error' THEN
    RETURN v_release_result;
  END IF;

  -- ──────────────────────────────────────────────────
  -- Step 2: Collect AI context for reply generation
  -- ──────────────────────────────────────────────────
  v_context := collect_ai_context(p_conversation_id);

  -- If context collection failed, return partial success
  -- (the release itself succeeded)
  IF v_context ? 'error' THEN
    RETURN jsonb_build_object(
      'conversation_id', p_conversation_id,
      'status', 'open',
      'ai_enabled', true,
      'event_type', 'released_to_ai',
      'ai_reply', jsonb_build_object(
        'skipped', true,
        'reason', v_context ->> 'error'
      )
    );
  END IF;

  -- ──────────────────────────────────────────────────
  -- Step 3: Generate deterministic stub reply
  -- Mock-SQL provider: no network calls, no API keys
  -- ──────────────────────────────────────────────────

  -- Extract customer name for personalization
  v_customer_name := COALESCE(
    v_context -> 'customer' ->> 'name',
    'valued customer'
  );

  -- Generate stub reply content
  v_reply_content := format(
    '[AI Assistant] Thank you for your message, %s. I''ve noted your request and our team is ready to help. How can I assist you further?',
    v_customer_name
  );

  -- ──────────────────────────────────────────────────
  -- Step 4: Persist the AI reply via existing RPC
  -- This handles: message insert, conversation counter
  -- update, AI interaction log, integration log, audit log
  -- ──────────────────────────────────────────────────
  v_reply_result := persist_ai_reply(
    p_conversation_id,
    v_reply_content,
    'text'::message_content_type,
    'mock-sql',   -- provider_name
    'mock-sql-v1', -- model
    5,             -- tokens_in (stub)
    20,            -- tokens_out (stub)
    1              -- latency_ms (near-instant)
  );

  -- If reply persistence failed, return partial success
  IF v_reply_result ? 'error' THEN
    RETURN jsonb_build_object(
      'conversation_id', p_conversation_id,
      'status', 'open',
      'ai_enabled', true,
      'event_type', 'released_to_ai',
      'ai_reply', jsonb_build_object(
        'skipped', true,
        'reason', v_reply_result ->> 'error'
      )
    );
  END IF;

  -- ──────────────────────────────────────────────────
  -- Step 5: Return combined success result
  -- ──────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'conversation_id', p_conversation_id,
    'status', 'open',
    'ai_enabled', true,
    'event_type', 'released_to_ai',
    'ai_reply', jsonb_build_object(
      'message_id', v_reply_result ->> 'message_id',
      'delivery_status', v_reply_result ->> 'delivery_status',
      'decision', v_reply_result ->> 'decision',
      'provider', 'mock-sql'
    )
  );
END;
$$;

COMMIT;
