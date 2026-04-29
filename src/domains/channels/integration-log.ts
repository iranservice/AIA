// ============================================================
// Channels Domain — Integration Log Types
//
// Aligns with the integration_logs SQL table created in 00018.
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../shared/types';
import type { ChannelType } from '../authz/types';

export interface IntegrationLogEntry {
  id: UUID;
  business_id: UUID | null;
  channel_type: ChannelType;
  direction: 'inbound' | 'outbound';
  provider_name: string;
  event_type: string | null;
  sender_identifier: string | null;
  request_payload: JsonObject;
  response_payload: JsonObject | null;
  status_code: number | null;
  latency_ms: number | null;
  error: string | null;
  processed: boolean;
  created_at: Timestamp;
}
