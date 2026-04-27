// ============================================================
// AI Config Domain — Types & Constants
//
// Owns: AI policies, prompt templates, prompt testing,
// AI behavior configuration, versioning.
//
// Boundary: AI Config owns HOW the AI behaves (rules, prompts).
//           Knowledge owns WHAT the AI knows (data, entries).
//           AI Runtime owns inference execution.
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../shared/types';

export const AI_CONFIG_DOMAIN = 'ai_config' as const;

// ── Prompt Templates ────────────────────────────────────────

/** Prompt template for AI interactions */
export interface PromptTemplate {
  id: UUID;
  business_id: UUID;
  name: string;
  description: string | null;
  template_text: string;         // with {{variable}} placeholders
  variables: string[];           // list of expected variables
  category: string;              // e.g., 'greeting', 'order_confirmation', 'handoff'
  is_default: boolean;
  is_active: boolean;
  version: number;
  created_at: Timestamp;
  updated_at: Timestamp;
}

// ── AI Policies ─────────────────────────────────────────────

/** AI policy — configurable behavior rules for AI */
export interface AiPolicy {
  id: UUID;
  business_id: UUID;
  name: string;
  description: string | null;
  policy_type: string;           // e.g., 'response_guard', 'escalation_trigger', 'tone'
  policy_config: JsonObject;     // type-specific configuration
  is_active: boolean;
  priority: number;
  created_at: Timestamp;
  updated_at: Timestamp;
}

// ── Well-known AI Policy Types ──────────────────────────────

export const AI_POLICY_TYPES = {
  RESPONSE_GUARD: 'response_guard',     // What AI must not say
  ESCALATION_TRIGGER: 'escalation_trigger', // When to escalate to human
  TONE: 'tone',                         // Communication style
  LANGUAGE: 'language',                 // Language preferences
  SCOPE_LIMIT: 'scope_limit',          // Topics AI can discuss
} as const;

export type AiPolicyType = (typeof AI_POLICY_TYPES)[keyof typeof AI_POLICY_TYPES];
