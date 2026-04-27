// ============================================================
// Providers Domain — Types & Constants
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../lib/types';

export const PROVIDERS_DOMAIN = 'providers' as const;

export const PROVIDER_TYPES = [
  'ai', 'sms', 'email', 'whatsapp', 'voice', 'payment',
] as const;
export type ProviderType = (typeof PROVIDER_TYPES)[number];

export const PROVIDER_SCOPES = ['platform', 'tenant'] as const;
export type ProviderScope = (typeof PROVIDER_SCOPES)[number];

export const PROVIDER_HEALTH_STATUSES = [
  'healthy', 'degraded', 'unhealthy', 'unknown',
] as const;
export type ProviderHealthStatus = (typeof PROVIDER_HEALTH_STATUSES)[number];

export interface ProviderRegistryEntry {
  id: UUID;
  business_id: UUID | null;
  provider_type: ProviderType;
  provider_scope: ProviderScope;
  provider_name: string;
  /** api_config is NOT directly accessible — use get_provider_config RPC */
  api_config?: JsonObject;
  is_active: boolean;
  health_status: ProviderHealthStatus;
  last_health_check_at: Timestamp | null;
  created_at: Timestamp;
  updated_at: Timestamp;
}
