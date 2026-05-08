# Phase IX-A Implementation Plan — AI Token/Cost Governance + Capability Router

> **Status**: Approved — committed in d3df971; ready for Phase IX-A implementation prompt.
> **Author**: CTO / Backend Architect
> **Date**: 2026-05-06
> **Base commit**: `c685ad0`
> **References**: [Feature Roadmap](../product/feature-roadmap.md) · [Platform Foundation Roadmap](./platform-foundation-roadmap.md)

---

## 1. Executive Summary

Phase IX-A adds **token budget enforcement**, **capability-based model routing**, and **usage ledger** to the AIA platform. This is the single blocking dependency for any real AI provider integration (Phase IX-E).

**Key outcomes:**
1. Every AI call is metered (tokens + estimated cost).
2. Per-business daily/monthly budgets are enforced — AI calls rejected when exhausted.
3. Capabilities (reply, classify, extract) route to configured models.
4. `release_to_ai_with_reply` gains budget preflight and usage recording.
5. All existing backend tests continue to pass.

---

## 2. Current-State Inventory

### 2.1 Existing AI Tables

| Table | Migration | Columns (key) | Tenant-scoped | RLS | Used By |
|---|---|---|---|---|---|
| `ai_agent_configs` | 00013 | business_id, provider_id→provider_registry, model_name, system_prompt, temperature, max_tokens, allowed_actions, is_active | ✅ business_id | Via 00016 | `get_ai_config_for_business()` |
| `ai_interaction_logs` | 00013+00020 | business_id, conversation_id, prompt_tokens, completion_tokens, model_used, decision, reason_code, trigger_type, message_id, provider_name | ✅ business_id | Via 00016 | `persist_ai_reply()`, `persist_ai_handoff()`, `log_ai_blocked()` |

**Assessment**: `ai_interaction_logs` already records token counts per interaction. It is an **audit/event log**, not a usage ledger optimized for aggregation. Phase IX-A will add a dedicated `ai_usage_ledger` for budget enforcement while keeping `ai_interaction_logs` for detailed audit.

### 2.2 Existing Provider Registry

| Aspect | Current State |
|---|---|
| Table | `provider_registry` (00012) with `api_config` JSONB (⚠️ stores secrets) |
| Enums | `provider_type` (ai, sms, email, whatsapp, voice, payment), `provider_scope` (platform, tenant), `provider_health_status` |
| Model binding | ❌ No model catalog — `ai_agent_configs.model_name` is a free text field |
| mock_sql support | ❌ No explicit mock_sql row — `release_to_ai_with_reply` hardcodes 'mock-sql' strings |
| Provider mode lock | ✅ `update_business_ai_settings` rejects non-mock_sql provider_mode |

**Assessment**: Provider registry is designed for external integrations (payment gateways, SMS). Phase IX-A should NOT store AI model catalog in `provider_registry` — that couples AI governance to the general provider system. Instead, create dedicated `ai_model_catalog` and `ai_capability_registry` tables.

### 2.3 Existing Policy Engine

| Aspect | Current State |
|---|---|
| Table | `policy_rules` (00005) — business_id, rule_type (text), rule_config (JSONB), is_active, priority |
| Constraint | `uq_policy_rule UNIQUE (business_id, rule_type)` — one rule per type per business |
| `evaluate_policy()` | Returns `rule_config` JSONB for active rule matching business_id + rule_type |
| `ai_allowed` | Used by `collect_ai_context()`, `release_to_ai()`, `update_business_ai_settings()` |
| Budget policy | ❌ No `ai_budget` rule_type exists |

**Assessment**: `policy_rules` can support a new `ai_budget` rule_type. Budget policy will use `policy_rules` for config storage and a new `check_ai_budget()` function for enforcement against usage ledger aggregates.

### 2.4 Existing Billing/Usage Schema

| Table | Migration | Purpose |
|---|---|---|
| `usage_meters` | 00015 | Period-based counters per business (ai_tokens, messages_sent, etc.) |
| `billing_events` | 00015 | Level A billing events (subscription, overage) |
| `increment_usage_meter()` | 00015 | Atomically increments monthly usage counter |

**Assessment**: `usage_meters` with `meter_type = 'ai_tokens'` is suitable for monthly aggregate counters. Phase IX-A will use `increment_usage_meter()` for aggregate tracking AND add a detailed `ai_usage_ledger` for per-call records. This keeps billing and AI governance loosely coupled.

### 2.5 Existing AI Runtime RPCs

| RPC | Migration | Behavior |
|---|---|---|
| `collect_ai_context()` | 00020 | Validates conversation state, checks `evaluate_policy('ai_allowed')`, returns context JSONB |
| `persist_ai_reply()` | 00020 | Inserts outbound AI message, updates conversation, creates `ai_interaction_logs` entry, integration log, audit log |
| `persist_ai_handoff()` | 00020 | Updates conversation state, creates handoff event, interaction log, audit log |
| `log_ai_blocked()` | 00020 | Records blocked/failed AI attempt in interaction logs + audit |
| `release_to_ai()` | 00020 | Permission check, AI policy check, state transition, handoff event, audit |
| `release_to_ai_with_reply()` | 00025 | Calls `release_to_ai()` → `collect_ai_context()` → generates mock-sql stub → `persist_ai_reply()` |
| `get_business_ai_settings()` | 00026 | Reads `policy_rules` for `ai_allowed`, returns settings JSONB |
| `update_business_ai_settings()` | 00026 | Validates + upserts `policy_rules` for `ai_allowed`, audit log |

### 2.6 Existing TS Service Layer

| File | Purpose |
|---|---|
| `src/domains/ai_runtime/provider.ts` | `AiProvider` interface, `AiProviderInput/Output` types |
| `src/domains/ai_runtime/service.ts` | `AiReplyService` — orchestrates context → provider → persist |
| `src/domains/ai_runtime/mock-provider.ts` | `MockAiProvider` — keyword-driven deterministic mock |

### 2.7 Existing Tests

- **Test file**: `test/foundation/10_ai_reply_handoff.test.ts` — covers AI reply, handoff, blocked, release-to-AI, release-to-AI-with-reply, AI settings CRUD, and auth/deny. Must remain fully passing.
- **Total tests**: Multiple test files across `test/foundation/`. Exact count must be reported by the implementation/audit phase — not hardcoded here.
- **Test pattern**: `withRollback()` transactions, `asUser()`/`asServiceRole()` for auth simulation.

---

## 3. Phase IX-A Scope

### 3.1 In Scope

1. **AI Capability Registry** — catalog of AI capabilities with risk levels
2. **AI Model Catalog** — catalog of available models with token cost metadata
3. **AI Model Bindings** — per-business capability→model mapping
4. **AI Usage Ledger** — per-call usage records (tokens, cost, status, actor)
5. **AI Budget Policy** — per-business daily/monthly token and cost limits
6. **Budget Preflight Check** — blocks AI call before provider invocation if budget exceeded
7. **Integration with `release_to_ai_with_reply`** — add budget check + usage recording
8. **Usage Summary RPC** — owner/manager can read aggregated usage
9. **Tests** — new tests proving budget/capability/binding/authorization behavior

### 3.2 NOT In Scope

- Real OpenAI/Claude/Gemini provider calls (Phase IX-E)
- Provider API keys or secret storage (placeholder `secret_ref` only)
- **Runtime/provider rate limiting** — RPM/TPM throttling, request-per-minute rate limiter, burst limiter, token bucket/leaky bucket, provider retry/backoff. Deferred to Phase IX-E (Controlled Real Provider Adapter) where provider-specific rate limits become relevant. IX-A budget enforcement (daily/monthly token/cost limits) is not the same as provider rate limiting
- Frontend UI (MVP-Plus Phase XII-B)
- WhatsApp/Web Chat/Voice channels
- Outbox/delivery, turn aggregation
- Fallback ladder implementation (Phase IX-B)
- Content policy filtering (Phase IX-E)
- Payment/POS/delivery
- GitHub issues, commit/push

---

## 4. Proposed Data Model

### 4.1 `ai_capability_registry` (new table)

```sql
CREATE TABLE ai_capability_registry (
  code            TEXT PRIMARY KEY,       -- 'reply_drafter', 'intent_classifier', etc.
  display_name    TEXT NOT NULL,
  description     TEXT,
  risk_level      TEXT NOT NULL DEFAULT 'low'
                  CHECK (risk_level IN ('low', 'medium', 'high', 'critical')),
  enabled_default BOOLEAN NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Seed capabilities (MVP):**
- `reply_drafter` (medium) — Primary AI reply generation
- `intent_classifier` (low) — Classify customer intent
- `handoff_decider` (medium) — Decide if human handoff is needed
- `order_extractor` (medium) — Extract order details from conversation
- `appointment_extractor` (medium) — Extract appointment/reservation details
- `summarizer` (low) — Summarize conversation
- `translator` (low) — Translate message content

**Design**: Platform-wide catalog, not tenant-scoped. No RLS needed — read-only reference data.

### 4.2 `ai_model_catalog` (new table)

```sql
CREATE TABLE ai_model_catalog (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_mode       TEXT NOT NULL,          -- 'mock_sql', 'openai', 'anthropic'
  model_code          TEXT NOT NULL UNIQUE,   -- 'mock-sql-v1', 'gpt-4o', 'claude-3-sonnet'
  display_name        TEXT NOT NULL,
  supports_text       BOOLEAN NOT NULL DEFAULT true,
  supports_json       BOOLEAN NOT NULL DEFAULT false,
  supports_vision     BOOLEAN NOT NULL DEFAULT false,
  supports_audio      BOOLEAN NOT NULL DEFAULT false,
  input_token_cost    NUMERIC(12,8) NOT NULL DEFAULT 0,  -- cost per 1 token (USD)
  output_token_cost   NUMERIC(12,8) NOT NULL DEFAULT 0,
  max_input_tokens    INT NOT NULL DEFAULT 4096,
  max_output_tokens   INT NOT NULL DEFAULT 4096,
  is_active           BOOLEAN NOT NULL DEFAULT true,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Seed models:**
- `mock-sql-v1` — provider_mode='mock_sql', cost=0, active=true
- `gpt-4o` — provider_mode='openai', cost set, **active=false** (catalog only, no calls until IX-E)
- `claude-3-5-sonnet` — provider_mode='anthropic', cost set, **active=false**

**Design**: Platform-wide catalog. Real providers exist as disabled rows for cost estimation only. No secrets stored. `provider_mode` is validated against an allowlist.

### 4.3 `ai_model_bindings` (new table)

```sql
CREATE TABLE ai_model_bindings (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  capability_code       TEXT NOT NULL REFERENCES ai_capability_registry(code),
  model_id              UUID NOT NULL REFERENCES ai_model_catalog(id),
  fallback_model_id     UUID REFERENCES ai_model_catalog(id),
  is_enabled            BOOLEAN NOT NULL DEFAULT true,
  max_input_tokens      INT,       -- override model default
  max_output_tokens     INT,       -- override model default
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_binding UNIQUE (business_id, capability_code)
);

CREATE INDEX idx_bindings_business ON ai_model_bindings(business_id);
```

**Design**: Business-scoped. Owner/manager configurable (future). Default bindings created for existing businesses via migration backfill, resolving to `mock-sql-v1`.

### 4.4 `ai_budget_policies` — use `policy_rules` table

Rather than a new table, store budget config in existing `policy_rules` with `rule_type = 'ai_budget'`:

```json
{
  "daily_token_limit": 50000,
  "monthly_token_limit": 1000000,
  "daily_cost_limit_usd": 5.00,
  "monthly_cost_limit_usd": 50.00,
  "per_conversation_token_limit": 5000,
  "hard_limit_enabled": true
}
```

**Design**: Reuses existing `policy_rules` infrastructure + `evaluate_policy()`. Defaults are returned by `check_ai_budget()` when no row exists (safe defaults = generous for mock_sql, restrictive for real providers).

### 4.5 `ai_usage_ledger` (new table)

```sql
CREATE TABLE ai_usage_ledger (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id             UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  conversation_id         UUID REFERENCES conversations(id) ON DELETE SET NULL,
  message_id              UUID REFERENCES messages(id) ON DELETE SET NULL,
  user_id                 UUID,          -- who triggered the AI call (nullable for system-triggered)
  capability_code         TEXT NOT NULL REFERENCES ai_capability_registry(code),
  provider_mode           TEXT NOT NULL,
  model_code              TEXT NOT NULL,
  status                  TEXT NOT NULL CHECK (status IN ('completed','failed','blocked','budget_exceeded')),
  input_tokens            INT NOT NULL DEFAULT 0,
  output_tokens           INT NOT NULL DEFAULT 0,
  total_tokens            INT NOT NULL DEFAULT 0,  -- computed by record_ai_usage RPC
  estimated_cost_usd      NUMERIC(12,6) NOT NULL DEFAULT 0,
  actual_cost_usd         NUMERIC(12,6),
  latency_ms              INT,
  error_code              TEXT,
  metadata                JSONB NOT NULL DEFAULT '{}',
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_usage_business_date ON ai_usage_ledger(business_id, created_at DESC);
CREATE INDEX idx_usage_business_daily ON ai_usage_ledger(business_id, (created_at::date));
CREATE INDEX idx_usage_conversation ON ai_usage_ledger(conversation_id) WHERE conversation_id IS NOT NULL;
CREATE INDEX idx_usage_status ON ai_usage_ledger(business_id, status);
CREATE INDEX idx_usage_user ON ai_usage_ledger(user_id) WHERE user_id IS NOT NULL;
```

**Design**: Source of truth for all AI usage. No raw prompts stored (privacy). No secrets. Every AI run — including blocked and failed — records a ledger entry.

**Field notes**:
- `user_id` — nullable UUID for attribution. Populated from `auth.uid()` when available. No FK to `auth.users` (avoids cross-schema dependency). Not used for cross-tenant access; `business_id` remains the primary tenant scope. For reporting and traceability only.
- `total_tokens` — explicitly computed and written by `record_ai_usage()` RPC as `input_tokens + output_tokens`. Avoids `GENERATED ALWAYS AS ... STORED` syntax for consistency with existing migration style.
- `estimated_cost_usd` — estimated at insert time using model catalog pricing.
- `actual_cost_usd` — nullable; populated when real provider returns actual cost (Phase IX-E). NULL for mock_sql.

---

## 5. Proposed RPC Contract

### 5.1 `resolve_ai_capability_binding(p_business_id, p_capability_code)`

**Returns**: JSONB with capability, model, provider_mode, limits, enabled status.

**Behavior**:
1. Look up `ai_model_bindings` for business + capability
2. If no binding exists, return default: mock-sql-v1 for all capabilities
3. Join with `ai_model_catalog` for cost and limit metadata
4. If model is inactive, return error
5. Internal function (SECURITY DEFINER, no direct RPC exposure)

### 5.2 `check_ai_budget(p_business_id, p_capability_code, p_estimated_tokens)`

**Returns**: JSONB `{allowed: bool, reason?: text, daily_used, monthly_used, daily_limit, monthly_limit}`

**Behavior**:
1. Read budget policy from `evaluate_policy(business_id, 'ai_budget')`
2. If no policy → return `{allowed: true}` (default = no limit for mock_sql)
3. Aggregate today's usage from `ai_usage_ledger` WHERE status='completed'
4. Aggregate this month's usage
5. Check daily token limit, monthly token limit, daily cost limit, monthly cost limit
6. If any limit exceeded → return `{allowed: false, reason: 'daily_token_limit_exceeded'}`
7. Does NOT mutate — pure check
8. Internal function (called by `release_to_ai_with_reply`)

### 5.3 `record_ai_usage(...)` (internal)

**Behavior**:
1. Compute `total_tokens = input_tokens + output_tokens`
2. Compute `estimated_cost_usd` from model catalog pricing × token counts
3. Insert into `ai_usage_ledger` with computed totals, `user_id` from caller context
4. Call `increment_usage_meter(business_id, 'ai_tokens', total_tokens)` for billing aggregate
5. SECURITY DEFINER, internal only
6. Never accepts secrets
7. `user_id` is for attribution only — does not affect tenant scoping

### 5.4 `get_business_ai_usage_summary(p_business_id, p_period)`

**Returns**: JSONB with aggregated usage by capability, model, status for the given period.

**Behavior**:
1. Validate caller is owner/manager of business (or platform admin)
2. Non-member → NULL (silent deny, consistent with `get_business_ai_settings`)
3. Operator → denied (read usage summary requires manager+)
4. Aggregate from `ai_usage_ledger` for the period
5. Return: total_tokens, total_cost, by_capability breakdown, by_status breakdown, budget remaining

### 5.5 Integration: Modified `release_to_ai_with_reply`

Current flow:
```
release_to_ai() → collect_ai_context() → generate stub → persist_ai_reply()
```

New flow:
```
release_to_ai() → collect_ai_context()
  → resolve_ai_capability_binding('reply_drafter')
  → check_ai_budget(estimated_tokens)
  → IF budget_exceeded: record_ai_usage(status='budget_exceeded') + return error
  → generate stub (using resolved model binding)
  → persist_ai_reply()
  → record_ai_usage(status='completed', tokens, cost)
```

**Backward compatibility**: When no budget policy exists (default), `check_ai_budget` returns `{allowed: true}`. Existing behavior is preserved. Existing tests pass without modification.

---

## 6. Authorization / RLS Plan

| Table | RLS | Read | Write | Notes |
|---|---|---|---|---|
| `ai_capability_registry` | No RLS (read-only platform catalog) | All authenticated | Migration only | Platform-managed seed data |
| `ai_model_catalog` | No RLS (read-only platform catalog) | All authenticated | Migration only | Platform-managed; real models are inactive |
| `ai_model_bindings` | Yes | Members of business | Owner/manager | Operator can trigger AI but not change bindings |
| `ai_usage_ledger` | Yes | Owner/manager | Internal (SECURITY DEFINER RPCs only) | Operator cannot read raw usage |
| `policy_rules` (ai_budget) | Existing RLS | Via `get_business_ai_settings` extension | Owner/manager via `update_business_ai_settings` extension | Reuses existing infrastructure |

**Role behavior matrix:**

| Role | read bindings | update bindings | read usage | update budget | trigger AI |
|---|---|---|---|---|---|
| anon | ❌ | ❌ | ❌ | ❌ | ❌ |
| non-member | ❌ | ❌ | ❌ | ❌ | ❌ |
| viewer | ❌ | ❌ | ❌ | ❌ | ❌ |
| operator | ❌ | ❌ | ❌ | ❌ | ✅ (existing release_to_ai) |
| manager | ✅ | ✅ | ✅ | ✅ | ✅ |
| owner | ✅ | ✅ | ✅ | ✅ | ✅ |

---

## 7. Default / Seed Strategy

### Migration backfill:

1. **Capabilities**: Insert 7 capability rows (platform-wide, idempotent).
2. **Models**: Insert `mock-sql-v1` (active) + `gpt-4o` and `claude-3-5-sonnet` (inactive, cost metadata only).
3. **Bindings**: For each existing business in `businesses` table, insert default bindings mapping `reply_drafter` → `mock-sql-v1`. Other capabilities get bindings as they become used.
4. **Budget**: No default `ai_budget` policy_rules row. `check_ai_budget()` treats "no policy" as "unlimited" (safe for mock_sql which has zero cost).

### Future businesses:

- `resolve_ai_capability_binding()` returns virtual defaults (mock-sql-v1) when no binding row exists — no hook needed.
- When Phase IX-D adds business type profiles, the business creation flow will insert type-appropriate bindings.

---

## 8. Test Plan

**File**: `test/foundation/14_ai_governance.test.ts`

| # | Test Name | Setup | Assertion |
|---|---|---|---|
| 1 | Default capabilities exist after migration | None | SELECT from `ai_capability_registry` returns ≥7 rows including `reply_drafter` |
| 2 | mock-sql-v1 model exists and is active | None | SELECT from `ai_model_catalog` WHERE model_code='mock-sql-v1' returns active=true |
| 3 | Default reply_drafter binding resolves for seeded business | Create business | `resolve_ai_capability_binding` returns mock-sql-v1 |
| 4 | Owner can read usage summary | Create business + owner, record usage | `get_business_ai_usage_summary` returns aggregated data |
| 5 | Non-member denied usage summary | Create business, outsider user | `get_business_ai_usage_summary` returns NULL |
| 6 | Operator cannot read usage summary | Create business + operator | `get_business_ai_usage_summary` returns permission error or NULL |
| 7 | Manager can update budget policy | Create business + manager | UPSERT budget policy via `update_business_ai_settings` extended to accept budget keys |
| 8 | Budget exceeded blocks release_to_ai_with_reply | Set daily_token_limit=1, record usage to exhaust, attempt release | Returns `{error: 'BUDGET_EXCEEDED'}` |
| 9 | Budget allowed permits release_to_ai_with_reply | Set generous budget, attempt release | Returns success with ai_reply |
| 10 | release_to_ai_with_reply records ai_usage_ledger entry | Execute release_to_ai_with_reply | `ai_usage_ledger` has row with capability='reply_drafter', status='completed' |
| 11 | Usage summary aggregates correctly | Record multiple usage events | Summary totals match individual records |
| 12 | Unknown capability code rejected | Call resolve with 'nonexistent_capability' | Returns error |
| 13 | Inactive model cannot be bound | Attempt binding to inactive model | Returns error |
| 14 | No API key / secret fields in any new table | Schema inspection | No column named api_key, secret, password in new tables |
| 15 | All existing backend tests still pass | Run full suite | All existing foundation tests pass; exact count reported by implementation |

---

## 9. Migration Plan

### Recommendation: Single migration file

**File**: `supabase/migrations/00027_ai_token_cost_governance.sql`

**Reason**: All schema changes are interdependent (capabilities reference models, bindings reference both, usage references capabilities, budget check references usage+policy). A single migration ensures atomic application.

**Contents**:
1. `ai_capability_registry` table + seed data
2. `ai_model_catalog` table + seed data (mock-sql-v1 active, others inactive)
3. `ai_model_bindings` table + RLS + trigger + backfill for existing businesses
4. `ai_usage_ledger` table + RLS + indexes
5. `resolve_ai_capability_binding()` function
6. `check_ai_budget()` function
7. `record_ai_usage()` function
8. `get_business_ai_usage_summary()` function
9. Modified `release_to_ai_with_reply()` — adds budget check + usage recording
10. Extended `update_business_ai_settings()` — adds budget-related allowed keys

**Wrapped in**: `BEGIN; ... COMMIT;`

---

## 10. Compatibility / Regression Plan

| Existing Behavior | Impact | Mitigation |
|---|---|---|
| `release_to_ai_with_reply` works with no budget policy | ✅ Preserved | `check_ai_budget` returns `{allowed: true}` when no `ai_budget` policy exists |
| AI Settings Contract (`get/update_business_ai_settings`) | ✅ Preserved | Extended with new allowed keys; existing keys unchanged |
| Operator release-to-AI UI behavior | ✅ Preserved | No frontend changes; same RPC signature |
| Existing test bootstrap (apply-migrations.sh) | ✅ Preserved | New migration follows same pattern |
| Local Supabase reset | ✅ Preserved | Migration is idempotent for seed data |
| `ai_interaction_logs` usage | ✅ Preserved | Not modified; `ai_usage_ledger` is additive |
| `increment_usage_meter` | ✅ Preserved | Called by `record_ai_usage` for aggregate billing |

---

## 11. Risk Review

| Risk | Severity | Mitigation |
|---|---|---|
| **Budget check race condition** — two concurrent AI calls may both pass budget check | Medium | Acceptable for MVP; budget is soft limit. Future: SELECT FOR UPDATE or advisory lock |
| **Mock token overcounting** — mock-sql reports arbitrary token counts | Low | mock-sql uses fixed small counts (5 in, 20 out); cost is $0; budget only matters for real providers |
| **Hardcoding provider pricing** | Medium | Store in `ai_model_catalog.input/output_token_cost`; updateable without migration |
| **Coupling usage to billing too early** | Low | `ai_usage_ledger` is the governance source of truth; `usage_meters` is the billing aggregate source. `record_ai_usage` bridges both by calling `increment_usage_meter`. Future billing reads `usage_meters`, not `ai_usage_ledger` directly |
| **RLS recursion** | High | New RLS policies must NOT join `business_memberships` in a way that triggers the recursion fixed in 00024. Use SECURITY DEFINER RPCs (e.g., `is_business_member()`, `is_business_manager_or_owner()`) instead of inline subqueries |
| **SECURITY DEFINER misuse** | Medium | All DEFINER functions validate caller membership internally; never return secret material |
| **Breaking existing AI reply flow** | High | `check_ai_budget` defaults to `{allowed: true}`; all existing tests run as regression suite |
| **Overbuilding provider management** | Medium | No BYOK, no multi-provider routing, no provider health dashboard. Catalog has disabled rows for cost estimation only |
| **user_id privacy** | Low | `user_id` in `ai_usage_ledger` is for attribution/reporting only. Not exposed in public APIs. Not used for cross-tenant access — `business_id` remains primary scope |

---

## 12. Open Questions

1. **Budget defaults for new businesses**: Should new businesses get a default `ai_budget` policy_rules row with generous limits, or should "no policy = unlimited" remain the default? **Recommendation**: No default row; unlimited for mock_sql. When real provider is enabled (IX-E), a budget row is required.

2. **Usage ledger retention**: Should old ledger entries be pruned? **Recommendation**: Not in IX-A. Add archival in Post-MVP when data volume justifies it.

3. **Extend `update_business_ai_settings` or create new RPC for budget?** **Recommendation**: Extend existing RPC with new allowed keys for budget settings. Keeps the API surface small and consistent. New budget keys must be added to the allowlist and validated (e.g., `daily_token_limit` must be positive integer, `hard_limit_enabled` must be boolean).

4. **Runtime rate limiting**: Provider RPM/TPM throttling, burst limiting, and retry/backoff are deferred to Phase IX-E (Controlled Real Provider Adapter). IX-A budget enforcement (daily/monthly limits checked against ledger aggregates) is a fundamentally different mechanism and does not require provider-level rate limiting infrastructure.

---

## 13. Implementation Prompt Outline

When approved, implementation should follow this order:

1. Create migration `00027_ai_token_cost_governance.sql`
   - Tables → Indexes → Constraints → RLS → Triggers → Seed data → Functions
2. Modify `release_to_ai_with_reply()` (CREATE OR REPLACE in same migration)
3. Extend `update_business_ai_settings()` (CREATE OR REPLACE in same migration)
4. Create `test/foundation/14_ai_governance.test.ts`
5. Run full test suite: `npx vitest run`
6. Verify all existing backend tests + new governance tests pass
7. No TS service layer changes required in IX-A (budget check is SQL-level)
8. No frontend changes
9. No runtime/provider rate limiting — deferred to IX-E
