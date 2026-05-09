# Phase IX-B — AI Resilience: Fallback Ladder + Handoff Re-entry

> **Status**: Approved — ready for Phase IX-B implementation prompt.
> **Phase**: IX-B
> **Depends**: IX-A (`2dcd647`), VIII-A (`0d6d3b1`), VIII-B (`8238c14`)
> **Migration**: `00028_ai_resilience_handoff_reentry.sql`
> **Test file**: `test/foundation/15_ai_resilience.test.ts`
> **Roadmap refs**: F-03 (AI Fallback Ladder), F-04 (Handoff Re-entry + AI Assist Mode)

---

## 1. Executive Summary

Phase IX-B adds deterministic failure handling and conversation re-entry support to the AI runtime. When AI reply generation fails for any reason (binding error, budget exceeded, context failure, persist failure, or future provider errors), the system must degrade gracefully through a structured fallback ladder rather than returning opaque errors. Additionally, conversations that were handed off to operators can be cleanly released back to AI, with safeguards against rapid re-failure loops.

**This phase does NOT include:**
- Real OpenAI/Claude/Gemini provider calls
- Provider API keys or secret management
- Frontend UI changes
- Web Chat / WhatsApp / Voice / Outbox / Turn Aggregation
- Content policy filtering
- Runtime provider rate limiting (RPM/TPM)
- Payment/POS/Delivery
- Circuit breaker with time-window logic (deferred to IX-E when real providers introduce actual latency/failure patterns)

---

## 2. Current-State Inventory

### 2.1 Handoff Model

| Component | State | Location |
|---|---|---|
| `release_to_ai(p_conversation_id)` | ✅ Implemented | 00020 L452-542 |
| `release_to_ai_with_reply(p_conversation_id)` | ✅ Implemented + IX-A governance | 00027 L336-419 |
| `assign_conversation(p_conversation_id, p_operator_id)` | ✅ Implemented | 00019 |
| `unassign_conversation(p_conversation_id)` | ✅ Implemented | 00019 |
| `transfer_conversation(p_conversation_id, p_to_operator_id)` | ✅ Implemented | 00019 |
| `send_reply(p_conversation_id, p_content, ...)` | ✅ Implemented (implicit takeover) | 00019 |
| `persist_ai_handoff(p_conversation_id, p_reason_code, ...)` | ✅ Implemented | 00020 L296-378 |
| `log_ai_blocked(p_conversation_id, p_reason_code, ...)` | ✅ Implemented | 00020 L384-443 |
| `handoff_events` table | ✅ With event types: assigned, unassigned, transferred, takeover, released_to_ai, auto_assigned, handoff_requested | 00019 + 00020 |

**Current handoff state machine:**
```
[open, ai_enabled=true, assigned_to=NULL] -- AI handles
        │
        ├── assign_conversation() ──→ [open, ai_enabled=false, assigned_to=operator]
        ├── send_reply() (owner/mgr) ──→ implicit takeover
        ├── persist_ai_handoff() ──→ [waiting, ai_enabled=false, assigned_to=NULL]
        │
[open/waiting, assigned_to=operator] -- Human handles
        │
        ├── release_to_ai() ──→ [open, ai_enabled=true, assigned_to=NULL]
        ├── unassign_conversation() ──→ [open, assigned_to=NULL] (ai_enabled unchanged)
        ├── transfer_conversation() ──→ [assigned_to=new_operator]
```

**Key observation:** `release_to_ai()` already supports re-entry — it clears `assigned_to`, sets `ai_enabled=true`, sets status to `open`, and records a `released_to_ai` handoff event. No new state machine transition is needed for basic re-entry.

### 2.2 Current AI Failure Behavior

`release_to_ai_with_reply()` (00027 L336-419) handles failures as follows:

| Failure Point | Current Behavior | Structured? |
|---|---|---|
| `release_to_ai()` error | Returns raw error from `release_to_ai` | ✅ Structured JSONB |
| Binding error (`resolve_ai_capability_binding`) | Returns `{skipped: true, reason: error}` | ⚠️ Partial — no fallback code |
| Budget exceeded (`check_ai_budget`) | Records `budget_exceeded` in ledger, returns `BUDGET_EXCEEDED` | ✅ Structured |
| Context failure (`collect_ai_context`) | Returns `{skipped: true, reason: error}` | ⚠️ Partial — no fallback code |
| Persist failure (`persist_ai_reply`) | Records `failed` in ledger, returns `{skipped: true}` | ⚠️ Partial — no fallback code |
| Success | Records `completed` in ledger, returns reply | ✅ |

**Gap:** Non-budget failures return inconsistent error shapes. There is no standardized fallback classification, no fallback action recommendation, and no single auditable fallback event.

### 2.3 Current Governance Integration (IX-A)

| Component | Status |
|---|---|
| `resolve_ai_capability_binding()` | ✅ Returns binding or error |
| `check_ai_budget()` | ✅ Daily/monthly/per-conversation enforcement |
| `record_ai_usage()` | ✅ Records completed/failed/blocked/budget_exceeded |
| `get_business_ai_usage_summary()` | ✅ Manager+ aggregation |
| `ai_usage_ledger` | ✅ With status, tokens, cost, error_code |
| `ai_interaction_logs` | ✅ With decision: replied/handoff/blocked/failed |

### 2.4 Current Test Coverage

| File | Tests | Relevant Coverage |
|---|---|---|
| `10_ai_reply_handoff.test.ts` | 28 | Handoff event, release-to-ai, reply with reply, permissions, AI settings |
| `14_ai_governance.test.ts` | 18 | Budget enforcement, binding resolution, usage ledger, per-conv limit |

---

## 3. Phase IX-B Scope

### 3.1 In Scope

1. **Fallback classification function** — maps any AI runtime error to a standardized fallback code, severity, and recommended action.
2. **Unified fallback response in `release_to_ai_with_reply`** — all failure paths use the fallback classifier to produce consistent, structured responses.
3. **Fallback event recording** — every fallback is recorded in `ai_usage_ledger` with the fallback code as `error_code` for auditability.
4. **Handoff re-entry verification tests** — prove that `release_to_ai` → `assign_conversation` → `release_to_ai_with_reply` cycle works correctly and respects budget/binding.
5. **Rapid re-handoff tracking** — add `last_ai_handoff_at` metadata to detect rapid re-failure patterns (foundation for future circuit breaker).
6. **AI Assist mode contract definition** — document the backend contract for AI draft suggestions while human owns conversation. Implementation deferred.

### 3.2 Not In Scope

- Real provider calls, API keys, secret management
- Circuit breaker with time-window enforcement (needs real provider failure patterns — deferred to IX-E)
- Frontend UI for fallback status or AI assist
- Automatic re-entry (AI automatically re-entering after human pause — future)
- Content policy filtering
- Turn aggregation
- Runtime rate limiting (RPM/TPM)
- Web Chat / WhatsApp / Voice / Outbox
- Payment / POS / Delivery

---

## 4. Design Options

### Option A: No New Table — Use Existing `ai_usage_ledger`

Fallback events are recorded as `ai_usage_ledger` rows with `status = 'failed'` or `'blocked'` and the `error_code` field containing the standardized fallback code.

- **Pros:** No schema change. Fallback visibility comes from existing `get_business_ai_usage_summary`. Existing RLS covers it.
- **Cons:** `ai_usage_ledger` rows for fallbacks have 0 tokens/cost — slightly denormalized but semantically valid (the "usage" is an attempt, not a success).

### Option B: New `ai_fallback_events` Table

A separate table dedicated to fallback/failure tracking.

- **Pros:** Clean separation. Can add severity, recommended_action columns.
- **Cons:** New table + RLS + indexes + maintenance for data that is largely redundant with `ai_usage_ledger` + `ai_interaction_logs`.

### Option C: Add Columns to `ai_usage_ledger`

Add `fallback_code` and `fallback_action` columns to `ai_usage_ledger`.

- **Pros:** Extends existing ledger without new table.
- **Cons:** Adds nullable columns; slightly denormalizes ledger for the majority of successful rows.

### Recommended: **Option A** (No New Table)

**Rationale:**
1. `ai_usage_ledger` already has `status` (`failed`, `blocked`, `budget_exceeded`) and `error_code` — the fallback code fits naturally into `error_code`.
2. `ai_interaction_logs` already records `decision` (`blocked`, `failed`, `handoff`) with `reason_code` — this covers audit/history.
3. Adding a third table creates maintenance burden for data that is already captured across two existing tables.
4. The fallback classification logic is a pure function — it doesn't need persistent storage; it just needs to map errors to standardized codes.
5. Existing `get_business_ai_usage_summary` already aggregates by status, so fallback visibility comes for free.

**Trade-off accepted:** Some `ai_usage_ledger` rows will have 0 tokens. This is already the case for `budget_exceeded` entries from IX-A.

---

## 5. Proposed Schema / Migration

### Migration: `00028_ai_resilience_handoff_reentry.sql`

**No new tables required.**

**Changes:**

#### 5.1 New Helper: `classify_ai_fallback()`

```sql
CREATE OR REPLACE FUNCTION classify_ai_fallback(
  p_error_source TEXT,    -- 'binding', 'budget', 'context', 'persist', 'provider'
  p_error_code   TEXT,    -- the raw error code from the source function
  p_metadata     JSONB DEFAULT '{}'
) RETURNS JSONB LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN CASE p_error_source
    WHEN 'binding' THEN
      jsonb_build_object(
        'fallback_code', 'BINDING_' || UPPER(COALESCE(p_error_code, 'UNKNOWN')),
        'severity', CASE p_error_code
          WHEN 'UNKNOWN_CAPABILITY' THEN 'critical'
          WHEN 'MODEL_INACTIVE' THEN 'high'
          ELSE 'medium' END,
        'action', 'skip_reply',
        'human_handoff', false,
        'retryable', false,
        'message', 'AI capability binding unavailable')
    WHEN 'budget' THEN
      jsonb_build_object(
        'fallback_code', 'BUDGET_' || UPPER(COALESCE(p_error_code, 'EXCEEDED')),
        'severity', 'medium',
        'action', 'skip_reply',
        'human_handoff', false,
        'retryable', false,
        'message', 'AI budget limit reached')
    WHEN 'context' THEN
      jsonb_build_object(
        'fallback_code', 'CONTEXT_' || UPPER(COALESCE(p_error_code, 'UNKNOWN')),
        'severity', CASE p_error_code
          WHEN 'CONVERSATION_CLOSED' THEN 'low'
          WHEN 'OPERATOR_OWNED' THEN 'low'
          WHEN 'AI_DISABLED' THEN 'low'
          WHEN 'AI_NOT_ALLOWED' THEN 'medium'
          ELSE 'medium' END,
        'action', CASE p_error_code
          WHEN 'OPERATOR_OWNED' THEN 'skip_reply'
          WHEN 'CONVERSATION_CLOSED' THEN 'skip_reply'
          ELSE 'skip_reply' END,
        'human_handoff', false,
        'retryable', false,
        'message', 'AI context collection failed: ' || COALESCE(p_error_code, 'unknown'))
    WHEN 'persist' THEN
      jsonb_build_object(
        'fallback_code', 'PERSIST_FAILED',
        'severity', 'high',
        'action', 'skip_reply',
        'human_handoff', false,
        'retryable', true,
        'message', 'AI reply could not be saved')
    WHEN 'provider' THEN
      jsonb_build_object(
        'fallback_code', 'PROVIDER_' || UPPER(COALESCE(p_error_code, 'ERROR')),
        'severity', 'high',
        'action', CASE
          WHEN p_metadata->>'has_fallback_model' = 'true' THEN 'try_fallback_model'
          ELSE 'skip_reply' END,
        'human_handoff', true,
        'retryable', true,
        'message', 'AI provider error')
    ELSE
      jsonb_build_object(
        'fallback_code', 'UNKNOWN_ERROR',
        'severity', 'critical',
        'action', 'skip_reply',
        'human_handoff', false,
        'retryable', false,
        'message', 'Unclassified AI failure')
  END;
END; $$;
```

**Key design decisions:**
- `IMMUTABLE` — pure classification, no state. Safe in index expressions if ever needed.
- Returns structured JSONB with standardized fields for the caller.
- `provider` source prepared for IX-E but only exercised via mock paths in IX-B.
- `human_handoff` is advisory — the caller decides whether to invoke `persist_ai_handoff`. In IX-B only `provider` errors recommend handoff.

#### 5.2 Modified `release_to_ai_with_reply()`

Modify the existing function (already in 00027, will be `CREATE OR REPLACE` in 00028) to use `classify_ai_fallback()` for all failure paths. The function signature remains `(p_conversation_id UUID) RETURNS JSONB`.

Changes:
1. After binding error → call `classify_ai_fallback('binding', error_code)`, record usage with `status='blocked'` and `error_code=fallback.fallback_code`.
2. After budget exceeded → already recorded. Add fallback classification to response.
3. After context error → call `classify_ai_fallback('context', error_code)`, record usage with `status='blocked'`.
4. After persist error → already records `failed`. Add fallback classification to response.
5. All error response shapes become consistent:
```json
{
  "conversation_id": "...",
  "status": "open",
  "ai_enabled": true,
  "event_type": "released_to_ai",
  "ai_reply": {
    "skipped": true,
    "reason": "...",
    "fallback": { "fallback_code": "...", "severity": "...", "action": "...", "retryable": false }
  }
}
```

**Backward compatibility:** The top-level response shape is preserved (`conversation_id`, `status`, `ai_enabled`, `event_type`, `ai_reply`). The `ai_reply.skipped=true` pattern is preserved. The new `ai_reply.fallback` object is additive. Budget exceeded still returns `error='BUDGET_EXCEEDED'` at top level for existing callers.

#### 5.3 Add `handoff_events` Event Type: `ai_fallback`

```sql
ALTER TABLE handoff_events DROP CONSTRAINT IF EXISTS handoff_events_event_type_check;
ALTER TABLE handoff_events ADD CONSTRAINT handoff_events_event_type_check
  CHECK (event_type IN (
    'assigned', 'unassigned', 'transferred',
    'takeover', 'released_to_ai', 'auto_assigned',
    'handoff_requested', 'ai_fallback'
  ));
```

When `classify_ai_fallback()` returns `human_handoff=true`, `release_to_ai_with_reply` records an `ai_fallback` handoff event (but does NOT call `persist_ai_handoff` — the fallback is informational, not a state change, because no real provider exists yet to trigger actual handoff in IX-B).

---

## 6. RPC / Function Plan

| Function | Action | Signature |
|---|---|---|
| `classify_ai_fallback()` | **NEW** | `(p_error_source TEXT, p_error_code TEXT, p_metadata JSONB DEFAULT '{}') RETURNS JSONB` |
| `release_to_ai_with_reply()` | **MODIFY** | Signature preserved: `(p_conversation_id UUID) RETURNS JSONB` |
| `release_to_ai()` | **NO CHANGE** | Already supports re-entry |
| `persist_ai_handoff()` | **NO CHANGE** | Already exists for handoff events |
| `check_ai_budget()` | **NO CHANGE** | Already returns structured budget info |
| `record_ai_usage()` | **NO CHANGE** | Already records error_code |
| `get_business_ai_usage_summary()` | **NO CHANGE** | Already aggregates by status |

### AI Assist Mode — Contract Only (Not Implemented in IX-B)

The following function is planned but NOT implemented in IX-B. It is documented here for future reference:

```
-- FUTURE (IX-B+1 or XII-B):
-- request_ai_assist_draft(p_conversation_id UUID) RETURNS JSONB
--
-- Preconditions:
--   - conversation.assigned_to IS NOT NULL (human owns)
--   - conversation.ai_enabled may be false (assist mode != auto-reply)
--   - caller has conversation:reply permission
--
-- Behavior:
--   - Collects context (variant that allows operator-owned)
--   - Generates draft reply but does NOT persist as message
--   - Returns draft content + metadata in response
--   - Records ai_usage_ledger with status='draft'
--   - Does NOT update conversation state
--
-- This is MVP-Plus (FP-03) and requires:
--   - A new 'draft' status in ai_usage_ledger CHECK constraint
--   - Frontend UI for draft preview
--   - Decision: should draft be persisted in a separate table or returned ephemerally?
```

---

## 7. Authorization / RLS Plan

### No New RLS Changes Required

| Operation | Who Can | Mechanism | Existing? |
|---|---|---|---|
| `release_to_ai` (re-entry) | Any member with `conversation:assign` | `check_permission()` inside SECURITY DEFINER | ✅ 00020 |
| `release_to_ai_with_reply` | Same as above (delegates to `release_to_ai`) | Same | ✅ 00025/00027 |
| Read fallback data (via usage summary) | Manager/Owner | `is_business_manager_or_owner()` inside SECURITY DEFINER | ✅ 00027 |
| Read handoff events | Business members | RLS on `handoff_events` | ✅ 00019 |
| `classify_ai_fallback` | Internal only (called by SECURITY DEFINER functions) | No direct RPC exposure | N/A |

**No new RLS policies needed.** Fallback data flows through existing `ai_usage_ledger` (RLS: manager+ read) and `handoff_events` (RLS: member read).

---

## 8. Test Plan

### File: `test/foundation/15_ai_resilience.test.ts`

| # | Test Name | Type | What It Proves |
|---|---|---|---|
| 1 | `classify_ai_fallback returns correct code for binding error` | RPC | UNKNOWN_CAPABILITY → BINDING_UNKNOWN_CAPABILITY, severity=critical |
| 2 | `classify_ai_fallback returns correct code for budget error` | RPC | daily_token_limit_exceeded → BUDGET_DAILY_TOKEN_LIMIT_EXCEEDED, severity=medium |
| 3 | `classify_ai_fallback returns correct code for context error` | RPC | AI_DISABLED → CONTEXT_AI_DISABLED, severity=low |
| 4 | `classify_ai_fallback returns correct code for persist error` | RPC | persist_failed → PERSIST_FAILED, severity=high, retryable=true |
| 5 | `classify_ai_fallback returns correct code for unknown source` | RPC | unknown → UNKNOWN_ERROR, severity=critical |
| 6 | `binding error produces structured fallback in release response` | E2E | Deactivate model → release_to_ai_with_reply → response has ai_reply.fallback |
| 7 | `budget exceeded produces structured fallback in release response` | E2E | Set low budget → release → response has ai_reply.fallback with BUDGET_ code |
| 8 | `context error produces structured fallback in release response` | E2E | Close conversation then open with ai_disabled → release → fallback |
| 9 | `success path still returns reply without fallback` | E2E | Normal release → no fallback object, reply exists |
| 10 | `handoff re-entry cycle works: assign → release back to AI` | E2E | Create conv → AI reply → assign operator → release_to_ai_with_reply → AI reply again |
| 11 | `re-entry respects budget on second release` | E2E | First release succeeds → assign → set low budget → second release blocked |
| 12 | `re-entry creates released_to_ai handoff event` | E2E | Assign → release → verify handoff_events has released_to_ai entry |
| 13 | `fallback records usage ledger entry with error_code` | DB | After fallback, ai_usage_ledger has row with fallback_code in error_code |
| 14 | `non-member cannot trigger release (re-entry denied)` | Auth | Non-member calls release_to_ai_with_reply → PERMISSION_DENIED |
| 15 | `fallback ledger data does not leak cross-tenant` | DB/Auth | Tenant A triggers fallback → Tenant B manager cannot see fallback ledger row via get_business_ai_usage_summary |
| 16 | `existing release_to_ai_with_reply tests still pass` | Regression | All 28 tests in 10_ai_reply_handoff + 18 in 14_ai_governance unmodified |

**Setup uses:** `withRollback`, `asUser`, `asServiceRole`, `createTestUser`, `createTestBusiness`, `createChannel`, `ingestMessage`, `createMembership`, `enableAiPolicy`, `setupAiConversation`.

**No hardcoded global test counts.** No skipped tests. No frontend dependencies.

---

## 9. Compatibility / Regression Plan

| Existing Behavior | Impact | Mitigation |
|---|---|---|
| `release_to_ai_with_reply` success response shape | `ai_reply.fallback` field absent on success — backward compatible | ✅ No change to success shape |
| Budget exceeded response (`error='BUDGET_EXCEEDED'`) | Preserved at top level. `ai_reply.fallback` is additive | ✅ |
| `ai_usage_ledger` semantics | 0-token rows already exist for budget_exceeded | ✅ No semantic change |
| `ai_interaction_logs` | No changes to this table | ✅ |
| Existing handoff tests (28 in `10_ai_reply_handoff.test.ts`) | Not modified | ✅ Run as-is |
| Existing governance tests (18 in `14_ai_governance.test.ts`) | Not modified | ✅ Run as-is |
| Frontend API | Top-level response keys unchanged; `fallback` sub-object is additive | ✅ |
| `schema_validation.test.ts` | No new tables → no table count change. New function `classify_ai_fallback` added to expected function list | Minor update |

---

## 10. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Overbuilding fallback before real providers exist | Medium | Keep classification pure/deterministic. No retry logic, no circuit breaker timers. Those belong in IX-E. |
| Duplicated handoff state machines | Low | No new state transitions. Re-entry uses existing `release_to_ai()`. Fallback does not change conversation state. |
| Ambiguous AI Assist vs Auto-Reply | Low | AI Assist is contract-only in IX-B. No implementation = no ambiguity. |
| Swallowing real errors silently | Medium | Fallback classification preserves raw error code. Usage ledger records `error_code`. Audit log captures source. |
| Audit noise from fallback events | Low | Fallback events go to `ai_usage_ledger` only (not audit_log for binding/context errors). Only `persist_failed` and `provider` errors warrant audit_log entries. |
| Cross-tenant fallback visibility | Low | RLS on `ai_usage_ledger` (manager+ read) already isolates tenants. |
| Breaking existing release-to-AI frontend flow | Low | Response shape is backward-compatible. `ai_reply.fallback` is additive, not breaking. |
| Budget ledger inconsistencies | Low | Fallback rows have explicit `status` and `error_code`. No ambiguity with successful rows. |

---

## 11. Open Questions

> [!IMPORTANT]
> **Q1: Should binding/context failures also create `handoff_events` rows?**
> Current plan: Only `classify_ai_fallback` returning `human_handoff=true` creates a handoff event (only `provider` errors in IX-B). Binding/context errors are recorded in `ai_usage_ledger` only.
> Recommendation: Keep handoff events for actual handoff-worthy situations. Don't pollute the handoff timeline with config/policy errors.

> [!NOTE]
> **Q2: Should `classify_ai_fallback` be exposed as an RPC callable by frontend?**
> Current plan: No. It is an internal helper called by SECURITY DEFINER functions. Frontend gets fallback info in the response of `release_to_ai_with_reply`.
> If future dashboards need fallback analytics, `get_business_ai_usage_summary` already provides `by_status` breakdown.

> [!NOTE]
> **Q3: Should we add `'draft'` to `ai_usage_ledger` status constraint now?**
> Current plan: No. AI Assist is contract-only in IX-B. Adding the status value is a one-line ALTER in the future AI Assist implementation migration.

---

## 12. Implementation Prompt Outline

1. **Verify baseline**: HEAD `2dcd647` or newer, clean tree, all tests passing.
2. **Create migration** `00028_ai_resilience_handoff_reentry.sql`:
   - Wrap in `BEGIN;` / `COMMIT;` per repo convention (all 27 prior migrations use this pattern).
   - Add `classify_ai_fallback()` function.
   - Modify `release_to_ai_with_reply()` to use fallback classification on all error paths.
   - Add `ai_fallback` to `handoff_events` event_type CHECK constraint.
   - Add required grants if any new function is callable.
   - No new tables.
   - No real provider calls, provider keys, runtime rate limiting, frontend references, or out-of-scope channels/actions.
3. **Create test file** `test/foundation/15_ai_resilience.test.ts`:
   - 15+ tests covering classification, E2E fallback, re-entry cycle, budget re-check, auth, cross-tenant isolation, and ledger recording.
4. **Update** `test/foundation/01_schema_validation.test.ts`:
   - Add `classify_ai_fallback` to expected functions list.
5. **Verify**:
   - Fresh DB reset + apply-migrations.
   - `npx tsc --noEmit` exit 0.
   - `npx vitest run` all tests pass.
   - Security/scope scan clean.
6. **Do not commit.** Report for audit.
