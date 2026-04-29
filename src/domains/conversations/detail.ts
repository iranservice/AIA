// ============================================================
// Conversations Domain — Conversation Detail Types
//
// Types for the get_conversation_detail() SQL RPC.
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../shared/types';
import type { ChannelType } from '../authz/types';
import type {
  ConversationStatus, MessageDirection, MessageSenderType,
  MessageContentType,
} from './types';

/** Full conversation detail response */
export interface ConversationDetailResult {
  conversation: {
    id: UUID;
    business_id: UUID;
    status: ConversationStatus;
    channel_type: ChannelType;
    channel_id: UUID | null;
    assigned_to: UUID | null;
    assigned_at: Timestamp | null;
    ai_enabled: boolean;
    subject: string | null;
    metadata: JsonObject;
    message_count: number;
    last_message_at: Timestamp | null;
    created_at: Timestamp;
    resolved_at: Timestamp | null;
    closed_at: Timestamp | null;
  };
  customer: {
    id: UUID;
    name: string | null;
    phone: string | null;
    email: string | null;
    metadata: JsonObject;
  };
  messages: ConversationMessage[];
  message_total: number;
}

/** Message within conversation detail */
export interface ConversationMessage {
  id: UUID;
  direction: MessageDirection;
  sender_type: MessageSenderType;
  sender_id: UUID | null;
  content_type: MessageContentType;
  content: string | null;
  content_metadata: JsonObject;
  is_internal: boolean;
  external_message_id: string | null;
  delivered_at: Timestamp | null;
  read_at: Timestamp | null;
  created_at: Timestamp;
}
