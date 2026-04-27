// ============================================================
// Channels / Integrations Domain — Types & Constants
//
// Owns: channel foundations (WhatsApp, SMS, email, webhook, voice),
// inbound event ingestion types, outbound delivery abstraction,
// integration logs, provider adapter contracts,
// Level A vs Level B integration separation.
//
// Boundary: Channels owns the connection/transport layer.
//           Conversations owns message persistence.
//           Providers owns the registry of external integrations.
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../lib/types';
import type { ChannelType } from '../authz/types';

export const CHANNELS_DOMAIN = 'channels' as const;

// ── Inbound Event Types ─────────────────────────────────────

export const INBOUND_EVENT_TYPES = [
  'message',           // New message from customer
  'message_status',    // Delivery/read receipt
  'media',             // Media attachment
  'location',          // Location share
  'reaction',          // Message reaction
  'typing',            // Typing indicator
  'call_start',        // Voice call initiated
  'call_end',          // Voice call ended
  'webhook',           // Generic webhook event
] as const;
export type InboundEventType = (typeof INBOUND_EVENT_TYPES)[number];

// ── Outbound Delivery Status ────────────────────────────────

export const DELIVERY_STATUSES = [
  'queued', 'sent', 'delivered', 'read', 'failed', 'rejected',
] as const;
export type DeliveryStatus = (typeof DELIVERY_STATUSES)[number];

// ── Entity Types ────────────────────────────────────────────

/** Normalized inbound event from any channel */
export interface InboundEvent {
  id: UUID;
  business_id: UUID;
  channel_type: ChannelType;
  channel_id: UUID;              // business_channels.id
  event_type: InboundEventType;
  sender_identifier: string;     // phone, email, etc.
  sender_name: string | null;
  raw_payload: JsonObject;       // original webhook payload
  normalized_payload: JsonObject; // standardized format
  processed: boolean;
  processed_at: Timestamp | null;
  error: string | null;
  created_at: Timestamp;
}

/** Outbound delivery record */
export interface OutboundDelivery {
  id: UUID;
  business_id: UUID;
  channel_type: ChannelType;
  channel_id: UUID;
  message_id: UUID;              // conversations.messages.id
  recipient_identifier: string;
  status: DeliveryStatus;
  provider_message_id: string | null; // ID from external provider
  sent_at: Timestamp | null;
  delivered_at: Timestamp | null;
  read_at: Timestamp | null;
  error: string | null;
  retry_count: number;
  created_at: Timestamp;
}

/** Integration log for debugging */
export interface IntegrationLog {
  id: UUID;
  business_id: UUID | null;       // null for platform-level
  channel_type: ChannelType;
  direction: 'inbound' | 'outbound';
  provider_name: string;
  request_payload: JsonObject;
  response_payload: JsonObject | null;
  status_code: number | null;
  latency_ms: number | null;
  error: string | null;
  created_at: Timestamp;
}

// ── Provider Adapter Contract ───────────────────────────────
// Interface that all channel provider adapters must implement.

export interface ChannelAdapterContract {
  /** Send a message through this channel */
  sendMessage: (params: OutboundMessageParams) => Promise<OutboundDeliveryResult>;
  /** Verify webhook signature */
  verifyWebhook: (headers: Record<string, string>, body: string) => boolean;
  /** Normalize inbound event to standard format */
  normalizeInbound: (rawPayload: JsonObject) => NormalizedInboundMessage;
}

export interface OutboundMessageParams {
  recipient: string;
  content: string;
  content_type: string;
  media_url?: string;
  template_id?: string;
  template_params?: Record<string, string>;
}

export interface OutboundDeliveryResult {
  provider_message_id: string;
  status: DeliveryStatus;
  error?: string;
}

export interface NormalizedInboundMessage {
  sender_identifier: string;
  sender_name: string | null;
  content: string | null;
  content_type: string;
  media_url: string | null;
  timestamp: string;
  metadata: JsonObject;
}
