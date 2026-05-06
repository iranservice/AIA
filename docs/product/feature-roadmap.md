# AIA — Feature Roadmap

> **Last updated**: 2026-05-05
> **Status**: Draft — pending audit before commit.
> **References**: [Product Definition](./product-definition.md) · [MVP Scope](./mvp-scope.md) · [Platform Foundation Roadmap](../architecture/platform-foundation-roadmap.md)

---

## 1. Purpose

This document translates the approved Product Definition and MVP Scope into prioritized feature groups, each with dependencies, acceptance criteria, and a suggested implementation phase.

**This is not an implementation spec.** It defines *what* to build and *in what order* — not *how* to build it. Implementation details belong in per-phase design docs and migration files.

### How to Use This Document

- **Product decisions**: Use the feature classification (MVP Core / MVP-Plus / Post-MVP) to make scope trade-offs.
- **Engineering planning**: Use the suggested phases and dependency graph to sequence work.
- **Stakeholder communication**: Use the feature list to set expectations on what ships when.

---

## 2. Feature Classification

| Bucket | Definition | Ships When |
|---|---|---|
| **MVP Core** | Must ship for the product to be pilotable with real businesses | Before first paid pilot |
| **MVP-Plus** | Enhances MVP but not blocking for initial pilots | During or shortly after first pilot cohort |
| **Post-MVP** | Valuable but requires MVP validation first | After MVP metrics are validated |
| **Labs / Experimental** | Unproven or compliance-risky; no SLA | Available for internal testing or opt-in pilots only |
| **Enterprise** | Features for large organizations with procurement/compliance requirements | After product-market fit is confirmed |

---

## 3. MVP Core Features

> [!NOTE]
> **Language requirement**: Persian/Farsi customer conversation support is MVP Core. English is baseline. Arabic is MVP-Plus unless the first paid pilot is Arabic-speaking. Language detection and reply language selection are part of the AI Runtime requirements and apply to all MVP Core AI features and channels.

### F-01: AI Token/Cost Governance

| Attribute | Detail |
|---|---|
| **Problem** | Without token budgets and cost tracking, a single tenant can generate unbounded AI costs |
| **Target user** | Platform Admin, Business Owner |
| **Dependencies** | AI Settings Contract (✅ Phase VIII-B complete) |
| **Product value** | Enables safe real-provider integration; prevents cost surprises |
| **Backend** | Usage ledger table, token budget enforcement RPC, rate limiter, cost estimation per model |
| **Frontend** | None required for backend contract; usage visibility is MVP-Plus |
| **Acceptance criteria** | Daily/monthly token caps enforced; AI calls rejected when budget exhausted; cost per interaction logged; rate limiting prevents burst abuse |
| **Suggested phase** | Phase IX-A |
| **Risks** | Incorrect cost estimation if model pricing changes; must be updateable without migration |

### F-02: AI Capability Router + Model Binding

| Attribute | Detail |
|---|---|
| **Problem** | AI capabilities (reply, classify, extract, summarize, propose) need per-capability model selection and context routing |
| **Target user** | Platform Admin, Business Owner (indirectly) |
| **Dependencies** | Token Governance (F-01), Provider Registry (schema exists) |
| **Product value** | Enables using lighter/cheaper models for classification while reserving powerful models for reply |
| **Backend** | Capability registry, model binding per capability per tenant, context builder per capability |
| **Frontend** | None for MVP Core |
| **Acceptance criteria** | Each AI capability routes to configured model; fallback model is defined; capability calls are logged with model + tokens |
| **Suggested phase** | Phase IX-A (combined with F-01) |
| **Risks** | Over-engineering model selection before having real usage data |

### F-03: AI Fallback Ladder

| Attribute | Detail |
|---|---|
| **Problem** | When primary AI provider fails (timeout, error, low confidence), system must degrade gracefully |
| **Target user** | Customer (transparent), Operator (receives handoff) |
| **Dependencies** | Capability Router (F-02), Handoff system (✅ exists) |
| **Product value** | Zero dead-end conversations; customer always gets a response or a human |
| **Backend** | Fallback chain configuration, provider health tracking, circuit breaker, stub response templates |
| **Frontend** | None for backend contract |
| **Acceptance criteria** | Primary fail → fallback model tried → stub response sent → human handoff triggered; circuit breaker prevents retry storms |
| **Suggested phase** | Phase IX-B |
| **Risks** | Cascading failures if fallback provider also fails; must have hard stop at stub + handoff |

### F-04: Handoff Re-entry + AI Assist Mode

| Attribute | Detail |
|---|---|
| **Problem** | After operator handles a conversation, releasing back to AI must resume naturally without loops |
| **Target user** | Operator, Customer |
| **Dependencies** | Release-to-AI (✅ Phase VIII-A), Fallback Ladder (F-03) |
| **Product value** | Operators can confidently release to AI; AI doesn't re-fail immediately and re-trigger handoff |
| **Backend** | Re-entry state machine, handoff history tracking, circuit breaker for rapid re-handoff, AI-assist draft mode |
| **Frontend** | AI-assist draft preview is MVP-Plus; re-entry trigger is backend |
| **Acceptance criteria** | Release-to-AI resumes with full context; if AI fails within 60s of re-entry, it does not re-trigger handoff (circuit breaker); handoff reason is logged |
| **Suggested phase** | Phase IX-B (combined with F-03) |
| **Risks** | Edge case: customer asks same question that caused original handoff |

### F-05: Conversation Turn Aggregation

| Attribute | Detail |
|---|---|
| **Problem** | Customers send 2–5 rapid messages; AI must not respond to each fragment |
| **Target user** | Customer (better responses), Business Owner (fewer wasted tokens) |
| **Dependencies** | Channel Adapter Contract (F-08 — at minimum the inbound path) |
| **Product value** | Reduces AI calls by ≥30%; improves response quality; reduces token cost |
| **Backend** | Turn aggregation service with configurable window (3–5s), message batching, turn closure event |
| **Frontend** | None |
| **Acceptance criteria** | 3 messages sent within 3 seconds are batched into 1 turn; AI processes the batch; turn aggregation efficiency metric is trackable |
| **Suggested phase** | Phase IX-C |
| **Risks** | Too-long window delays first response; too-short window misses fragments |

### F-06: Business Type Profiles + Dynamic Capabilities

| Attribute | Detail |
|---|---|
| **Problem** | Restaurant, clinic, and salon have different capabilities, data models, and safety policies |
| **Target user** | Business Owner (at onboarding), AI Runtime |
| **Dependencies** | Business settings (✅ exists), AI Settings Contract (✅ exists) |
| **Product value** | AI behavior adapts to business type without manual configuration per tenant |
| **Backend** | Business type registry, per-type capability set, per-type content policy defaults, per-type knowledge schema |
| **Frontend** | Business type selector at onboarding; type-specific settings UI |
| **Acceptance criteria** | Creating a restaurant business auto-enables menu capabilities and blocks medical advice; creating a clinic enables appointment capabilities and enforces medical disclaimers |
| **Suggested phase** | Phase IX-D |
| **Risks** | Over-generalizing types; some businesses span multiple types |

### F-07: Dynamic Action Schema + Approval Policy

| Attribute | Detail |
|---|---|
| **Problem** | AI-proposed actions (reserve, book, cancel) need structured schemas and configurable approval workflows |
| **Target user** | Business Owner/Manager (configures), Customer (receives outcome) |
| **Dependencies** | Business Type Profiles (F-06), Action Engine (schema exists) |
| **Product value** | Actions are validated, auditable, and policy-controlled; sensitive actions require manager approval |
| **Backend** | Action schema registry, approval queue, approval policy per action type, action execution log |
| **Frontend** | Approval queue UI is MVP-Plus |
| **Acceptance criteria** | AI proposes reservation → schema validates → policy checks → auto-approved or queued for manager; action result is logged |
| **Suggested phase** | Phase IX-D (combined with F-06) |
| **Risks** | Complex approval workflows are Enterprise scope; MVP should support auto-approve + manual-approve only |

### F-15: Controlled Real AI Provider Adapter (Pilot Runtime Readiness)

| Attribute | Detail |
|---|---|
| **Problem** | `mock-sql` stub responses cannot satisfy MVP exit criteria ("AI handles 30–50% of FAQ-heavy inquiries"). A real AI provider is required for pilot validation |
| **Target user** | Customer (receives real AI responses), Business Owner (validates product value) |
| **Dependencies** | Token/Cost Governance (F-01), Capability Router (F-02), Fallback Ladder (F-03), Content Policy (F-16), Secret Management (server-side Vault or equivalent) |
| **Product value** | Enables real customer pilots with production-quality AI responses — the core product promise |
| **Backend** | Single provider adapter (e.g., OpenAI GPT-4o), server-side key storage, budget preflight before every call, usage ledger integration, fallback to mock-sql on error, provider enable/disable per tenant/environment |
| **Frontend** | None — provider selection is backend-only |
| **Acceptance criteria** | Provider key stored server-side only (never in frontend); every provider call records usage in ledger; budget preflight rejects call if over budget; provider errors mapped into fallback ladder; provider output treated as reply draft/action proposal (not direct execution); mock-sql remains available as fallback/testing provider; provider can be disabled per tenant |
| **Suggested phase** | Phase IX-E (after governance, fallback, and content policy are proven) |
| **Risks** | Provider cost if governance has bugs; must have budget kill-switch. Provider latency affects response time. Provider content filtering may not catch all unsafe outputs — content policy (F-16) is defense-in-depth |

> [!IMPORTANT]
> **F-15 is NOT multi-provider management.** It is a single controlled provider adapter for pilot readiness. Multi-provider routing, BYOK, and provider marketplace are Post-MVP/Enterprise.

### F-16: Content Policy + Input/Output Safety Filtering

| Attribute | Detail |
|---|---|
| **Problem** | AI may generate unsafe content (medical advice, legal counsel, PII exposure) or receive abusive/harmful input. Input/output filtering beyond `ai_allowed` is required before any real provider is enabled |
| **Target user** | Customer (protected from unsafe AI), Business Owner (brand/liability protection), Platform Admin (compliance) |
| **Dependencies** | Policy Engine (evaluate_policy ✅ exists), Business Type Profiles (F-06) |
| **Product value** | Prevents liability from unsafe AI responses; enables per-vertical safety defaults (clinics block diagnosis, salons block medical advice) |
| **Backend** | Input filter (pre-AI), output filter (post-AI), topic restriction rules per business type, blocked content categories, escalation/handoff triggers for unsafe topics, audit logging of all blocked/filtered cases |
| **Frontend** | None for MVP Core (policy management UI is MVP-Plus) |
| **Acceptance criteria** | Clinic profile blocks diagnosis/prescription responses; legal/financial advice triggers safe response or handoff; complaint/refund can trigger human handoff; every policy decision is logged in audit_log; AI response cannot bypass policy engine; per-business policy profile support |
| **Suggested phase** | Phase IX-E (combined with F-15 — content policy must be proven before real provider is enabled) |
| **Risks** | Over-filtering produces unhelpful responses; under-filtering allows unsafe content. Must be tunable per business type |

### F-08: Channel Adapter + Multimodal Event Contract

| Attribute | Detail |
|---|---|
| **Problem** | Core needs a stable contract for ingesting messages from any channel, including multimodal content |
| **Target user** | Platform (internal), future channel adapters |
| **Dependencies** | Conversations schema (✅ exists) |
| **Product value** | Adding a new channel = implementing an adapter, not modifying core |
| **Backend** | Channel adapter interface, message part types (text, image, audio, document, location, contact), inbound/outbound contracts |
| **Frontend** | Message renderer supporting multimodal parts |
| **Acceptance criteria** | Web chat adapter implements the contract; messages with images are stored with type metadata; operator can view attachments |
| **Suggested phase** | Phase X-A |
| **Risks** | Over-engineering for channels not yet needed; keep contract minimal |

### F-09: Outbox + Delivery + Idempotency

| Attribute | Detail |
|---|---|
| **Problem** | Outbound messages must not duplicate; delivery must be reliable and retryable |
| **Target user** | Customer (no duplicate messages), Platform (reliability) |
| **Dependencies** | Channel Adapter Contract (F-08) |
| **Product value** | Zero duplicate outbound messages; reliable delivery tracking |
| **Backend** | Outbox table, delivery worker, idempotency keys, delivery status tracking, retry with backoff |
| **Frontend** | Delivery status indicators (sent, delivered, read) |
| **Acceptance criteria** | Message queued in outbox → delivered once → status updated; retry on failure does not duplicate; idempotency key prevents double-send |
| **Suggested phase** | Phase X-B |
| **Risks** | Outbox worker complexity; must handle channel-specific delivery semantics |

### F-10: Customer Identity Resolution

| Attribute | Detail |
|---|---|
| **Problem** | Same customer may message from WhatsApp and web chat; needs unified identity |
| **Target user** | Operator (sees full customer history), AI (has complete context) |
| **Dependencies** | Customer schema (✅ exists), Channel Adapter (F-08) |
| **Product value** | Operators see one customer across channels; AI has full conversation history |
| **Backend** | Identity resolution rules (phone, email, channel ID), merge/link operations, conflict resolution |
| **Frontend** | Customer profile with linked identities |
| **Acceptance criteria** | Customer messaging from WhatsApp and web chat with same phone is resolved to one profile; conversation history is unified |
| **Suggested phase** | Phase X-B (combined with F-09) |
| **Risks** | False merges; must support manual unlink |

### F-11: Native Web Chat Widget

| Attribute | Detail |
|---|---|
| **Problem** | Businesses need an embeddable chat widget for their website — the MVP channel |
| **Target user** | Customer, Business Owner |
| **Dependencies** | Channel Adapter (F-08), Outbox (F-09), Turn Aggregation (F-05) |
| **Product value** | The primary MVP channel; no third-party dependency; full UX control |
| **Backend** | Web chat session management, anonymous customer creation, widget configuration per business. Must support Persian/Farsi and English customer conversations from day one |
| **Frontend** | Embeddable widget (iframe or web component), conversation UI, typing indicators |
| **Acceptance criteria** | Widget loads in <2s; customer can send text messages; AI responds; handoff to operator works; widget is brandable per business |
| **Suggested phase** | Phase X-C |
| **Risks** | Widget security (XSS, session hijacking); must sandbox properly |

### F-12: Appointment / Reservation Foundation

| Attribute | Detail |
|---|---|
| **Problem** | Clinic and salon verticals need appointment booking; restaurant needs reservation |
| **Target user** | Customer, Business Owner |
| **Dependencies** | Business Type Profiles (F-06), Dynamic Action Schema (F-07), Reservation schema (✅ exists) |
| **Product value** | Core vertical workflow — AI can propose and backend can confirm bookings |
| **Backend** | Availability engine, slot management, booking confirmation, cancellation policy enforcement |
| **Frontend** | Appointment/reservation list view; calendar view is MVP-Plus |
| **Acceptance criteria** | AI proposes appointment → backend checks availability → confirms or suggests alternatives; cancellation respects policy |
| **Suggested phase** | Phase XI-A |
| **Risks** | Complex availability rules per provider/staff; keep MVP simple (time slots, not calendar optimization) |

### F-13: Knowledge / Content Center (Basic)

| Attribute | Detail |
|---|---|
| **Problem** | AI needs business-specific knowledge (menu, services, FAQ) to answer accurately |
| **Target user** | Business Owner (uploads), AI (reads) |
| **Dependencies** | Business Type Profiles (F-06) |
| **Product value** | AI answers from real business knowledge, not hallucinated facts |
| **Backend** | Knowledge entry CRUD, per-type knowledge schemas (menu items, services, FAQ), indexing for retrieval |
| **Frontend** | Knowledge management UI (add/edit/delete entries) |
| **Acceptance criteria** | Owner uploads menu items; AI answers "What's on your menu?" from uploaded data; knowledge changes are audited |
| **Suggested phase** | Phase XI-B |
| **Risks** | Retrieval accuracy depends on indexing quality; full RAG is Post-MVP |

### F-14: Usage / Health Visibility (Basic)

| Attribute | Detail |
|---|---|
| **Problem** | Platform admin and business owner need to see AI usage, cost, and system health |
| **Target user** | Platform Admin, Business Owner |
| **Dependencies** | Token Governance (F-01), Usage Ledger (F-01) |
| **Product value** | Visibility into AI cost and behavior; early warning for budget exhaustion |
| **Backend** | Usage aggregation queries, health check endpoints |
| **Frontend** | Basic usage summary (today's tokens, month's tokens, budget remaining, recent AI interactions) |
| **Acceptance criteria** | Business owner sees daily/monthly token usage and remaining budget; platform admin sees per-tenant usage |
| **Suggested phase** | Phase XI-C |
| **Risks** | Real-time aggregation can be expensive; use materialized views or periodic rollups |

---

## 4. MVP-Plus Features

| ID | Feature | Description | Dependencies | Suggested Phase |
|---|---|---|---|---|
| **FP-01** | Official WhatsApp Adapter | Meta Business API integration; template messages; 24h window management | F-08, F-09, F-10, Meta verification | Phase XII-A |
| **FP-02** | Usage Dashboard + AI Credits UX | Visual dashboard for owners showing AI usage, cost trends, and credit balance | F-14 | Phase XII-B |
| **FP-03** | Operator AI Assist UI | AI drafts a reply; operator reviews and sends; not full auto-reply | F-04 | Phase XII-B |
| **FP-04** | Approval Queue UI | Manager reviews and approves AI-proposed actions (reservations, cancellations) | F-07 | Phase XII-C |
| **FP-05** | PDF/Document Knowledge Ingestion | Upload PDFs; extract and index content for AI retrieval | F-13 | Phase XII-C |
| **FP-06** | Arabic Language Expansion | Promote Arabic to MVP Core if pilot requires; add Arabic content policies | F-05, AI provider with Arabic support | Phase XII-D |
| **FP-07** | Canned Responses / Templates | Pre-defined operator reply templates | Operator workspace (✅ exists) | Phase XII-B |
| **FP-08** | Scheduled Handoff (Business Hours) | Auto-handoff to operator during business hours; AI handles after-hours | Business profile hours (✅ exists) | Phase XII-D |

---

## 5. Post-MVP Features

| ID | Feature | Description | Depends On |
|---|---|---|---|
| **FX-01** | Advanced Multi-Provider Management | Multi-provider routing, failover optimization, provider health dashboard, cost-per-model optimization | F-15 (controlled provider) |
| **FX-02** | Voice Call Session Foundation | STT/TTS adapter, call session model, consent policy | Channel contract, cost governance |
| **FX-03** | Full Multimodal Processing | Image OCR, voice transcription, document parsing by AI | F-08, F-15 (real provider) |
| **FX-04** | Additional Vertical Packs | Retail, home service, education, real estate business profiles | F-06 |
| **FX-05** | Payment/POS/Delivery Integrations | PCI-compliant payment, POS sync, delivery dispatch | Action engine, security audit |
| **FX-06** | CRM Integrations | Salesforce, HubSpot, custom CRM sync | Customer identity, webhook outbox |
| **FX-07** | Advanced Analytics | Conversation analytics, AI performance dashboards, trend analysis | Usage ledger, data warehouse |
| **FX-08** | Mobile App | Native mobile app for operators | Operator workspace API |
| **FX-09** | Marketing Automation | Proactive outbound campaigns, follow-ups | Outbox, content policy, consent |
| **FX-10** | Multi-language Expansion | French, Urdu, Turkish, and other languages | AI provider multilingual support |

---

## 6. Labs / Experimental

### FL-01: WhatsApp Web Bridge (Labs)

| Attribute | Detail |
|---|---|
| **Status** | Labs — no SLA, no production guarantee |
| **What it is** | Unofficial WhatsApp connection via web session bridge (e.g., whatsapp-web.js) |
| **Why Labs** | Violates WhatsApp TOS; sessions are fragile (QR re-auth, session expiry); Meta can block at any time |
| **Use case** | Internal testing, pilot validation before official API approval |
| **Compliance risk** | Account ban, message loss, data handling concerns |
| **Migration path** | All conversations and customers created via bridge must be compatible with official WhatsApp API adapter (FP-01) |
| **Engineering rule** | Bridge adapter must implement the same Channel Adapter Contract (F-08) as official adapters. No bridge-specific core logic |

---

## 7. Enterprise Features

| ID | Feature | Description |
|---|---|---|
| **FE-01** | BYOK (Bring Your Own Key) | Tenant provides their own AI provider API key; AIA manages routing and governance |
| **FE-02** | SSO / SAML | Enterprise authentication via corporate identity provider |
| **FE-03** | Advanced Audit Export | Export audit logs to external SIEM/compliance systems |
| **FE-04** | Custom Roles | Beyond owner/manager/operator; custom permission sets |
| **FE-05** | SLA / Retention Policies | Configurable data retention, conversation archival, SLA enforcement |
| **FE-06** | White-label / Reseller | Remove AIA branding; reseller management portal |

---

## 8. Prioritized Execution Order

### Phase Numbering Rationale

The repository already has completed phases through VIII-B:
- Phase I–III: Auth, tenant, messaging foundation (`a1d4ec3`)
- Phase II-A: Business settings + members (`11f39b4`)
- Phase VII-E: RLS recursion fix (`19e2128`)
- Phase VII-F2: Auth mock separation (`d80236f`)
- Phase VIII-A: Release-to-AI stub reply (`0d6d3b1`)
- Phase VIII-B: AI settings contract (`8238c14`)

**Next phases start at IX.** Phase IX focuses on AI governance, content safety, and controlled real provider enablement (the prerequisites for a real pilot). Phase X focuses on channel foundation. Phase XI focuses on vertical workflows. Phase XII is MVP-Plus.

### Execution Sequence

```
Phase IX — AI Governance + Behavior Foundation + Pilot Runtime
├── IX-A: Token/Cost Governance + Capability Router (F-01, F-02)
├── IX-B: Fallback Ladder + Handoff Re-entry (F-03, F-04)
├── IX-C: Conversation Turn Aggregation (F-05)
├── IX-D: Business Type Profiles + Dynamic Actions (F-06, F-07)
└── IX-E: Content Policy + Controlled Real Provider (F-15, F-16)

Phase X — Channel + Delivery Foundation
├── X-A: Channel Adapter + Multimodal Contract (F-08)
├── X-B: Outbox + Delivery + Identity Resolution (F-09, F-10)
└── X-C: Native Web Chat Widget (F-11)

Phase XI — Vertical Workflows + Knowledge
├── XI-A: Appointment / Reservation Foundation (F-12)
├── XI-B: Knowledge / Content Center (F-13)
└── XI-C: Usage / Health Visibility (F-14)

Phase XII — MVP-Plus
├── XII-A: Official WhatsApp Adapter (FP-01)
├── XII-B: Usage Dashboard + AI Assist UI + Templates (FP-02, FP-03, FP-07)
├── XII-C: Approval Queue + PDF Ingestion (FP-04, FP-05)
└── XII-D: Arabic Expansion + Scheduled Handoff (FP-06, FP-08)
```

> [!NOTE]
> Phase numbering is indicative. Sub-phases may be reordered based on pilot urgency. The critical constraint is: **no real AI provider (IX-E) until IX-A through IX-D governance, fallback, and content policy foundations are complete.**

---

## 9. Key Dependencies (Summary)

```
Controlled Real Provider (IX-E) ──depends on──→ Token Governance (IX-A) + Capability Router (IX-A)
                                                + Fallback Ladder (IX-B) + Content Policy (IX-E)
                                                + Secret Management (server-side)
Advanced Multi-Provider (Post-MVP) ──depends on──→ Controlled Real Provider (IX-E)
WhatsApp Adapter ──depends on──→ Channel Contract (X-A) + Outbox (X-B) + Identity (X-B)
                                 + Turn Aggregation (IX-C)
Web Chat Widget ──depends on──→ Channel Contract (X-A) + Turn Aggregation (IX-C) + Outbox (X-B)
Knowledge Center ──depends on──→ Business Type Profiles (IX-D)
Appointments    ──depends on──→ Business Type Profiles (IX-D) + Dynamic Actions (IX-D)
Usage Dashboard ──depends on──→ Token Governance (IX-A) + Usage Ledger (IX-A)
Voice           ──depends on──→ Channel Contract (X-A) + STT/TTS adapter + Consent + Cost Governance
```
