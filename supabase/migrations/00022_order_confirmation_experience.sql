-- ============================================================
-- 00022 — Order Confirmation Experience Contract
--
-- Phase: 3B-A
-- Depends: 00021_order_from_conversation
--
-- Adds:
--   1. get_order_confirmation_payload() — UI-ready order payload
--   2. request_customer_confirmation() — draft → pending_confirmation
--   3. Enhance get_conversation_detail() — per-order available_actions
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- Helper: build available_actions array for an order
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_order_available_actions(
  p_order_status  order_status,
  p_has_update    BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_actions TEXT[] := ARRAY['view_order'];
BEGIN
  IF p_has_update THEN
    CASE p_order_status
      WHEN 'draft' THEN
        v_actions := v_actions || ARRAY['confirm_order', 'cancel_order', 'request_customer_confirmation'];
      WHEN 'pending_confirmation' THEN
        v_actions := v_actions || ARRAY['confirm_order', 'cancel_order'];
      WHEN 'confirmed' THEN
        v_actions := v_actions || ARRAY['cancel_order'];
      WHEN 'preparing' THEN
        v_actions := v_actions || ARRAY['cancel_order'];
      ELSE
        -- ready, delivering, delivered, cancelled, refunded → view only
        NULL;
    END CASE;
  END IF;

  RETURN to_jsonb(v_actions);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- Helper: build suggested confirmation text from items
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION build_confirmation_text(
  p_items    JSONB,
  p_total    NUMERIC,
  p_currency TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_parts  TEXT[] := '{}';
  v_item   JSONB;
  v_qty    INTEGER;
  v_name   TEXT;
BEGIN
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_qty  := COALESCE((v_item ->> 'quantity')::INTEGER, 1);
    v_name := COALESCE(v_item ->> 'item_name', v_item ->> 'name', 'Item');
    v_parts := v_parts || (v_qty || 'x ' || v_name);
  END LOOP;

  RETURN format(
    'Please confirm your order: %s. Total: %s %s. Is this correct?',
    array_to_string(v_parts, ', '),
    TRIM(TO_CHAR(p_total, 'FM999999990.00')),
    p_currency
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 1. get_order_confirmation_payload() — Full UI-ready payload
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_order_confirmation_payload(
  p_order_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_order       RECORD;
  v_caller_id   UUID;
  v_has_update  BOOLEAN := false;
  v_items_arr   JSONB;
BEGIN
  v_caller_id := auth.uid();

  -- Step 1: Fetch order
  SELECT o.*
  INTO v_order
  FROM orders o
  WHERE o.id = p_order_id;

  IF v_order IS NULL THEN
    RETURN jsonb_build_object('error', 'ORDER_NOT_FOUND');
  END IF;

  -- Step 2: Access check — must be active member of the business
  IF v_caller_id IS NULL OR (
    NOT EXISTS (
      SELECT 1 FROM business_memberships
      WHERE business_id = v_order.business_id
        AND user_id = v_caller_id
        AND is_active = true
    )
    AND NOT is_platform_admin(v_caller_id)
  ) THEN
    RETURN jsonb_build_object('error', 'ACCESS_DENIED');
  END IF;

  -- Step 3: Check if caller has order:update permission
  IF v_caller_id IS NOT NULL
    AND check_permission(v_caller_id, v_order.business_id, 'order:update') THEN
    v_has_update := true;
  END IF;

  -- Step 4: Build items array from order_items table
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', oi.id,
      'item_name', oi.item_name,
      'quantity', oi.quantity,
      'unit_price', oi.unit_price,
      'total', oi.total,
      'notes', oi.notes,
      'modifiers', oi.modifiers
    ) ORDER BY oi.sort_order
  ), '[]'::jsonb)
  INTO v_items_arr
  FROM order_items oi
  WHERE oi.order_id = p_order_id;

  -- Step 5: Return payload
  RETURN jsonb_build_object(
    'order_id', v_order.id,
    'order_number', v_order.order_number,
    'business_id', v_order.business_id,
    'customer_id', v_order.customer_id,
    'conversation_id', v_order.conversation_id,
    'status', v_order.status,
    'order_type', v_order.order_type,
    'items', v_items_arr,
    'subtotal', v_order.subtotal,
    'total', v_order.total,
    'currency', v_order.currency,
    'delivery_address', v_order.delivery_address,
    'notes', v_order.notes,
    'source', v_order.source,
    'created_at', v_order.created_at,
    'confirmed_at', v_order.confirmed_at,
    'cancelled_at', v_order.cancelled_at,
    'cancellation_reason', v_order.cancellation_reason,
    'available_actions', get_order_available_actions(v_order.status, v_has_update),
    'suggested_confirmation_text', build_confirmation_text(
      v_order.items, v_order.total, v_order.currency
    )
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 2. request_customer_confirmation() — draft → pending
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION request_customer_confirmation(
  p_order_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller_id   UUID;
  v_order       RECORD;
  v_transition  JSONB;
BEGIN
  v_caller_id := auth.uid();

  -- Step 1: Fetch order
  SELECT o.id, o.status, o.business_id
  INTO v_order
  FROM orders o
  WHERE o.id = p_order_id;

  IF v_order IS NULL THEN
    RETURN jsonb_build_object('error', 'ORDER_NOT_FOUND');
  END IF;

  -- Step 2: Permission check
  IF v_caller_id IS NULL OR
    NOT check_permission(v_caller_id, v_order.business_id, 'order:update') THEN
    RETURN jsonb_build_object('error', 'PERMISSION_DENIED',
      'message', 'Caller lacks order:update permission');
  END IF;

  -- Step 3: Validate status — only draft can be sent for confirmation
  IF v_order.status != 'draft' THEN
    RETURN jsonb_build_object('error', 'INVALID_STATUS',
      'message', format('Cannot request confirmation for order in status: %s', v_order.status),
      'current_status', v_order.status::text);
  END IF;

  -- Step 4: Transition to pending_confirmation
  v_transition := transition_order_status(
    p_order_id, 'pending_confirmation', v_caller_id, 'Customer confirmation requested'
  );

  IF v_transition ? 'error' THEN
    RETURN v_transition;
  END IF;

  -- Step 5: Audit log (separate from transition audit)
  INSERT INTO audit_log (
    business_id, user_id, action, entity_type, entity_id,
    severity, metadata
  ) VALUES (
    v_order.business_id, v_caller_id,
    'confirmation_requested', 'order', p_order_id,
    'info'::audit_severity,
    jsonb_build_object(
      'from_status', 'draft',
      'to_status', 'pending_confirmation',
      'order_id', p_order_id::text
    )
  );

  -- Step 6: Return confirmation payload
  RETURN get_order_confirmation_payload(p_order_id);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 3. Enhance get_conversation_detail() — per-order actions
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
  v_has_update  BOOLEAN := false;
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

  -- Check order:update for available_actions
  IF v_caller_id IS NOT NULL
    AND check_permission(v_caller_id, v_business_id, 'order:update') THEN
    v_has_update := true;
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
    ),
    'orders', (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'id', o.id,
          'order_number', o.order_number,
          'status', o.status,
          'order_type', o.order_type,
          'total', o.total,
          'item_count', jsonb_array_length(o.items),
          'source', o.source,
          'created_at', o.created_at,
          'available_actions', get_order_available_actions(o.status, v_has_update)
        ) ORDER BY o.created_at DESC
      ), '[]'::jsonb)
      FROM orders o
      WHERE o.conversation_id = p_conversation_id
    )
  );

  RETURN v_result;
END;
$$;

COMMIT;
