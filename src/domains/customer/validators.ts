// ============================================================
// Customer Domain — Validators
// ============================================================

import { z } from 'zod';

export const resolveCustomerInputSchema = z.object({
  business_id: z.string().uuid(),
  channel_type: z.enum([
    'whatsapp', 'sms', 'email', 'web_chat', 'voice', 'in_app',
  ]),
  identifier: z.string().min(1).max(320),
  name: z.string().min(1).max(255).optional(),
});

export type ValidatedResolveCustomerInput = z.infer<
  typeof resolveCustomerInputSchema
>;
