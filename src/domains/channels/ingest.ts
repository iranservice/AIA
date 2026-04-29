// ============================================================
// Channels Domain — Inbound Message Ingestion
//
// Validates and ingests inbound messages from channel webhooks.
// Calls the ingest_inbound_message() SQL RPC which handles:
//   customer resolution → conversation resolution →
//   message persistence → window update → audit logging
//
// Boundary: Channels owns ingestion.
//           CRM owns customer resolution (via SQL RPC).
//           Conversations owns message persistence (via SQL RPC).
// ============================================================

import type { UUID, JsonObject } from '../../shared/types';
import type { ChannelType } from '../authz/types';
import type { MessageContentType } from '../conversations/types';

// ── Input Types ─────────────────────────────────────────────

/** Raw inbound payload from a webhook or test harness */
export interface InboundMessagePayload {
  business_id: UUID;
  channel_id: UUID;
  channel_type: ChannelType;
  sender_identifier: string;
  sender_name?: string | null;
  content?: string | null;
  content_type?: MessageContentType;
  external_message_id?: string | null;
  raw_payload?: JsonObject;
}

// ── Output Types ────────────────────────────────────────────

export interface IngestResult {
  conversation_id: UUID;
  customer_id: UUID;
  message_id: UUID;
  window_id?: UUID;
  is_new_customer: boolean;
  is_new_conversation: boolean;
  is_duplicate: boolean;
}

export interface IngestError {
  error: string;
  message: string;
}

export type IngestResponse = IngestResult | IngestError;

// ── Validation ──────────────────────────────────────────────

export interface ValidationError {
  field: string;
  message: string;
}

/**
 * Validates an inbound message payload.
 * Returns an array of validation errors (empty = valid).
 */
export function validateInboundPayload(
  payload: Partial<InboundMessagePayload>
): ValidationError[] {
  const errors: ValidationError[] = [];

  if (!payload.business_id) {
    errors.push({ field: 'business_id', message: 'Required' });
  }
  if (!payload.channel_id) {
    errors.push({ field: 'channel_id', message: 'Required' });
  }
  if (!payload.channel_type) {
    errors.push({ field: 'channel_type', message: 'Required' });
  }
  if (!payload.sender_identifier) {
    errors.push({ field: 'sender_identifier', message: 'Required' });
  }

  return errors;
}

/**
 * Check if an IngestResponse is an error.
 */
export function isIngestError(response: IngestResponse): response is IngestError {
  return 'error' in response && typeof (response as IngestError).error === 'string'
    && !('conversation_id' in response);
}
