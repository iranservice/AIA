// ============================================================
// Identity Domain — Validators
// ============================================================

import { z } from 'zod';

export const userProfileInputSchema = z.object({
  display_name: z.string().min(1).max(255).optional(),
  phone: z
    .string()
    .regex(/^\+?[1-9]\d{6,14}$/, 'Invalid phone number format')
    .optional(),
  email: z.string().email('Invalid email format').optional(),
  avatar_url: z.string().url('Invalid URL format').optional(),
  preferred_language: z.enum(['en', 'fa', 'ar']).optional(),
  timezone: z.string().min(1).max(100).optional(),
});

export type ValidatedUserProfileInput = z.infer<typeof userProfileInputSchema>;
