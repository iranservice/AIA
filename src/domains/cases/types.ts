// ============================================================
// Tickets Domain — Types & Constants
// ============================================================

import type { UUID, Timestamp } from '../../shared/types';

export const TICKETS_DOMAIN = 'tickets' as const;

export const TICKET_STATUSES = [
  'open', 'in_progress', 'waiting_customer', 'resolved', 'closed',
] as const;
export type TicketStatus = (typeof TICKET_STATUSES)[number];

export const TICKET_PRIORITIES = ['low', 'medium', 'high', 'urgent'] as const;
export type TicketPriority = (typeof TICKET_PRIORITIES)[number];

export interface Ticket {
  id: UUID;
  business_id: UUID;
  customer_id: UUID;
  conversation_id: UUID | null;
  ticket_number: string;
  status: TicketStatus;
  priority: TicketPriority;
  subject: string;
  description: string | null;
  assigned_to: UUID | null;
  callback_requested: boolean;
  callback_phone: string | null;
  callback_scheduled_at: Timestamp | null;
  callback_completed_at: Timestamp | null;
  resolved_at: Timestamp | null;
  created_at: Timestamp;
  updated_at: Timestamp;
}
