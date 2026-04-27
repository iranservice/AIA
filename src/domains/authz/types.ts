// ============================================================
// RBAC Domain — Types
// ============================================================

import type { UUID, Timestamp } from '../../shared/types';
import type { BusinessType } from '../tenancy/types';

// ── Enums ───────────────────────────────────────────────────

export const MEMBERSHIP_ROLES = ['owner', 'manager', 'operator', 'viewer'] as const;
export type MembershipRole = (typeof MEMBERSHIP_ROLES)[number];

export const PLATFORM_ROLES = ['super_admin', 'platform_admin', 'support'] as const;
export type PlatformRole = (typeof PLATFORM_ROLES)[number];

export const CHANNEL_TYPES = [
  'whatsapp', 'sms', 'email', 'web_chat', 'voice', 'in_app',
] as const;
export type ChannelType = (typeof CHANNEL_TYPES)[number];

// ── Permission Types ────────────────────────────────────────

export interface Permission {
  id: UUID;
  code: string;
  description: string | null;
  domain: string;
  created_at: Timestamp;
}

export interface RolePermission {
  id: UUID;
  role: MembershipRole;
  permission_id: UUID;
  business_type: BusinessType | null;
  created_at: Timestamp;
}

// ── Policy Rule Types ───────────────────────────────────────

export interface PolicyRule {
  id: UUID;
  business_id: UUID;
  rule_type: string;
  rule_config: Record<string, unknown>;
  is_active: boolean;
  priority: number;
  created_at: Timestamp;
  updated_at: Timestamp;
}

// ── Well-known Policy Rule Types ────────────────────────────

export interface AutoAssignPolicy {
  strategy: 'round_robin' | 'least_busy' | 'manual';
  roles: MembershipRole[];
}

export interface AiAllowedPolicy {
  enabled: boolean;
  channels?: ChannelType[];
}

export interface ApprovalRequiredPolicy {
  order_amount_threshold?: number;
  [actionType: string]: boolean | number | undefined;
}

export interface WorkingHoursPolicy {
  enforce: boolean;
  auto_reply_outside: boolean;
  auto_reply_message?: string;
}
