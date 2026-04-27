# Commit Convention

## Format

```
<type>(<domain>): <short description>
```

## Allowed Types

| Type | Use When |
|------|----------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `test` | Adding or updating tests |
| `refactor` | Code restructuring without behavior change |
| `docs` | Documentation only |
| `chore` | Tooling, dependencies, CI, non-code changes |
| `perf` | Performance improvement |
| `ci` | CI/CD pipeline changes |

## Domain Names

Use the canonical domain name:

```
identity | tenancy | authz | crm | channels | conversations | routing |
ai_runtime | knowledge | ai_config | actions | orders | reservations |
cases | approvals | audit | billing | analytics | shared
```

For infrastructure or cross-cutting: `infra`, `deps`, `ci`.

## Examples

```
feat(identity): add user session foundation
feat(tenancy): add business membership model
feat(authz): implement access control service
test(authz): add cross-tenant denial tests
feat(channels): add inbound webhook ingestion
feat(crm): resolve customer from channel identity
feat(conversations): add message persistence and inbox query
feat(routing): add ownership history and handoff events
fix(routing): prevent AI reply when operator owns conversation
feat(ai_runtime): add OpenAI provider abstraction
feat(knowledge): add knowledge base entry CRUD
feat(ai_config): add prompt template versioning
feat(actions): add action handler registry
feat(orders): add create order flow
test(orders): add order confirmation flow tests
feat(approvals): add approval decision lifecycle
feat(analytics): add conversation metrics aggregation
```

## Rules

1. **One domain per commit.** One commit belongs to one clear domain or one closely related integration point.
2. **No cross-domain mixing.** Do not mix unrelated domains in one commit.
3. **No UI + backend mixing.** Do not mix UI and backend sensitive logic in one commit.
4. **Explicit migrations.** Migration commits: `feat(<domain>): add <table> migration`.
5. **Tests with features.** Tests should be committed with or immediately after the related feature.
6. **Small commits.** If a change touches more than 3 domains, split it or explain why.
7. **Revertable.** Every commit should be revertable without breaking unrelated domains.

## Sensitive Flows Requiring Tests Before Merge

- `authz` — tenant isolation, cross-tenant denial
- `routing` — operator reply, handoff, AI/operator state
- `actions` — action execution, handler dispatch
- `orders` — order creation, status transitions, payment provider validation
- `approvals` — approval flow, expiration
- Level A/B payment separation
