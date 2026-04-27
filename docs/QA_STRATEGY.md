# QA Strategy

## QA Expectations Per Phase

Every task that modifies sensitive flows must pass the QA checklist below before being marked `Ready for Review`.

## Required Checks

### 1. Build & Type Safety
- [ ] `pnpm typecheck` — 0 errors
- [ ] `pnpm lint` — 0 errors (when configured)
- [ ] No dead imports or unused exports

### 2. Domain Isolation
- [ ] Changes scoped to declared domain(s)
- [ ] No cross-domain writes (only reads)
- [ ] Imports respect dependency rules (see DOMAIN_MAP.md)

### 3. RLS / Security (if DB changes)
- [ ] RLS enabled on new tables
- [ ] RLS policies cover read, write, delete as needed
- [ ] Role-based access verified:
  - [ ] Owner: full access
  - [ ] Manager: expected access
  - [ ] Operator: expected access
  - [ ] Viewer: read-only
  - [ ] Cross-tenant: denied
- [ ] Platform admin bypass works
- [ ] No raw SQL exposed to client

### 4. Money / Payment (if payment-related)
- [ ] Level A/B payment isolation verified
- [ ] `validate_order_payment_provider()` tested
- [ ] Order payment uses `provider_scope = 'tenant'` only
- [ ] Platform billing uses `provider_scope = 'platform'` only
- [ ] Refund/discount logic is server-side only

### 5. State Machine (if status transitions)
- [ ] Valid transitions documented
- [ ] Invalid transitions raise exception
- [ ] Status history recorded
- [ ] Row-level locking used (FOR UPDATE)

### 6. Authz (if permission-related)
- [ ] `check_permission()` used for all gated operations
- [ ] Permission codes match seed data
- [ ] RBAC tests pass for all roles

### 7. Routing / Handoff (if conversation ownership changes)
- [ ] AI cannot reply when operator owns conversation
- [ ] Operator cannot take over without permission
- [ ] Handoff events recorded
- [ ] Ownership history tracked

### 8. Approvals (if approval-related)
- [ ] Approval request created before mutation
- [ ] Domain mutation only happens after approval
- [ ] Expiration handled
- [ ] Decision audit trail recorded

### 9. Audit (if sensitive operation)
- [ ] `log_audit()` called for the operation
- [ ] Old/new values captured where applicable
- [ ] Actor and timestamp recorded

## Evidence Pack (per IRANI Done Policy)

| Change Type | Required Evidence |
|---|---|
| Any task | Commit hash + full test output log |
| DB / RLS | Migration file names + apply log + role-based allow/deny proof |
| Storage | Signed-URL success proof + deny (403) proof |
| Webhook | Real or mocked request+response log + persisted DB log |

## Test Folder Structure

```
test/
├── identity/          # Identity domain tests
├── tenancy/           # Tenancy domain tests
├── authz/             # Authz domain tests
├── crm/               # CRM domain tests
├── channels/          # Channels domain tests
├── conversations/     # Conversations domain tests
├── routing/           # Routing domain tests
├── ai_runtime/        # AI Runtime domain tests
├── knowledge/         # Knowledge domain tests
├── ai_config/         # AI Config domain tests
├── actions/           # Actions domain tests
├── orders/            # Orders domain tests
├── reservations/      # Reservations domain tests
├── cases/             # Cases domain tests
├── approvals/         # Approvals domain tests
├── audit/             # Audit domain tests
├── billing/           # Billing domain tests
├── analytics/         # Analytics domain tests
├── shared/            # Shared utilities tests
└── integration/       # Cross-domain integration tests
```

Each domain test folder mirrors the domain module structure. Tests are committed with or immediately after the related feature.
