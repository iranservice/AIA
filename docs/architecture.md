# Architecture Overview

## System Architecture

AIA is a multi-tenant B2B AI receptionist platform built as a **modular monolith** on Supabase/PostgreSQL.

### Why Modular Monolith?

1. **Single deployable** — Simpler operations for an early-stage product
2. **Explicit domain boundaries** — Domain isolation via module structure and RPC boundaries, not network calls
3. **Future-proof** — Clean module boundaries make extraction to microservices possible if needed later
4. **Supabase-native** — Leverages PostgREST, RLS, Edge Functions, and Realtime without middleware

### API Layer

| Layer | Technology | Use Case |
|-------|-----------|----------|
| **PostgREST** | Auto-generated from schema | CRUD operations on tables (filtered by RLS) |
| **plpgsql RPCs** | PostgreSQL functions | Business logic, state machines, permission checks |
| **Edge Functions** | Deno on Supabase | External integrations, webhooks, AI inference |

### Security Model

1. **Authentication**: Supabase Auth (JWT tokens)
2. **Authorization**: Three-layer model:
   - **RLS**: Row-level security on every table prevents cross-tenant data access
   - **RBAC**: Role-based permission checks via `check_permission()` RPC
   - **Policy Engine**: Configurable business rules via `evaluate_policy()` RPC
3. **Secrets**: Provider API keys stored in `provider_registry.api_config`, accessible only via secure RPCs

### Multi-Tenancy

- **Strategy**: Shared database, Row-Level Security
- **Isolation Key**: `business_id` column on every tenant-scoped table
- **Helper**: `is_business_member()` function used in RLS policies
- **Platform Override**: `is_platform_admin()` allows platform admins to read across tenants

### Business Type Extensibility

The system is not locked to restaurants. `business_type` enum + `business_config` JSONB allows:
- Restaurant-specific config (menu, delivery, prep time)
- Clinic-specific config (specialties, appointment duration)
- Salon-specific config (service categories)
- Any future business type without schema changes

### Voice Readiness

The data model is voice-ready:
- `channel_type` includes `'voice'`
- `message_content_type` includes `'audio'`
- `provider_type` includes `'voice'`
- Conversation routing supports voice channel
- No WebRTC/SIP infrastructure built yet (future phase)
