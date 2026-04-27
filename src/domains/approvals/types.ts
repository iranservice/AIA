// ============================================================
// Approvals Domain — Types & Constants
//
// Owns: approval requests, approval decisions, approval lifecycle,
// and approval-required handling.
//
// Boundary: Approvals can be requested by Actions, Orders,
//           AI Runtime, or Routing.
//           Approvals must NOT directly mutate domain records
//           without going through a domain service.
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../shared/types';
import type { MembershipRole } from '../authz/types';

export const APPROVALS_DOMAIN = 'approvals' as const;

// ── Approval Status ─────────────────────────────────────────

export const APPROVAL_STATUSES = [
  'pending', 'approved', 'rejected', 'escalated', 'expired',
] as const;
export type ApprovalStatus = (typeof APPROVAL_STATUSES)[number];

// ── Approval Source ─────────────────────────────────────────
// What triggered the approval request

export const APPROVAL_SOURCES = [
  'action',         // Action engine requested approval
  'order',          // Order above threshold
  'ai_runtime',     // AI wants to perform sensitive action
  'routing',        // Routing rule requires manager approval
  'manual',         // Manually requested by operator
] as const;
export type ApprovalSource = (typeof APPROVAL_SOURCES)[number];

// ── Entity Types ────────────────────────────────────────────

/** Approval request */
export interface ApprovalRequest {
  id: UUID;
  business_id: UUID;
  source: ApprovalSource;
  source_entity_type: string;    // e.g., 'action_execution', 'order', 'conversation'
  source_entity_id: UUID;
  title: string;
  description: string | null;
  requested_by: UUID | null;     // user or null for AI/system
  required_roles: MembershipRole[]; // who can approve
  approval_data: JsonObject;     // context data for the approver
  status: ApprovalStatus;
  decided_by: UUID | null;
  decided_at: Timestamp | null;
  decision_reason: string | null;
  expires_at: Timestamp | null;
  created_at: Timestamp;
  updated_at: Timestamp;
}

/** Approval decision record (audit trail) */
export interface ApprovalDecision {
  id: UUID;
  approval_request_id: UUID;
  decided_by: UUID;
  status: 'approved' | 'rejected' | 'escalated';
  reason: string | null;
  metadata: JsonObject;
  created_at: Timestamp;
}

// ── RPC Input Types ─────────────────────────────────────────

export interface CreateApprovalRequestInput {
  business_id: UUID;
  source: ApprovalSource;
  source_entity_type: string;
  source_entity_id: UUID;
  title: string;
  description?: string;
  requested_by?: UUID;
  required_roles: MembershipRole[];
  approval_data?: JsonObject;
  expires_at?: string;
}

export interface DecideApprovalInput {
  approval_request_id: UUID;
  decided_by: UUID;
  approved: boolean;
  reason?: string;
}
