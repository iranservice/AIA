# QA Checklist Template

Use this template for every task that modifies sensitive flows.
Copy and fill before marking any task as `Ready for Review`.

---

## Task: [Task Name]
## Domain: [domain name]
## Branch: [branch name]

---

## Pre-Merge Checks

### Build & Lint
- [ ] `pnpm typecheck` — 0 errors
- [ ] `pnpm lint` — 0 errors (when linter is configured)
- [ ] `pnpm build` — builds successfully (when applicable)

### Domain Isolation
- [ ] Changes scoped to declared domain(s)
- [ ] No cross-domain writes (only reads)
- [ ] Imports respect dependency rules

### RLS / Security (if DB changes)
- [ ] RLS enabled on new tables
- [ ] RLS policies cover: read, write, delete as needed
- [ ] Role-based access verified:
  - [ ] Owner: full access
  - [ ] Manager: expected access
  - [ ] Operator: expected access
  - [ ] Viewer: read-only
  - [ ] Cross-tenant: denied
- [ ] Platform admin: bypass works
- [ ] No raw SQL exposed to client

### Money / Payment (if payment-related)
- [ ] Level A/B payment isolation verified
- [ ] `validate_order_payment_provider()` tested
- [ ] Order payment uses `provider_scope = 'tenant'` only
- [ ] Platform billing uses `provider_scope = 'platform'` only
- [ ] Refund/discount logic is server-side only

### State Machine (if status transitions)
- [ ] Valid transitions documented
- [ ] Invalid transitions raise exception
- [ ] Status history recorded
- [ ] Row-level locking used (FOR UPDATE)

### Authz (if permission-related)
- [ ] `check_permission()` used for all gated operations
- [ ] Permission codes match seed data
- [ ] RBAC tests pass for all roles

### Routing / Handoff (if conversation ownership changes)
- [ ] AI cannot reply when operator owns conversation
- [ ] Operator cannot take over without permission
- [ ] Handoff events recorded
- [ ] Ownership history tracked

### Approvals (if approval-related)
- [ ] Approval request created before mutation
- [ ] Domain mutation only happens after approval
- [ ] Expiration handled
- [ ] Decision audit trail recorded

### Audit (if sensitive operation)
- [ ] `log_audit()` called for the operation
- [ ] Old/new values captured where applicable
- [ ] Actor and timestamp recorded

---

## Evidence Pack

| Item | Status | Notes |
|------|--------|-------|
| Commit/PR | | |
| Test output | | |
| Migration files | | |
| RLS allow/deny proof | | |
| Payment isolation proof | | |
| Webhook logs (if applicable) | | |

---

## Sign-off

- [ ] All applicable checks above are verified
- [ ] Task moved to `Ready for Review`
- [ ] Evidence pack attached
