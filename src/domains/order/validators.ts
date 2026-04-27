// ============================================================
// Order Domain — Validators
// ============================================================

import { z } from 'zod';

const orderLineItemSchema = z.object({
  name: z.string().min(1).max(255),
  quantity: z.number().int().positive(),
  unit_price: z.number().nonnegative(),
  total: z.number().nonnegative(),
  notes: z.string().max(500).optional(),
});

export const createOrderInputSchema = z.object({
  business_id: z.string().uuid(),
  customer_id: z.string().uuid(),
  items: z.array(orderLineItemSchema).min(1),
  order_type: z.enum(['dine_in', 'takeaway', 'delivery']).default('dine_in'),
  conversation_id: z.string().uuid().optional(),
  delivery_address: z.record(z.unknown()).optional(),
  notes: z.string().max(2000).optional(),
  created_by: z.string().uuid().optional(),
});

export const transitionOrderInputSchema = z.object({
  order_id: z.string().uuid(),
  new_status: z.enum([
    'draft', 'pending_confirmation', 'confirmed', 'preparing',
    'ready', 'delivering', 'delivered', 'cancelled', 'refunded',
  ]),
  changed_by: z.string().uuid().optional(),
  reason: z.string().max(500).optional(),
});

export type ValidatedCreateOrderInput = z.infer<typeof createOrderInputSchema>;
export type ValidatedTransitionOrderInput = z.infer<
  typeof transitionOrderInputSchema
>;
