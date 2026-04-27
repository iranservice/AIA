// ============================================================
// Billing Domain — Types & Constants
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../shared/types';

export const BILLING_DOMAIN = 'billing' as const;

export const USAGE_METER_TYPES = [
  'ai_tokens', 'messages_sent', 'api_calls', 'storage_bytes', 'voice_minutes',
] as const;
export type UsageMeterType = (typeof USAGE_METER_TYPES)[number];

export const BILLING_EVENT_TYPES = [
  'subscription', 'overage', 'addon', 'credit', 'refund',
] as const;
export type BillingEventType = (typeof BILLING_EVENT_TYPES)[number];

export interface UsageMeter {
  id: UUID;
  business_id: UUID;
  meter_type: UsageMeterType;
  period_start: string; // date
  period_end: string;   // date
  quantity: number;
  created_at: Timestamp;
}

/**
 * Level A billing event ONLY.
 * platform_payment_reference uses the PLATFORM's payment gateway.
 * This is completely isolated from tenant order payments (Level B).
 */
export interface BillingEvent {
  id: UUID;
  business_id: UUID;
  event_type: BillingEventType;
  amount: number;
  currency: string;
  platform_payment_reference: string | null;
  description: string | null;
  metadata: JsonObject;
  created_at: Timestamp;
}
