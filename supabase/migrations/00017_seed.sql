-- ============================================================
-- Migration 00017: Seed Data
-- Default permissions, role mappings, platform provider stubs,
-- and a demo business for development.
-- ============================================================

-- ═══════════════════════════════════════════════════════════
-- 1. Default Permissions
-- ═══════════════════════════════════════════════════════════

insert into permissions (code, description, domain) values
  -- Conversation domain
  ('conversation:read',     'Read conversations',                    'conversation'),
  ('conversation:write',    'Send messages in conversations',        'conversation'),
  ('conversation:assign',   'Assign conversations to operators',     'conversation'),
  ('conversation:takeover', 'Take over conversations from others',   'conversation'),
  ('conversation:close',    'Close/resolve conversations',           'conversation'),

  -- Customer domain
  ('customer:read',         'View customer profiles',                'customer'),
  ('customer:write',        'Create/update customer profiles',       'customer'),
  ('customer:delete',       'Delete customer profiles',              'customer'),

  -- Order domain
  ('order:read',            'View orders',                           'order'),
  ('order:create',          'Create new orders',                     'order'),
  ('order:update',          'Update order status',                   'order'),
  ('order:cancel',          'Cancel orders',                         'order'),
  ('order:refund',          'Process order refunds',                 'order'),

  -- Reservation domain
  ('reservation:read',      'View reservations',                     'reservation'),
  ('reservation:create',    'Create reservations',                   'reservation'),
  ('reservation:update',    'Update reservation status',             'reservation'),
  ('reservation:cancel',    'Cancel reservations',                   'reservation'),

  -- Ticket domain
  ('ticket:read',           'View support tickets',                  'ticket'),
  ('ticket:create',         'Create support tickets',                'ticket'),
  ('ticket:write',          'Update support tickets',                'ticket'),
  ('ticket:assign',         'Assign tickets to operators',           'ticket'),

  -- Action domain
  ('action:execute',        'Execute actions',                       'action'),
  ('action:approve',        'Approve pending actions',               'action'),

  -- Provider domain
  ('provider:read',         'View provider configurations',          'provider'),
  ('provider:manage',       'Manage provider settings and keys',     'provider'),

  -- AI domain
  ('ai:configure',          'Configure AI agent settings',           'ai'),
  ('ai:view_logs',          'View AI interaction logs',              'ai'),

  -- Audit domain
  ('audit:read',            'View audit logs',                       'audit'),

  -- Billing domain
  ('billing:read',          'View billing and usage data',           'billing'),
  ('billing:manage',        'Manage billing settings',               'billing'),

  -- Business domain
  ('business:settings',     'Manage business settings',              'business'),
  ('business:members',      'Manage team members',                   'business'),
  ('business:channels',     'Manage communication channels',        'business'),
  ('business:policies',     'Manage business policy rules',          'business')
on conflict (code) do nothing;

-- ═══════════════════════════════════════════════════════════
-- 2. Role-Permission Matrix
-- Owner gets all (handled in check_permission logic).
-- Below maps manager, operator, viewer permissions.
-- ═══════════════════════════════════════════════════════════

-- ── Manager Permissions ─────────────────────────────────────
-- Managers get most permissions except billing management
-- and provider key management.

insert into role_permissions (role, permission_id)
select 'manager', p.id from permissions p
where p.code in (
  'conversation:read', 'conversation:write', 'conversation:assign',
  'conversation:takeover', 'conversation:close',
  'customer:read', 'customer:write',
  'order:read', 'order:create', 'order:update', 'order:cancel',
  'reservation:read', 'reservation:create', 'reservation:update', 'reservation:cancel',
  'ticket:read', 'ticket:create', 'ticket:write', 'ticket:assign',
  'action:execute', 'action:approve',
  'provider:read',
  'ai:configure', 'ai:view_logs',
  'audit:read',
  'billing:read',
  'business:settings', 'business:members', 'business:channels', 'business:policies'
);

-- ── Operator Permissions ────────────────────────────────────
-- Operators handle day-to-day conversations, orders, tickets.

insert into role_permissions (role, permission_id)
select 'operator', p.id from permissions p
where p.code in (
  'conversation:read', 'conversation:write', 'conversation:assign',
  'conversation:close',
  'customer:read', 'customer:write',
  'order:read', 'order:create', 'order:update',
  'reservation:read', 'reservation:create', 'reservation:update',
  'ticket:read', 'ticket:create', 'ticket:write',
  'action:execute'
);

-- ── Viewer Permissions ──────────────────────────────────────
-- Viewers can only read, never modify.

insert into role_permissions (role, permission_id)
select 'viewer', p.id from permissions p
where p.code in (
  'conversation:read',
  'customer:read',
  'order:read',
  'reservation:read',
  'ticket:read',
  'billing:read'
);

-- ═══════════════════════════════════════════════════════════
-- 3. Platform-Level Action Definitions
-- ═══════════════════════════════════════════════════════════

insert into action_definitions (business_id, action_type, name, description, input_schema, requires_approval) values
  (null, 'send_message',       'Send Message',        'Send a message in a conversation',
   '{"type":"object","properties":{"conversation_id":{"type":"string"},"content":{"type":"string"},"content_type":{"type":"string"}},"required":["conversation_id","content"]}',
   false),

  (null, 'create_order',       'Create Order',        'Create a new order for a customer',
   '{"type":"object","properties":{"customer_id":{"type":"string"},"items":{"type":"array"},"order_type":{"type":"string"}},"required":["customer_id","items"]}',
   false),

  (null, 'update_order',       'Update Order',        'Update an existing order status',
   '{"type":"object","properties":{"order_id":{"type":"string"},"new_status":{"type":"string"},"reason":{"type":"string"}},"required":["order_id","new_status"]}',
   false),

  (null, 'create_reservation', 'Create Reservation',  'Create a new reservation',
   '{"type":"object","properties":{"customer_id":{"type":"string"},"reserved_at":{"type":"string"},"party_size":{"type":"integer"}},"required":["customer_id","reserved_at"]}',
   false),

  (null, 'update_reservation', 'Update Reservation',  'Update an existing reservation',
   '{"type":"object","properties":{"reservation_id":{"type":"string"},"new_status":{"type":"string"}},"required":["reservation_id","new_status"]}',
   false),

  (null, 'create_ticket',      'Create Ticket',       'Create a support ticket',
   '{"type":"object","properties":{"customer_id":{"type":"string"},"subject":{"type":"string"},"priority":{"type":"string"}},"required":["customer_id","subject"]}',
   false),

  (null, 'escalate',           'Escalate',            'Escalate to a human operator',
   '{"type":"object","properties":{"conversation_id":{"type":"string"},"reason":{"type":"string"}},"required":["conversation_id"]}',
   false),

  (null, 'transfer',           'Transfer',            'Transfer conversation to another operator',
   '{"type":"object","properties":{"conversation_id":{"type":"string"},"target_operator_id":{"type":"string"}},"required":["conversation_id","target_operator_id"]}',
   false);

-- ═══════════════════════════════════════════════════════════
-- 4. Platform-Level Provider Stubs
-- (No real API keys — for development scaffolding only)
-- ═══════════════════════════════════════════════════════════

insert into provider_registry (business_id, provider_type, provider_scope, provider_name, api_config, is_active) values
  -- AI Provider
  (null, 'ai',      'platform', 'openai',    '{"api_key": "sk-placeholder", "base_url": "https://api.openai.com/v1"}', false),

  -- SMS Provider
  (null, 'sms',     'platform', 'twilio',    '{"account_sid": "placeholder", "auth_token": "placeholder", "from_number": "+1234567890"}', false),

  -- Email Provider
  (null, 'email',   'platform', 'resend',    '{"api_key": "placeholder", "from_address": "noreply@aia.app"}', false),

  -- WhatsApp Provider
  (null, 'whatsapp','platform', 'meta',      '{"access_token": "placeholder", "phone_number_id": "placeholder", "webhook_verify_token": "placeholder"}', false),

  -- Voice Provider (future)
  (null, 'voice',   'platform', 'twilio',    '{"account_sid": "placeholder", "auth_token": "placeholder"}', false);
