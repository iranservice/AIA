-- ============================================================
-- 00021 — Order from Conversation
--
-- Phase: 3A
-- Depends: 00020_ai_reply_handoff
--
-- Adds:
--   1. orders.source column
--   2. order_items relational table + RLS
--   3. Upgrade create_order() (UUID → JSONB, auth, validation, audit)
--   4. Upgrade transition_order_status() (void → JSONB, audit)
--   5. confirm_order() convenience RPC
--   6. cancel_order() convenience RPC
--   7. execute_create_order_action() action engine integration
--   8. Enhance get_conversation_detail() with linked orders
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. orders.source column
-- ────────────────────────────────────────────────────────────

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS source TEXT
    DEFAULT 'operator'
    CHECK (source IN ('operator', 'ai_suggested', 'system'));

-- ────────────────────────────────────────────────────────────
-- 2. order_items relational table
-- ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS order_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  item_name   TEXT NOT NULL,
  quantity    INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price  NUMERIC(12,2),
  total       NUMERIC(12,2),
  notes       TEXT,
  modifiers   JSONB NOT NULL DEFAULT '{}'::jsonb,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_items_order
  ON order_items(order_id);

-- RLS
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS members_read_order_items ON order_items;
CREATE POLICY members_read_order_items ON order_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM orders o
      WHERE o.id = order_items.order_id
        AND is_business_member(o.business_id)
    )
  );

-- Platform admins read all
DROP POLICY IF EXISTS platform_admins_read_order_items ON order_items;
CREATE POLICY platform_admins_read_order_items ON order_items
  FOR SELECT USING (is_platform_admin(auth.uid()));

-- Add platform admin read policy for orders too (was missing)
DROP POLICY IF EXISTS platform_admins_read_orders ON orders;
CREATE POLICY platform_admins_read_orders ON orders
  FOR SELECT USING (is_platform_admin(auth.uid()));

-- ────────────────────────────────────────────────────────────
-- 3. Upgrade create_order() — Full validation, auth, JSONB return
-- ────────────────────────────────────────────────────────────

-- Drop old UUID-returning stub
DROP FUNCTION IF EXISTS create_order(UUID, UUID, JSONB, order_type, UUID, JSONB, TEXT, UUID);

CREATE OR REPLACE FUNCTION create_order(
  p_business_id       UUID,
  p_customer_id       UUID,
  p_items             JSONB,
  p_order_type        order_type DEFAULT 'dine_in',
  p_conversation_id   UUID DEFAULT NULL,
  p_delivery_address  JSONB DEFAULT NULL,
  p_notes             TEXT DEFAULT NULL,
  p_source            TEXT DEFAULT 'operator',
  p_initial_status    order_status DEFAULT 'draft'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller_id      UUID;
  v_order_id       UUID;
  v_order_number   TEXT;
  v_subtotal       NUMERIC(12,2) := 0;
  v_total          NUMERIC(12,2) := 0;
  v_missing_fields TEXT[] := '{}';
  v_has_pricing    BOOLEAN := true;
  v_item           JSONB;
  v_item_price     NUMERIC(12,2);
  v_item_total     NUMERIC(12,2);
  v_idx            INTEGER := 0;
BEGIN
  v_caller_id := auth.uid();

  -- Step 1: Permission check
  IF v_caller_id IS NOT NULL
    AND NOT check_permission(v_caller_id, p_business_id, 'order:create') THEN
    RETURN jsonb_build_object('error', 'PERMISSION_DENIED',
      'message', 'Caller lacks order:create permission');
  END IF;

  -- Step 2: Validate items
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    v_missing_fields := array_append(v_missing_fields, 'items');
  END IF;

  -- Step 3: Validate delivery address
  IF p_order_type = 'delivery' AND p_delivery_address IS NULL THEN
    v_missing_fields := array_append(v_missing_fields, 'delivery_address');
  END IF;

  -- Return missing fields if any
  IF array_length(v_missing_fields, 1) > 0 THEN
    RETURN jsonb_build_object(
      'error', 'MISSING_REQUIRED_FIELDS',
      'missing_fields', to_jsonb(v_missing_fields)
    );
  END IF;

  -- Step 4: Tenant isolation — customer belongs to business
  IF NOT EXISTS (
    SELECT 1 FROM customers
    WHERE id = p_customer_id AND business_id = p_business_id
  ) THEN
    RETURN jsonb_build_object('error', 'CUSTOMER_NOT_FOUND',
      'message', 'Customer does not belong to this business');
  END IF;

  -- Step 5: Conversation belongs to same business (if provided)
  IF p_conversation_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM conversations
      WHERE id = p_conversation_id AND business_id = p_business_id
    ) THEN
      RETURN jsonb_build_object('error', 'CONVERSATION_NOT_FOUND',
        'message', 'Conversation does not belong to this business');
    END IF;
  END IF;

  -- Step 6: Generate order number
  v_order_number := generate_order_number(p_business_id);

  -- Step 7: Calculate totals from items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_item_price := (v_item ->> 'unit_price')::NUMERIC(12,2);
    IF v_item_price IS NOT NULL THEN
      v_item_total := v_item_price * COALESCE((v_item ->> 'quantity')::INTEGER, 1);
      v_subtotal := v_subtotal + v_item_total;
    ELSE
      v_has_pricing := false;
    END IF;
  END LOOP;
  v_total := v_subtotal;

  -- Step 8: Insert order
  INSERT INTO orders (
    business_id, customer_id, conversation_id,
    order_number, order_type, items,
    subtotal, total,
    delivery_address, notes, created_by, source,
    status
  ) VALUES (
    p_business_id, p_customer_id, p_conversation_id,
    v_order_number, p_order_type, p_items,
    v_subtotal, v_total,
    p_delivery_address, p_notes, v_caller_id, p_source,
    CASE WHEN NOT v_has_pricing THEN 'draft'::order_status
         ELSE p_initial_status END
  )
  RETURNING id INTO v_order_id;

  -- Step 9: Insert order_items (relational)
  v_idx := 0;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_item_price := (v_item ->> 'unit_price')::NUMERIC(12,2);
    v_item_total := CASE
      WHEN v_item_price IS NOT NULL
      THEN v_item_price * COALESCE((v_item ->> 'quantity')::INTEGER, 1)
      ELSE NULL
    END;

    INSERT INTO order_items (
      order_id, item_name, quantity, unit_price, total,
      notes, modifiers, sort_order
    ) VALUES (
      v_order_id,
      COALESCE(v_item ->> 'item_name', v_item ->> 'name', 'Unnamed Item'),
      COALESCE((v_item ->> 'quantity')::INTEGER, 1),
      v_item_price,
      v_item_total,
      v_item ->> 'notes',
      COALESCE(v_item -> 'modifiers', '{}'::jsonb),
      v_idx
    );
    v_idx := v_idx + 1;
  END LOOP;

  -- Step 10: Record initial status history
  INSERT INTO order_status_history (order_id, to_status, changed_by)
  VALUES (v_order_id,
    CASE WHEN NOT v_has_pricing THEN 'draft'::order_status ELSE p_initial_status END,
    v_caller_id);

  -- Step 11: Update customer order count
  UPDATE customers
  SET order_count = order_count + 1
  WHERE id = p_customer_id;

  -- Step 12: Audit log
  INSERT INTO audit_log (
    business_id, user_id, action, entity_type, entity_id,
    severity, metadata
  ) VALUES (
    p_business_id, v_caller_id,
    'order_created', 'order', v_order_id,
    'info',
    jsonb_build_object(
      'order_number', v_order_number,
      'order_type', p_order_type::text,
      'source', p_source,
      'item_count', jsonb_array_length(p_items),
      'total', v_total,
      'conversation_id', p_conversation_id::text,
      'has_pricing', v_has_pricing
    )
  );

  RETURN jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_order_number,
    'status', CASE WHEN NOT v_has_pricing THEN 'draft' ELSE p_initial_status::text END,
    'subtotal', v_subtotal,
    'total', v_total,
    'item_count', jsonb_array_length(p_items),
    'has_pricing', v_has_pricing
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 4. Upgrade transition_order_status() — JSONB return + audit
-- ────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS transition_order_status(UUID, order_status, UUID, TEXT);

CREATE OR REPLACE FUNCTION transition_order_status(
  p_order_id   UUID,
  p_new_status order_status,
  p_changed_by UUID DEFAULT NULL,
  p_reason     TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_current_status   order_status;
  v_business_id      UUID;
  v_customer_id      UUID;
  v_valid_transitions order_status[];
BEGIN
  -- Get current state
  SELECT o.status, o.business_id, o.customer_id
  INTO v_current_status, v_business_id, v_customer_id
  FROM orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_current_status IS NULL THEN
    RETURN jsonb_build_object('error', 'ORDER_NOT_FOUND');
  END IF;

  -- Define valid state transitions
  v_valid_transitions := CASE v_current_status
    WHEN 'draft'                THEN ARRAY['pending_confirmation', 'confirmed', 'cancelled']::order_status[]
    WHEN 'pending_confirmation' THEN ARRAY['confirmed', 'cancelled']::order_status[]
    WHEN 'confirmed'            THEN ARRAY['preparing', 'cancelled']::order_status[]
    WHEN 'preparing'            THEN ARRAY['ready', 'cancelled']::order_status[]
    WHEN 'ready'                THEN ARRAY['delivering', 'delivered', 'cancelled']::order_status[]
    WHEN 'delivering'           THEN ARRAY['delivered', 'cancelled']::order_status[]
    WHEN 'delivered'            THEN ARRAY['refunded']::order_status[]
    WHEN 'cancelled'            THEN ARRAY['refunded']::order_status[]
    WHEN 'refunded'             THEN ARRAY[]::order_status[]
    ELSE ARRAY[]::order_status[]
  END;

  -- Validate transition
  IF NOT (p_new_status = ANY(v_valid_transitions)) THEN
    RETURN jsonb_build_object('error', 'INVALID_TRANSITION',
      'message', format('Invalid order status transition: %s → %s', v_current_status, p_new_status),
      'from_status', v_current_status::text,
      'to_status', p_new_status::text);
  END IF;

  -- Check permission for status change
  IF p_changed_by IS NOT NULL THEN
    IF NOT check_permission(p_changed_by, v_business_id, 'order:update') THEN
      RETURN jsonb_build_object('error', 'PERMISSION_DENIED',
        'message', 'Caller lacks order:update permission');
    END IF;
  END IF;

  -- Apply transition
  UPDATE orders
  SET
    status = p_new_status,
    confirmed_at        = CASE WHEN p_new_status = 'confirmed' THEN now() ELSE confirmed_at END,
    ready_at            = CASE WHEN p_new_status = 'ready' THEN now() ELSE ready_at END,
    delivered_at        = CASE WHEN p_new_status = 'delivered' THEN now() ELSE delivered_at END,
    cancelled_at        = CASE WHEN p_new_status = 'cancelled' THEN now() ELSE cancelled_at END,
    cancellation_reason = CASE WHEN p_new_status = 'cancelled' THEN p_reason ELSE cancellation_reason END,
    updated_at          = now()
  WHERE id = p_order_id;

  -- Record history
  INSERT INTO order_status_history (order_id, from_status, to_status, changed_by, reason)
  VALUES (p_order_id, v_current_status, p_new_status, p_changed_by, p_reason);

  -- Update customer total_spent on delivery
  IF p_new_status = 'delivered' THEN
    UPDATE customers
    SET total_spent = total_spent + (
      SELECT total FROM orders WHERE id = p_order_id
    )
    WHERE id = v_customer_id;
  END IF;

  -- Audit log
  INSERT INTO audit_log (
    business_id, user_id, action, entity_type, entity_id,
    severity, metadata
  ) VALUES (
    v_business_id, p_changed_by,
    'order_status_changed', 'order', p_order_id,
    CASE WHEN p_new_status = 'cancelled' THEN 'warning'::audit_severity ELSE 'info'::audit_severity END,
    jsonb_build_object(
      'from_status', v_current_status::text,
      'to_status', p_new_status::text,
      'reason', COALESCE(p_reason, '')
    )
  );

  RETURN jsonb_build_object(
    'order_id', p_order_id,
    'from_status', v_current_status,
    'to_status', p_new_status
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 5. confirm_order() — Convenience wrapper
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION confirm_order(
  p_order_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  v_caller_id := auth.uid();
  RETURN transition_order_status(p_order_id, 'confirmed', v_caller_id);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 6. cancel_order() — Convenience wrapper
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION cancel_order(
  p_order_id UUID,
  p_reason   TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  v_caller_id := auth.uid();
  RETURN transition_order_status(p_order_id, 'cancelled', v_caller_id, p_reason);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 7. execute_create_order_action() — Action engine integration
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION execute_create_order_action(
  p_business_id       UUID,
  p_customer_id       UUID,
  p_items             JSONB,
  p_order_type        order_type DEFAULT 'dine_in',
  p_conversation_id   UUID DEFAULT NULL,
  p_delivery_address  JSONB DEFAULT NULL,
  p_notes             TEXT DEFAULT NULL,
  p_source            TEXT DEFAULT 'operator',
  p_triggered_by      action_trigger_source DEFAULT 'operator'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller_id      UUID;
  v_execution_id   UUID;
  v_order_result   JSONB;
BEGIN
  v_caller_id := auth.uid();

  -- Step 1: Create action execution record
  v_execution_id := request_action(
    'create_order'::action_type,
    p_business_id,
    jsonb_build_object(
      'customer_id', p_customer_id::text,
      'items', p_items,
      'order_type', p_order_type::text,
      'conversation_id', p_conversation_id::text,
      'delivery_address', p_delivery_address,
      'notes', p_notes,
      'source', p_source
    ),
    p_triggered_by,
    v_caller_id,
    p_conversation_id
  );

  -- Step 2: Check if action needs approval
  IF EXISTS (
    SELECT 1 FROM action_executions
    WHERE id = v_execution_id AND approval_status = 'pending'
  ) THEN
    RETURN jsonb_build_object(
      'execution_id', v_execution_id,
      'status', 'pending_approval',
      'message', 'Order creation requires approval'
    );
  END IF;

  -- Step 3: Execute — call orders domain
  v_order_result := create_order(
    p_business_id, p_customer_id, p_items,
    p_order_type, p_conversation_id,
    p_delivery_address, p_notes, p_source
  );

  -- Step 4: Update execution with result
  UPDATE action_executions
  SET output_data = v_order_result,
      executed_at = now(),
      error = CASE WHEN v_order_result ? 'error' THEN v_order_result ->> 'error' ELSE NULL END
  WHERE id = v_execution_id;

  -- Step 5: Return combined result
  RETURN jsonb_build_object(
    'execution_id', v_execution_id,
    'order', v_order_result
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 8. Enhance get_conversation_detail() — Add linked orders
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
          'created_at', o.created_at
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
