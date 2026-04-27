// ============================================================
// Knowledge Domain — Types & Constants
//
// Owns: knowledge bases, entries (FAQ, menu, business data),
// versioning foundation.
//
// Boundary: Knowledge owns WHAT the AI knows (data).
//           AI Config owns HOW the AI behaves (policies, prompts).
//           AI Runtime owns inference execution.
// ============================================================

import type { UUID, Timestamp, JsonObject } from '../../shared/types';

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
