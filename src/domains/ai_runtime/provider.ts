// ============================================================
// AI Runtime Domain — Provider Abstraction
//
// Defines the contract for AI response generation providers.
// Providers are pluggable: mock for tests, OpenAI for production.
//
// Boundary: ai_runtime owns orchestration and provider calls.
//           conversations owns message persistence.
//           routing owns ownership decisions.
// ============================================================

import type { UUID, JsonObject } from '../../shared/types';

// ── Provider Input ──────────────────────────────────────────

/** Context passed to the AI provider for reply generation */
export interface AiProviderInput {
  conversation_id: UUID;
  business_id: UUID;
  messages: AiContextMessage[];
  system_prompt: string;
  customer_summary: {
    name: string | null;
    phone: string | null;
    email: string | null;
  };
  business_context: JsonObject;
  ai_policy: JsonObject | null;
}

/** Simplified message for AI context window */
export interface AiContextMessage {
  role: 'user' | 'assistant' | 'system';
  content: string;
  sender_type: string;
  created_at: string;
}

// ── Provider Output ─────────────────────────────────────────

/** Decision the AI provider makes */
export const AI_DECISIONS = ['reply', 'handoff', 'blocked', 'failed'] as const;
export type AiDecision = (typeof AI_DECISIONS)[number];

/** Output from the AI provider */
export interface AiProviderOutput {
  decision: AiDecision;
  content?: string;           // when decision=reply
  reason_code?: string;       // when handoff/blocked/failed
  reason_text?: string;       // human-readable reason
  model?: string;
  tokens_in?: number;
  tokens_out?: number;
  latency_ms?: number;
}

// ── Provider Interface ──────────────────────────────────────

/** Contract that all AI providers must implement */
export interface AiProvider {
  /** Provider name (e.g., 'openai', 'mock') */
  readonly name: string;

  /** Generate a reply or decision given conversation context */
  generateReply(input: AiProviderInput): Promise<AiProviderOutput>;
}

// ── Interaction Log Types ───────────────────────────────────

export interface AiInteractionLogEntry {
  id: UUID;
  business_id: UUID;
  conversation_id: UUID;
  decision: AiDecision;
  reason_code: string | null;
  trigger_type: 'message_window' | 'manual' | 'system';
  provider_name: string;
  model_used: string;
  message_id: UUID | null;
  prompt_tokens: number;
  completion_tokens: number;
  latency_ms: number | null;
  error: string | null;
  created_at: string;
}
