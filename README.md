# AIA — Multi-Tenant B2B AI Receptionist Platform

Backend core for a multi-tenant B2B AI receptionist platform built with modular monolith architecture.

## Architecture

- **Runtime**: Node.js 20+ / TypeScript 5.8+
- **Database**: PostgreSQL 15 (Supabase)
- **API**: PostgREST (auto-generated CRUD) + plpgsql RPCs (business logic) + Deno Edge Functions (external integrations)
- **Auth**: Supabase Auth (JWT, magic link, OAuth, OTP)
- **Tenant Isolation**: Shared DB with Row-Level Security (RLS)

## Project Structure

```
AIA/
├── supabase/
│   ├── config.toml           # Supabase local config
│   ├── migrations/           # Sequential SQL migrations (00001-00017)
│   ├── functions/            # Deno Edge Functions
│   └── seeds/                # Dev seed data
├── src/
│   ├── domains/              # Domain modules
│   │   ├── identity/         # User profiles
│   │   ├── tenancy/          # Businesses, memberships, channels
│   │   ├── rbac/             # Roles, permissions, policy engine
│   │   ├── customer/         # End-customer CRM
│   │   ├── conversation/     # Messaging, routing, assignment
│   │   ├── order/            # Order state machine
│   │   ├── reservation/      # Reservation management
│   │   ├── tickets/          # Support tickets & callbacks
│   │   ├── action-engine/    # Action orchestration & approvals
│   │   ├── providers/        # External integration registry
│   │   ├── ai-runtime/       # AI agent config & interaction logs
│   │   ├── audit/            # Universal audit trail
│   │   └── billing/          # Platform (Level A) billing
│   ├── contracts/            # API contract definitions
│   └── lib/                  # Shared utilities
├── docs/                     # Documentation
├── .env.example              # Environment template
├── package.json
└── tsconfig.json
```

## Domain Modules

| Module | Responsibility |
|--------|---------------|
| **identity** | User profiles, auth trigger |
| **tenancy** | Business entities, memberships, channels, operating hours |
| **rbac** | Permissions, role-permission mapping, policy rules |
| **customer** | End-customer CRM, multi-channel identity resolution |
| **conversation** | Conversations, messages, windows, routing, assignment |
| **order** | Order CRUD, state machine, customer confirmation |
| **reservation** | Reservation CRUD, double-booking prevention |
| **tickets** | Support tickets, callback scheduling |
| **action-engine** | Action definitions, execution log, approval workflow |
| **providers** | External integration registry (Level A + Level B) |
| **ai-runtime** | AI agent configs, interaction logging |
| **audit** | Universal audit trail |
| **billing** | Platform-level usage metering and billing events |

## Critical Business Rules

1. **Level A vs Level B Payment Isolation**: Order payments MUST use the tenant's own payment gateway (Level B). Platform billing (Level A) is completely separate.
2. **Server-Side State Machines**: Order and reservation status transitions are enforced server-side via RPCs. No client-side shortcuts.
3. **RBAC Enforcement**: All permission checks go through `check_permission()` RPC. Owner bypasses all. Platform admin bypasses tenant isolation.
4. **AI Policy Compliance**: AI runtime must evaluate policies before executing any action. Interactions are fully logged with policy traces.

## Getting Started

```bash
# Install dependencies
pnpm install

# Copy environment file
cp .env.example .env

# TypeScript validation
pnpm typecheck
```

## Migrations

Migrations are in `supabase/migrations/` and numbered sequentially:

| # | Migration | Domain |
|---|-----------|--------|
| 00001 | Extensions | Infrastructure |
| 00002 | Enums | Shared |
| 00003 | Identity | identity |
| 00004 | Tenancy | tenancy |
| 00005 | RBAC | rbac |
| 00006 | Customer | customer |
| 00007 | Conversation | conversation |
| 00008 | Order | order |
| 00009 | Reservation | reservation |
| 00010 | Tickets | tickets |
| 00011 | Action Engine | action-engine |
| 00012 | Provider Registry | providers |
| 00013 | AI Runtime | ai-runtime |
| 00014 | Audit | audit |
| 00015 | Billing | billing |
| 00016 | RLS Policies | security |
| 00017 | Seed Data | all |
