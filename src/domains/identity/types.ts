// ============================================================
// Identity Domain — Types
// ============================================================

import type { UUID, Timestamp } from '../../lib/types';
import type { PlatformRole } from '../authz/types';

/** User profile extending Supabase auth.users */
export interface UserProfile {
  id: UUID;
  display_name: string | null;
  phone: string | null;
  email: string | null;
  avatar_url: string | null;
  preferred_language: string;
  timezone: string;
  platform_role: PlatformRole | null;
  is_active: boolean;
  last_seen_at: Timestamp | null;
  created_at: Timestamp;
  updated_at: Timestamp;
}

/** Input for creating/updating a user profile */
export interface UserProfileInput {
  display_name?: string;
  phone?: string;
  email?: string;
  avatar_url?: string;
  preferred_language?: string;
  timezone?: string;
}
