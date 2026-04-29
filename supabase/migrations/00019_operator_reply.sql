-- ============================================================
-- 00019 — Operator Reply + Assignment Foundation
--
-- Phase: 2B
-- Depends: 00018_messaging_inbox
--
-- Adds:
--   1. Security patch: is_platform_admin() → always returns boolean
--   2. handoff_events table (routing ownership history)
--   3. messages.delivery_status column
--   4. assign_conversation() RPC
--   5. unassign_conversation() RPC
--   6. transfer_conversation() RPC
--   7. operator_reply() RPC
--   8. Cleanup: remove COALESCE workarounds in 2A RPCs
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. Security Patch — is_platform_admin()
--    Root cause: returned NULL when platform_role was NULL
--    Fix: COALESCE the IN expression to always return boolean
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION is_platform_admin(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_role platform_role;
BEGIN
  SELECT up.platform_role INTO v_role
  FROM user_profiles up
  WHERE up.id = p_user_id;

  RETURN COALESCE(v_role IN ('super_admin', 'platform_admin'), false);
END;
$function$;

-- ────────────────────────────────────────────────────────────
-- 2. Handoff Events Table (Routing Domain)
-- ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS handoff_events (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  event_type      TEXT NOT NULL
                    CHECK (event_type IN (
                      'assigned', 'unassigned', 'transferred',
                      'takeover', 'released_to_ai', 'auto_assigned'
                    )),
  from_owner_type TEXT CHECK (from_owner_type IN ('operator', 'ai', 'unassigned')),
  from_owner_id   UUID,
  to_owner_type   TEXT NOT NULL CHECK (to_owner_type IN ('operator', 'ai', 'unassigned')),
  to_owner_id     UUID,
  reason          TEXT,
  triggered_by    UUID,
  metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_handoff_events_conversation
  ON handoff_events(conversation_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_handoff_events_business
  ON handoff_events(business_id, created_at DESC);

-- RLS
ALTER TABLE handoff_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS members_read_handoff_events ON handoff_events;
CREATE POLICY members_read_handoff_events ON handoff_events
  FOR SELECT USING (is_business_member(business_id));

DROP POLICY IF EXISTS platform_admins_read_handoff_events ON handoff_events;
CREATE POLICY platform_admins_read_handoff_events ON handoff_events
  FOR SELECT USING (is_platform_admin(auth.uid()));

-- ────────────────────────────────────────────────────────────
-- 3. Messages — delivery_status column
-- ────────────────────────────────────────────────────────────

ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS delivery_status TEXT
    NOT NULL DEFAULT 'none'
    CHECK (delivery_status IN ('none', 'queued', 'sent', 'delivered', 'read', 'failed'));

-- ────────────────────────────────────────────────────────────
-- 4. assign_conversation() — Routing RPC
-- ────────────────────────────────────────────────────────────

-- Drop old Phase 0 stub (returns void, incompatible with new JSONB return)
DROP FUNCTION IF EXISTS assign_conversation(UUID, UUID);

CREATE OR REPLACE FUNCTION assign_conversation(
  p_conversation_id UUID,
  p_operator_id     UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller_id    UUID;
  v_convo        RECORD;
  v_prev_owner   UUID;
  v_prev_type    TEXT;
  v_member_check BOOLEAN;
BEGIN
  v_caller_id := auth.uid();

  -- Step 1: Get conversation
  SELECT c.id, c.business_id, c.status, c.assigned_to
  INTO v_convo
  FROM conversations c
  WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  -- Step 2: Caller must have assign permission
  IF NOT check_permission(v_caller_id, v_convo.business_id, 'conversation:assign') THEN
    RETURN jsonb_build_object('error', 'PERMISSION_DENIED',
      'message', 'Caller lacks conversation:assign permission');
  END IF;

  -- Step 3: Conversation must not be closed/resolved
  IF v_convo.status IN ('closed', 'resolved') THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_CLOSED',
      'message', 'Cannot assign a closed or resolved conversation');
  END IF;

  -- Step 4: Operator must be active member of same business
  SELECT EXISTS(
    SELECT 1 FROM business_memberships
    WHERE user_id = p_operator_id
      AND business_id = v_convo.business_id
      AND is_active = true
  ) INTO v_member_check;

  IF NOT v_member_check THEN
    RETURN jsonb_build_object('error', 'INVALID_OPERATOR',
      'message', 'Operator is not an active member of this business');
  END IF;

  -- Save previous owner
  v_prev_owner := v_convo.assigned_to;
  v_prev_type := CASE
    WHEN v_convo.assigned_to IS NOT NULL THEN 'operator'
    ELSE 'unassigned'
  END;

  -- Step 5: Update conversation
  UPDATE conversations
  SET assigned_to = p_operator_id,
      assigned_at = now(),
      status = 'assigned',
      ai_enabled = false,
      updated_at = now()
  WHERE id = p_conversation_id;

  -- Step 6: Insert handoff event
  INSERT INTO handoff_events (
    conversation_id, business_id, event_type,
    from_owner_type, from_owner_id,
    to_owner_type, to_owner_id,
    triggered_by
  ) VALUES (
    p_conversation_id, v_convo.business_id, 'assigned',
    v_prev_type, v_prev_owner,
    'operator', p_operator_id,
    v_caller_id
  );

  -- Step 7: Audit log
  INSERT INTO audit_log (
    business_id, user_id, action, entity_type, entity_id,
    severity, metadata
  ) VALUES (
    v_convo.business_id, v_caller_id,
    'conversation_assigned', 'conversation', p_conversation_id,
    'info',
    jsonb_build_object(
      'operator_id', p_operator_id::text,
      'previous_owner', v_prev_owner::text,
      'previous_owner_type', v_prev_type
    )
  );

  RETURN jsonb_build_object(
    'conversation_id', p_conversation_id,
    'assigned_to', p_operator_id,
    'status', 'assigned',
    'event_type', 'assigned'
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 5. unassign_conversation() — Routing RPC
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION unassign_conversation(
  p_conversation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller_id  UUID;
  v_convo      RECORD;
  v_prev_owner UUID;
BEGIN
  v_caller_id := auth.uid();

  SELECT c.id, c.business_id, c.status, c.assigned_to
  INTO v_convo
  FROM conversations c
  WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  IF NOT check_permission(v_caller_id, v_convo.business_id, 'conversation:assign') THEN
    RETURN jsonb_build_object('error', 'PERMISSION_DENIED');
  END IF;

  IF v_convo.assigned_to IS NULL THEN
    RETURN jsonb_build_object('error', 'NOT_ASSIGNED',
      'message', 'Conversation is not currently assigned');
  END IF;

  v_prev_owner := v_convo.assigned_to;

  UPDATE conversations
  SET assigned_to = NULL,
      assigned_at = NULL,
      status = 'open',
      updated_at = now()
  WHERE id = p_conversation_id;

  INSERT INTO handoff_events (
    conversation_id, business_id, event_type,
    from_owner_type, from_owner_id,
    to_owner_type, to_owner_id,
    triggered_by
  ) VALUES (
    p_conversation_id, v_convo.business_id, 'unassigned',
    'operator', v_prev_owner,
    'unassigned', NULL,
    v_caller_id
  );

  INSERT INTO audit_log (
    business_id, user_id, action, entity_type, entity_id,
    severity, metadata
  ) VALUES (
    v_convo.business_id, v_caller_id,
    'conversation_unassigned', 'conversation', p_conversation_id,
    'info',
    jsonb_build_object('previous_operator', v_prev_owner::text)
  );

  RETURN jsonb_build_object(
    'conversation_id', p_conversation_id,
    'status', 'open',
    'event_type', 'unassigned'
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 6. transfer_conversation() — Routing RPC
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION transfer_conversation(
  p_conversation_id  UUID,
  p_to_operator_id   UUID,
  p_reason           TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller_id    UUID;
  v_convo        RECORD;
  v_prev_owner   UUID;
  v_member_check BOOLEAN;
BEGIN
  v_caller_id := auth.uid();

  SELECT c.id, c.business_id, c.status, c.assigned_to
  INTO v_convo
  FROM conversations c
  WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  -- Caller must be the current assignee OR have assign permission
  IF v_convo.assigned_to != v_caller_id
    AND NOT check_permission(v_caller_id, v_convo.business_id, 'conversation:assign') THEN
    RETURN jsonb_build_object('error', 'PERMISSION_DENIED',
      'message', 'Only the assigned operator or a user with assign permission can transfer');
  END IF;

  IF v_convo.status IN ('closed', 'resolved') THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_CLOSED');
  END IF;

  -- Target operator must be active member
  SELECT EXISTS(
    SELECT 1 FROM business_memberships
    WHERE user_id = p_to_operator_id
      AND business_id = v_convo.business_id
      AND is_active = true
  ) INTO v_member_check;

  IF NOT v_member_check THEN
    RETURN jsonb_build_object('error', 'INVALID_OPERATOR',
      'message', 'Target operator is not an active member of this business');
  END IF;

  v_prev_owner := v_convo.assigned_to;

  UPDATE conversations
  SET assigned_to = p_to_operator_id,
      assigned_at = now(),
      status = 'assigned',
      updated_at = now()
  WHERE id = p_conversation_id;

  INSERT INTO handoff_events (
    conversation_id, business_id, event_type,
    from_owner_type, from_owner_id,
    to_owner_type, to_owner_id,
    reason, triggered_by
  ) VALUES (
    p_conversation_id, v_convo.business_id, 'transferred',
    'operator', v_prev_owner,
    'operator', p_to_operator_id,
    p_reason, v_caller_id
  );

  INSERT INTO audit_log (
    business_id, user_id, action, entity_type, entity_id,
    severity, metadata
  ) VALUES (
    v_convo.business_id, v_caller_id,
    'conversation_transferred', 'conversation', p_conversation_id,
    'info',
    jsonb_build_object(
      'from_operator', v_prev_owner::text,
      'to_operator', p_to_operator_id::text,
      'reason', COALESCE(p_reason, '')
    )
  );

  RETURN jsonb_build_object(
    'conversation_id', p_conversation_id,
    'assigned_to', p_to_operator_id,
    'status', 'assigned',
    'event_type', 'transferred'
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 7. operator_reply() — Conversations + Channels RPC
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION operator_reply(
  p_conversation_id UUID,
  p_content         TEXT,
  p_content_type    message_content_type DEFAULT 'text'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller_id   UUID;
  v_convo       RECORD;
  v_message_id  UUID;
  v_role        membership_role;
  v_can_reply   BOOLEAN := false;
BEGIN
  v_caller_id := auth.uid();

  -- Step 1: Get conversation
  SELECT c.id, c.business_id, c.status, c.assigned_to,
         c.channel_type, c.channel_id, c.customer_id
  INTO v_convo
  FROM conversations c
  WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  -- Step 2: Conversation must not be closed/resolved
  IF v_convo.status IN ('closed', 'resolved') THEN
    INSERT INTO audit_log (
      business_id, user_id, action, entity_type, entity_id,
      severity, metadata
    ) VALUES (
      v_convo.business_id, v_caller_id,
      'operator_reply_denied', 'conversation', p_conversation_id,
      'warning',
      jsonb_build_object('reason', 'conversation_closed', 'status', v_convo.status::text)
    );

    RETURN jsonb_build_object('error', 'CONVERSATION_CLOSED',
      'message', 'Cannot reply to a closed or resolved conversation');
  END IF;

  -- Step 3: Check conversation:write permission
  IF NOT check_permission(v_caller_id, v_convo.business_id, 'conversation:write') THEN
    INSERT INTO audit_log (
      business_id, user_id, action, entity_type, entity_id,
      severity, metadata
    ) VALUES (
      v_convo.business_id, v_caller_id,
      'operator_reply_denied', 'conversation', p_conversation_id,
      'warning',
      jsonb_build_object('reason', 'permission_denied')
    );

    RETURN jsonb_build_object('error', 'PERMISSION_DENIED',
      'message', 'Caller lacks conversation:write permission');
  END IF;

  -- Step 4: Assignment rule
  -- Get caller's role
  SELECT bm.role INTO v_role
  FROM business_memberships bm
  WHERE bm.user_id = v_caller_id
    AND bm.business_id = v_convo.business_id
    AND bm.is_active = true
  LIMIT 1;

  -- Check who can reply:
  -- a) Assigned operator
  IF v_convo.assigned_to = v_caller_id THEN
    v_can_reply := true;
  -- b) Owner bypass
  ELSIF v_role = 'owner' THEN
    v_can_reply := true;
    -- Auto-assign to owner if not already assigned
    IF v_convo.assigned_to IS NULL OR v_convo.assigned_to != v_caller_id THEN
      UPDATE conversations
      SET assigned_to = v_caller_id,
          assigned_at = now(),
          status = 'assigned',
          ai_enabled = false
      WHERE id = p_conversation_id;

      INSERT INTO handoff_events (
        conversation_id, business_id, event_type,
        from_owner_type, from_owner_id,
        to_owner_type, to_owner_id,
        triggered_by, metadata
      ) VALUES (
        p_conversation_id, v_convo.business_id, 'takeover',
        CASE WHEN v_convo.assigned_to IS NOT NULL THEN 'operator' ELSE 'unassigned' END,
        v_convo.assigned_to,
        'operator', v_caller_id,
        v_caller_id,
        '{"reason": "owner_reply_takeover"}'::jsonb
      );
    END IF;
  -- c) Manager with takeover permission
  ELSIF v_role = 'manager'
    AND check_permission(v_caller_id, v_convo.business_id, 'conversation:takeover') THEN
    v_can_reply := true;
    -- Auto-assign to manager
    IF v_convo.assigned_to IS NULL OR v_convo.assigned_to != v_caller_id THEN
      UPDATE conversations
      SET assigned_to = v_caller_id,
          assigned_at = now(),
          status = 'assigned',
          ai_enabled = false
      WHERE id = p_conversation_id;

      INSERT INTO handoff_events (
        conversation_id, business_id, event_type,
        from_owner_type, from_owner_id,
        to_owner_type, to_owner_id,
        triggered_by, metadata
      ) VALUES (
        p_conversation_id, v_convo.business_id, 'takeover',
        CASE WHEN v_convo.assigned_to IS NOT NULL THEN 'operator' ELSE 'unassigned' END,
        v_convo.assigned_to,
        'operator', v_caller_id,
        v_caller_id,
        '{"reason": "manager_reply_takeover"}'::jsonb
      );
    END IF;
  END IF;

  IF NOT v_can_reply THEN
    INSERT INTO audit_log (
      business_id, user_id, action, entity_type, entity_id,
      severity, metadata
    ) VALUES (
      v_convo.business_id, v_caller_id,
      'operator_reply_denied', 'conversation', p_conversation_id,
      'warning',
      jsonb_build_object(
        'reason', 'not_assigned',
        'assigned_to', v_convo.assigned_to::text,
        'caller_role', v_role::text
      )
    );

    RETURN jsonb_build_object('error', 'NOT_ASSIGNED_TO_YOU',
      'message', 'You must be assigned to this conversation to reply');
  END IF;

  -- Step 5: Insert outbound message
  INSERT INTO messages (
    conversation_id, direction, sender_type, sender_id,
    content_type, content, delivery_status,
    created_at
  ) VALUES (
    p_conversation_id, 'outbound', 'operator', v_caller_id,
    p_content_type, p_content, 'queued',
    clock_timestamp()
  )
  RETURNING id INTO v_message_id;

  -- Step 6: Update conversation counters
  UPDATE conversations
  SET message_count = message_count + 1,
      last_message_at = now(),
      updated_at = now()
  WHERE id = p_conversation_id;

  -- Step 7: Outbound integration log
  INSERT INTO integration_logs (
    business_id, channel_type, direction, event_type,
    request_payload, processed
  ) VALUES (
    v_convo.business_id, v_convo.channel_type, 'outbound', 'operator_reply',
    jsonb_build_object(
      'message_id', v_message_id::text,
      'conversation_id', p_conversation_id::text,
      'content_type', p_content_type::text,
      'operator_id', v_caller_id::text
    ),
    false  -- not delivered yet (no real channel send in Phase 2B)
  );

  -- Step 8: Audit log
  INSERT INTO audit_log (
    business_id, user_id, action, entity_type, entity_id,
    severity, metadata
  ) VALUES (
    v_convo.business_id, v_caller_id,
    'operator_reply', 'conversation', p_conversation_id,
    'info',
    jsonb_build_object(
      'message_id', v_message_id::text,
      'content_type', p_content_type::text
    )
  );

  RETURN jsonb_build_object(
    'message_id', v_message_id,
    'conversation_id', p_conversation_id,
    'delivery_status', 'queued'
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 8. Cleanup — Remove COALESCE workarounds in 2A RPCs
--    Now that is_platform_admin() always returns boolean,
--    we can use NOT is_platform_admin() directly.
-- ────────────────────────────────────────────────────────────

-- Re-create get_inbox_list with clean admin check
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
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL OR (
    NOT EXISTS (
      SELECT 1 FROM business_memberships
      WHERE business_id = p_business_id
        AND user_id = v_caller_id
        AND is_active = true
    )
    AND NOT is_platform_admin(v_caller_id)
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
        ORDER BY m.created_at DESC, m.id DESC
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

-- Re-create get_conversation_detail with clean admin check
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
  SELECT c.*, cu.name as customer_name, cu.phone as customer_phone,
         cu.email as customer_email, cu.metadata as customer_metadata
  INTO v_convo
  FROM conversations c
  JOIN customers cu ON cu.id = c.customer_id
  WHERE c.id = p_conversation_id;

  IF v_convo IS NULL THEN
    RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND');
  END IF;

  v_caller_id := auth.uid();
  v_business_id := v_convo.business_id;
  IF v_caller_id IS NULL OR (
    NOT EXISTS (
      SELECT 1 FROM business_memberships
      WHERE business_id = v_business_id
        AND user_id = v_caller_id
        AND is_active = true
    )
    AND NOT is_platform_admin(v_caller_id)
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
          'delivery_status', sub.delivery_status,
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
