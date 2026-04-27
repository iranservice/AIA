# AIA — Multi-Tenant B2B AI Receptionist Platform

## Architecture

**Runtime:** Node.js 20+ / TypeScript 5.8+
**Database:** PostgreSQL 15 (Supabase)
**API:** PostgREST (CRUD) + plpgsql RPCs (business logic) + Deno Edge Functions (external integrations)
**Auth:** Supabase Auth (JWT, magic link, OAuth, OTP)
**Tenant Isolation:** Shared DB with Row-Level Security (RLS)
**Architecture:** Modular monolith with explicit domain boundaries

## Project Structure

```
AIA/
├── supabase/
│   ├── config.toml                   # Supabase local config
│   ├── migrations/                   # Sequential SQL migrations
│   └── functions/                    # Deno Edge Functions (future)
│
├── src/
│   ├── domains/                      # Domain modules
│   │   ├── identity/                 # Users, auth, sessions
│   │   ├── tenancy/                  # Businesses, memberships, config
│   │   ├── authz/                    # Roles, permissions, policies
│   │   ├── crm/                      # Customers, identities, tags
│   │   ├── channels/                 # Inbound/outbound, providers, adapters
│   │   ├── conversations/            # Messages, windows, inbox
│   │   ├── routing/                  # Ownership, handoff, assignment
│   │   ├── ai_runtime/              # AI inference, interaction logs
│   │   ├── knowledge/                # Knowledge bases, entries
│   │   ├── ai_config/               # Prompt templates, AI policies
│   │   ├── actions/                  # Action definitions, execution
│   │   ├── orders/                   # Order lifecycle, state machine
│   │   ├── reservations/             # Reservation management
│   │   ├── cases/                    # Tickets, callbacks, escalation
│   │   ├── approvals/                # Approval requests, decisions
│   │   ├── audit/                    # Universal audit trail
│   │   ├── billing/                  # Level A usage/billing
│   │   └── analytics/                # Operational metrics
│   │
│   ├── shared/                       # Shared kernel (types, errors, utils)
│   └── contracts/                    # API contract definitions
│
├── test/                             # Tests mirror domain structure
├── config/                           # App configuration
├── docs/                             # Governance & architecture docs
│   ├── DOMAIN_MAP.md
│   ├── DEVELOPMENT_PIPELINE.md
│   ├── COMMIT_CONVENTION.md
│   └── QA_STRATEGY.md
│
├── .env.example
├── package.json
└── tsconfig.json
```

## Business Levels

- **Level A** = Platform business (our own billing, SMS panel, email, WhatsApp, automation)
- **Level B** = Tenant businesses (their own payment gateway, channels, integrations)

**Critical rule:** Level B payments use the tenant's own payment gateway. Never route through Level A.

## Getting Started

```bash
pnpm install
cp .env.example .env
pnpm typecheck
```

## Documentation

- [DOMAIN_MAP.md](docs/DOMAIN_MAP.md) — 19-domain architecture with dependency rules
- [DEVELOPMENT_PIPELINE.md](docs/DEVELOPMENT_PIPELINE.md) — Phase roadmap and branch strategy
- [COMMIT_CONVENTION.md](docs/COMMIT_CONVENTION.md) — Commit format and rules
- [QA_STRATEGY.md](docs/QA_STRATEGY.md) — QA checklist and test structure
