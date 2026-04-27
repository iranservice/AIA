// ============================================================
// RBAC Domain — Validators
// ============================================================

import { z } from 'zod';

export const policyRuleInputSchema = z.object({
  rule_type: z.string().min(1).max(100),
  rule_config: z.record(z.unknown()),
  is_active: z.boolean().default(true),
  priority: z.number().int().default(0),
});

export const autoAssignPolicySchema = z.object({
  strategy: z.enum(['round_robin', 'least_busy', 'manual']),
  roles: z.array(z.enum(['owner', 'manager', 'operator', 'viewer'])),
});

export const aiAllowedPolicySchema = z.object({
  enabled: z.boolean(),
  channels: z
    .array(z.enum(['whatsapp', 'sms', 'email', 'web_chat', 'voice', 'in_app']))
    .optional(),
});

export type ValidatedPolicyRuleInput = z.infer<typeof policyRuleInputSchema>;
