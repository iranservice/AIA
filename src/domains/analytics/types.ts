// ============================================================
// Analytics Domain — Types & Constants
//
// Owns: conversation counts, handoff counts, AI response counts,
// order metrics, approval metrics, and basic operational
// dashboard data.
//
// Boundary: Analytics consumes events or reads through query
//           services. It must NOT become a hidden owner of
//           business logic.
// ============================================================

import type { UUID, Timestamp } from '../../lib/types';

export const ANALYTICS_DOMAIN = 'analytics' as const;

// ── Metric Period ───────────────────────────────────────────

export const METRIC_PERIODS = ['hour', 'day', 'week', 'month'] as const;
export type MetricPeriod = (typeof METRIC_PERIODS)[number];

// ── Metric Types ────────────────────────────────────────────

/** Conversation metrics for a business */
export interface ConversationMetrics {
  business_id: UUID;
  period: MetricPeriod;
  period_start: Timestamp;
  total_conversations: number;
  open_conversations: number;
  resolved_conversations: number;
  avg_resolution_time_seconds: number | null;
  avg_first_response_time_seconds: number | null;
}

/** Routing/handoff metrics */
export interface HandoffMetrics {
  business_id: UUID;
  period: MetricPeriod;
  period_start: Timestamp;
  total_handoffs: number;
  ai_to_operator_count: number;
  operator_to_ai_count: number;
  takeover_count: number;
  transfer_count: number;
  avg_ai_handling_time_seconds: number | null;
  avg_operator_handling_time_seconds: number | null;
}

/** AI response metrics */
export interface AiResponseMetrics {
  business_id: UUID;
  period: MetricPeriod;
  period_start: Timestamp;
  total_ai_responses: number;
  total_tokens_used: number;
  avg_latency_ms: number | null;
  error_count: number;
  actions_triggered_count: number;
}

/** Order metrics */
export interface OrderMetrics {
  business_id: UUID;
  period: MetricPeriod;
  period_start: Timestamp;
  total_orders: number;
  confirmed_orders: number;
  cancelled_orders: number;
  total_revenue: number;
  avg_order_value: number | null;
  avg_fulfillment_time_seconds: number | null;
}

/** Approval metrics */
export interface ApprovalMetrics {
  business_id: UUID;
  period: MetricPeriod;
  period_start: Timestamp;
  total_requests: number;
  approved_count: number;
  rejected_count: number;
  expired_count: number;
  avg_decision_time_seconds: number | null;
}

/** Dashboard summary (composite) */
export interface DashboardSummary {
  business_id: UUID;
  period: MetricPeriod;
  period_start: Timestamp;
  conversations: ConversationMetrics;
  handoffs: HandoffMetrics;
  ai_responses: AiResponseMetrics;
  orders: OrderMetrics;
  approvals: ApprovalMetrics;
}
