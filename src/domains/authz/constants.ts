// ============================================================
// Authz Domain — Constants
// ============================================================

export const AUTHZ_DOMAIN = 'authz' as const;

/** All permission codes in the system */
export const PERMISSION_CODES = {
  // Conversation
  CONVERSATION_READ: 'conversation:read',
  CONVERSATION_WRITE: 'conversation:write',
  CONVERSATION_ASSIGN: 'conversation:assign',
  CONVERSATION_TAKEOVER: 'conversation:takeover',
  CONVERSATION_CLOSE: 'conversation:close',

  // Customer
  CUSTOMER_READ: 'customer:read',
  CUSTOMER_WRITE: 'customer:write',
  CUSTOMER_DELETE: 'customer:delete',

  // Order
  ORDER_READ: 'order:read',
  ORDER_CREATE: 'order:create',
  ORDER_UPDATE: 'order:update',
  ORDER_CANCEL: 'order:cancel',
  ORDER_REFUND: 'order:refund',

  // Reservation
  RESERVATION_READ: 'reservation:read',
  RESERVATION_CREATE: 'reservation:create',
  RESERVATION_UPDATE: 'reservation:update',
  RESERVATION_CANCEL: 'reservation:cancel',

  // Ticket
  TICKET_READ: 'ticket:read',
  TICKET_CREATE: 'ticket:create',
  TICKET_WRITE: 'ticket:write',
  TICKET_ASSIGN: 'ticket:assign',

  // Action
  ACTION_EXECUTE: 'action:execute',
  ACTION_APPROVE: 'action:approve',

  // Provider
  PROVIDER_READ: 'provider:read',
  PROVIDER_MANAGE: 'provider:manage',

  // AI
  AI_CONFIGURE: 'ai:configure',
  AI_VIEW_LOGS: 'ai:view_logs',

  // Audit
  AUDIT_READ: 'audit:read',

  // Billing
  BILLING_READ: 'billing:read',
  BILLING_MANAGE: 'billing:manage',

  // Business
  BUSINESS_SETTINGS: 'business:settings',
  BUSINESS_MEMBERS: 'business:members',
  BUSINESS_CHANNELS: 'business:channels',
  BUSINESS_POLICIES: 'business:policies',
} as const;

export type PermissionCode =
  (typeof PERMISSION_CODES)[keyof typeof PERMISSION_CODES];

/** Well-known policy rule types */
export const POLICY_RULE_TYPES = {
  AUTO_ASSIGN: 'auto_assign',
  AI_ALLOWED: 'ai_allowed',
  APPROVAL_REQUIRED: 'approval_required',
  WORKING_HOURS: 'working_hours',
} as const;

export type PolicyRuleType =
  (typeof POLICY_RULE_TYPES)[keyof typeof POLICY_RULE_TYPES];
