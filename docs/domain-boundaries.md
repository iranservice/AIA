# Domain Boundaries

## 17-Domain Map

| # | Domain | Owns |
|---|--------|------|
| 1 | **Identity** | Users, authentication, sessions, user status, login/me/logout foundations |
| 2 | **Tenancy** | Businesses, profiles, configs, Level A/B separation, memberships, teams, operational roles, working hours, service areas |
| 3 | **Authz** | Roles, permissions, role assignments, RBAC/ABAC enforcement, permission overrides, policy definitions, policy rules, access control service, resource-level checks |
| 4 | **CRM** | Customers, customer channel identities, addresses, notes, tags, memory profile, customer auto-create/resolve from inbound messages |
| 5 | **Channels** | WhatsApp/email/SMS/webhook/channel foundations, inbound event ingestion, outbound delivery abstraction, integration logs, provider adapter contracts, Level A vs Level B integration separation |
| 6 | **Conversations** | Conversations, messages, attachments, threads, message processing windows, inbox-ready query data, conversation notes, tags |
| 7 | **Routing** | Conversation ownership, assignment, queues, takeover, transfer, release-to-AI, handoff events, ownership history |
| 8 | **AI Runtime** | AI reply trigger flow, AI provider abstraction, OpenAI-ready provider interface, retrieval logs, AI interaction logs, summaries, AI handoff pre-checks, voice-ready runtime abstractions |
| 9 | **Knowledge** | Knowledge bases, entries (FAQ/menu/business data), AI policies, prompt templates, prompt testing, versioning foundation |
| 10 | **Actions** | Action definitions, business action configs, action execution orchestration, action logs, handler registry, dispatch to domain handlers |
| 11 | **Orders** | Orders, order items, order lifecycle, customer confirmation, order status, pricing/refund/discount foundations |
| 12 | **Reservations** | Reservation foundation, create/edit/cancel/confirm basics |
| 13 | **Cases** | Tickets, callback requests, escalation/de-escalation basics |
| 14 | **Approvals** | Approval requests, approval decisions, approval lifecycle, approval-required handling |
| 15 | **Audit** | Audit logs, sensitive operation logs, AI-linked operation logs, before/after state changes, actor/time/target metadata |
| 16 | **Billing** | Subscription plans foundation, usage ledgers, billing summary foundations, Level A payment foundation, Level B payment integration readiness |
| 17 | **Analytics** | Conversation counts, handoff counts, AI response counts, order metrics, approval metrics, basic operational dashboard data |

## Boundary Rules

1. **No cross-domain table writes in RPCs** — Each domain's RPCs only write to their own tables. Cross-domain coordination goes through the action engine or explicit domain RPCs.

2. **Shared read is allowed** — A conversation RPC can read customer data to validate, but it doesn't write to the customers table directly.

3. **Action engine orchestrates** — When AI or an operator triggers a cross-domain operation (e.g., "create an order from this conversation"), the action engine calls the target domain's RPC. It never duplicates domain logic.

4. **Provider registry is referenced, not owned** — Domains reference `provider_registry.id` via FK, but provider management is owned by the channels/providers domain.

5. **Audit is append-only** — Any domain can call `log_audit()`, but no domain reads or modifies audit logs as part of business logic.

6. **Conversations ≠ Routing** — Messages vs. ownership are separate concerns. Never mix them.

7. **Approvals gate, domains execute** — Approvals don't directly mutate records. They approve/reject, then the domain service performs the mutation.

## Level A / Level B Boundary

| Concern | Level A (Platform) | Level B (Tenant) |
|---------|-------------------|------------------|
| **Payment** | Platform billing (subscriptions, overages) | Customer order payments |
| **Gateway** | Platform payment gateway | Tenant's own payment gateway |
| **SMS/Email** | Platform notifications to tenants | Customer-facing messages |
| **AI** | Provider management, model access | Per-business agent config |
| **Storage** | Platform assets | Tenant business assets |

### Non-Negotiable Rules

- Level B order payment MUST use `provider_scope = 'tenant'`
- Level A billing MUST use `provider_scope = 'platform'`
- These two paths must NEVER cross
- `validate_order_payment_provider()` enforces this at the database level
