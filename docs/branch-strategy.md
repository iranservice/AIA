# Branch Strategy

## Main Branches

| Branch | Purpose |
|--------|---------|
| `main` | Production-ready code. Stable at all times. |
| `develop` | Integration branch. All feature branches merge here first. |

## Branch Types

| Pattern | Purpose | Example |
|---------|---------|---------|
| `feature/<domain>-<short-task>` | New feature work | `feature/identity-session-foundation` |
| `fix/<domain>-<short-issue>` | Bug fix | `fix/routing-ai-reply-guard` |
| `test/<domain>-<test-scope>` | Test additions | `test/authz-cross-tenant-denial` |
| `docs/<domain>-<topic>` | Documentation | `docs/orders-state-machine` |

## Workflow

```
main ← develop ← feature/<domain>-<task>
```

1. Create feature branch from `develop`
2. Work on the feature, commit per domain rules
3. Open PR to `develop`
4. After review + tests pass, merge to `develop`
5. Periodically merge `develop` → `main` for releases

## Branch Naming Examples

```
feature/identity-session-foundation
feature/tenancy-business-membership
feature/authz-access-control
feature/channels-inbound-message
feature/conversations-inbox-core
feature/routing-handoff-flow
feature/ai-runtime-provider-foundation
feature/knowledge-prompt-templates
feature/orders-create-order
feature/actions-execution-service
feature/approvals-decision-flow
feature/analytics-dashboard-metrics
feature/cases-callback-scheduling
fix/routing-prevent-ai-reply-when-operator-owns
test/orders-payment-provider-validation
docs/architecture-level-ab-separation
```

## Rules

1. **Always branch from `develop`** — never from `main` directly (except hotfixes).
2. **One domain per branch** — keep branches focused.
3. **Short-lived branches** — merge within days, not weeks.
4. **Delete after merge** — clean up merged branches.
5. **Hotfix exception** — for critical production fixes, branch from `main`, fix, merge to both `main` and `develop`.
