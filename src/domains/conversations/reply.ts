// ============================================================
// Conversations Domain — Operator Reply Types
//
// Types for the operator_reply() SQL RPC.
//
// Boundary: Conversations owns message persistence.
//           Routing owns assignment checks (done inside RPC).
//           Channels owns outbound delivery (abstracted here).
// ============================================================

import type { UUID } from '../../shared/types';
import type { MessageContentType } from './types';

// ── RPC Input ───────────────────────────────────────────────

export interface OperatorReplyParams {
  conversation_id: UUID;
  content: string;
  content_type?: MessageContentType;
}

// ── RPC Output ──────────────────────────────────────────────

export interface OperatorReplyResult {
  message_id: UUID;
  conversation_id: UUID;
  delivery_status: 'queued';
}

export interface OperatorReplyError {
  error: string;
  message?: string;
}

export type OperatorReplyResponse = OperatorReplyResult | OperatorReplyError;

export function isReplyError(r: OperatorReplyResponse): r is OperatorReplyError {
  return 'error' in r && typeof (r as OperatorReplyError).error === 'string'
    && !('message_id' in r);
}
