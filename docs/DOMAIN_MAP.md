# Domain Map

## 19-Domain Architecture

| # | Domain | Folder | Owns |
|---|--------|--------|------|
| 1 | **Identity** | `identity/` | Users, authentication, sessions, user status, login/me/logout foundations |
| 2 | **Tenancy** | `tenancy/` | Businesses, business profiles, configs, Level A/B separation, memberships, teams, operational roles, working hours, service areas |
| 3 | **Authz** | `authz/` | Roles, permissions, role assignments, RBAC/ABAC enforcement, permission overrides, policy definitions, policy rules, access control service, resource-level checks |
| 4 | **CRM** | `crm/` | Customers, customer channel identities, addresses, notes, tags, memory profile, customer auto-create/resolve from inbound messages |
| 5 | **Channels** | `channels/` | WhatsApp/email/SMS/webhook/channel foundations, inbound event ingestion, outbound delivery abstraction, integration logs, provider adapter contracts, provider registry, Level A vs Level B integration separation |
| 6 | **Conversations** | `conversations/` | Conversations, messages, attachments, threads, message processing windows, inbox-ready query data, conversation notes, tags |
| 7 | **Routing** | `routing/` | Conversation ownership, assignment, queues, takeover, transfer, release-to-AI, handoff events, ownership history |
| 8 | **AI Runtime** | `ai_runtime/` | AI reply trigger flow, AI provider abstraction, OpenAI-ready provider interface, retrieval logs, AI interaction logs, summaries, AI handoff pre-checks, voice-ready runtime abstractions |
| 9 | **Knowledge** | `knowledge/` | Knowledge bases, entries (FAQ, menu, business data), versioning foundation |
| 10 | **AI Config** | `ai_config/` | AI policies, prompt templates, prompt testing, versioning foundation |
| 11 | **Actions** | `actions/` | Action definitions, business action configs, action execution orchestration, action logs, handler registry, dispatch to domain handlers |
| 12 | **Orders** | `orders/` | Orders, order items, order lifecycle, customer confirmation, order status, pricing/refund/discount foundations |
| 13 | **Reservations** | `reservations/` | Reservation foundation, create/edit/cancel/confirm basics |
| 14 | **Cases** | `cases/` | Tickets, callback requests, escalation/de-escalation basics |
| 15 | **Approvals** | `approvals/` | Approval requests, approval decisions, approval lifecycle, approval-required handling |
| 16 | **Audit** | `audit/` | Audit logs, sensitive operation logs, AI-linked operation logs, before/after state changes, actor/time/target metadata |
| 17 | **Billing** | `billing/` | Subscription plans foundation, usage ledgers, billing summary foundations, Level A payment foundation, Level B payment integration readiness |
| 18 | **Analytics** | `analytics/` | Conversation counts, handoff counts, AI response counts, order metrics, approval metrics, basic operational dashboard data |
| 19 | **Shared** | `shared/` | Shared types, error hierarchy, utilities, Supabase client, cross-cutting foundations |

## Dependency Rules

### Foundation Domains (upstream only)
`Identity`, `Tenancy`, `Authz` — other modules depend on them. They must not depend on operational domains.

### CRM Is Shared Read
Used by Conversations, Orders, Actions, AI Runtime. CRM must not own those flows.

### Conversations ≠ Routing
Conversations owns message persistence. Routing owns ownership and handoff. Never mix.

### AI Runtime Uses Service Interfaces
May call Conversations, Routing, Knowledge, AI Config, Actions, CRM through service interfaces. Must not bypass Authz, Policy, Approval, or Ownership rules.

### Actions Orchestrate, Domains Execute
Actions may call Orders, Reservations, CRM, Routing, Cases. Actions must not implement domain business logic internally.

### Orders Owns Order Lifecycle
Conversations may reference orders but must not implement order rules.

### Approvals Are Standalone
Can be requested by Actions, Orders, AI Runtime, or Routing. Must not directly mutate domain records without a domain service.

### Audit Is Cross-Cutting
Every sensitive domain must write audit events. Audit is append-only.

### Billing & Analytics Are Consumers
Must not become hidden owners of business logic.

## Level A / Level B Boundary

| Concern | Level A (Platform) | Level B (Tenant) |
|---------|-------------------|------------------|
| Payment | Platform billing | Customer order payments |
| Gateway | Platform payment gateway | Tenant's own payment gateway |
| SMS/Email | Platform notifications to tenants | Customer-facing messages |
| AI | Provider management, model access | Per-business agent config |

**Non-negotiable:** Level B order payment uses `provider_scope = 'tenant'`. Level A billing uses `provider_scope = 'platform'`. These paths must never cross.

## Anti-Patterns

1. God module
2. Conversation owns order
3. Action owns domain logic
4. UI owns permission truth
5. AI bypasses policy
6. Mixed Level A/B integrations
7. Restaurant lock-in
8. Sensitive changes without audit
9. Huge commits touching unrelated domains
10. Hidden ownership, approval, handoff, or AI/operator state
