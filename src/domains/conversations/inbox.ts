// ============================================================
// Conversations Domain — Inbox Query Types
//
// Types for the get_inbox_list() SQL RPC.
// Boundary: Conversations owns inbox-ready data.
// ============================================================

import type { UUID, Timestamp } from '../../shared/types';
import type { ChannelType } from '../authz/types';
import type { ConversationStatus, MessageContentType, MessageSenderType, MessageDirection } from './types';

/** Single item in the inbox list */
export interface InboxListItem {
  id: UUID;
  business_id: UUID;
  status: ConversationStatus;
  channel_type: ChannelType;
  assigned_to: UUID | null;
  ai_enabled: boolean;
  message_count: number;
  last_message_at: Timestamp | null;
  created_at: Timestamp;
  customer: {
    id: UUID;
    name: string | null;
    phone: string | null;
    email: string | null;
  };
  last_message: {
    id: UUID;
    content: string | null;
    content_type: MessageContentType;
    sender_type: MessageSenderType;
    direction: MessageDirection;
    created_at: Timestamp;
  } | null;
  unread_count: number;
}

/** Response from get_inbox_list() RPC */
export interface InboxListResponse {
  conversations: InboxListItem[];
  total: number;
}

/** Filters for inbox query */
export interface InboxFilters {
  business_id: UUID;
  status_filter?: ConversationStatus[];
  limit?: number;
  offset?: number;
}
