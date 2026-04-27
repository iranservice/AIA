// ============================================================
// Order Domain — Types
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../shared/types';

// ── Enums ───────────────────────────────────────────────────

export const ORDER_STATUSES = [
  'draft', 'pending_confirmation', 'confirmed', 'preparing',
  'ready', 'delivering', 'delivered', 'cancelled', 'refunded',
] as const;
export type OrderStatus = (typeof ORDER_STATUSES)[number];

export const ORDER_TYPES = ['dine_in', 'takeaway', 'delivery'] as const;
export type OrderType = (typeof ORDER_TYPES)[number];

export const PAYMENT_STATUSES = [
  'unpaid', 'pending', 'paid', 'partially_refunded', 'refunded', 'failed',
] as const;
export type PaymentStatus = (typeof PAYMENT_STATUSES)[number];

// ── Entity Types ────────────────────────────────────────────

export interface OrderLineItem {
  name: string;
  quantity: number;
  unit_price: number;
  total: number;
  notes?: string;
}

export interface Order {
  id: UUID;
  business_id: UUID;
  customer_id: UUID;
  conversation_id: UUID | null;
  order_number: string;
  status: OrderStatus;
  order_type: OrderType;
  items: OrderLineItem[];
  subtotal: number;
  tax: number;
  delivery_fee: number;
  discount: number;
  total: number;
  currency: string;
  payment_status: PaymentStatus;
  payment_gateway_id: UUID | null;
  payment_reference: string | null;
  delivery_address: JsonObject | null;
  notes: string | null;
  estimated_ready_at: Timestamp | null;
  confirmed_at: Timestamp | null;
  ready_at: Timestamp | null;
  delivered_at: Timestamp | null;
  cancelled_at: Timestamp | null;
  cancellation_reason: string | null;
  created_by: UUID | null;
  created_at: Timestamp;
  updated_at: Timestamp;
}

export interface OrderStatusHistory {
  id: UUID;
  order_id: UUID;
  from_status: OrderStatus | null;
  to_status: OrderStatus;
  changed_by: UUID | null;
  reason: string | null;
  created_at: Timestamp;
}

// ── RPC Input Types ─────────────────────────────────────────

export interface CreateOrderInput {
  business_id: UUID;
  customer_id: UUID;
  items: OrderLineItem[];
  order_type?: OrderType;
  conversation_id?: UUID;
  delivery_address?: JsonObject;
  notes?: string;
  created_by?: UUID;
}

export interface TransitionOrderInput {
  order_id: UUID;
  new_status: OrderStatus;
  changed_by?: UUID;
  reason?: string;
}
