// ============================================================
// Tenancy Domain — Types
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../lib/types';
import type { MembershipRole, ChannelType } from '../authz/types';

// ── Business Types ──────────────────────────────────────────

export const BUSINESS_TYPES = [
  'restaurant',
  'clinic',
  'salon',
  'supermarket',
  'general',
] as const;
export type BusinessType = (typeof BUSINESS_TYPES)[number];

/** Tenant business entity */
export interface Business {
  id: UUID;
  name: string;
  slug: string;
  business_type: BusinessType;
  business_config: JsonObject;
  timezone: string;
  default_language: string;
  subscription_tier: string;
  is_active: boolean;
  created_at: Timestamp;
  updated_at: Timestamp;
}

/** Input for creating a new business */
export interface BusinessInput {
  name: string;
  slug: string;
  business_type: BusinessType;
  business_config?: JsonObject;
  timezone?: string;
  default_language?: string;
}

// ── Membership Types ────────────────────────────────────────

/** Links a user to a business with a role */
export interface BusinessMembership {
  id: UUID;
  user_id: UUID;
  business_id: UUID;
  role: MembershipRole;
  is_active: boolean;
  invited_by: UUID | null;
  joined_at: Timestamp;
  created_at: Timestamp;
}

// ── Channel Types ───────────────────────────────────────────

/** Communication channel connected to a business */
export interface BusinessChannel {
  id: UUID;
  business_id: UUID;
  channel_type: ChannelType;
  provider_id: UUID | null;
  channel_config: JsonObject;
  is_active: boolean;
  verified_at: Timestamp | null;
  created_at: Timestamp;
  updated_at: Timestamp;
}

// ── Operating Hours ─────────────────────────────────────────

/** Day-of-week operating hours (0=Sunday, 6=Saturday) */
export interface BusinessOperatingHours {
  id: UUID;
  business_id: UUID;
  day_of_week: 0 | 1 | 2 | 3 | 4 | 5 | 6;
  open_time: string | null;
  close_time: string | null;
  is_closed: boolean;
  created_at: Timestamp;
}

// ── Business Config Schemas (per type) ──────────────────────

export interface RestaurantConfig {
  menu_url?: string;
  delivery_enabled?: boolean;
  delivery_radius_km?: number;
  average_prep_time_min?: number;
  cuisine_types?: string[];
  accepts_reservations?: boolean;
  max_party_size?: number;
}

export interface ClinicConfig {
  specialties?: string[];
  appointment_duration_min?: number;
  requires_referral?: boolean;
  accepts_walk_ins?: boolean;
}

export interface SalonConfig {
  service_categories?: string[];
  average_appointment_min?: number;
  accepts_walk_ins?: boolean;
}

export interface SupermarketConfig {
  delivery_enabled?: boolean;
  delivery_radius_km?: number;
  min_order_amount?: number;
}
