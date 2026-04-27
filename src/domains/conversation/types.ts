// ============================================================
// Conversation Domain — Types
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../lib/types';
import type { ChannelType } from '../rbac/types';

// ── Enums ───────────────────────────────────────────────────

export const CONVERSATION_STATUSES = [
  'open', 'assigned', 'waiting', 'resolved', 'closed',
] as const;
export type ConversationStatus = (typeof CONVERSATION_STATUSES)[number];

export const MESSAGE_DIRECTIONS = ['inbound', 'outbound'] as const;
export type MessageDirection = (typeof MESSAGE_DIRECTIONS)[number];

export const MESSAGE_SENDER_TYPES = [
  'customer', 'operator', 'ai', 'system',
] as const;
export type MessageSenderType = (typeof MESSAGE_SENDER_TYPES)[number];

export const MESSAGE_CONTENT_TYPES = [
  'text', 'image', 'audio', 'video', 'file',
  'location', 'template', 'system_event',
] as const;
export type MessageContentType = (typeof MESSAGE_CONTENT_TYPES)[number];

// ── Entity Types ────────────────────────────────────────────

export interface Conversation {
  id: UUID;
  business_id: UUID;
  customer_id: UUID;
  channel_type: ChannelType;
  channel_id: UUID | null;
  status: ConversationStatus;
  assigned_to: UUID | null;
  assigned_at: Timestamp | null;
  ai_enabled: boolean;
  subject: string | null;
  metadata: JsonObject;
  last_message_at: Timestamp | null;
  message_count: number;
  created_at: Timestamp;
  updated_at: Timestamp;
  resolved_at: Timestamp | null;
  closed_at: Timestamp | null;
}

export interface Message {
  id: UUID;
  conversation_id: UUID;
  direction: MessageDirection;
  sender_type: MessageSenderType;
  sender_id: UUID | null;
  content_type: MessageContentType;
  content: string | null;
  content_metadata: JsonObject;
  is_internal: boolean;
  reply_to_id: UUID | null;
  delivered_at: Timestamp | null;
  read_at: Timestamp | null;
  created_at: Timestamp;
}

export interface MessageWindow {
  id: UUID;
  conversation_id: UUID;
  window_start: Timestamp;
  window_end: Timestamp;
  message_count: number;
  summary: string | null;
  tokens_used: number | null;
  created_at: Timestamp;
}

// ── RPC Input Types ─────────────────────────────────────────

export interface SendMessageInput {
  conversation_id: UUID;
  direction: MessageDirection;
  sender_type: MessageSenderType;
  sender_id?: UUID;
  content?: string;
  content_type?: MessageContentType;
  content_metadata?: JsonObject;
  is_internal?: boolean;
  reply_to_id?: UUID;
}

export interface CreateConversationInput {
  business_id: UUID;
  customer_id: UUID;
  channel_type: ChannelType;
  channel_id?: UUID;
  subject?: string;
}
