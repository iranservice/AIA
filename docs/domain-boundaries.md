# Domain Boundaries

## Boundary Rules

1. **No cross-domain table access in RPCs** — Each domain's RPCs only write to their own tables. Cross-domain coordination goes through the action engine or explicit domain RPCs.

2. **Shared read is allowed** — A conversation RPC can read customer data to validate, but it doesn't write to the customers table directly.

3. **Action engine orchestrates** — When AI or an operator triggers a cross-domain operation (e.g., "create an order from this conversation"), the action engine calls the target domain's RPC. It never duplicates domain logic.

4. **Provider registry is referenced, not owned** — Domains reference `provider_registry.id` via FK, but provider management is owned by the providers domain.

5. **Audit is append-only** — Any domain can call `log_audit()`, but no domain reads or modifies audit logs as part of business logic.

## Domain Dependency Map

```
identity ← tenancy ← rbac ← customer ← conversation
                                              ↓
                                    order, reservation, tickets
                                              ↓
                                       action-engine
                                              ↓
                                    ai-runtime, providers
                                              ↓
                                      audit, billing
```

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
