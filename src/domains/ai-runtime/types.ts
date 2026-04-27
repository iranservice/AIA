// ============================================================
// AI Runtime Domain — Types & Constants
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../lib/types';
import type { ActionType } from '../actions/types';

export const AI_RUNTIME_DOMAIN = 'ai-runtime' as const;

export interface AiAgentConfig {
  id: UUID;
  business_id: UUID;
  provider_id: UUID;
  model_name: string;
  system_prompt: string | null;
  temperature: number;
  max_tokens: number;
  allowed_actions: ActionType[];
  knowledge_base_config: JsonObject;
  max_context_messages: number;
  window_summary_enabled: boolean;
  is_active: boolean;
  created_at: Timestamp;
  updated_at: Timestamp;
}

export interface AiInteractionLog {
  id: UUID;
  business_id: UUID;
  conversation_id: UUID;
  agent_config_id: UUID;
  prompt_tokens: number;
  completion_tokens: number;
  model_used: string;
  request_payload: JsonObject;
  response_payload: JsonObject;
  actions_triggered: ActionType[];
  policy_checks: JsonObject[];
  latency_ms: number | null;
  error: string | null;
  created_at: Timestamp;
}
