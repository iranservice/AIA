// ============================================================
// Tenancy Domain — Validators
// ============================================================

import { z } from 'zod';

export const businessInputSchema = z.object({
  name: z.string().min(1).max(255),
  slug: z
    .string()
    .min(2)
    .max(63)
    .regex(
      /^[a-z0-9][a-z0-9-]*[a-z0-9]$/,
      'Slug must be lowercase alphanumeric with hyphens, starting and ending with alphanumeric'
    ),
  business_type: z.enum([
    'restaurant',
    'clinic',
    'salon',
    'supermarket',
    'general',
  ]),
  business_config: z.record(z.unknown()).optional().default({}),
  timezone: z.string().min(1).max(100).optional(),
  default_language: z.string().min(2).max(5).optional(),
});

export const operatingHoursSchema = z.object({
  day_of_week: z.number().int().min(0).max(6),
  open_time: z.string().regex(/^\d{2}:\d{2}$/).optional(),
  close_time: z.string().regex(/^\d{2}:\d{2}$/).optional(),
  is_closed: z.boolean().default(false),
});

export type ValidatedBusinessInput = z.infer<typeof businessInputSchema>;
export type ValidatedOperatingHours = z.infer<typeof operatingHoursSchema>;
