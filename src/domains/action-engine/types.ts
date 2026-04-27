// ============================================================
// Action Engine Domain — Types & Constants
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../lib/types';
import type { MembershipRole } from '../rbac/types';

export const ACTION_ENGINE_DOMAIN = 'action-engine' as const;

export const ACTION_TYPES = [
  'send_message', 'create_order', 'update_order',
  'create_reservation', 'update_reservation',
  'create_ticket', 'escalate', 'transfer', 'custom',
] as const;
export type ActionType = (typeof ACTION_TYPES)[number];

export const ACTION_TRIGGER_SOURCES = [
  'ai', 'operator', 'system', 'automation',
] as const;
export type ActionTriggerSource = (typeof ACTION_TRIGGER_SOURCES)[number];

export const APPROVAL_STATUSES = [
  'pending', 'approved', 'rejected', 'escalated',
] as const;
export type ApprovalStatus = (typeof APPROVAL_STATUSES)[number];

export interface ActionDefinition {
  id: UUID;
  business_id: UUID | null;
  action_type: ActionType;
  name: string;
  description: string | null;
  input_schema: JsonObject;
  requires_approval: boolean;
  approval_roles: MembershipRole[];
  is_active: boolean;
  created_at: Timestamp;
  updated_at: Timestamp;
}

export interface ActionExecution {
  id: UUID;
  action_definition_id: UUID;
  business_id: UUID;
  conversation_id: UUID | null;
  triggered_by: ActionTriggerSource;
  trigger_user_id: UUID | null;
  input_data: JsonObject;
  output_data: JsonObject | null;
  approval_status: ApprovalStatus;
  approved_by: UUID | null;
  approved_at: Timestamp | null;
  rejection_reason: string | null;
  executed_at: Timestamp | null;
  error: string | null;
  created_at: Timestamp;
}
