// ============================================================
// Audit Domain — Types & Constants
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../shared/types';

export const AUDIT_DOMAIN = 'audit' as const;

export const AUDIT_SEVERITIES = ['info', 'warning', 'error', 'critical'] as const;
export type AuditSeverity = (typeof AUDIT_SEVERITIES)[number];

export interface AuditLogEntry {
  id: UUID;
  business_id: UUID | null;
  user_id: UUID | null;
  action: string;
  entity_type: string;
  entity_id: UUID | null;
  severity: AuditSeverity;
  old_values: JsonObject | null;
  new_values: JsonObject | null;
  ip_address: string | null;
  user_agent: string | null;
  metadata: JsonObject;
  created_at: Timestamp;
}

/** Well-known audit actions */
export const AUDIT_ACTIONS = {
  // Conversation
  CONVERSATION_CREATED: 'conversation.created',
  CONVERSATION_ASSIGNED: 'conversation.assigned',
  CONVERSATION_HANDOFF: 'conversation.handoff',
  CONVERSATION_TAKEOVER: 'conversation.takeover',
  CONVERSATION_RELEASED_TO_AI: 'conversation.released_to_ai',
  CONVERSATION_RESOLVED: 'conversation.resolved',

  // Order
  ORDER_CREATED: 'order.created',
  ORDER_STATUS_CHANGED: 'order.status_changed',
  ORDER_CANCELLED: 'order.cancelled',
  ORDER_REFUNDED: 'order.refunded',

  // Reservation
  RESERVATION_CREATED: 'reservation.created',
  RESERVATION_STATUS_CHANGED: 'reservation.status_changed',

  // Customer
  CUSTOMER_CREATED: 'customer.created',
  CUSTOMER_MERGED: 'customer.merged',

  // Provider
  PROVIDER_CONFIG_ACCESSED: 'provider.config_accessed',
  PROVIDER_CONFIG_UPDATED: 'provider.config_updated',

  // Action
  ACTION_REQUESTED: 'action.requested',
  ACTION_APPROVED: 'action.approved',
  ACTION_REJECTED: 'action.rejected',
  ACTION_EXECUTED: 'action.executed',

  // AI
  AI_INTERACTION: 'ai.interaction',
  AI_ACTION_TRIGGERED: 'ai.action_triggered',

  // Business Settings
  BUSINESS_PROFILE_UPDATED: 'business.profile_updated',

  // Member Management
  MEMBER_ROLE_UPDATED: 'member.role_updated',
  MEMBER_DEACTIVATED: 'member.deactivated',
  MEMBER_INVITED: 'member.invited',

  // Auth / Security
  AUTH_LOGIN: 'auth.login',
  AUTH_LOGOUT: 'auth.logout',
  SECURITY_VIOLATION: 'security.violation',
} as const;

export type AuditAction = (typeof AUDIT_ACTIONS)[keyof typeof AUDIT_ACTIONS];
