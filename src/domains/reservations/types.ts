// ============================================================
// Reservation Domain — Types & Constants
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../shared/types';

export const RESERVATION_DOMAIN = 'reservation' as const;

export const RESERVATION_STATUSES = [
  'pending', 'confirmed', 'seated', 'completed', 'cancelled', 'no_show',
] as const;
export type ReservationStatus = (typeof RESERVATION_STATUSES)[number];

export const VALID_RESERVATION_TRANSITIONS: Record<ReservationStatus, ReservationStatus[]> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['seated', 'cancelled', 'no_show'],
  seated: ['completed'],
  completed: [],
  cancelled: [],
  no_show: [],
};

export interface Reservation {
  id: UUID;
  business_id: UUID;
  customer_id: UUID;
  conversation_id: UUID | null;
  reservation_number: string;
  status: ReservationStatus;
  party_size: number;
  reserved_at: Timestamp;
  duration_minutes: number;
  preferences: JsonObject;
  notes: string | null;
  confirmed_at: Timestamp | null;
  seated_at: Timestamp | null;
  completed_at: Timestamp | null;
  cancelled_at: Timestamp | null;
  cancellation_reason: string | null;
  no_show_at: Timestamp | null;
  created_by: UUID | null;
  created_at: Timestamp;
  updated_at: Timestamp;
}

export interface ReservationStatusHistory {
  id: UUID;
  reservation_id: UUID;
  from_status: ReservationStatus | null;
  to_status: ReservationStatus;
  changed_by: UUID | null;
  reason: string | null;
  created_at: Timestamp;
}
