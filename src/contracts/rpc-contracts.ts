// ============================================================
// API Contracts — RPC Function Signatures
// Type-safe contract definitions for all Supabase RPCs.
// ============================================================

import type { UUID } from '../lib/types';
import type { ChannelType, MembershipRole } from '../domains/rbac/types';
import type { MessageDirection, MessageSenderType, MessageContentType } from '../domains/conversation/types';
import type { OrderStatus, OrderType } from '../domains/order/types';
import type { ReservationStatus } from '../domains/reservation/types';
import type { TicketPriority } from '../domains/tickets/types';
import type { ActionType, ActionTriggerSource } from '../domains/action-engine/types';
import type { AuditSeverity } from '../domains/audit/types';
import type { UsageMeterType } from '../domains/billing/types';
import type { JsonObject } from '../lib/types';

// ── Identity RPCs ───────────────────────────────────────────

// handle_new_user — automatic trigger, no RPC call needed

// ── Tenancy RPCs ────────────────────────────────────────────

export interface GetUserMembershipParams {
  p_user_id: UUID;
  p_business_id: UUID;
}

export interface GetUserMembershipResult {
  membership_id: UUID;
  role: MembershipRole;
  is_active: boolean;
}

// ── RBAC RPCs ───────────────────────────────────────────────

export interface CheckPermissionParams {
  p_user_id: UUID;
  p_business_id: UUID;
  p_permission_code: string;
}

export interface GetUserPermissionsParams {
  p_user_id: UUID;
  p_business_id: UUID;
}

export interface EvaluatePolicyParams {
  p_business_id: UUID;
  p_rule_type: string;
  p_context?: JsonObject;
}

// ── Customer RPCs ───────────────────────────────────────────

export interface ResolveOrCreateCustomerParams {
  p_business_id: UUID;
  p_channel_type: ChannelType;
  p_identifier: string;
  p_name?: string;
}

// ── Conversation RPCs ───────────────────────────────────────

export interface CreateConversationParams {
  p_business_id: UUID;
  p_customer_id: UUID;
  p_channel_type: ChannelType;
  p_channel_id?: UUID;
  p_subject?: string;
}

export interface SendMessageParams {
  p_conversation_id: UUID;
  p_direction: MessageDirection;
  p_sender_type: MessageSenderType;
  p_sender_id?: UUID;
  p_content?: string;
  p_content_type?: MessageContentType;
  p_content_metadata?: JsonObject;
  p_is_internal?: boolean;
  p_reply_to_id?: UUID;
}

export interface AssignConversationParams {
  p_conversation_id: UUID;
  p_operator_id: UUID;
}

export interface ReleaseToAiParams {
  p_conversation_id: UUID;
}

export interface HandoffToOperatorParams {
  p_conversation_id: UUID;
  p_operator_id?: UUID;
  p_reason?: string;
}

export interface TakeoverConversationParams {
  p_conversation_id: UUID;
  p_operator_id: UUID;
}

// ── Order RPCs ──────────────────────────────────────────────

export interface CreateOrderParams {
  p_business_id: UUID;
  p_customer_id: UUID;
  p_items: JsonObject;
  p_order_type?: OrderType;
  p_conversation_id?: UUID;
  p_delivery_address?: JsonObject;
  p_notes?: string;
  p_created_by?: UUID;
}

export interface TransitionOrderStatusParams {
  p_order_id: UUID;
  p_new_status: OrderStatus;
  p_changed_by?: UUID;
  p_reason?: string;
}

export interface ConfirmOrderByCustomerParams {
  p_order_id: UUID;
  p_customer_id: UUID;
}

// ── Reservation RPCs ────────────────────────────────────────

export interface CreateReservationParams {
  p_business_id: UUID;
  p_customer_id: UUID;
  p_reserved_at: string; // timestamptz
  p_party_size?: number;
  p_duration_minutes?: number;
  p_preferences?: JsonObject;
  p_conversation_id?: UUID;
  p_notes?: string;
  p_created_by?: UUID;
}

export interface TransitionReservationStatusParams {
  p_reservation_id: UUID;
  p_new_status: ReservationStatus;
  p_changed_by?: UUID;
  p_reason?: string;
}

// ── Ticket RPCs ─────────────────────────────────────────────

export interface CreateTicketParams {
  p_business_id: UUID;
  p_customer_id: UUID;
  p_subject: string;
  p_description?: string;
  p_priority?: TicketPriority;
  p_conversation_id?: UUID;
  p_callback_requested?: boolean;
  p_callback_phone?: string;
  p_callback_scheduled_at?: string;
}

// ── Action Engine RPCs ──────────────────────────────────────

export interface RequestActionParams {
  p_action_type: ActionType;
  p_business_id: UUID;
  p_input_data: JsonObject;
  p_triggered_by: ActionTriggerSource;
  p_trigger_user_id?: UUID;
  p_conversation_id?: UUID;
}

export interface ApproveActionParams {
  p_execution_id: UUID;
  p_approver_id: UUID;
  p_approved: boolean;
  p_reason?: string;
}

// ── Provider RPCs ───────────────────────────────────────────

export interface GetProviderConfigParams {
  p_provider_id: UUID;
  p_requesting_user_id: UUID;
}

export interface ValidateOrderPaymentProviderParams {
  p_order_id: UUID;
}

// ── AI Runtime RPCs ─────────────────────────────────────────

export interface GetAiConfigForBusinessParams {
  p_business_id: UUID;
}

export interface LogAiInteractionParams {
  p_business_id: UUID;
  p_conversation_id: UUID;
  p_agent_config_id: UUID;
  p_model_used: string;
  p_prompt_tokens: number;
  p_completion_tokens: number;
  p_request_payload?: JsonObject;
  p_response_payload?: JsonObject;
  p_actions_triggered?: ActionType[];
  p_policy_checks?: JsonObject;
  p_latency_ms?: number;
  p_error?: string;
}

// ── Audit RPCs ──────────────────────────────────────────────

export interface LogAuditParams {
  p_action: string;
  p_entity_type: string;
  p_entity_id?: UUID;
  p_business_id?: UUID;
  p_user_id?: UUID;
  p_severity?: AuditSeverity;
  p_old_values?: JsonObject;
  p_new_values?: JsonObject;
  p_metadata?: JsonObject;
}

// ── Billing RPCs ────────────────────────────────────────────

export interface IncrementUsageMeterParams {
  p_business_id: UUID;
  p_meter_type: UsageMeterType;
  p_quantity?: number;
}
