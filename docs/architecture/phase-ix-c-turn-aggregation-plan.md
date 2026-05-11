# Phase IX-C — Conversation Turn Aggregation

> **Status**: Approved — ready for Phase IX-C implementation prompt.
> **Depends on**: Phase IX-A (usage ledger), Phase IX-B (fallback ladder)
> **Migration**: `00029_conversation_turn_aggregation.sql`
> **Test file**: `test/foundation/16_turn_aggregation.test.ts`

---

## 1. Executive Summary

### Problem

Customers frequently send fragmented messages in rapid bursts:

```
"سلام"           → 0s
"خوب هستین؟"     → 2s
"سفارش من"       → 4s
"آماده نشد؟"     → 6s
```

Without turn aggregation, the AI runtime would attempt to reply to each fragment individually, causing:
- **Wrong/incomplete answers** — AI responds to "سلام" before seeing the real question
- **Wasted tokens** — 4 AI calls instead of 1
- **Duplicate/conflicting replies** — customer receives 4 separate answers
- **System load** — 4× budget checks, context collections, usage ledger entries

### Solution

Introduce a **conversation turn** abstraction that groups rapid inbound messages into a single logical customer turn before AI processing. The existing `message_windows` table (00007/00018) provides time-based batching but lacks turn semantics, status tracking, and idempotent processing guarantees needed for AI integration.

### Key Design Decision

**Evolve existing `message_windows` into `conversation_turns` rather than replacing it.** The `message_windows` table was a prototype for this exact problem (15s configurable window, message counting). Phase IX-C formalizes it with proper status lifecycle, message-to-turn mapping, and AI-processing integration while preserving backward compatibility.

---

## 2. Current-State Inventory

### Message Model (`messages` — 00007)

| Field | Type | Notes |
|---|---|---|
| id | UUID PK | |
| conversation_id | UUID FK | |
| direction | `message_direction` enum | inbound, outbound |
| sender_type | `message_sender_type` enum | customer, operator, ai, system |
| sender_id | UUID nullable | polymorphic sender |
| content_type | `message_content_type` enum | text, image, audio, video, file, location, template, system_event |
| content | TEXT nullable | text body |
| content_metadata | JSONB | media URLs, template params |
| is_internal | BOOLEAN | operator-only notes |
| external_message_id | TEXT (00018) | dedup for webhook idempotency |
| delivery_status | TEXT (00019) | none, queued, sent, delivered, read, failed |
| created_at | TIMESTAMPTZ | |

### Conversation Model (`conversations` — 00007)

| Field | Type | Notes |
|---|---|---|
| status | `conversation_status` enum | open, assigned, waiting, resolved, closed |
| ai_enabled | BOOLEAN | AI steps back when operator assigns |
| assigned_to | UUID nullable | current operator |
| last_message_at | TIMESTAMPTZ | denormalized |
| message_count | INT | denormalized |

### Existing Message Windows (`message_windows` — 00007, extended 00020)

| Field | Type | Notes |
|---|---|---|
| id | UUID PK | |
| conversation_id | UUID FK | |
| window_start | TIMESTAMPTZ | |
| window_end | TIMESTAMPTZ | sliding window boundary |
| message_count | INT | |
| summary | TEXT nullable | AI-generated summary (unused) |
| tokens_used | INT nullable | summary token count (unused) |
| processed | BOOLEAN (00020) | whether AI has processed |
| processed_at | TIMESTAMPTZ (00020) | |

**Key finding**: `ingest_inbound_message()` (00018 L256-282) already creates/extends `message_windows` with a configurable delay from `business_config.response_delay_seconds` (default 15s). This is the existing turn batching primitive.

### Ingestion Flow (`ingest_inbound_message` — 00018)

1. Validate channel → resolve/create customer → find/create conversation
2. Dedup by `external_message_id`
3. Insert message, update conversation counters
4. **Create or extend `message_windows`** (15s default, configurable)
5. Log integration + audit events
6. Return `{ conversation_id, message_id, window_id, ... }`

**Critical**: Ingestion does NOT trigger AI. AI is triggered separately via `release_to_ai_with_reply()`. The window exists but is not consumed by the AI runtime.

### AI Context Flow (`collect_ai_context` — 00020)

- Reads last N messages (default 20) from conversation
- Does NOT distinguish messages vs turns
- Does NOT reference `message_windows`
- Safety checks: closed, operator-owned, AI disabled, policy blocked

### `release_to_ai_with_reply` (00025, refactored 00028)

- Delegates state transition to `release_to_ai()`
- Resolves capability binding → budget check → context collection → stub reply → persist → usage ledger
- Does NOT check for pending/finalized turns
- Does NOT prevent duplicate AI replies to same message batch
- IX-B added fallback classification on all failure paths

---

## 3. Phase IX-C Scope

### In Scope

1. **`conversation_turns` table** — formalized turn records with status lifecycle
2. **`conversation_turn_messages` mapping** — which messages belong to which turn
3. **Turn lifecycle RPCs** — get/create pending turn, append message, finalize, mark processed
4. **Integration with `ingest_inbound_message`** — auto-append to pending turn on ingestion
5. **Integration with `release_to_ai_with_reply`** — process finalized turn, prevent duplicates
6. **Turn-aware `collect_ai_context`** — expose current turn in context payload
7. **Aggregation rules** — quiet window, max messages, max chars, direction break
8. **RLS policies** on new tables
9. **Schema validation update** — register new functions
10. **Comprehensive tests** — `16_turn_aggregation.test.ts`

### NOT In Scope

- Real WhatsApp/Web Chat/Instagram/SMS integrations
- Outbox/delivery worker
- Scheduled worker/cron for auto-finalization (primitives only; dispatch deferred)
- Real AI provider calls or API keys
- Frontend UI
- Content policy filtering
- Runtime provider rate limiting (RPM/TPM)
- Fallback ladder changes (IX-B is stable)
- Payment/POS/Delivery
- GitHub issues
- Multimodal content analysis (metadata preserved, not deeply processed)

---

## 4. Design Options Assessment

### Option A — Compute aggregated turn from recent messages at runtime

| Pro | Con |
|---|---|
| No new tables | Race risk: two concurrent AI calls process same messages |
| Simple | No auditability: cannot track which messages were processed together |
| | Cannot mark messages as "processed" durably |
| | No idempotency guarantee |

**Verdict**: ❌ Rejected — unacceptable race and duplicate-reply risk.

### Option B — `conversation_turns` + `conversation_turn_messages` mapping

| Pro | Con |
|---|---|
| Full auditability | Two new tables |
| Idempotent processing | RLS on two tables |
| Turn status lifecycle | Slightly more complex |
| Message-level membership tracking | |
| Future worker/cron compatible | |

**Verdict**: ✅ **Recommended** — best safety, auditability, and extensibility.

### Option C — Add only `turn_id` column to messages

| Pro | Con |
|---|---|
| Simpler schema | Cannot track turn status/finalization without separate table anyway |
| | Harder to enforce unique message membership |
| | Weaker metadata (no aggregated text, no finalization reason) |

**Verdict**: ❌ Rejected — insufficient for status tracking and idempotency.

### Option D — Pending queue table

| Pro | Con |
|---|---|
| Future worker compatible | Overbuilds before outbox/delivery phase |
| | Separate queue + turn = redundant state |

**Verdict**: ❌ Rejected — premature; queue semantics belong in Phase X-B (Outbox).

---

## 5. Proposed Schema

### 5.1 `conversation_turns`

```sql
CREATE TABLE conversation_turns (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  conversation_id     UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  actor_type          TEXT NOT NULL DEFAULT 'customer'
                        CHECK (actor_type IN ('customer', 'operator', 'ai', 'system')),
  direction           TEXT NOT NULL DEFAULT 'inbound'
                        CHECK (direction IN ('inbound', 'outbound')),
  status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN (
                          'pending',      -- accumulating messages
                          'finalized',    -- ready for AI processing
                          'processing',   -- AI is working on it
                          'processed',    -- AI reply completed
                          'skipped',      -- skipped (operator took over, closed, etc.)
                          'superseded'    -- replaced by newer turn
                        )),
  first_message_id    UUID REFERENCES messages(id),
  last_message_id     UUID REFERENCES messages(id),
  message_count       INT NOT NULL DEFAULT 0,
  total_characters    INT NOT NULL DEFAULT 0,
  aggregated_text     TEXT,               -- concatenated text snapshot at finalization
  aggregated_metadata JSONB NOT NULL DEFAULT '{}',
  finalized_reason    TEXT,               -- quiet_window, max_messages, max_chars, direction_break,
                                          -- operator_takeover, manual, state_change
  finalized_at        TIMESTAMPTZ,
  processed_at        TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_turns_conversation_status
  ON conversation_turns(conversation_id, status, created_at DESC);
CREATE INDEX idx_turns_business_date
  ON conversation_turns(business_id, created_at DESC);
CREATE INDEX idx_turns_pending
  ON conversation_turns(conversation_id, status)
  WHERE status = 'pending';

-- Enforces exactly one pending turn per conversation+actor+direction.
-- Enables safe INSERT ... ON CONFLICT in get_or_create_pending_turn.
-- Scoped by conversation_id (which belongs to one business), so
-- business_id is not needed in this index — it remains on the table for RLS.
CREATE UNIQUE INDEX uq_one_pending_customer_turn
  ON conversation_turns(conversation_id, actor_type, direction)
  WHERE status = 'pending';

CREATE TRIGGER trg_turns_updated_at
  BEFORE UPDATE ON conversation_turns
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
```

### 5.2 `conversation_turn_messages`

```sql
CREATE TABLE conversation_turn_messages (
  turn_id           UUID NOT NULL REFERENCES conversation_turns(id) ON DELETE CASCADE,
  message_id        UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  business_id       UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  conversation_id   UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sequence_index    INT NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (turn_id, message_id),
  CONSTRAINT uq_message_one_turn UNIQUE (message_id),
  CONSTRAINT uq_turn_sequence UNIQUE (turn_id, sequence_index)
);

CREATE INDEX idx_turn_messages_conversation
  ON conversation_turn_messages(conversation_id);
CREATE INDEX idx_turn_messages_business
  ON conversation_turn_messages(business_id);
```

**Key constraints**:
- `UNIQUE(message_id)` — a message can belong to exactly one turn
- `UNIQUE(turn_id, sequence_index)` — ordered within turn
- `business_id` on both tables for RLS without joins

---

## 6. Proposed RPC / Function Contract

### 6.1 `get_or_create_pending_turn(p_conversation_id UUID, p_actor_type TEXT DEFAULT 'customer', p_direction TEXT DEFAULT 'inbound')`

- **Access**: SECURITY DEFINER (internal)
- **Behavior**: Returns existing pending inbound customer turn for conversation, or creates one
- **Constraint**: Only one pending turn per conversation+actor_type+direction at a time, enforced by `uq_one_pending_customer_turn` unique partial index
- **Concurrency strategy** (explicit):
  1. `SELECT ... FROM conversation_turns WHERE conversation_id = p_conversation_id AND actor_type = p_actor_type AND direction = p_direction AND status = 'pending' FOR UPDATE` — acquires row lock on existing pending turn. Competing concurrent calls **wait** (do NOT use `SKIP LOCKED` here — we want all concurrent inbound messages to serialize on the same pending turn, not skip and create duplicates).
  2. If found, return the locked row.
  3. If not found, `INSERT INTO conversation_turns (...) VALUES (...) ON CONFLICT ON CONSTRAINT uq_one_pending_customer_turn DO NOTHING RETURNING *` — handles race where another transaction inserted between our SELECT and INSERT.
  4. If INSERT returned no row (conflict), re-`SELECT ... FOR UPDATE` the existing pending turn.
  5. Validate that `conversation_id` belongs to the expected `business_id` before any write.
- **Idempotency**: Safe under concurrent inbound message ingestion — always returns exactly one pending turn per conversation+actor+direction.
- **Returns**: `{ turn_id, status, message_count, created_at }`

### 6.2 `append_message_to_turn(p_message_id UUID)`

- **Access**: SECURITY DEFINER (internal)
- **Behavior**:
  - Validates message is inbound customer message
  - Gets or creates pending customer turn for the message's conversation
  - Appends message to turn (idempotent if already attached)
  - Updates `message_count`, `total_characters`, `last_message_id`
  - Auto-finalizes if max messages or max characters exceeded
- **Race safety**: `UNIQUE(message_id)` prevents double-attach; `ON CONFLICT DO NOTHING`
- **Returns**: `{ turn_id, message_count, auto_finalized, finalized_reason }`

### 6.3 `finalize_conversation_turn(p_turn_id UUID, p_reason TEXT DEFAULT 'manual')`

- **Access**: SECURITY DEFINER (internal/public with auth)
- **Behavior**:
  - Marks pending turn → finalized
  - Freezes `aggregated_text` by concatenating all turn messages in order
  - Sets `finalized_at`, `finalized_reason`
  - No-op if already finalized/processed/skipped
- **Returns**: `{ turn_id, status, message_count, aggregated_text_length }`

### 6.4 `finalize_due_turns(p_quiet_window_seconds INT DEFAULT 10, p_business_id UUID DEFAULT NULL)`

- **Access**: SECURITY DEFINER (internal — future worker/cron entry point)
- **Behavior**:
  - Finds pending turns where `updated_at + quiet_window < now()`
  - Finalizes each with reason `quiet_window`
  - Optional business_id filter for per-tenant processing
- **Returns**: `{ finalized_count, turn_ids[] }`
- **Note**: This is the DB primitive only. Actual scheduled invocation deferred to outbox/worker phase.

### 6.5 `get_finalized_turn_for_ai(p_conversation_id UUID)`

- **Access**: SECURITY DEFINER (internal)
- **Behavior**:
  - Returns oldest finalized (unprocessed) customer turn for conversation
  - If no finalized turn exists, checks for pending turn and auto-finalizes if quiet window elapsed
  - Returns NULL if no turn available
- **Concurrency strategy** (explicit — prevents duplicate AI processing):
  1. `SELECT ... FROM conversation_turns WHERE conversation_id = p_conversation_id AND actor_type = 'customer' AND direction = 'inbound' AND status = 'finalized' ORDER BY finalized_at ASC LIMIT 1 FOR UPDATE` — acquires exclusive row lock on the oldest finalized turn.
  2. **Atomically** update the locked row: `UPDATE conversation_turns SET status = 'processing' WHERE id = v_turn_id AND status = 'finalized'` — this guarantees a second concurrent `release_to_ai_with_reply` cannot receive the same turn.
  3. If no finalized turn found, check for pending turn where `updated_at + quiet_window < now()` and auto-finalize it, then apply the same `FOR UPDATE` + `processing` transition.
  4. Return the turn payload with `status = 'processing'` or NULL if no turn available.
- **Guarantee**: Two concurrent `release_to_ai_with_reply` calls will never process the same turn. The first caller locks and transitions to `processing`; the second caller sees no `finalized` turns remaining.
- **Returns**: `{ turn_id, aggregated_text, message_count, message_ids[], first_message_at, last_message_at }` or NULL

### 6.6 `mark_turn_processed(p_turn_id UUID, p_ai_message_id UUID DEFAULT NULL, p_usage_id UUID DEFAULT NULL)`

- **Access**: SECURITY DEFINER (internal)
- **Behavior**:
  - Marks processing → processed (primary path)
  - Sets `processed_at`, stores `ai_message_id` and `usage_id` in `aggregated_metadata`
  - Idempotent: no-op if already processed
  - **Rejects** if turn is still pending (must finalize first)
- **Failure/fallback handling**: If `release_to_ai_with_reply` fails after `get_finalized_turn_for_ai` locked a turn as `processing`:
  - IX-B fallback paths should call `mark_turn_processed` with error metadata to transition processing → processed (with error info in `aggregated_metadata`), OR
  - A cleanup function can reset stale `processing` turns (older than e.g. 5 minutes) back to `finalized` for retry. This is a safety net, not the primary path.
  - IX-C will implement the simpler path: always mark processed on both success and failure, storing outcome in `aggregated_metadata`. This avoids orphaned `processing` turns.
- **Returns**: `{ turn_id, status, processed_at }`

### 6.7 `skip_pending_turns_for_conversation(p_conversation_id UUID, p_reason TEXT)`

- **Access**: SECURITY DEFINER (internal)
- **Behavior**: Marks all pending turns for conversation as `skipped`
- **Use case**: Operator takeover, conversation close, AI disabled
- **Returns**: `{ skipped_count }`

---

## 7. Aggregation Rules

### 7.1 Quiet Window

| Parameter | Default | Source | Notes |
|---|---|---|---|
| `quiet_window_seconds` | 10 | Function parameter / constant | Matches existing `message_windows` pattern |
| Business override | Via `business_config.response_delay_seconds` | Already exists in `businesses.business_config` | Used by `ingest_inbound_message` today |

**Decision**: Use existing `business_config.response_delay_seconds` for per-business quiet window. Default 10s (reduced from current 15s for better responsiveness). No new config table needed in IX-C.

### 7.2 Max Aggregation Window

| Parameter | Default | Notes |
|---|---|---|
| `max_turn_age_seconds` | 60 | From first message in turn. Prevents indefinite accumulation |

### 7.3 Max Messages Per Turn

| Parameter | Default | Notes |
|---|---|---|
| `max_messages_per_turn` | 10 | Auto-finalizes when reached |

### 7.4 Max Characters Per Turn

| Parameter | Default | Notes |
|---|---|---|
| `max_chars_per_turn` | 4000 | ~1000 tokens. Auto-finalizes when reached |

### 7.5 Direction Break

- **Outbound message** (operator/AI reply) → finalize any pending inbound customer turn with reason `direction_break`
- **New customer message after AI/operator reply** → starts a new pending turn

### 7.6 Conversation State Break

- `assigned_to` set (operator takeover) → skip pending turns with reason `operator_takeover`
- Conversation closed/resolved → skip pending turns with reason `state_change`
- AI disabled → skip pending turns with reason `ai_disabled`

### 7.7 Multimodal

- Image/audio/video/file/location messages are appended to turns normally
- `content_metadata` preserved in turn message mapping
- `aggregated_text` includes text content only; non-text messages represented as `[image]`, `[audio]`, etc.
- No deep multimodal analysis in IX-C

---

## 8. AI Runtime Integration

### 8.1 `ingest_inbound_message` Integration

**Approach**: Append to turn inside `ingest_inbound_message` after message insert.

```
Step 6: Insert message → v_message_id
Step 6b (NEW): append_message_to_turn(v_message_id)  -- auto-creates pending turn
Step 7: Update conversation counters (existing)
Step 8: Message window (existing — preserved for backward compat)
```

**Rationale**: Coupling turn creation to ingestion ensures every inbound customer message is captured. The alternative (lazy aggregation at AI runtime) risks missing messages and complicates race handling.

**Backward compatibility**: Existing `message_windows` logic is preserved (not removed). Both coexist during transition. Future migration can deprecate `message_windows` once turn system is proven.

### 8.2 `collect_ai_context` Enhancement

Add `current_turn` to context payload:

```json
{
  "conversation": { ... },
  "customer": { ... },
  "messages": [ ... ],
  "current_turn": {
    "turn_id": "uuid",
    "aggregated_text": "سلام خوب هستین؟ سفارش من آماده نشد؟",
    "message_count": 4,
    "message_ids": ["uuid1", "uuid2", "uuid3", "uuid4"]
  },
  "ai_policy": { ... },
  "safe": true
}
```

`messages` array continues to include recent messages for broader context. `current_turn` provides the specific aggregated input for the current AI response.

### 8.3 `release_to_ai_with_reply` Integration

**Modified flow** (signature unchanged):

```
Step 1: release_to_ai() — state transition (unchanged)
Step 1b (NEW): Finalize any pending turns for conversation (quiet window check)
Step 1c (NEW): Get finalized unprocessed turn
             → If no turn available, return success with ai_reply.skipped=true, reason='no_pending_turn'
Step 1d (NEW): Mark turn as 'processing'
Step 2: Resolve capability binding (unchanged)
Step 3: Budget check (unchanged)
Step 4: collect_ai_context — now includes current_turn (enhanced)
Step 5-6: Generate + persist reply (unchanged)
Step 6b (NEW): mark_turn_processed(turn_id, message_id, usage_id)
Step 7: Record usage — add turn_id to metadata (enhanced)
Step 8: Return success (unchanged shape)
```

**Duplicate prevention**: `mark_turn_processed` ensures a processed turn cannot be processed again. If `release_to_ai_with_reply` is called twice, the second call gets no finalized unprocessed turn and returns `no_pending_turn`.

### 8.4 `ai_usage_ledger` Integration

- Store `turn_id` in existing `metadata` JSONB field
- No schema column change needed
- Example: `metadata: { "turn_id": "uuid", "turn_message_count": 4 }`

### 8.5 `handoff_events` — No Change

Turn finalization does not create handoff events. Operator takeover skips pending turns but uses existing `assign_conversation` / `takeover_conversation` flows unchanged.

---

## 9. Authorization / RLS Plan

### `conversation_turns`

```sql
ALTER TABLE conversation_turns ENABLE ROW LEVEL SECURITY;

-- Members can read turns for their business
CREATE POLICY members_read_turns ON conversation_turns
  FOR SELECT USING (is_business_member(business_id));

-- Internal functions handle writes via SECURITY DEFINER
-- No direct INSERT/UPDATE/DELETE policies for end users
```

### `conversation_turn_messages`

```sql
ALTER TABLE conversation_turn_messages ENABLE ROW LEVEL SECURITY;

-- Members can read turn-message mappings for their business
CREATE POLICY members_read_turn_messages ON conversation_turn_messages
  FOR SELECT USING (is_business_member(business_id));
```

**Design notes**:
- All write operations through SECURITY DEFINER RPCs with internal auth checks
- `business_id` on both tables avoids joining to conversations for RLS (prevents recursion)
- Non-members see empty results (not errors) — consistent with existing RLS pattern
- No `business_memberships` recursion risk — uses `is_business_member()` helper

---

## 10. Default / Configuration Strategy

| Setting | Default | Storage | Per-Business in IX-C? |
|---|---|---|---|
| Quiet window (seconds) | 10 | `business_config.response_delay_seconds` | ✅ Already exists |
| Max turn age (seconds) | 60 | Function constant | ❌ Deferred |
| Max messages per turn | 10 | Function constant | ❌ Deferred |
| Max chars per turn | 4000 | Function constant | ❌ Deferred |

**Strategy**: Constants in function bodies for max age/messages/chars. Per-business quiet window via existing `business_config`. Future phases can move constants to `business_ai_settings` or `policy_rules` when UI is available. Existing businesses are unaffected — turn aggregation activates only when `ingest_inbound_message` is called (which already happens).

---

## 11. Test Plan

### File: `test/foundation/16_turn_aggregation.test.ts`

| # | Test | Category |
|---|---|---|
| 1 | Inbound message creates pending customer turn | Unit |
| 2 | Multiple inbound messages aggregate into one pending turn | Unit |
| 3 | Messages from different conversations create different turns | Isolation |
| 4 | Messages from different businesses cannot mix in turns | Tenant isolation |
| 5 | Same message cannot be added to turn twice (idempotent) | Idempotency |
| 6 | Max message limit auto-finalizes turn | Aggregation rule |
| 7 | Max character limit auto-finalizes turn | Aggregation rule |
| 8 | finalize_due_turns finalizes quiet-window-expired turns | Finalization |
| 9 | Outbound operator reply skips pending inbound turn | Direction break |
| 10 | release_to_ai_with_reply processes finalized turn once | E2E |
| 11 | Duplicate release_to_ai_with_reply does not create duplicate AI replies | Idempotency |
| 12 | release_to_ai_with_reply records turn_id in usage ledger metadata | Integration |
| 13 | Operator-owned conversation respects existing AI context rules | Compat |
| 14 | Non-member denied turn read | Auth |
| 15 | RLS prevents cross-tenant turn visibility | RLS |
| 16 | collect_ai_context includes current_turn | Integration |
| 17 | Turn with mixed content types aggregates text correctly | Multimodal |
| 18 | Existing 10/14/15 AI tests still pass (regression) | Regression |

**Setup**: Uses existing `withRollback`, `createTestUser`, `createTestBusiness`, `createMembership`, `asUser`, `asServiceRole` helpers. No frontend dependency. No hardcoded global test count.

---

## 12. Migration Plan

### File: `00029_conversation_turn_aggregation.sql`

**Single migration** containing:
1. `conversation_turns` table + indexes + trigger
2. `conversation_turn_messages` table + indexes + constraints
3. RLS policies + grants
4. `get_or_create_pending_turn()`
5. `append_message_to_turn()`
6. `finalize_conversation_turn()`
7. `finalize_due_turns()`
8. `get_finalized_turn_for_ai()`
9. `mark_turn_processed()`
10. `skip_pending_turns_for_conversation()`
11. Modified `ingest_inbound_message()` — add `append_message_to_turn` call
12. Modified `collect_ai_context()` — add `current_turn` to output
13. Modified `release_to_ai_with_reply()` — turn-aware processing

**Existing migrations remain untouched.** All changes are CREATE OR REPLACE or additive.

### Schema validation update

`01_schema_validation.test.ts` must register:
- Tables: `conversation_turns`, `conversation_turn_messages`
- Functions: `get_or_create_pending_turn`, `append_message_to_turn`, `finalize_conversation_turn`, `finalize_due_turns`, `get_finalized_turn_for_ai`, `mark_turn_processed`, `skip_pending_turns_for_conversation`

---

## 13. Compatibility / Regression Plan

| Concern | Mitigation |
|---|---|
| `ingest_inbound_message` return shape | Preserved — `window_id` still returned. Add `turn_id` additively |
| `collect_ai_context` return shape | Preserved — `current_turn` is additive field |
| `release_to_ai_with_reply` signature | Unchanged: `(UUID) RETURNS JSONB` |
| `release_to_ai_with_reply` success response | Same shape. `turn_id` in metadata only |
| `release_to_ai_with_reply` fallback/error responses | Unchanged — IX-B fallback paths preserved |
| IX-A budget enforcement | Unchanged — budget check still happens before AI call |
| IX-B fallback classification | Unchanged — `classify_ai_fallback` is IMMUTABLE |
| `message_windows` table | Preserved (not removed). Coexists with `conversation_turns` |
| Existing tests 01-15 | Must all pass without modification |
| Handoff/re-entry behavior | Unchanged — `release_to_ai()` delegation preserved |

---

## 14. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Duplicate AI replies due to race** | High | `UNIQUE(message_id)` on turn_messages + `mark_turn_processed` idempotency + `processing` intermediate status |
| **Locking/concurrency on pending turn** | Medium | `SELECT ... FOR UPDATE` (wait, not skip) + `INSERT ... ON CONFLICT` on `uq_one_pending_customer_turn` partial unique index. Concurrent inbound messages serialize on the same pending turn. |
| **Delaying AI response too much** | Medium | Default quiet window 10s (not 30s). Max turn age 60s hard cap |
| **Aggregating unrelated messages** | Low | Direction break rule resets turns. Operator takeover skips pending turns |
| **Messages crossing operator takeover** | Medium | `assign_conversation` calls `skip_pending_turns_for_conversation` |
| **No worker/scheduler yet** | Low | `finalize_due_turns()` is callable as DB primitive. `release_to_ai_with_reply` auto-finalizes on demand. Scheduled invocation deferred to outbox phase |
| **RLS recursion** | Low | `business_id` directly on turn tables — no join to conversations for RLS |
| **Future multimodal support** | Low | Non-text messages stored with `[type]` placeholder in aggregated_text. Metadata preserved |
| **Over-coupling turns to AI** | Low | Turn is a conversation domain concept (actor_type, direction). Not AI-specific |
| **Per-channel timing differences** | Low | Channel-neutral design. Per-business quiet window via existing config |

---

## 15. Open Questions

> [!IMPORTANT]
> **Q1**: Should `release_to_ai_with_reply` return `no_pending_turn` as a success with `ai_reply.skipped=true`, or as a new error type in the fallback ladder? Recommendation: success with `skipped=true` and `reason='no_pending_turn'` — this is not an error, it's a valid state.

> [!IMPORTANT]
> **Q2**: Should `assign_conversation` and `takeover_conversation` be modified in this migration to call `skip_pending_turns_for_conversation`, or should that integration be deferred? Recommendation: include it — operator takeover must prevent AI from processing a turn that the operator is now handling.

> [!NOTE]
> **Q3**: Should the existing `message_windows` table be deprecated (soft) in IX-C or left untouched until a future cleanup phase? Recommendation: leave untouched — both coexist. `message_windows` can be deprecated when turn system is proven in production.

> [!NOTE]
> **Q4**: Default quiet window: 10s vs 15s? Current `message_windows` uses 15s. Recommendation: 10s for better perceived responsiveness, but respect existing `business_config.response_delay_seconds` if set.

---

## 16. Implementation Prompt Outline

The implementation should follow this sequence:

1. **Schema**: Create `conversation_turns` + `conversation_turn_messages` with all constraints and indexes
2. **RLS**: Enable RLS, create read policies for members
3. **Core RPCs**: `get_or_create_pending_turn`, `append_message_to_turn`, `finalize_conversation_turn`
4. **Finalization RPCs**: `finalize_due_turns`, `get_finalized_turn_for_ai`, `mark_turn_processed`, `skip_pending_turns_for_conversation`
5. **Integration**: Modify `ingest_inbound_message` to call `append_message_to_turn`
6. **Integration**: Modify `collect_ai_context` to include `current_turn`
7. **Integration**: Modify `release_to_ai_with_reply` for turn-aware processing
8. **Integration**: Modify `assign_conversation` and `takeover_conversation` to skip pending turns
9. **Tests**: `16_turn_aggregation.test.ts` — all 18 test cases
10. **Schema validation**: Register new tables and functions in `01_schema_validation.test.ts`
11. **Verification**: Full suite (all 15+ test files pass), typecheck, security scan
