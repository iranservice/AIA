BEGIN;

-- ============================================================
-- 00029 — Conversation Turn Aggregation
-- Phase: IX-C
-- Depends: 00028_ai_resilience_handoff_reentry (IX-B)
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. Table: conversation_turns
-- ────────────────────────────────────────────────────────────

CREATE TABLE conversation_turns (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  conversation_id     UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  actor_type          TEXT NOT NULL DEFAULT 'customer'
                        CHECK (actor_type IN ('customer','operator','ai','system')),
  direction           TEXT NOT NULL DEFAULT 'inbound'
                        CHECK (direction IN ('inbound','outbound')),
  status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','finalized','processing','processed','skipped','superseded')),
  first_message_id    UUID REFERENCES messages(id),
  last_message_id     UUID REFERENCES messages(id),
  message_count       INT NOT NULL DEFAULT 0,
  total_characters    INT NOT NULL DEFAULT 0,
  aggregated_text     TEXT,
  aggregated_metadata JSONB NOT NULL DEFAULT '{}',
  finalized_reason    TEXT,
  finalized_at        TIMESTAMPTZ,
  processed_at        TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_conversation_turns_conversation_status
  ON conversation_turns(conversation_id, status, created_at DESC);
CREATE INDEX idx_conversation_turns_business_date
  ON conversation_turns(business_id, created_at DESC);
CREATE INDEX idx_conversation_turns_pending
  ON conversation_turns(conversation_id, status)
  WHERE status = 'pending';

CREATE UNIQUE INDEX uq_one_pending_customer_turn
  ON conversation_turns(conversation_id, actor_type, direction)
  WHERE status = 'pending';

CREATE TRIGGER trg_conversation_turns_updated_at
  BEFORE UPDATE ON conversation_turns
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ────────────────────────────────────────────────────────────
-- 2. Table: conversation_turn_messages
-- ────────────────────────────────────────────────────────────

CREATE TABLE conversation_turn_messages (
  turn_id           UUID NOT NULL REFERENCES conversation_turns(id) ON DELETE CASCADE,
  message_id        UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  business_id       UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  conversation_id   UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sequence_index    INT NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (turn_id, message_id),
  CONSTRAINT uq_message_one_turn UNIQUE (message_id),
  CONSTRAINT uq_turn_sequence UNIQUE (turn_id, sequence_index)
);

CREATE INDEX idx_conversation_turn_messages_conversation
  ON conversation_turn_messages(conversation_id);
CREATE INDEX idx_conversation_turn_messages_business
  ON conversation_turn_messages(business_id);

-- ────────────────────────────────────────────────────────────
-- 3. RLS Policies
-- ────────────────────────────────────────────────────────────

ALTER TABLE conversation_turns ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversation_turn_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY members_read_turns ON conversation_turns
  FOR SELECT USING (is_business_member(business_id));

CREATE POLICY members_read_turn_messages ON conversation_turn_messages
  FOR SELECT USING (is_business_member(business_id));

-- ────────────────────────────────────────────────────────────
-- 4. Turn Lifecycle Functions
-- ────────────────────────────────────────────────────────────

-- 4a. get_or_create_pending_turn
CREATE OR REPLACE FUNCTION get_or_create_pending_turn(
  p_conversation_id UUID,
  p_actor_type TEXT DEFAULT 'customer',
  p_direction TEXT DEFAULT 'inbound'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_turn RECORD;
  v_biz_id UUID;
BEGIN
  SELECT business_id INTO v_biz_id FROM conversations WHERE id = p_conversation_id;
  IF v_biz_id IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  -- Try to lock existing pending turn
  SELECT * INTO v_turn FROM conversation_turns
  WHERE conversation_id = p_conversation_id
    AND actor_type = p_actor_type AND direction = p_direction
    AND status = 'pending'
  FOR UPDATE;

  IF v_turn.id IS NOT NULL THEN
    RETURN jsonb_build_object('turn_id', v_turn.id, 'status', v_turn.status,
      'message_count', v_turn.message_count, 'created_at', v_turn.created_at);
  END IF;

  -- Insert new pending turn
  INSERT INTO conversation_turns (business_id, conversation_id, actor_type, direction, status)
  VALUES (v_biz_id, p_conversation_id, p_actor_type, p_direction, 'pending')
  ON CONFLICT (conversation_id, actor_type, direction) WHERE status = 'pending' DO NOTHING
  RETURNING * INTO v_turn;

  IF v_turn.id IS NOT NULL THEN
    RETURN jsonb_build_object('turn_id', v_turn.id, 'status', v_turn.status,
      'message_count', v_turn.message_count, 'created_at', v_turn.created_at);
  END IF;

  -- Race: another txn inserted first, re-lock it
  SELECT * INTO v_turn FROM conversation_turns
  WHERE conversation_id = p_conversation_id
    AND actor_type = p_actor_type AND direction = p_direction
    AND status = 'pending'
  FOR UPDATE;

  RETURN jsonb_build_object('turn_id', v_turn.id, 'status', v_turn.status,
    'message_count', v_turn.message_count, 'created_at', v_turn.created_at);
END; $$;

-- 4b. append_message_to_turn
CREATE OR REPLACE FUNCTION append_message_to_turn(p_message_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_msg RECORD;
  v_turn_result JSONB;
  v_turn_id UUID;
  v_seq INT;
  v_new_count INT;
  v_new_chars INT;
  v_auto_finalized BOOLEAN := false;
  v_finalized_reason TEXT;
  v_max_messages INT := 10;
  v_max_chars INT := 4000;
BEGIN
  SELECT m.id, m.conversation_id, m.direction, m.sender_type, m.content,
         c.business_id
  INTO v_msg
  FROM messages m JOIN conversations c ON c.id = m.conversation_id
  WHERE m.id = p_message_id;

  IF v_msg.id IS NULL THEN
    RETURN jsonb_build_object('error', 'MESSAGE_NOT_FOUND');
  END IF;

  IF v_msg.direction != 'inbound' OR v_msg.sender_type != 'customer' THEN
    RETURN jsonb_build_object('error', 'NOT_INBOUND_CUSTOMER', 'message_id', p_message_id);
  END IF;

  -- Get or create pending turn
  v_turn_result := get_or_create_pending_turn(v_msg.conversation_id, 'customer', 'inbound');
  IF v_turn_result ? 'error' THEN RETURN v_turn_result; END IF;
  v_turn_id := (v_turn_result->>'turn_id')::uuid;

  -- Get next sequence index
  SELECT COALESCE(MAX(sequence_index), -1) + 1 INTO v_seq
  FROM conversation_turn_messages WHERE turn_id = v_turn_id;

  -- Idempotent attach
  INSERT INTO conversation_turn_messages (turn_id, message_id, business_id, conversation_id, sequence_index)
  VALUES (v_turn_id, p_message_id, v_msg.business_id, v_msg.conversation_id, v_seq)
  ON CONFLICT (message_id) DO NOTHING;

  -- Update turn counters
  SELECT COUNT(*), COALESCE(SUM(CHAR_LENGTH(COALESCE(m.content,''))),0)
  INTO v_new_count, v_new_chars
  FROM conversation_turn_messages ctm
  JOIN messages m ON m.id = ctm.message_id
  WHERE ctm.turn_id = v_turn_id;

  UPDATE conversation_turns SET
    message_count = v_new_count,
    total_characters = v_new_chars,
    first_message_id = COALESCE(first_message_id, p_message_id),
    last_message_id = p_message_id
  WHERE id = v_turn_id;

  -- Auto-finalize if limits exceeded
  IF v_new_count >= v_max_messages THEN
    v_finalized_reason := 'max_messages';
    v_auto_finalized := true;
  ELSIF v_new_chars >= v_max_chars THEN
    v_finalized_reason := 'max_characters';
    v_auto_finalized := true;
  END IF;

  IF v_auto_finalized THEN
    PERFORM finalize_conversation_turn(v_turn_id, v_finalized_reason);
  END IF;

  RETURN jsonb_build_object('turn_id', v_turn_id, 'message_count', v_new_count,
    'auto_finalized', v_auto_finalized, 'finalized_reason', v_finalized_reason);
END; $$;

-- 4c. finalize_conversation_turn
CREATE OR REPLACE FUNCTION finalize_conversation_turn(
  p_turn_id UUID,
  p_reason TEXT DEFAULT 'manual'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_turn RECORD;
  v_agg_text TEXT;
BEGIN
  SELECT * INTO v_turn FROM conversation_turns WHERE id = p_turn_id FOR UPDATE;
  IF v_turn IS NULL THEN
    RETURN jsonb_build_object('error', 'TURN_NOT_FOUND');
  END IF;

  IF v_turn.status != 'pending' THEN
    RETURN jsonb_build_object('turn_id', p_turn_id, 'status', v_turn.status,
      'message_count', v_turn.message_count, 'noop', true);
  END IF;

  -- Freeze aggregated text
  SELECT STRING_AGG(COALESCE(m.content, ''), E'\n' ORDER BY ctm.sequence_index)
  INTO v_agg_text
  FROM conversation_turn_messages ctm
  JOIN messages m ON m.id = ctm.message_id
  WHERE ctm.turn_id = p_turn_id;

  UPDATE conversation_turns SET
    status = 'finalized',
    aggregated_text = v_agg_text,
    finalized_reason = p_reason,
    finalized_at = now()
  WHERE id = p_turn_id;

  RETURN jsonb_build_object('turn_id', p_turn_id, 'status', 'finalized',
    'message_count', v_turn.message_count,
    'aggregated_text_length', COALESCE(CHAR_LENGTH(v_agg_text), 0));
END; $$;

-- 4d. finalize_due_turns
CREATE OR REPLACE FUNCTION finalize_due_turns(
  p_quiet_window_seconds INT DEFAULT 10,
  p_business_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_turn RECORD;
  v_count INT := 0;
  v_ids UUID[] := '{}';
BEGIN
  FOR v_turn IN
    SELECT id FROM conversation_turns
    WHERE status = 'pending'
      AND updated_at + (p_quiet_window_seconds || ' seconds')::interval < now()
      AND (p_business_id IS NULL OR business_id = p_business_id)
    ORDER BY created_at ASC
    FOR UPDATE SKIP LOCKED
  LOOP
    PERFORM finalize_conversation_turn(v_turn.id, 'quiet_window');
    v_count := v_count + 1;
    v_ids := v_ids || v_turn.id;
  END LOOP;

  RETURN jsonb_build_object('finalized_count', v_count, 'turn_ids', to_jsonb(v_ids));
END; $$;

-- 4e. get_finalized_turn_for_ai
CREATE OR REPLACE FUNCTION get_finalized_turn_for_ai(p_conversation_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_turn RECORD;
  v_quiet INT;
  v_biz_id UUID;
  v_msg_ids UUID[];
  v_first_at TIMESTAMPTZ;
  v_last_at TIMESTAMPTZ;
BEGIN
  -- Try oldest finalized turn first
  SELECT * INTO v_turn FROM conversation_turns
  WHERE conversation_id = p_conversation_id
    AND actor_type = 'customer' AND direction = 'inbound'
    AND status = 'finalized'
  ORDER BY finalized_at ASC LIMIT 1
  FOR UPDATE;

  -- If none, try auto-finalizing a pending turn past quiet window
  IF v_turn.id IS NULL THEN
    SELECT business_id INTO v_biz_id FROM conversations WHERE id = p_conversation_id;
    SELECT COALESCE((b.business_config->>'response_delay_seconds')::int, 10)
    INTO v_quiet FROM businesses b WHERE b.id = v_biz_id;

    SELECT * INTO v_turn FROM conversation_turns
    WHERE conversation_id = p_conversation_id
      AND actor_type = 'customer' AND direction = 'inbound'
      AND status = 'pending'
      AND updated_at + (v_quiet || ' seconds')::interval < now()
    ORDER BY created_at ASC LIMIT 1
    FOR UPDATE;

    IF v_turn.id IS NOT NULL THEN
      PERFORM finalize_conversation_turn(v_turn.id, 'quiet_window_auto');
      -- Refresh after finalization
      SELECT * INTO v_turn FROM conversation_turns WHERE id = v_turn.id;
    END IF;
  END IF;

  IF v_turn.id IS NULL THEN RETURN NULL; END IF;

  -- Atomically transition finalized → processing
  UPDATE conversation_turns SET status = 'processing' WHERE id = v_turn.id AND status = 'finalized';

  -- Gather message IDs and timestamps
  SELECT ARRAY_AGG(ctm.message_id ORDER BY ctm.sequence_index),
         MIN(m.created_at), MAX(m.created_at)
  INTO v_msg_ids, v_first_at, v_last_at
  FROM conversation_turn_messages ctm
  JOIN messages m ON m.id = ctm.message_id
  WHERE ctm.turn_id = v_turn.id;

  RETURN jsonb_build_object('turn_id', v_turn.id,
    'aggregated_text', v_turn.aggregated_text,
    'message_count', v_turn.message_count,
    'message_ids', to_jsonb(v_msg_ids),
    'first_message_at', v_first_at,
    'last_message_at', v_last_at);
END; $$;

-- 4f. mark_turn_processed
CREATE OR REPLACE FUNCTION mark_turn_processed(
  p_turn_id UUID,
  p_ai_message_id UUID DEFAULT NULL,
  p_usage_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_turn RECORD;
BEGIN
  SELECT * INTO v_turn FROM conversation_turns WHERE id = p_turn_id FOR UPDATE;
  IF v_turn IS NULL THEN
    RETURN jsonb_build_object('error', 'TURN_NOT_FOUND');
  END IF;

  IF v_turn.status = 'processed' THEN
    RETURN jsonb_build_object('turn_id', p_turn_id, 'status', 'processed',
      'processed_at', v_turn.processed_at, 'noop', true);
  END IF;

  IF v_turn.status = 'pending' THEN
    RETURN jsonb_build_object('error', 'TURN_NOT_FINALIZED', 'status', v_turn.status);
  END IF;

  UPDATE conversation_turns SET
    status = 'processed',
    processed_at = now(),
    aggregated_metadata = aggregated_metadata || jsonb_build_object(
      'ai_message_id', p_ai_message_id,
      'usage_id', p_usage_id,
      'processed_status', CASE WHEN p_ai_message_id IS NOT NULL THEN 'success' ELSE 'failed' END
    )
  WHERE id = p_turn_id;

  RETURN jsonb_build_object('turn_id', p_turn_id, 'status', 'processed', 'processed_at', now());
END; $$;

-- 4g. skip_pending_turns_for_conversation
-- Also supersedes finalized turns to prevent stale AI processing after operator takeover
CREATE OR REPLACE FUNCTION skip_pending_turns_for_conversation(
  p_conversation_id UUID,
  p_reason TEXT DEFAULT 'manual'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_skipped_count INT;
  v_superseded_count INT;
  v_affected_count INT;
BEGIN
  WITH updated AS (
    UPDATE conversation_turns SET
      status = CASE
        WHEN status = 'finalized' THEN 'superseded'
        ELSE 'skipped'
      END,
      finalized_reason = p_reason,
      finalized_at = COALESCE(finalized_at, now()),
      updated_at = now()
    WHERE conversation_id = p_conversation_id
      AND status IN ('pending', 'finalized')
    RETURNING status
  )
  SELECT
    COUNT(*) FILTER (WHERE status = 'skipped'),
    COUNT(*) FILTER (WHERE status = 'superseded'),
    COUNT(*)
  INTO v_skipped_count, v_superseded_count, v_affected_count
  FROM updated;

  RETURN jsonb_build_object(
    'skipped_count', v_skipped_count,
    'superseded_count', v_superseded_count,
    'affected_count', v_affected_count);
END; $$;

-- ────────────────────────────────────────────────────────────
-- 5. Integration: Modified Existing Functions
-- ────────────────────────────────────────────────────────────

-- 5a. Modified ingest_inbound_message — adds append_message_to_turn
CREATE OR REPLACE FUNCTION ingest_inbound_message(
  p_business_id        UUID,
  p_channel_id         UUID,
  p_channel_type       channel_type,
  p_sender_identifier  TEXT,
  p_sender_name        TEXT DEFAULT NULL,
  p_content            TEXT DEFAULT NULL,
  p_content_type       message_content_type DEFAULT 'text',
  p_external_message_id TEXT DEFAULT NULL,
  p_raw_payload        JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_channel         RECORD;
  v_customer_id     UUID;
  v_conversation_id UUID;
  v_message_id      UUID;
  v_is_new_customer BOOLEAN := false;
  v_is_new_convo    BOOLEAN := false;
  v_log_id          UUID;
  v_window_id       UUID;
  v_window_delay    INTEGER;
  v_existing_msg    UUID;
  v_turn_result     JSONB;
BEGIN
  -- Step 1: Validate channel belongs to business
  SELECT id, channel_type, is_active, channel_config
  INTO v_channel
  FROM business_channels
  WHERE id = p_channel_id AND business_id = p_business_id;

  IF v_channel IS NULL THEN
    INSERT INTO integration_logs (
      business_id, channel_type, direction, event_type,
      sender_identifier, request_payload, error, processed
    ) VALUES (
      p_business_id, p_channel_type, 'inbound', 'message',
      p_sender_identifier, p_raw_payload,
      'Channel not found or does not belong to business', true
    );
    RETURN jsonb_build_object('error', 'CHANNEL_NOT_FOUND',
      'message', 'Channel does not belong to business');
  END IF;

  IF NOT v_channel.is_active THEN
    INSERT INTO integration_logs (
      business_id, channel_type, direction, event_type,
      sender_identifier, request_payload, error, processed
    ) VALUES (
      p_business_id, p_channel_type, 'inbound', 'message',
      p_sender_identifier, p_raw_payload, 'Channel is inactive', true
    );
    RETURN jsonb_build_object('error', 'CHANNEL_INACTIVE',
      'message', 'Channel is not active');
  END IF;

  -- Step 2: Write integration log
  INSERT INTO integration_logs (
    business_id, channel_type, direction, event_type,
    sender_identifier, request_payload, processed
  ) VALUES (
    p_business_id, p_channel_type, 'inbound', 'message',
    p_sender_identifier, p_raw_payload, false
  ) RETURNING id INTO v_log_id;

  -- Step 3: Resolve or create customer
  SELECT ci.customer_id INTO v_customer_id
  FROM customer_identities ci
  JOIN customers c ON c.id = ci.customer_id
  WHERE ci.channel_type = p_channel_type
    AND ci.channel_identifier = p_sender_identifier
    AND c.business_id = p_business_id
  LIMIT 1;

  IF v_customer_id IS NULL THEN
    v_is_new_customer := true;
  END IF;

  v_customer_id := resolve_or_create_customer(
    p_business_id, p_channel_type, p_sender_identifier, p_sender_name
  );

  -- Step 4: Find or create conversation
  SELECT id INTO v_conversation_id
  FROM conversations
  WHERE business_id = p_business_id
    AND customer_id = v_customer_id
    AND channel_type = p_channel_type
    AND status IN ('open', 'assigned', 'waiting')
  ORDER BY last_message_at DESC NULLS LAST
  LIMIT 1;

  IF v_conversation_id IS NULL THEN
    v_is_new_convo := true;
    INSERT INTO conversations (
      business_id, customer_id, channel_type, channel_id,
      status, last_message_at, message_count
    ) VALUES (
      p_business_id, v_customer_id, p_channel_type, p_channel_id,
      'open', now(), 0
    ) RETURNING id INTO v_conversation_id;
  END IF;

  -- Step 5: Dedup by external_message_id
  IF p_external_message_id IS NOT NULL THEN
    SELECT id INTO v_existing_msg
    FROM messages
    WHERE conversation_id = v_conversation_id
      AND external_message_id = p_external_message_id;

    IF v_existing_msg IS NOT NULL THEN
      UPDATE integration_logs
      SET processed = true,
          response_payload = jsonb_build_object(
            'duplicate', true, 'existing_message_id', v_existing_msg)
      WHERE id = v_log_id;

      RETURN jsonb_build_object(
        'conversation_id', v_conversation_id,
        'customer_id', v_customer_id,
        'message_id', v_existing_msg,
        'is_new_customer', false,
        'is_new_conversation', false,
        'is_duplicate', true);
    END IF;
  END IF;

  -- Step 6: Insert message
  INSERT INTO messages (
    conversation_id, direction, sender_type, sender_id,
    content_type, content, external_message_id
  ) VALUES (
    v_conversation_id, 'inbound', 'customer', v_customer_id,
    p_content_type, p_content, p_external_message_id
  ) RETURNING id INTO v_message_id;

  -- Step 7: Update conversation counters
  UPDATE conversations
  SET message_count = message_count + 1,
      last_message_at = now(),
      status = CASE WHEN status = 'waiting' THEN 'open' ELSE status END
  WHERE id = v_conversation_id;

  IF v_is_new_convo THEN
    UPDATE customers
    SET conversation_count = conversation_count + 1, last_seen_at = now()
    WHERE id = v_customer_id;
  ELSE
    UPDATE customers SET last_seen_at = now() WHERE id = v_customer_id;
  END IF;

  -- Step 8: Message window (preserved from original)
  v_window_delay := COALESCE(
    (SELECT (b.business_config ->>'response_delay_seconds')::int
     FROM businesses b WHERE b.id = p_business_id), 15);

  UPDATE message_windows
  SET window_end = now() + (v_window_delay || ' seconds')::interval,
      message_count = message_count + 1
  WHERE conversation_id = v_conversation_id AND window_end > now()
  RETURNING id INTO v_window_id;

  IF v_window_id IS NULL THEN
    INSERT INTO message_windows (
      conversation_id, window_start, window_end, message_count
    ) VALUES (
      v_conversation_id, now(),
      now() + (v_window_delay || ' seconds')::interval, 1
    ) RETURNING id INTO v_window_id;
  END IF;

  -- Step 8b (IX-C): Append message to conversation turn
  v_turn_result := append_message_to_turn(v_message_id);

  -- Step 9: Update integration log
  UPDATE integration_logs
  SET processed = true,
      response_payload = jsonb_build_object(
        'conversation_id', v_conversation_id,
        'customer_id', v_customer_id,
        'message_id', v_message_id,
        'window_id', v_window_id)
  WHERE id = v_log_id;

  -- Step 10: Audit log for auto-creations
  IF v_is_new_customer THEN
    INSERT INTO audit_log (
      business_id, user_id, action, entity_type, entity_id,
      severity, metadata
    ) VALUES (
      p_business_id, NULL, 'customer_auto_created', 'customer',
      v_customer_id, 'info',
      jsonb_build_object('source', 'inbound_message',
        'channel_type', p_channel_type::text,
        'sender_identifier', p_sender_identifier));
  END IF;

  IF v_is_new_convo THEN
    INSERT INTO audit_log (
      business_id, user_id, action, entity_type, entity_id,
      severity, metadata
    ) VALUES (
      p_business_id, NULL, 'conversation_auto_created', 'conversation',
      v_conversation_id, 'info',
      jsonb_build_object('source', 'inbound_message',
        'channel_type', p_channel_type::text,
        'customer_id', v_customer_id::text));
  END IF;

  -- Return (preserving all existing fields, adding turn_id)
  RETURN jsonb_build_object(
    'conversation_id', v_conversation_id,
    'customer_id', v_customer_id,
    'message_id', v_message_id,
    'window_id', v_window_id,
    'turn_id', v_turn_result->>'turn_id',
    'is_new_customer', v_is_new_customer,
    'is_new_conversation', v_is_new_convo,
    'is_duplicate', false);
END; $$;

-- 5b. Modified collect_ai_context — adds current_turn
CREATE OR REPLACE FUNCTION collect_ai_context(
  p_conversation_id UUID,
  p_max_messages    INTEGER DEFAULT 20
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_convo       RECORD;
  v_customer    RECORD;
  v_ai_policy   JSONB;
  v_messages    JSONB;
  v_current_turn JSONB;
BEGIN
  SELECT c.id, c.business_id, c.customer_id, c.status,
         c.assigned_to, c.ai_enabled, c.channel_type,
         c.channel_id, c.message_count
  INTO v_convo FROM conversations c WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  IF v_convo.status IN ('closed', 'resolved') THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_CLOSED',
      'reason_code', 'conversation_closed');
  END IF;

  IF v_convo.assigned_to IS NOT NULL THEN
    RETURN jsonb_build_object('error', 'OPERATOR_OWNED',
      'reason_code', 'operator_owned', 'assigned_to', v_convo.assigned_to);
  END IF;

  IF NOT v_convo.ai_enabled THEN
    RETURN jsonb_build_object('error', 'AI_DISABLED',
      'reason_code', 'ai_disabled');
  END IF;

  v_ai_policy := evaluate_policy(v_convo.business_id, 'ai_allowed');
  IF v_ai_policy IS NULL OR (v_ai_policy ->>'enabled')::boolean IS DISTINCT FROM true THEN
    RETURN jsonb_build_object('error', 'AI_NOT_ALLOWED',
      'reason_code', 'policy_blocked');
  END IF;

  SELECT cu.id, cu.name, cu.phone, cu.email, cu.metadata
  INTO v_customer FROM customers cu WHERE cu.id = v_convo.customer_id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', sub.id, 'direction', sub.direction,
      'sender_type', sub.sender_type, 'content', sub.content,
      'content_type', sub.content_type, 'created_at', sub.created_at
    ) ORDER BY sub.created_at ASC
  ), '[]'::jsonb) INTO v_messages
  FROM (
    SELECT m.* FROM messages m
    WHERE m.conversation_id = p_conversation_id AND m.is_internal = false
    ORDER BY m.created_at DESC LIMIT p_max_messages
  ) sub;

  -- IX-C: Get current processing turn if available
  SELECT jsonb_build_object(
    'turn_id', ct.id,
    'aggregated_text', ct.aggregated_text,
    'message_count', ct.message_count,
    'finalized_reason', ct.finalized_reason,
    'status', ct.status,
    'created_at', ct.created_at,
    'finalized_at', ct.finalized_at
  ) INTO v_current_turn
  FROM conversation_turns ct
  WHERE ct.conversation_id = p_conversation_id
    AND ct.actor_type = 'customer' AND ct.direction = 'inbound'
    AND ct.status IN ('processing', 'finalized')
  ORDER BY ct.created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'conversation', jsonb_build_object(
      'id', v_convo.id, 'business_id', v_convo.business_id,
      'status', v_convo.status, 'channel_type', v_convo.channel_type,
      'message_count', v_convo.message_count),
    'customer', jsonb_build_object(
      'id', v_customer.id, 'name', v_customer.name,
      'phone', v_customer.phone, 'email', v_customer.email),
    'messages', v_messages,
    'ai_policy', v_ai_policy,
    'current_turn', v_current_turn,
    'safe', true);
END; $$;

-- 5c. Modified release_to_ai_with_reply — turn-aware flow
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
  v_turn           JSONB;
  v_turn_id        UUID;
BEGIN
  v_release_result := release_to_ai(p_conversation_id);
  IF v_release_result ? 'error' THEN
    RETURN v_release_result;
  END IF;

  SELECT business_id INTO v_biz_id FROM conversations WHERE id = p_conversation_id;

  -- IX-C: Try to claim a finalized turn
  v_turn := get_finalized_turn_for_ai(p_conversation_id);
  IF v_turn IS NOT NULL THEN
    v_turn_id := (v_turn->>'turn_id')::uuid;
  END IF;

  v_binding := resolve_ai_capability_binding(v_biz_id, 'reply_drafter');
  IF v_binding ? 'error' THEN
    v_error_code := v_binding->>'error';
    v_fallback := classify_ai_fallback('binding', v_error_code);
    PERFORM record_ai_usage(v_biz_id, p_conversation_id, NULL,
      'reply_drafter', 'unknown', 'unknown',
      'blocked', 0, 0, NULL, v_fallback->>'fallback_code');
    IF v_turn_id IS NOT NULL THEN
      PERFORM mark_turn_processed(v_turn_id, NULL, NULL);
    END IF;
    RETURN jsonb_build_object(
      'conversation_id', p_conversation_id,
      'status', 'open', 'ai_enabled', true,
      'event_type', 'released_to_ai',
      'ai_reply', jsonb_build_object('skipped', true,
        'reason', v_error_code, 'fallback', v_fallback));
  END IF;

  v_budget := check_ai_budget(v_biz_id, 'reply_drafter', 25, p_conversation_id);
  IF NOT (v_budget->>'allowed')::boolean THEN
    PERFORM record_ai_usage(v_biz_id, p_conversation_id, NULL,
      'reply_drafter', v_binding->>'provider_mode', v_binding->>'model_code',
      'budget_exceeded', 0, 0, NULL, v_budget->>'reason');
    v_fallback := classify_ai_fallback('budget', v_budget->>'reason');
    IF v_turn_id IS NOT NULL THEN
      PERFORM mark_turn_processed(v_turn_id, NULL, NULL);
    END IF;
    RETURN jsonb_build_object(
      'conversation_id', p_conversation_id,
      'error', 'BUDGET_EXCEEDED',
      'reason', v_budget->>'reason',
      'budget', v_budget,
      'ai_reply', jsonb_build_object('skipped', true,
        'reason', v_budget->>'reason', 'fallback', v_fallback));
  END IF;

  v_context := collect_ai_context(p_conversation_id);
  IF v_context ? 'error' THEN
    v_error_code := v_context->>'error';
    v_fallback := classify_ai_fallback('context', v_error_code);
    PERFORM record_ai_usage(v_biz_id, p_conversation_id, NULL,
      'reply_drafter', v_binding->>'provider_mode', v_binding->>'model_code',
      'blocked', 0, 0, NULL, v_fallback->>'fallback_code');
    IF v_turn_id IS NOT NULL THEN
      PERFORM mark_turn_processed(v_turn_id, NULL, NULL);
    END IF;
    RETURN jsonb_build_object(
      'conversation_id', p_conversation_id,
      'status', 'open', 'ai_enabled', true,
      'event_type', 'released_to_ai',
      'ai_reply', jsonb_build_object('skipped', true,
        'reason', v_error_code, 'fallback', v_fallback));
  END IF;

  v_customer_name := COALESCE(v_context->'customer'->>'name','valued customer');
  v_reply_content := format(
    '[AI Assistant] Thank you for your message, %s. I''ve noted your request and our team is ready to help. How can I assist you further?',
    v_customer_name);

  v_reply_result := persist_ai_reply(
    p_conversation_id, v_reply_content, 'text'::message_content_type,
    'mock-sql', 'mock-sql-v1', 5, 20, 1);

  IF v_reply_result ? 'error' THEN
    v_error_code := v_reply_result->>'error';
    v_fallback := classify_ai_fallback('persist', v_error_code);
    PERFORM record_ai_usage(v_biz_id, p_conversation_id, NULL,
      'reply_drafter', v_binding->>'provider_mode', v_binding->>'model_code',
      'failed', 5, 20, 1, v_fallback->>'fallback_code');
    IF (v_fallback->>'human_handoff')::boolean = true THEN
      INSERT INTO handoff_events (
        conversation_id, business_id, event_type,
        from_owner_type, to_owner_type, reason, metadata
      ) VALUES (
        p_conversation_id, v_biz_id, 'ai_fallback',
        'ai', 'unassigned', v_fallback->>'message',
        jsonb_build_object('fallback_code', v_fallback->>'fallback_code',
          'severity', v_fallback->>'severity', 'error_source', 'persist'));
    END IF;
    IF v_turn_id IS NOT NULL THEN
      PERFORM mark_turn_processed(v_turn_id, NULL, NULL);
    END IF;
    RETURN jsonb_build_object(
      'conversation_id', p_conversation_id,
      'status', 'open', 'ai_enabled', true,
      'event_type', 'released_to_ai',
      'ai_reply', jsonb_build_object('skipped', true,
        'reason', v_error_code, 'fallback', v_fallback));
  END IF;

  v_usage_id := record_ai_usage(v_biz_id, p_conversation_id,
    (v_reply_result->>'message_id')::uuid,
    'reply_drafter', v_binding->>'provider_mode', v_binding->>'model_code',
    'completed', 5, 20, 1);

  -- IX-C: mark turn processed on success
  IF v_turn_id IS NOT NULL THEN
    PERFORM mark_turn_processed(v_turn_id,
      (v_reply_result->>'message_id')::uuid, v_usage_id);
  END IF;

  RETURN jsonb_build_object(
    'conversation_id', p_conversation_id,
    'status', 'open', 'ai_enabled', true,
    'event_type', 'released_to_ai',
    'ai_reply', jsonb_build_object(
      'message_id', v_reply_result->>'message_id',
      'delivery_status', v_reply_result->>'delivery_status',
      'decision', v_reply_result->>'decision',
      'provider', 'mock-sql',
      'usage_id', v_usage_id,
      'turn_id', v_turn_id));
END; $$;

-- 5d. Modified assign_conversation — skip pending turns on operator takeover
CREATE OR REPLACE FUNCTION assign_conversation(
  p_conversation_id UUID,
  p_operator_id     UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
DECLARE
  v_caller_id    UUID;
  v_convo        RECORD;
  v_prev_owner   UUID;
  v_prev_type    TEXT;
  v_member_check BOOLEAN;
BEGIN
  v_caller_id := auth.uid();

  SELECT c.id, c.business_id, c.status, c.assigned_to
  INTO v_convo FROM conversations c WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  IF NOT check_permission(v_caller_id, v_convo.business_id, 'conversation:assign') THEN
    RETURN jsonb_build_object('error', 'PERMISSION_DENIED',
      'message', 'Caller lacks conversation:assign permission');
  END IF;

  IF v_convo.status IN ('closed', 'resolved') THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_CLOSED',
      'message', 'Cannot assign a closed or resolved conversation');
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM business_memberships
    WHERE user_id = p_operator_id
      AND business_id = v_convo.business_id AND is_active = true
  ) INTO v_member_check;

  IF NOT v_member_check THEN
    RETURN jsonb_build_object('error', 'INVALID_OPERATOR',
      'message', 'Operator is not an active member of this business');
  END IF;

  v_prev_owner := v_convo.assigned_to;
  v_prev_type := CASE
    WHEN v_convo.assigned_to IS NOT NULL THEN 'operator'
    ELSE 'unassigned' END;

  UPDATE conversations
  SET assigned_to = p_operator_id, assigned_at = now(),
      status = 'assigned', ai_enabled = false, updated_at = now()
  WHERE id = p_conversation_id;

  -- IX-C: Skip pending turns when operator takes over
  PERFORM skip_pending_turns_for_conversation(p_conversation_id, 'operator_takeover');

  INSERT INTO handoff_events (
    conversation_id, business_id, event_type,
    from_owner_type, from_owner_id, to_owner_type, to_owner_id, triggered_by
  ) VALUES (
    p_conversation_id, v_convo.business_id, 'assigned',
    v_prev_type, v_prev_owner, 'operator', p_operator_id, v_caller_id);

  INSERT INTO audit_log (
    business_id, user_id, action, entity_type, entity_id, severity, metadata
  ) VALUES (
    v_convo.business_id, v_caller_id,
    'conversation_assigned', 'conversation', p_conversation_id, 'info',
    jsonb_build_object('operator_id', p_operator_id::text,
      'previous_owner', v_prev_owner::text,
      'previous_owner_type', v_prev_type));

  RETURN jsonb_build_object(
    'conversation_id', p_conversation_id,
    'assigned_to', p_operator_id,
    'status', 'assigned', 'event_type', 'assigned');
END; $$;

COMMIT;
