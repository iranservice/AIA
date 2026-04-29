// ============================================================
// Orders Domain — Confirmation Experience Types
//
// UI-facing contracts for order confirmation payload,
// available actions, and customer confirmation workflow.
//
// These types match the SQL RPC contracts from
// 00022_order_confirmation_experience.sql
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../shared/types';

// ── Available Actions ───────────────────────────────────────

export type OrderAction =
  | 'view_order'
  | 'confirm_order'
  | 'cancel_order'
  | 'request_customer_confirmation';

/**
 * Rules for available_actions by order status:
 *
 * | Status                 | With order:update       | Without order:update |
 * |------------------------|-------------------------|----------------------|
 * | draft                  | view, confirm, cancel,  | view_order           |
 * |                        | request_confirmation    |                      |
 * | pending_confirmation   | view, confirm, cancel   | view_order           |
 * | confirmed              | view, cancel            | view_order           |
 * | preparing              | view, cancel            | view_order           |
 * | ready+                 | view_order              | view_order           |
 * | cancelled/refunded     | view_order              | view_order           |
 */

// ── Order Confirmation Payload ──────────────────────────────

export interface OrderConfirmationPayload {
  order_id: UUID;
  order_number: string;
  business_id: UUID;
  customer_id: UUID;
  conversation_id: UUID | null;
  status: string;
  order_type: string;
  items: OrderConfirmationItem[];
  subtotal: number;
  total: number;
  currency: string;
  delivery_address: JsonObject | null;
  notes: string | null;
  source: string;
  created_at: Timestamp;
  confirmed_at: Timestamp | null;
  cancelled_at: Timestamp | null;
  cancellation_reason: string | null;
  available_actions: OrderAction[];
  suggested_confirmation_text: string;
  // Error fields (only present on failure)
  error?: string;
  message?: string;
}

export interface OrderConfirmationItem {
  id: UUID;
  item_name: string;
  quantity: number;
  unit_price: number | null;
  total: number | null;
  notes: string | null;
  modifiers: JsonObject;
}

// ── Request Customer Confirmation ───────────────────────────

/**
 * request_customer_confirmation(order_id) returns the full
 * OrderConfirmationPayload after transitioning draft → pending_confirmation.
 *
 * Errors:
 * - ORDER_NOT_FOUND
 * - PERMISSION_DENIED
 * - INVALID_STATUS (order not in draft)
 * - INVALID_TRANSITION (from transition_order_status)
 */
export type RequestConfirmationResult = OrderConfirmationPayload;

// ── Order Summary with Actions (conversation detail) ────────

export interface OrderSummaryWithActions {
  id: UUID;
  order_number: string;
  status: string;
  order_type: string;
  total: number;
  item_count: number;
  source: string;
  created_at: Timestamp;
  available_actions: OrderAction[];
}
