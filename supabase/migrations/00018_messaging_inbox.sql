-- ============================================================
-- 00018 — Messaging & Inbox Core
--
-- Adds:
--   1. integration_logs table (channel event debugging)
--   2. messages.external_message_id column (dedup)
--   3. ingest_inbound_message() RPC (orchestrator)
--   4. get_inbox_list() RPC (inbox query)
--   5. get_conversation_detail() RPC (detail query)
--
-- Phase: 2A
-- Depends: 00007_conversation, 00006_customer, 00016_rls_policies
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. Integration Logs Table
-- ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS integration_logs (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       UUID REFERENCES businesses(id) ON DELETE CASCADE,
  channel_type      channel_type NOT NULL,
  direction         TEXT NOT NULL DEFAULT 'inbound'
                      CHECK (direction IN ('inbound', 'outbound')),
  provider_name     TEXT NOT NULL DEFAULT 'test',
  event_type        TEXT,
  sender_identifier TEXT,
  request_payload   JSONB NOT NULL DEFAULT '{}'::jsonb,
  response_payload  JSONB,
  status_code       INTEGER,
  latency_ms        INTEGER,
  error             TEXT,
  processed         BOOLEAN NOT NULL DEFAULT false,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_integration_logs_business
  ON integration_logs(business_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_integration_logs_error
  ON integration_logs(business_id)
  WHERE error IS NOT NULL;

-- RLS
ALTER TABLE integration_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS members_read_integration_logs ON integration_logs;
CREATE POLICY members_read_integration_logs ON integration_logs
  FOR SELECT USING (
    business_id IS NOT NULL AND is_business_member(business_id)
  );

DROP POLICY IF EXISTS platform_admins_read_integration_logs ON integration_logs;
CREATE POLICY platform_admins_read_integration_logs ON integration_logs
  FOR SELECT USING (is_platform_admin(auth.uid()));

-- ────────────────────────────────────────────────────────────
-- 2. External Message ID for Dedup
-- ────────────────────────────────────────────────────────────

ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS external_message_id TEXT;

-- Unique per conversation — prevents duplicate webhook deliveries
CREATE UNIQUE INDEX IF NOT EXISTS uq_messages_external_id
  ON messages(conversation_id, external_message_id)
  WHERE external_message_id IS NOT NULL;

-- ────────────────────────────────────────────────────────────
-- 3. Ingest Inbound Message — Orchestrator RPC
-- ────────────────────────────────────────────────────────────

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
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
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
BEGIN
  -- ── Step 1: Validate channel belongs to business ──────────
  SELECT id, channel_type, is_active, channel_config
  INTO v_channel
  FROM business_channels
  WHERE id = p_channel_id
    AND business_id = p_business_id;

  IF v_channel IS NULL THEN
    -- Log the failed attempt
    INSERT INTO integration_logs (
      business_id, channel_type, direction, event_type,
      sender_identifier, request_payload, error, processed
    ) VALUES (
      p_business_id, p_channel_type, 'inbound', 'message',
      p_sender_identifier, p_raw_payload,
      'Channel not found or does not belong to business', true
    );

    RETURN jsonb_build_object(
      'error', 'CHANNEL_NOT_FOUND',
      'message', 'Channel does not belong to business'
    );
  END IF;

  IF NOT v_channel.is_active THEN
    INSERT INTO integration_logs (
      business_id, channel_type, direction, event_type,
      sender_identifier, request_payload, error, processed
    ) VALUES (
      p_business_id, p_channel_type, 'inbound', 'message',
      p_sender_identifier, p_raw_payload,
      'Channel is inactive', true
    );

    RETURN jsonb_build_object(
      'error', 'CHANNEL_INACTIVE',
      'message', 'Channel is not active'
    );
  END IF;

  -- ── Step 2: Write integration log ─────────────────────────
  INSERT INTO integration_logs (
    business_id, channel_type, direction, event_type,
    sender_identifier, request_payload, processed
  ) VALUES (
    p_business_id, p_channel_type, 'inbound', 'message',
    p_sender_identifier, p_raw_payload, false
  )
  RETURNING id INTO v_log_id;

  -- ── Step 3: Resolve or create customer ────────────────────
  -- Check if customer exists first (to track is_new_customer)
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

  -- ── Step 4: Find or create conversation ───────────────────
  -- Look for existing open/assigned/waiting conversation
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
    )
    RETURNING id INTO v_conversation_id;
  END IF;

  -- ── Step 5: Dedup by external_message_id ──────────────────
  IF p_external_message_id IS NOT NULL THEN
    SELECT id INTO v_existing_msg
    FROM messages
    WHERE conversation_id = v_conversation_id
      AND external_message_id = p_external_message_id;

    IF v_existing_msg IS NOT NULL THEN
      -- Already ingested — update integration log and return
      UPDATE integration_logs
      SET processed = true,
          response_payload = jsonb_build_object(
            'duplicate', true,
            'existing_message_id', v_existing_msg
          )
      WHERE id = v_log_id;

      RETURN jsonb_build_object(
        'conversation_id', v_conversation_id,
        'customer_id', v_customer_id,
        'message_id', v_existing_msg,
        'is_new_customer', false,
        'is_new_conversation', false,
        'is_duplicate', true
      );
    END IF;
  END IF;

  -- ── Step 6: Insert message ────────────────────────────────
  INSERT INTO messages (
    conversation_id, direction, sender_type, sender_id,
    content_type, content, external_message_id
  ) VALUES (
    v_conversation_id, 'inbound', 'customer', v_customer_id,
    p_content_type, p_content, p_external_message_id
  )
  RETURNING id INTO v_message_id;

  -- ── Step 7: Update conversation counters ──────────────────
  UPDATE conversations
  SET message_count = message_count + 1,
      last_message_at = now(),
      -- If conversation was waiting, re-open it
      status = CASE
        WHEN status = 'waiting' THEN 'open'
        ELSE status
      END
  WHERE id = v_conversation_id;

  -- Update customer conversation count if new
  IF v_is_new_convo THEN
    UPDATE customers
    SET conversation_count = conversation_count + 1,
        last_seen_at = now()
    WHERE id = v_customer_id;
  ELSE
    UPDATE customers
    SET last_seen_at = now()
    WHERE id = v_customer_id;
  END IF;

  -- ── Step 8: Message window (fragmented message batching) ──
  -- Default 15s window, configurable via business_config
  v_window_delay := COALESCE(
    (SELECT (b.business_config ->> 'response_delay_seconds')::int
     FROM businesses b WHERE b.id = p_business_id),
    15
  );

  -- Try to extend an existing open window
  UPDATE message_windows
  SET window_end = now() + (v_window_delay || ' seconds')::interval,
      message_count = message_count + 1
  WHERE conversation_id = v_conversation_id
    AND window_end > now()
  RETURNING id INTO v_window_id;

  -- If no open window, create one
  IF v_window_id IS NULL THEN
    INSERT INTO message_windows (
      conversation_id, window_start, window_end, message_count
    ) VALUES (
      v_conversation_id, now(),
      now() + (v_window_delay || ' seconds')::interval,
      1
    )
    RETURNING id INTO v_window_id;
  END IF;

  -- ── Step 9: Update integration log ────────────────────────
  UPDATE integration_logs
  SET processed = true,
      response_payload = jsonb_build_object(
        'conversation_id', v_conversation_id,
        'customer_id', v_customer_id,
        'message_id', v_message_id,
        'window_id', v_window_id
      )
  WHERE id = v_log_id;

-- ── Step 10: Audit log for auto-creations ─────────────────
  -- Use NULL for user_id since this is a system-initiated action
  IF v_is_new_customer THEN
    INSERT INTO audit_log (
      business_id, user_id, action, entity_type, entity_id,
      severity, metadata
    ) VALUES (
      p_business_id, NULL, 'customer_auto_created', 'customer',
      v_customer_id, 'info',
      jsonb_build_object(
        'source', 'inbound_message',
        'channel_type', p_channel_type::text,
        'sender_identifier', p_sender_identifier
      )
    );
  END IF;

  IF v_is_new_convo THEN
    INSERT INTO audit_log (
      business_id, user_id, action, entity_type, entity_id,
      severity, metadata
    ) VALUES (
      p_business_id, NULL, 'conversation_auto_created', 'conversation',
      v_conversation_id, 'info',
      jsonb_build_object(
        'source', 'inbound_message',
        'channel_type', p_channel_type::text,
        'customer_id', v_customer_id::text
      )
    );
  END IF;

  -- ── Return ────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'conversation_id', v_conversation_id,
    'customer_id', v_customer_id,
    'message_id', v_message_id,
    'window_id', v_window_id,
    'is_new_customer', v_is_new_customer,
    'is_new_conversation', v_is_new_convo,
    'is_duplicate', false
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 4. Inbox List Query RPC
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_inbox_list(
  p_business_id    UUID,
  p_status_filter  conversation_status[] DEFAULT NULL,
  p_limit          INTEGER DEFAULT 50,
  p_offset         INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_result    JSONB;
  v_caller_id UUID;
BEGIN
  -- Explicit membership check (SECURITY DEFINER bypasses RLS)
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL OR (
    NOT EXISTS (
      SELECT 1 FROM business_memberships
      WHERE business_id = p_business_id
        AND user_id = v_caller_id
        AND is_active = true
    )
    AND COALESCE(is_platform_admin(v_caller_id), false) = false
  ) THEN
    RETURN jsonb_build_object('conversations', '[]'::jsonb, 'total', 0);
  END IF;

  SELECT jsonb_build_object(
    'conversations', COALESCE(jsonb_agg(item ORDER BY item->>'last_message_at' DESC), '[]'::jsonb),
    'total', (
      SELECT count(*)
      FROM conversations c2
      WHERE c2.business_id = p_business_id
        AND (p_status_filter IS NULL OR c2.status = ANY(p_status_filter))
    )
  ) INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'id', c.id,
      'business_id', c.business_id,
      'status', c.status,
      'channel_type', c.channel_type,
      'assigned_to', c.assigned_to,
      'ai_enabled', c.ai_enabled,
      'message_count', c.message_count,
      'last_message_at', c.last_message_at,
      'created_at', c.created_at,
      'customer', jsonb_build_object(
        'id', cu.id,
        'name', cu.name,
        'phone', cu.phone,
        'email', cu.email
      ),
      'last_message', (
        SELECT jsonb_build_object(
          'id', m.id,
          'content', LEFT(m.content, 120),
          'content_type', m.content_type,
          'sender_type', m.sender_type,
          'direction', m.direction,
          'created_at', m.created_at
        )
        FROM messages m
        WHERE m.conversation_id = c.id
        ORDER BY m.created_at DESC
        LIMIT 1
      ),
      'unread_count', (
        SELECT count(*)
        FROM messages m2
        WHERE m2.conversation_id = c.id
          AND m2.direction = 'inbound'
          AND m2.read_at IS NULL
      )
    ) AS item
    FROM conversations c
    JOIN customers cu ON cu.id = c.customer_id
    WHERE c.business_id = p_business_id
      AND (p_status_filter IS NULL OR c.status = ANY(p_status_filter))
    ORDER BY c.last_message_at DESC NULLS LAST
    LIMIT p_limit
    OFFSET p_offset
  ) sub;

  RETURN COALESCE(v_result, jsonb_build_object('conversations', '[]'::jsonb, 'total', 0));
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 5. Conversation Detail Query RPC
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_conversation_detail(
  p_conversation_id UUID,
  p_message_limit   INTEGER DEFAULT 50,
  p_message_offset  INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_convo       RECORD;
  v_result      JSONB;
  v_caller_id   UUID;
  v_business_id UUID;
BEGIN
  -- Get conversation (no RLS — SECURITY DEFINER)
  SELECT c.*, cu.name as customer_name, cu.phone as customer_phone,
         cu.email as customer_email, cu.metadata as customer_metadata
  INTO v_convo
  FROM conversations c
  JOIN customers cu ON cu.id = c.customer_id
  WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  -- Explicit membership check
  v_caller_id := auth.uid();
  v_business_id := v_convo.business_id;
  IF v_caller_id IS NULL OR (
    NOT EXISTS (
      SELECT 1 FROM business_memberships
      WHERE business_id = v_business_id
        AND user_id = v_caller_id
        AND is_active = true
    )
    AND COALESCE(is_platform_admin(v_caller_id), false) = false
  ) THEN
    RETURN jsonb_build_object('error', 'ACCESS_DENIED');
  END IF;

  v_result := jsonb_build_object(
    'conversation', jsonb_build_object(
      'id', v_convo.id,
      'business_id', v_convo.business_id,
      'status', v_convo.status,
      'channel_type', v_convo.channel_type,
      'channel_id', v_convo.channel_id,
      'assigned_to', v_convo.assigned_to,
      'assigned_at', v_convo.assigned_at,
      'ai_enabled', v_convo.ai_enabled,
      'subject', v_convo.subject,
      'metadata', v_convo.metadata,
      'message_count', v_convo.message_count,
      'last_message_at', v_convo.last_message_at,
      'created_at', v_convo.created_at,
      'resolved_at', v_convo.resolved_at,
      'closed_at', v_convo.closed_at
    ),
    'customer', jsonb_build_object(
      'id', v_convo.customer_id,
      'name', v_convo.customer_name,
      'phone', v_convo.customer_phone,
      'email', v_convo.customer_email,
      'metadata', v_convo.customer_metadata
    ),
    'messages', (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'id', sub.id,
          'direction', sub.direction,
          'sender_type', sub.sender_type,
          'sender_id', sub.sender_id,
          'content_type', sub.content_type,
          'content', sub.content,
          'content_metadata', sub.content_metadata,
          'is_internal', sub.is_internal,
          'external_message_id', sub.external_message_id,
          'delivered_at', sub.delivered_at,
          'read_at', sub.read_at,
          'created_at', sub.created_at
        ) ORDER BY sub.created_at ASC
      ), '[]'::jsonb)
      FROM (
        SELECT m.*
        FROM messages m
        WHERE m.conversation_id = p_conversation_id
        ORDER BY m.created_at ASC
        LIMIT p_message_limit
        OFFSET p_message_offset
      ) sub
    ),
    'message_total', (
      SELECT count(*) FROM messages
      WHERE conversation_id = p_conversation_id
    )
  );

  RETURN v_result;
END;
$$;

COMMIT;
