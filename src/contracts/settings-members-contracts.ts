// ============================================================
// Phase II-A — Business Settings & Members RPC Contracts
// Type-safe contract definitions for settings/members RPCs.
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../shared/types';
import type { MembershipRole, PlatformRole } from '../domains/authz/types';
import type { BusinessType } from '../domains/tenancy/types';

// ── get_my_workspaces() ─────────────────────────────────────

/** No params — uses auth.uid() internally */
export type GetMyWorkspacesParams = Record<string, never>;

export interface WorkspaceRow {
  business_id: UUID;
  business_slug: string;
  business_name: string;
  business_type: BusinessType;
  membership_id: UUID;
  membership_role: MembershipRole;
  membership_is_active: boolean;
  is_owner_or_admin: boolean;
  platform_role: PlatformRole | null;
  default_workspace: boolean;
}

// ── get_my_platform_access() ────────────────────────────────

export type GetMyPlatformAccessParams = Record<string, never>;

export interface PlatformAccessRow {
  user_id: UUID;
  platform_role: PlatformRole | null;
  is_platform_admin: boolean;
}

// ── get_business_profile(p_business_id) ─────────────────────

export interface GetBusinessProfileParams {
  p_business_id: UUID;
}

export interface BusinessProfileRow {
  business_id: UUID;
  slug: string;
  name: string;
  business_type: BusinessType;
  logo_url: string | null;
  phone: string | null;
  email: string | null;
  timezone: string;
  default_language: string;
  business_config: JsonObject;
  subscription_tier: string;
  is_active: boolean;
  created_at: Timestamp;
  updated_at: Timestamp;
}

// ── update_business_profile(...) ────────────────────────────

export interface UpdateBusinessProfileParams {
  p_business_id: UUID;
  p_name?: string;
  p_logo_url?: string;
  p_phone?: string;
  p_email?: string;
  p_timezone?: string;
  p_default_language?: string;
  p_business_config?: JsonObject;
}

/** Returns the new profile state as JSONB */
export type UpdateBusinessProfileResult = JsonObject;

// ── get_business_members(p_business_id) ─────────────────────

export interface GetBusinessMembersParams {
  p_business_id: UUID;
}

export interface BusinessMemberRow {
  membership_id: UUID;
  user_id: UUID;
  display_name: string | null;
  email: string | null;
  phone: string | null;
  avatar_url: string | null;
  role: MembershipRole;
  is_active: boolean;
  joined_at: Timestamp;
  created_at: Timestamp;
  last_seen_at: Timestamp | null;
  status: 'active' | 'inactive';
}

// ── update_business_member_role(...) ────────────────────────

export interface UpdateBusinessMemberRoleParams {
  p_membership_id: UUID;
  p_new_role: MembershipRole;
}

export interface UpdateBusinessMemberRoleResult {
  membership_id: UUID;
  new_role: MembershipRole;
}

// ── deactivate_business_member(...) ─────────────────────────

export interface DeactivateBusinessMemberParams {
  p_membership_id: UUID;
}

export interface DeactivateBusinessMemberResult {
  membership_id: UUID;
  deactivated: boolean;
}

// ── invite_business_member(...) ─────────────────────────────

export interface InviteBusinessMemberParams {
  p_business_id: UUID;
  p_email: string;
  p_role?: MembershipRole;
}

export interface InviteBusinessMemberResult {
  business_id: UUID;
  email: string;
  role: MembershipRole;
  invited_by: UUID;
  membership_id: UUID | null;
  status: 'joined' | 'pending_signup';
}

// ── get_business_teams(...) — placeholder ───────────────────

export interface GetBusinessTeamsParams {
  p_business_id: UUID;
}

export interface BusinessTeamRow {
  team_id: UUID;
  team_name: string;
  member_count: number;
}
