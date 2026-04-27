// ============================================================
// Tenancy Domain — Constants
// ============================================================

export const TENANCY_DOMAIN = 'tenancy' as const;

export const SUBSCRIPTION_TIERS = ['free', 'starter', 'pro', 'enterprise'] as const;
export type SubscriptionTier = (typeof SUBSCRIPTION_TIERS)[number];

export const DAYS_OF_WEEK = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
] as const;
