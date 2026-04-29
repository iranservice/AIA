// ============================================================
// Orders Domain — Service Types
//
// Input/output types for order creation and management.
// These types mirror the SQL RPC contracts.
//
// Boundary: orders owns order lifecycle and items.
//           actions orchestrates but does not own order logic.
// ============================================================

import type { UUID, JsonObject } from '../../shared/types';
import type { OrderStatus, OrderType } from './types';

// ── Create Order ────────────────────────────────────────────

export interface CreateOrderParams {
  business_id: UUID;
  customer_id: UUID;
  items: CreateOrderItem[];
  order_type?: OrderType;
  conversation_id?: UUID;
  delivery_address?: JsonObject;
  notes?: string;
  source?: 'operator' | 'ai_suggested' | 'system';
  initial_status?: OrderStatus;
}

export interface CreateOrderItem {
  item_name: string;
  quantity: number;
  unit_price?: number;
  notes?: string;
  modifiers?: JsonObject;
}

export interface CreateOrderResult {
  order_id?: UUID;
  order_number?: string;
  status?: string;
  subtotal?: number;
  total?: number;
  item_count?: number;
  has_pricing?: boolean;
  error?: string;
  message?: string;
  missing_fields?: string[];
}

// ── Transition Order ────────────────────────────────────────

export interface TransitionOrderResult {
  order_id?: UUID;
  from_status?: string;
  to_status?: string;
  error?: string;
  message?: string;
}

// ── Order Summary (for conversation detail) ─────────────────

export interface OrderSummary {
  id: UUID;
  order_number: string;
  status: string;
  order_type: string;
  total: number;
  item_count: number;
  source: string;
  created_at: string;
}
