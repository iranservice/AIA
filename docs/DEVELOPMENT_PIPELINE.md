# Development Pipeline

## Phase Map

### Phase 0 — Domain Setup & Repo Discipline ✅
**Goal:** Lock domain map, module boundaries, commit conventions, branch naming, QA rules.

**Deliverables:**
- Module folder structure
- Domain ownership notes
- Dependency rules
- Commit convention
- Branch strategy
- QA strategy

---

### Phase 1 — Foundation Core (AG-1)
**Domains:** Identity, Tenancy, Authz, Audit foundation, DB/migrations/seeds

**What to build:**
- User profiles, auth triggers
- Business entities, memberships, channels, operating hours
- Permissions, role-permission matrix, policy rules engine
- Audit log foundation
- All foundation migrations applied and tested

---

### Phase 2 — Messaging & Inbox Core (AG-2)
**Domains:** Channels, CRM, Conversations

**What to build:**
- Inbound event ingestion (webhook → normalized event)
- Customer auto-create/resolve from inbound messages
- Conversation creation, message persistence
- Message windows for AI context
- Inbox-ready query interfaces

---

### Phase 3 — Routing, Operator Reply, Handoff (AG-3)
**Domains:** Routing, Conversations, Authz, Audit

**What to build:**
- Conversation assignment (manual, auto, round-robin)
- Operator reply flow
- AI-to-operator handoff
- Operator-to-AI release
- Takeover and transfer
- Ownership history and handoff events
- Authz checks on all routing operations

---

### Phase 4 — AI Runtime Foundation (AG-4)
**Domains:** AI Runtime, Knowledge, AI Config, Routing, Conversations

**What to build:**
- AI provider abstraction (OpenAI-ready interface)
- Knowledge base data model and entry CRUD
- Prompt template management
- AI policy enforcement
- AI reply trigger flow
- AI interaction logging with policy traces
- AI handoff pre-checks

---

### Phase 5 — Orders, Actions, Approvals (AG-5)
**Domains:** Orders, Actions, Approvals, Reservations foundation, Cases foundation

**What to build:**
- Order CRUD and state machine
- Customer order confirmation
- Action definitions and handler registry
- Action execution and dispatch
- Approval request/decision lifecycle
- Reservation basics
- Ticket/callback basics

---

### Phase 6 — Level A / Level B Integration Foundations (AG-6)
**Domains:** Channels, Billing, Tenancy

**What to build:**
- Platform-level provider connections (SMS, email, WhatsApp)
- Tenant-level provider onboarding
- Usage metering
- Billing events
- Level A/B payment isolation enforcement

---

## Branch Strategy

### Main Branches
| Branch | Purpose |
|--------|---------|
| `main` | Production-ready. Stable at all times. |
| `develop` | Integration branch. Feature branches merge here first. |

### Branch Types
| Pattern | Example |
|---------|---------|
| `feature/<domain>-<task>` | `feature/identity-session-foundation` |
| `fix/<domain>-<issue>` | `fix/routing-ai-reply-guard` |
| `test/<domain>-<scope>` | `test/authz-cross-tenant-denial` |
| `docs/<domain>-<topic>` | `docs/orders-state-machine` |

### Workflow
1. Branch from `develop`
2. Work on the feature, commit per domain rules
3. PR to `develop`
4. After review + tests, merge to `develop`
5. Periodically merge `develop` → `main` for releases
