// ============================================================
// Customer Domain — Types
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../lib/types';
import type { ChannelType } from '../authz/types';

/** End-customer of a tenant business */
export interface Customer {
  id: UUID;
  business_id: UUID;
  external_id: string | null;
  phone: string | null;
  email: string | null;
  name: string | null;
  metadata: JsonObject;
  first_seen_at: Timestamp;
  last_seen_at: Timestamp;
  conversation_count: number;
  order_count: number;
  total_spent: number;
  created_at: Timestamp;
  updated_at: Timestamp;
}

/** Multi-channel identity for customer resolution */
export interface CustomerIdentity {
  id: UUID;
  customer_id: UUID;
  channel_type: ChannelType;
  channel_identifier: string;
  is_primary: boolean;
  verified_at: Timestamp | null;
  created_at: Timestamp;
}

/** Input for resolve_or_create_customer RPC */
export interface ResolveCustomerInput {
  business_id: UUID;
  channel_type: ChannelType;
  identifier: string;
  name?: string;
}
