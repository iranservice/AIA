// ============================================================
// Knowledge / AI Config Domain — Types & Constants
//
// Owns: knowledge bases, entries (FAQ, menu, business data),
// AI policies, prompt templates, prompt testing,
// versioning foundation.
//
// Boundary: Knowledge owns what the AI knows and how it behaves.
//           AI Runtime owns the inference execution.
//           These two responsibilities must not be mixed.
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../lib/types';

export const KNOWLEDGE_DOMAIN = 'knowledge' as const;

// ── Knowledge Entry Types ───────────────────────────────────

export const KNOWLEDGE_ENTRY_TYPES = [
  'faq',               // Question/answer pair
  'menu_item',         // Menu/catalog item
  'business_info',     // Operating hours, location, policies
  'procedure',         // Step-by-step procedures
  'policy',            // Business rules and policies
  'custom',            // Custom knowledge entry
] as const;
export type KnowledgeEntryType = (typeof KNOWLEDGE_ENTRY_TYPES)[number];

// ── Entity Types ────────────────────────────────────────────

/** Knowledge base — container for entries */
export interface KnowledgeBase {
  id: UUID;
  business_id: UUID;
  name: string;
  description: string | null;
  is_active: boolean;
  version: number;
  entry_count: number;
  last_updated_at: Timestamp;
  created_at: Timestamp;
  updated_at: Timestamp;
}

/** Individual knowledge entry */
export interface KnowledgeEntry {
  id: UUID;
  knowledge_base_id: UUID;
  entry_type: KnowledgeEntryType;
  title: string;
  content: string;
  metadata: JsonObject;          // type-specific: price, category, etc.
  tags: string[];
  embedding_vector: number[] | null; // for semantic search (future)
  is_active: boolean;
  version: number;
  created_at: Timestamp;
  updated_at: Timestamp;
}

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
