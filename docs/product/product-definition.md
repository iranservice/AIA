# AIA — Product Definition

> **Last updated**: 2026-05-05
> **Status**: Foundation — drives MVP scope and engineering roadmap.

---

## 1. Product One-Liner

**AIA is a multi-tenant AI Receptionist platform that lets service businesses automate customer conversations across messaging channels — with human-quality responses, built-in governance, and seamless operator handoff.**

---

## 2. Problem Statement

Service businesses (restaurants, clinics, salons) receive a high volume of repetitive customer inquiries via messaging channels: hours, availability, booking, menu, pricing, directions, and status checks. Today:

- **Small businesses** miss messages because staff are busy serving customers.
- **Medium businesses** hire dedicated receptionists or call centers, which are expensive and don't scale across channels or languages.
- **Chatbot tools** produce generic, low-quality responses that frustrate customers and damage brand trust.
- **Fragmented channels** force businesses to monitor WhatsApp, web chat, and Instagram separately, leading to delayed or dropped responses.
- **No existing platform** combines AI-powered conversation handling with domain-specific business knowledge, policy-based governance, and graceful human handoff — especially for the service verticals dominant in the Iran and MENA region.

**The result**: Lost revenue from missed inquiries, poor customer experience from delayed or robotic responses, and wasted operator time answering the same questions repeatedly.

---

## 3. Target Users

### Primary Users

| User | Role | Goal |
|---|---|---|
| **Business Owner** | Subscribes to AIA, configures AI behavior | Reduce missed inquiries, save staff time, maintain brand quality |
| **Business Manager** | Manages team, reviews conversations, adjusts settings | Ensure operational quality and SLA compliance |
| **Operator** | Handles conversations when AI cannot, or when customer requests human | Respond efficiently with AI-prepared context |

### Secondary Users

| User | Role | Goal |
|---|---|---|
| **Customer** | Sends messages via WhatsApp, Web Chat, etc. | Get fast, accurate answers without friction |
| **Platform Admin** | Manages the AIA platform itself | Onboard tenants, monitor usage, enforce limits |

---

## 4. Ideal Customer Profile (ICP)

### MVP ICP

| Attribute | Value |
|---|---|
| **Industry** | Restaurant / Cafe, Clinic / Dental / Polyclinic, Salon / Spa / Beauty |
| **Size** | 1–50 employees, single or multi-location |
| **Region** | Iran, UAE, GCC, MENA |
| **Languages** | Persian/Farsi (MVP Core for customer conversations), English (baseline), Arabic (MVP-Plus) |
| **Channel** | Primarily WhatsApp and Web Chat |
| **Pain** | High volume of repetitive customer inquiries (hours, menu, availability, booking) |
| **Sophistication** | Comfortable with WhatsApp Business; may not have IT staff |
| **Budget** | Willing to pay $50–$300/month to avoid hiring a receptionist |
| **Decision Maker** | Owner or manager, not a procurement department |

#### Language Policy

- **Persian/Farsi**: MVP Core for customer-facing conversations. The initial pilot market includes Persian-speaking service businesses in Iran and the Persian-speaking diaspora in the UAE. AI must detect Persian input and respond in Persian.
- **English**: Baseline for product documentation, admin/operator UI, and customer conversations where the customer writes in English.
- **Arabic**: MVP-Plus. Promoted to MVP Core if the first paid pilot is an Arabic-speaking business.
- **Admin/Operator UI**: English for early MVP. Persian UI localization is planned based on pilot feedback.
- **Language detection**: AI must detect the customer's language from the first message and respond in that language. Customer preferred language should be stored in the customer profile for future interactions.

### Anti-ICP (Not MVP Targets)

- Enterprise call centers (need voice, complex IVR, CRM integrations)
- E-commerce businesses (need product catalog, cart, payment — different problem)
- Businesses requiring medical diagnosis or legal advice
- Businesses with fewer than ~30 inquiries/week (ROI too low)

---

## 5. Core Use Cases

### UC-1: Automated Inquiry Response

A customer messages the business. AIA's AI Receptionist reads the conversation context, checks the business knowledge base, and responds with a relevant, branded answer — without human involvement.

**Example**: "What are your hours?" → AI reads the business profile's operating hours and responds in the customer's language.

### UC-2: Human Handoff

When AI cannot answer confidently, or the customer requests a human, AIA escalates to an available operator with full conversation context and AI-prepared summaries.

**Example**: "I want to speak to someone about my allergy" → AI hands off to an operator with context: customer name, conversation history, reason for handoff.

### UC-3: Action Proposal and Execution

AI proposes a structured action (e.g., "confirm reservation for 7 PM, party of 4") which the backend validates against business rules before execution. AI never executes actions directly.

**Example**: "Can I book a table for tonight?" → AI proposes a reservation action → backend checks availability → confirms or denies.

### UC-4: Operator Workspace

Operators use a unified inbox to manage conversations across channels. They can reply, take over from AI, assign/transfer conversations, and release back to AI when done.

### UC-5: Business Configuration

Owners/managers configure their AI Receptionist: enable/disable AI, set business profile, upload knowledge content, manage team members, and control policies.

### UC-6: Governance and Cost Control

Platform enforces per-tenant token budgets, rate limits, and content policies. Businesses see usage metrics. No uncontrolled AI spending.

### UC-7: Conversation Turn Aggregation

Customers — especially on WhatsApp — often send fragmented messages in rapid succession (e.g., "Hi" → "I wanted to ask" → "do you have a table for 4 tonight?"). AIA aggregates these rapid messages into a single complete "turn" before triggering AI processing.

**Why this matters**:
- A message is not a turn. Every inbound message is stored, but not every message triggers AI.
- Without aggregation, AI responds to "Hi" before the customer finishes their actual question, wasting tokens and producing irrelevant replies.
- Turn aggregation is MVP Core because WhatsApp and web chat users routinely send 2–5 messages within seconds.

**Behavior**: After receiving a message, AIA waits a configurable window (e.g., 3–5 seconds) for additional messages. Once the window closes without new messages, the batch is treated as a single turn and sent to AI.

### UC-8: Multimodal Input Readiness

Customers may send images (menu photos, location screenshots), voice notes, documents (PDFs, prescriptions), location pins, and contact cards. AIA must handle these inputs gracefully even before full AI processing of each modality is implemented.

**MVP behavior**:
- **Store**: All multimodal inputs are stored and attached to the conversation as message attachments with type metadata (image, audio, document, location, contact).
- **Acknowledge**: AI acknowledges receipt ("I received your image. Let me connect you with our team for assistance.").
- **Hand off if needed**: If the input is critical to the inquiry and AI cannot process the modality, trigger handoff to a human operator who can view the attachment.
- **Model-ready structure**: Attachments are stored in a format that future AI capabilities (image recognition, voice transcription, document parsing) can consume without migration.

**Post-MVP**: Full AI processing of images (menu OCR, product identification), voice notes (speech-to-text), and documents (PDF extraction).

---

## 6. Product Principles

### P1: Receptionist, Not Chatbot

AIA is a domain-specialized AI Receptionist that understands service business workflows (reservations, appointments, orders, inquiries). It is not a generic chatbot builder or conversational AI toolkit.

### P2: AI Proposes, Backend Decides

AI generates responses and proposes actions. The backend policy engine validates, authorizes, and executes. AI is never the arbiter of business logic, access control, or state transitions.

### P3: Graceful Degradation

When AI is uncertain, over budget, or encountering novel situations, it must degrade gracefully: try a fallback model, simplify the response, or hand off to a human. Never hallucinate an answer. Never go silent.

### P4: Business Identity First

Every AI response reflects the business's brand, tone, and knowledge — not a generic AI personality. The receptionist speaks as the business, not as "an AI assistant."

### P5: Channels Are Adapters

WhatsApp, Web Chat, SMS, and future channels are interchangeable adapters over a unified conversation model. Channel-specific logic (message windows, delivery receipts) is isolated at the adapter layer. Core AI and business logic is channel-agnostic.

### P6: Tenant Isolation Is Absolute

One business never sees another business's conversations, customers, configuration, or usage data. This is enforced at the database level (RLS), not just the application layer.

### P7: Human Always Available

Customers must always be able to reach a human. AI can't block handoff. Operators can always take over. The system must never create a dead end.

---

## 7. Technical Principles

### T1: Backend-First

All business logic, authorization, state transitions, and policy enforcement live in the backend (SQL RPCs, server functions). The frontend is a presentation layer that calls backend contracts.

### T2: Security Definer With Auth Checks

Database RPCs use `SECURITY DEFINER` to cross table boundaries, but always perform their own `auth.uid()` and membership/role checks internally. RLS provides defense-in-depth, not the primary authorization mechanism for RPCs.

### T3: Policy Engine Before AI

Before any AI action, the policy engine evaluates tenant-specific rules (ai_allowed, content_policy, rate limits). If policy denies, AI does not execute. This is non-negotiable.

### T4: Governance Before Provider

No real AI provider (OpenAI, Anthropic, Google) is integrated until token budgets, cost tracking, rate limiting, and content filtering are implemented and tested. The `mock-sql` provider serves as a deterministic stand-in.

### T5: Migration-Driven Schema

All schema changes go through numbered, sequential, idempotent SQL migrations. No ad-hoc schema changes. Test databases and local Supabase replay the same migration chain.

### T6: Audit Everything

Every state transition, permission change, AI interaction, and settings update is logged in the audit_log table with old/new values, actor, severity, and metadata.

### T7: Capability-Based AI

AI capabilities (reply, summarize, classify, extract, propose action) are discrete, testable functions — not a monolithic "chat with AI" endpoint. Each capability has its own context requirements, policy checks, and output contracts.

### T8: Modular Monolith First

The backend is organized as a modular monolith with domain boundaries (messaging, AI runtime, orders, auth, etc.) before considering microservices. Modules communicate through well-defined internal interfaces. Extraction to separate services is a future optimization, not a prerequisite.

### T9: Outbox and Idempotency

All outbound messages and notifications use an outbox pattern to prevent duplicate delivery. Every external-facing operation (message send, webhook delivery, action execution) must be idempotent — safe to retry without side effects. This prevents duplicate messages to customers, which is a critical UX failure.

### T10: Usage Ledger

Every AI interaction records token count, estimated cost, provider, model, and tenant in a usage ledger. This is distinct from audit logging — the usage ledger drives cost tracking, budget enforcement, and billing. No AI call may execute without a corresponding ledger entry.

---

## 8. Competitive Positioning

### Market Landscape

| Competitor Category | Examples | What They Do | AIA Differentiation |
|---|---|---|---|
| **Support Automation** | Tidio, Intercom, Zendesk | Generic customer support chatbots and ticketing | AIA is domain-specialized for service businesses; understands reservations, menus, appointments natively — not a generic support tool |
| **Chat Flow Builders** | Landbot, ManyChat | Visual chatbot flow builders for WhatsApp/Messenger | AIA uses AI comprehension, not decision trees; handles novel questions without pre-built flows |
| **WhatsApp Platforms** | WATI, Respond.io | WhatsApp-specific automation and CRM | AIA is channel-agnostic; same AI works across Web Chat, WhatsApp, SMS. Channels are adapters, not the product |
| **Vertical Booking** | OpenTable, Resy | Restaurant reservation and waitlist workflow | AIA is conversation-first — AI handles the customer inquiry via messaging. OpenTable is UI-first — customer navigates a booking form. AIA can complement or replace the messaging layer |
| **Vertical Appointments** | Zocdoc, Doctolib | Clinic/dental appointment and patient intake | Same conversation-first differentiation. AIA handles the inquiry; backend proposes the appointment. Zocdoc requires the patient to use a booking portal |
| **Vertical Wellness** | Mindbody, Fresha | Salon, spa, and wellness booking workflow | AIA adds AI-powered conversational booking on top of or alongside these platforms. Not a replacement for their POS/scheduling core |
| **Messaging Infrastructure** | Twilio, MessageBird | Low-level messaging APIs and voice infrastructure | AIA is an application, not infrastructure. Twilio provides the pipes; AIA provides the intelligence and workflow |
| **Custom GPT Wrappers** | Various | "Build your own AI chatbot" with ChatGPT API | AIA provides full operational backend: handoff, team management, policy governance, action execution, cost control — not just a chat UI over an API |

### AIA's Positioning

AIA is positioned as **a purpose-built AI Receptionist platform for service businesses** — combining AI-powered conversation handling with domain-specific business profiles, policy-governed actions, and seamless human handoff.

Unlike pure infrastructure (Twilio), AIA is a complete application. Unlike pure chatbots (ManyChat), AIA understands business workflows. Unlike vertical booking platforms (OpenTable, Zocdoc, Mindbody), AIA is conversation-first — meeting customers where they already are (WhatsApp, web chat) instead of requiring them to navigate a separate booking UI.

Key differentiators:
1. **Domain-specific business profiles** (restaurant, clinic, salon) — not a generic chatbot
2. **Policy-governed AI** — token budgets, content filtering, action validation
3. **Multilingual** — Persian/Farsi and English native, Arabic planned
4. **Human handoff as a first-class feature** — not an afterthought
5. **Multi-tenant SaaS** — onboard any service business, not a one-off deployment
6. **Governance before capability** — cost control and audit trail from day one

---

## 9. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **AI hallucination** — AI gives incorrect information (wrong hours, wrong menu, wrong availability) | Critical | Knowledge base grounding + confidence scoring + fallback ladder + human handoff |
| **Cost runaway** — Uncontrolled token consumption per tenant | High | Token budgets, rate limits, cost tracking, mock provider until governance is ready |
| **Channel lock-in** — Building too deep into WhatsApp specifics | Medium | Channel adapter architecture; core logic is channel-agnostic |
| **Scope creep** — Trying to be a CRM/POS/ERP | High | Strict MVP scope; business profiles, not business operations |
| **MENA regulatory** — Data residency, privacy, AI content rules | Medium | Regional hosting options; content policy engine; audit trail |
| **WhatsApp Business API cost/approval** — Meta approval process is slow and restrictive | Medium | MVP on Native Web Chat; WhatsApp as MVP-plus adapter |
| **Medical/legal liability** — AI giving health or legal advice | Critical | No diagnosis/advice; explicit scope restrictions in business profiles; content policy blocks |
| **Duplicate outbound messages** — Outbox failure or retry causes customer to receive the same message twice | High | Outbox pattern with idempotency keys; delivery status tracking; deduplication at adapter layer |
| **Provider downtime** — AI provider (OpenAI, etc.) is unavailable or degraded | Medium | Fallback ladder: primary → fallback model → stub response → human handoff. No single provider dependency |

---

## 10. Non-Negotiables

These are absolute constraints that apply at every phase:

1. **No cross-tenant data leakage.** Enforced by RLS + RPCs, tested in every phase.
2. **No AI execution without policy check.** Every AI action passes through `evaluate_policy()` before execution.
3. **No real provider without governance.** Token budgets, rate limits, and cost tracking must exist before OpenAI/Anthropic/Google keys are loaded.
4. **No client-side money or state enforcement.** Wallet, billing, and state transitions are server-enforced.
5. **No medical diagnosis or legal advice.** Content policy must block, and business profiles must disclaim.
6. **Audit trail for every mutation.** No silent state changes.
7. **Human handoff always available.** AI cannot block a customer from reaching a human.
8. **Secrets never in frontend.** API keys, service roles, and provider credentials are backend-only.
9. **No duplicate outbound messages.** Outbox + idempotency patterns must prevent double-sending to customers.
10. **No channel-specific core logic.** Business logic and AI behavior must be channel-agnostic. Channel adapters handle protocol differences only.
