// ============================================================
// Routing / Handoff Domain — Types & Constants
//
// Owns: conversation ownership, assignment, queues, takeover,
// transfer, release-to-AI, handoff events, ownership history.
//
// Boundary: Routing owns WHO controls a conversation.
//           Conversations owns the MESSAGE content.
//           These two responsibilities must not be mixed.
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../lib/types';

export const ROUTING_DOMAIN = 'routing' as const;

// ── Assignment Owner Types ──────────────────────────────────

export const ASSIGNMENT_OWNER_TYPES = ['operator', 'ai', 'queue', 'unassigned'] as const;
export type AssignmentOwnerType = (typeof ASSIGNMENT_OWNER_TYPES)[number];

// ── Handoff Event Types ─────────────────────────────────────

export const HANDOFF_EVENT_TYPES = [
  'assigned',          // Conversation assigned to an operator
  'released_to_ai',   // Operator released conversation back to AI
  'handoff_requested', // AI or system requested human takeover
  'takeover',          // Manager overrode current assignment
  'transferred',       // Conversation transferred between operators
  'queued',            // Conversation placed in queue awaiting pickup
  'auto_assigned',     // System auto-assigned based on policy
] as const;
export type HandoffEventType = (typeof HANDOFF_EVENT_TYPES)[number];

// ── Entity Types ────────────────────────────────────────────

/** Current ownership state of a conversation */
export interface ConversationOwnership {
  conversation_id: UUID;
  business_id: UUID;
  owner_type: AssignmentOwnerType;
  owner_id: UUID | null;       // user_id of the operator (null for AI/queue/unassigned)
  ai_enabled: boolean;
  assigned_at: Timestamp | null;
}

/** Record of an ownership change (handoff event) */
export interface HandoffEvent {
  id: UUID;
  conversation_id: UUID;
  business_id: UUID;
  event_type: HandoffEventType;
  from_owner_type: AssignmentOwnerType | null;
  from_owner_id: UUID | null;
  to_owner_type: AssignmentOwnerType;
  to_owner_id: UUID | null;
  reason: string | null;
  triggered_by: UUID | null;     // user who initiated the handoff
  metadata: JsonObject;
  created_at: Timestamp;
}

/** Ownership history entry for audit/analytics */
export interface OwnershipHistoryEntry {
  conversation_id: UUID;
  owner_type: AssignmentOwnerType;
  owner_id: UUID | null;
  started_at: Timestamp;
  ended_at: Timestamp | null;
  duration_seconds: number | null;
}

// ── RPC Input Types ─────────────────────────────────────────

export interface AssignConversationInput {
  conversation_id: UUID;
  operator_id: UUID;
}

export interface ReleaseToAiInput {
  conversation_id: UUID;
}

export interface HandoffToOperatorInput {
  conversation_id: UUID;
  operator_id?: UUID;
  reason?: string;
}

export interface TakeoverConversationInput {
  conversation_id: UUID;
  operator_id: UUID;
}

export interface TransferConversationInput {
  conversation_id: UUID;
  from_operator_id: UUID;
  to_operator_id: UUID;
  reason?: string;
}
