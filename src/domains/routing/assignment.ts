// ============================================================
// Routing Domain — Assignment Types
//
// Types for conversation assignment RPCs:
//   assign_conversation, unassign_conversation, transfer_conversation
//
// Boundary: Routing owns WHO controls a conversation.
//           Conversations owns MESSAGE content.
// ============================================================

import type { UUID } from '../../shared/types';

// ── RPC Inputs ──────────────────────────────────────────────

export interface AssignConversationParams {
  conversation_id: UUID;
  operator_id: UUID;
}

export interface UnassignConversationParams {
  conversation_id: UUID;
}

export interface TransferConversationParams {
  conversation_id: UUID;
  to_operator_id: UUID;
  reason?: string;
}

// ── RPC Outputs ─────────────────────────────────────────────

export interface AssignmentResult {
  conversation_id: UUID;
  assigned_to: UUID;
  status: string;
  event_type: string;
}

export interface UnassignResult {
  conversation_id: UUID;
  status: 'open';
  event_type: 'unassigned';
}

export interface TransferResult {
  conversation_id: UUID;
  assigned_to: UUID;
  status: 'assigned';
  event_type: 'transferred';
}

export interface AssignmentError {
  error: string;
  message?: string;
}

export type AssignmentResponse = AssignmentResult | AssignmentError;

export function isAssignmentError(r: AssignmentResponse): r is AssignmentError {
  return 'error' in r && typeof (r as AssignmentError).error === 'string'
    && !('assigned_to' in r);
}
