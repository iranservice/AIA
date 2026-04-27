// ============================================================
// Order Domain — Constants
// ============================================================

import type { OrderStatus } from './types';

export const ORDER_DOMAIN = 'order' as const;

/** Valid order status transitions (server-enforced) */
export const VALID_ORDER_TRANSITIONS: Record<OrderStatus, OrderStatus[]> = {
  draft: ['pending_confirmation', 'cancelled'],
  pending_confirmation: ['confirmed', 'cancelled'],
  confirmed: ['preparing', 'cancelled'],
  preparing: ['ready', 'cancelled'],
  ready: ['delivering', 'delivered', 'cancelled'],
  delivering: ['delivered', 'cancelled'],
  delivered: ['refunded'],
  cancelled: ['refunded'],
  refunded: [],
};

/** Terminal order statuses (no further transitions possible) */
export const TERMINAL_ORDER_STATUSES: OrderStatus[] = ['refunded'];

/** Cancellable order statuses */
export const CANCELLABLE_ORDER_STATUSES: OrderStatus[] = [
  'draft',
  'pending_confirmation',
  'confirmed',
  'preparing',
  'ready',
  'delivering',
];
