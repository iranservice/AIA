// ============================================================
// Actions Domain — Handler Types
//
// Defines the contract for action handlers.
// Each action_type (e.g., create_order) has a handler that:
//   1. Validates input
//   2. Calls the owning domain's service/RPC
//   3. Returns structured output
//
// Boundary: actions orchestrate. Domain services execute.
// ============================================================

import type { UUID, JsonObject } from '../../shared/types';
import type { ActionTriggerSource } from './types';

// ── Action Handler Interface ────────────────────────────────

export interface ActionHandlerInput {
  business_id: UUID;
  conversation_id?: UUID;
  triggered_by: ActionTriggerSource;
  trigger_user_id?: UUID;
  input_data: JsonObject;
}

export interface ActionHandlerOutput {
  success: boolean;
  execution_id?: UUID;
  result?: JsonObject;
  error?: string;
  pending_approval?: boolean;
}

// ── Execute Create Order Action ─────────────────────────────

export interface ExecuteCreateOrderActionParams {
  business_id: UUID;
  customer_id: UUID;
  items: Array<{
    item_name: string;
    quantity: number;
    unit_price?: number;
    notes?: string;
    modifiers?: JsonObject;
  }>;
  order_type?: string;
  conversation_id?: UUID;
  delivery_address?: JsonObject;
  notes?: string;
  source?: string;
  triggered_by?: ActionTriggerSource;
}

export interface ExecuteCreateOrderActionResult {
  execution_id?: UUID;
  order?: {
    order_id?: UUID;
    order_number?: string;
    status?: string;
    total?: number;
    error?: string;
  };
  status?: string;
  message?: string;
  error?: string;
}
