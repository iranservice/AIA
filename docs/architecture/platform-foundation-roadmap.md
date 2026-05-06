# AIA — Platform Foundation Roadmap

> **Last updated**: 2026-05-06
> **Status**: Finalized — committed in d3ecf91; approved for issue/backlog creation.
> **References**: [Product Definition](../product/product-definition.md) · [MVP Scope](../product/mvp-scope.md) · [Feature Roadmap](../product/feature-roadmap.md)

---

## 1. Architecture Goal

AIA is a **modular monolith** platform built on Supabase (PostgreSQL + Auth + Storage + Edge Functions) that provides AI-powered receptionist capabilities to service businesses.

### Core vs Adapters

```
┌─────────────────────────────────────────────────────┐
│                    AIA Platform Core                 │
│                                                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ Tenancy  │  │Conversa- │  │   AI Runtime     │  │
│  │ + Auth   │  │  tions   │  │ (Capability      │  │
│  │ + RBAC   │  │+ Messages│  │  Router + Policy  │  │
│  │          │  │          │  │  + Governance)    │  │
│  └──────────┘  └──────────┘  └──────────────────┘  │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ Orders + │  │ Action   │  │   Knowledge      │  │
│  │Appoint-  │  │ Engine + │  │   + Content      │  │
│  │ ments    │  │ Approvals│  │   Policy         │  │
│  └──────────┘  └──────────┘  └──────────────────┘  │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ Audit +  │  │ Usage +  │  │   Outbox +       │  │
│  │ Observ-  │  │ Billing  │  │   Delivery       │  │
│  │ ability  │  │Foundation│  │                   │  │
│  └──────────┘  └──────────┘  └──────────────────┘  │
└──────────────────────┬──────────────────────────────┘
                       │ Channel Adapter Interface
          ┌────────────┼────────────┐
          │            │            │
     ┌────▼───┐  ┌────▼───┐  ┌────▼───┐
     │Web Chat│  │WhatsApp│  │ Voice  │
     │Adapter │  │Adapter │  │Adapter │
     └────────┘  └────────┘  └────────┘
                       │ Provider Adapter Interface
          ┌────────────┼────────────┐
          │            │            │
     ┌────▼───┐  ┌────▼───┐  ┌────▼───┐
     │mock-sql│  │ OpenAI │  │Anthro- │
     │(stub)  │  │Adapter │  │pic     │
     └────────┘  └────────┘  └────────┘
```

**Design rule**: Core domains never reference a specific channel or provider. Adapters implement stable interfaces defined by core.

---

## 2. Completed Foundation

The following areas are implemented and committed on `main` (through `326f693`):

| Domain | Commit | Migrations | Status |
|---|---|---|---|
| **Auth + Tenant Context** | `a1d4ec3` | 00001–00005 (extensions, enums, identity, tenancy, RBAC) | ✅ Complete |
| **Customer Schema** | `a1d4ec3` | 00006 | ✅ Complete |
| **Conversations + Messages** | `a1d4ec3` | 00007, 00018 (messaging inbox) | ✅ Complete |
| **Orders** | `a1d4ec3` | 00008, 00021 (order from conversation), 00022 (confirmation) | ✅ Complete |
| **Reservations Schema** | `a1d4ec3` | 00009 | ✅ Schema only (no availability engine) |
| **Tickets Schema** | `a1d4ec3` | 00010 | ✅ Schema only |
| **Action Engine Schema** | `a1d4ec3` | 00011 | ✅ Schema only (no approval workflow) |
| **Provider Registry Schema** | `a1d4ec3` | 00012 | ✅ Schema only |
| **AI Runtime Schema** | `a1d4ec3` | 00013 | ✅ Schema only |
| **Audit Log** | `a1d4ec3` | 00014 | ✅ Complete |
| **Billing Schema** | `a1d4ec3` | 00015 | ✅ Schema only |
| **RLS Policies** | `a1d4ec3`, `19e2128` | 00016, 00024 (recursion fix) | ✅ Complete |
| **Seed Data** | `a1d4ec3` | 00017 | ✅ Complete |
| **Operator Reply** | `a1d4ec3` | 00019 | ✅ Complete |
| **AI Reply + Handoff** | `a1d4ec3`, `0d6d3b1` | 00020, 00025 (release-to-AI with reply) | ✅ Complete (stub provider) |
| **Business Settings + Members** | `11f39b4` | 00023 | ✅ Complete |
| **Auth Mock Separation** | `d80236f` | (moved to test/bootstrap) | ✅ Complete |
| **AI Settings Contract** | `8238c14` | 00026 | ✅ Complete |
| **Product Foundation Docs** | `326f693` | (docs only) | ✅ Complete |

### What "Complete" Means

- **✅ Complete**: RPC exists, tested, RLS verified, audit logging in place.
- **✅ Schema only**: Table/types exist from Phase 0 foundation but no business logic RPCs, no tests, no RLS verification beyond base policies.

---

## 3. Platform Domains

### Domain Boundary Map

| Domain | Responsibility | Current State | Key Tables |
|---|---|---|---|
| **Tenancy / Auth** | User authentication, tenant (business) creation, session management | ✅ Complete | `profiles`, `businesses` |
| **Memberships / Permissions** | Role-based access, team membership, permission checks | ✅ Complete | `business_memberships` |
| **Conversations** | Conversation lifecycle, status management, assignment | ✅ Complete | `conversations`, `messages` |
| **Customers / Identity** | Customer profiles, channel identity, resolution | ⚠️ Schema only | `customers` |
| **AI Runtime** | Capability routing, model binding, prompt management, response generation. Must support Persian/Farsi and English customer conversations as MVP Core; Arabic is MVP-Plus | ⚠️ Stub only (mock-sql) | `ai_interactions`, `provider_registry` |
| **Policy Engine** | Rule evaluation (ai_allowed, content_policy, rate limits) | ⚠️ Partial (evaluate_policy exists) | `policy_rules` |
| **Action Engine** | Action proposal, validation, approval workflow, execution | ⚠️ Schema only | `actions` |
| **Approvals** | Approval queue, manager review, auto-approve rules | ❌ Not started | (part of action engine) |
| **Orders** | Order lifecycle, status transitions, order from conversation | ✅ Complete | `orders`, `order_items` |
| **Appointments / Reservations** | Booking lifecycle, availability, cancellation policy | ⚠️ Schema only | `reservations` |
| **Channels** | Channel adapter interface, inbound/outbound contracts | ❌ Not started | (no adapter tables yet) |
| **Knowledge** | Business FAQ, menu/service data, content indexing | ❌ Not started | (no knowledge tables yet) |
| **Outbox / Delivery** | Outbound message queue, delivery tracking, idempotency | ❌ Not started | (no outbox table yet) |
| **Audit / Observability** | Event logging, audit trail, health checks | ✅ Complete | `audit_log` |
| **Usage / Billing** | Token tracking, cost estimation, budget enforcement | ⚠️ Schema only | `billing` (needs usage_ledger) |

### Domain Communication Rules

1. Domains communicate through **SQL RPCs** (SECURITY DEFINER with internal auth checks).
2. No domain directly queries another domain's tables — use RPCs or views.
3. Cross-domain events are logged in `audit_log`.
4. AI Runtime calls Policy Engine before every AI action.
5. Action Engine calls Policy Engine before executing any proposed action.

---

## 4. Architectural Principles

### AP-1: Modular Monolith First

All domains live in a single Supabase project. Domain boundaries are enforced by convention (separate migration files, separate RPCs, separate test files). Microservice extraction is a future optimization, not a prerequisite.

### AP-2: Channels Are Adapters

All channel-specific logic (WhatsApp message windows, web chat sessions, SMS delivery) is isolated in adapter modules. Core domains (conversations, AI runtime, orders) are channel-agnostic. The channel adapter interface defines:
- `ingest_inbound_message(channel, payload)` — normalize external message to internal format
- `deliver_outbound_message(message_id, channel, payload)` — deliver internal message to external channel
- Channel-specific metadata (delivery receipts, read status, message windows)

### AP-3: Provider Adapters Behind AI Runtime

AI provider calls (OpenAI, Anthropic, etc.) are behind the AI Runtime's provider adapter interface. The runtime selects the provider based on capability + tenant configuration + fallback chain. Core never calls a provider directly.

### AP-4: AI Proposes, Backend Executes

AI generates responses and proposes structured actions. The Action Engine validates proposals against schemas, evaluates policies, and executes (or queues for approval). AI never has direct write access to business data.

### AP-5: Policy Before Action

Every AI call and every action execution passes through the Policy Engine first:
```
Request → Policy Engine (evaluate_policy) → AI Runtime / Action Engine → Audit Log
```

### AP-6: Audit for Sensitive Operations

All state transitions, permission changes, AI interactions, settings updates, and action executions are logged in `audit_log` with:
- Actor (user ID or system)
- Action type and severity
- Old and new state (JSONB)
- Metadata (request context, tenant, timestamp)

### AP-7: No Secrets in Frontend

API keys, service_role tokens, provider credentials, and webhook secrets are stored server-side only. Frontend communicates through Supabase client (anon key + RLS) or authenticated RPCs. No SECURITY DEFINER RPC exposes secret material in its return value.

### AP-8: RLS + Tenant Isolation

Every table with tenant-scoped data has RLS policies enforcing `business_id` isolation. RPCs perform their own membership/role checks internally. Cross-tenant queries return empty results, never errors (preventing information leakage).

### AP-9: Outbox + Idempotency for Outbound

All outbound messages flow through an outbox table:
```
AI/Operator Response → messages table → outbox → delivery worker → channel adapter → external
```
Idempotency keys prevent duplicate delivery on retry. Delivery status is tracked per message.

### AP-10: Usage Ledger for AI

Every AI call records: tenant, capability, model, provider, token count (input + output), estimated cost, latency, and success/failure. The usage ledger is the source of truth for:
- Budget enforcement (reject if over budget)
- Cost reporting (usage dashboard)
- Rate limiting (calls per minute per tenant)
- Billing (Post-MVP)

### AP-11: Business Type Profile-Driven Behavior

AI capabilities, knowledge schemas, content policies, and action schemas are configured per business type (restaurant, clinic, salon). When a business is created with a type, it inherits the type's defaults. Owners can customize within the type's boundaries.

---

## 5. Foundation Gaps

These are the missing pieces between the current completed foundation and a pilotable MVP:

| Gap | Why It Matters | Blocks |
|---|---|---|
| **Token/Cost Governance** | Cannot safely enable real AI provider without budget enforcement | Real provider, any production AI use |
| **Capability Router + Model Binding** | Cannot route different AI tasks to appropriate models | Efficient AI usage, cost optimization |
| **Fallback Ladder** | Provider failure = dead conversation without graceful degradation | Production reliability |
| **Handoff Re-entry State Machine** | Release-to-AI exists but lacks circuit breaker and context-aware re-entry | Operator confidence in AI handoff |
| **Turn Aggregation** | Fragmented messages waste tokens and produce poor AI responses | AI quality, cost efficiency |
| **Customer Identity Resolution** | Same customer on multiple channels appears as separate contacts | Unified customer view, conversation history |
| **Channel Adapter Contract** | No stable interface for adding channels; web chat has no adapter | Web chat widget, WhatsApp adapter |
| **Multimodal Message Parts** | Messages schema doesn't support image/audio/document attachments | Multimodal input handling |
| **Outbox + Idempotency** | No guarantee against duplicate outbound messages | Delivery reliability |
| **Business Type Profiles** | All businesses behave identically; no type-specific AI capabilities | Vertical differentiation |
| **Dynamic Action Schemas** | Action engine schema exists but no validation or approval workflow | AI-proposed actions (booking, reservation) |
| **Appointment/Reservation Logic** | Schema exists but no availability engine or booking RPCs | Clinic and salon verticals |
| **Knowledge Center** | No knowledge storage or retrieval; AI has no business-specific data | AI response quality |
| **Content Policy Engine (Full)** | evaluate_policy exists for ai_allowed but no input/output content filtering | Content safety |
| **Controlled Real Provider Adapter** | `mock-sql` cannot satisfy pilot exit criteria; real provider needed for pilot validation | Pilot readiness, product-market fit |
| **Persian/Farsi Language Support** | Language detection and Persian response generation are MVP Core but not yet implemented in AI runtime | Pilot market readiness (Iran, UAE) |

---

## 6. Dependency Graph

```
Phase IX-A: Token Governance + Capability Router
    └──→ No dependencies (builds on existing AI Settings Contract)

Phase IX-B: Fallback Ladder + Handoff Re-entry
    └──→ Depends on: IX-A (capability router for fallback model selection)

Phase IX-C: Turn Aggregation
    └──→ Depends on: None (can start in parallel with IX-A/IX-B)
    └──→ Note: Needs channel adapter contract eventually, but can prototype with existing message flow

Phase IX-D: Business Type Profiles + Dynamic Actions
    └──→ Depends on: None (builds on existing business settings)
    └──→ Enables: Knowledge Center, Appointment Foundation

Phase X-A: Channel Adapter + Multimodal Contract
    └──→ Depends on: IX-C (turn aggregation interface)

Phase X-B: Outbox + Delivery + Identity Resolution
    └──→ Depends on: X-A (channel adapter for delivery)

Phase X-C: Native Web Chat Widget
    └──→ Depends on: X-A (channel adapter), X-B (outbox), IX-C (turn aggregation)

Phase XI-A: Appointment / Reservation Foundation
    └──→ Depends on: IX-D (business type profiles + dynamic actions)

Phase XI-B: Knowledge / Content Center
    └──→ Depends on: IX-D (business type profiles for knowledge schemas)

Phase XI-C: Usage / Health Visibility
    └──→ Depends on: IX-A (usage ledger data)

Phase IX-E: Content Policy + Controlled Real Provider
    └──→ Depends on: IX-A (governance), IX-B (fallback), IX-D (business type safety defaults)
    └──→ Enables: Real pilot with production AI quality
    └──→ Note: mock-sql remains available as fallback/testing provider

--- MVP-Plus boundary ---

Phase XII-A: Official WhatsApp Adapter
    └──→ Depends on: X-A, X-B, X-C (channel foundation must be proven first)

Advanced Multi-Provider Management (Post-MVP):
    └──→ Depends on: IX-E (controlled provider must be proven first)
```

### Parallelization Opportunities

The following can run in parallel:
- **IX-A** (governance) and **IX-C** (turn aggregation) — independent concerns
- **IX-D** (business profiles) can start after IX-A but parallel with IX-B
- **XI-A** (appointments) and **XI-B** (knowledge) — independent once IX-D is complete
- **IX-E** (content policy + real provider) starts after IX-A, IX-B, and IX-D are complete

---

## 7. Risk Register

| Risk | Severity | Mitigation | Owner |
|---|---|---|---|
| **Scope creep** — Adding features before governance is ready | High | Enforce Phase IX before any real provider or channel adapter | CTO |
| **Cost explosion** — Uncontrolled AI token usage in production | Critical | Token budgets, rate limits, usage ledger (Phase IX-A) | Engineering |
| **Provider downtime** — AI provider unavailable | Medium | Fallback ladder with stub + handoff (Phase IX-B) | Engineering |
| **WhatsApp unofficial instability** — Bridge sessions break | Medium | Labs-only classification; official adapter in MVP-Plus | Engineering |
| **Duplicate outbound messages** — Customer receives same message twice | High | Outbox + idempotency (Phase X-B) | Engineering |
| **Cross-tenant data leakage** — Business A sees Business B's data | Critical | RLS + RPC auth checks; tested in every phase | Engineering |
| **Hallucinated actions** — AI proposes invalid actions (wrong time, unavailable service) | High | Action schema validation + policy check + approval workflow (Phase IX-D) | Engineering |
| **Medical/legal unsafe responses** — AI gives health or legal advice | Critical | Content policy engine + topic restrictions + business type safety defaults | Engineering |
| **Overbuilding enterprise** — Building BYOK/SSO before MVP is validated | Medium | Enterprise features are explicitly Post-MVP; no engineering time until PMF confirmed | CTO |
| **Over-engineering channels** — Building voice/Telegram before web chat works | Medium | Web Chat is MVP Core; all other channels are MVP-Plus or later | CTO |

---

## 8. Engineering Gates

Every future implementation phase must pass these gates before the task can be marked as finalized:

### Pre-Implementation
- [ ] Design doc or implementation plan reviewed
- [ ] Dependencies confirmed complete
- [ ] Scope explicitly bounded (what is NOT included)

### Implementation
- [ ] Migration file(s) created (if schema changes)
- [ ] RPCs use SECURITY DEFINER with internal auth/membership checks
- [ ] RLS policies reviewed (if new tables or policy changes)
- [ ] Audit logging for all state transitions and sensitive operations
- [ ] Usage/cost tracking (if AI-related)
- [ ] Tests added covering: happy path, auth/deny, edge cases
- [ ] No secrets, service_role, or provider keys in frontend

### Post-Implementation
- [ ] All tests pass (vitest)
- [ ] Backend typecheck passes (tsc)
- [ ] Frontend tsc/lint/build pass (if frontend touched)
- [ ] Scope/security scan (grep for secrets, service_role, etc.)
- [ ] Post-implementation audit by reviewer
- [ ] Finalization commit with conventional commit message
- [ ] Push to main
- [ ] Post-finalization audit confirming committed scope

### Per-Change-Type Evidence

| Change Type | Required Evidence |
|---|---|
| **Any task** | Commit hash + full test output log |
| **DB / RLS** | Migration file names + apply log + role-based allow/deny proof |
| **Storage** | Signed-URL success + deny (403) proof + bucket/policy name |
| **AI / Provider** | Usage ledger entry proof + token count + cost logged |
| **Webhook / Notifications** | Request/response log + persisted DB record |

---

## 9. Recommended Next Engineering Phase

### Phase IX-A: AI Token/Cost Governance + Capability Router

**Why this is next**:
1. It is the single blocking dependency for any real AI provider integration.
2. It builds directly on the completed AI Settings Contract (Phase VIII-B, migration 00026).
3. It requires no channel, frontend, or third-party dependencies.
4. It provides immediate measurable value: safe AI usage with cost visibility.

**Scope**:
- Usage ledger table and RPCs
- Token budget enforcement (daily/monthly caps)
- Rate limiting per tenant
- Cost estimation per model/capability
- Capability registry with model binding
- Integration with existing `evaluate_policy()` and `release_to_ai_with_reply()`

**Not in scope**:
- Real provider integration (blocked until governance + content policy are proven — Phase IX-E)
- Frontend usage UI (MVP-Plus, Phase XII-B)
- Billing/payment (Post-MVP)

**Estimated migrations**: 1–2 new migration files (00027+)

**Estimated tests**: 10–15 new tests (exact count reported by implementation phase, not hardcoded in roadmap)

**Success criteria**: AI call rejected when budget exhausted; cost logged per interaction; rate limit enforced; all existing backend tests still pass.

> [!NOTE]
> **Language requirement**: Persian/Farsi customer conversation support is MVP Core for the AI Runtime. Language detection and Persian response generation must be validated as part of the AI capability router and real provider integration (Phase IX-E). Admin/operator UI may remain English early unless pilot requires localization.
