# AIA — MVP Scope

> **Last updated**: 2026-05-05
> **Status**: Foundation — defines what is in and out of the Minimum Viable Product.
> **Reference**: [Product Definition](./product-definition.md)

---

## 1. MVP Objective

**Ship a working AI Receptionist that can handle common customer inquiries for service businesses — with governance, human handoff, and a usable operator workspace — to validate product-market fit with 5–15 pilot businesses in Iran and the UAE.**

The MVP is not a demo. It is a real product that real businesses use with real customers. It must be reliable, governed, and graceful when it reaches its limits.

### MVP Exit Criteria

> [!NOTE]
> All numeric targets below are **pilot hypotheses**, not commitments. They will be validated and adjusted during the first cohort of 5–15 pilot businesses.

- [ ] 5+ pilot businesses onboarded and actively using AIA
- [ ] AI handles 30–50% of FAQ-heavy inquiries without human intervention (pilot hypothesis)
- [ ] Average first-response time < 5 seconds after turn closure for web chat
- [ ] Zero cross-tenant data leakage incidents
- [ ] Zero uncontrolled AI cost incidents (all within budget)
- [ ] Operators can take over and release back to AI without friction
- [ ] Positive qualitative feedback from pilot business owners

---

## 2. MVP Target Verticals

### 2.1 Restaurant / Cafe

**Why**: Highest inquiry volume, most repetitive questions, clear ROI.

| Capability | MVP Scope |
|---|---|
| Menu inquiry | AI answers from uploaded menu knowledge base |
| Hours / location | AI reads from business profile |
| Reservation inquiry | AI proposes reservation action (date, time, party size); backend validates availability |
| Order status | AI retrieves order status from order table |
| Delivery inquiry | AI responds with delivery info from knowledge base; **no delivery dispatch integration** |
| Dietary / allergy | AI answers from menu metadata; disclaims when uncertain |
| Complaints | AI acknowledges, logs, and hands off to human |

**Not MVP**: POS integration, online ordering with payment, delivery dispatch, kitchen display.

**Success signal**: Order draft created from conversation, menu Q&A resolved without handoff, reservation request captured and confirmed.

**Required data model**: menu/catalog items, order drafts, order line items, confirmation policy, business hours/location profile.

### 2.2 Clinic / Dental / Polyclinic

**Why**: High appointment volume, strong need for after-hours responsiveness.

| Capability | MVP Scope |
|---|---|
| Service inquiry | AI answers from services knowledge base (procedures, pricing ranges) |
| Hours / location / insurance | AI reads from business profile and knowledge base |
| Appointment inquiry | AI proposes appointment action (date, time, service, provider); backend validates |
| Wait time | AI retrieves from business status if available; disclaims if not |
| Prescription / referral | **AI does NOT provide medical advice**; hands off to human |
| Emergency triage | AI detects urgency keywords and immediately hands off with priority flag |

**Not MVP**: EMR/EHR integration, diagnosis, prescription management, lab results, telemedicine.

**Success signal**: Appointment draft created with service/provider/time selected, patient intake info captured, medical safety handoff triggered correctly.

**Required data model**: service catalog, provider/staff directory, appointment slots, intake form fields, medical safety content policy (no diagnosis, no prescription).

> [!CAUTION]
> **AIA must never provide medical diagnosis, treatment recommendations, or medication advice.** Content policy must block these topics. Business profile for clinics must include explicit disclaimers. AI must hand off to a human for any health-related question beyond scheduling and general information.

### 2.3 Salon / Spa / Beauty

**Why**: High booking volume, strong preference for messaging over phone calls.

| Capability | MVP Scope |
|---|---|
| Service inquiry | AI answers from services knowledge base (treatments, pricing, duration) |
| Hours / location | AI reads from business profile |
| Booking inquiry | AI proposes appointment action (date, time, service, stylist/therapist); backend validates |
| Cancellation / reschedule | AI proposes cancellation or reschedule action; backend enforces cancellation policy |
| Product inquiry | AI answers from product knowledge base if uploaded |
| Loyalty / membership | AI reads membership status if available; **no loyalty program management** |

**Not MVP**: POS integration, product e-commerce, loyalty program management, staff scheduling.

**Success signal**: Service/staff/time selected via conversation, appointment draft created and confirmed, cancellation policy enforced.

**Required data model**: service catalog, staff schedule/availability, appointment slots, no-show/cancellation policy.

---

## 3. MVP Channel Scope

| Channel | MVP Status | Rationale |
|---|---|---|
| **Native Web Chat** | ✅ **MVP Core** | No third-party dependency; embeddable widget; full control over UX |
| **WhatsApp Business API** | 🟡 **MVP-Plus** | Most requested channel in MENA; requires Meta Business verification; adapter ready, pending official API integration |
| **WhatsApp Web Bridge** | 🔴 **Labs / Post-MVP** | Unofficial; TOS risk; useful for pilot validation only |
| **SMS** | 🔴 **Post-MVP** | Low priority in MENA (WhatsApp dominates); adapter architecture supports it |
| **Voice** | 🔴 **Post-MVP** | High complexity; different AI modality; only if a pilot specifically requires it |
| **Telegram** | 🔴 **Post-MVP** | Low priority; adapter architecture supports it |
| **Instagram DM** | 🔴 **Post-MVP** | Dependent on Meta API; low priority vs. WhatsApp |

### Channel Architecture Note

All channels are **adapters** over the unified conversation model. Adding a new channel means implementing:
1. Inbound message adapter (external → `ingest_inbound_message`)
2. Outbound delivery adapter (`messages` table → external)
3. Channel-specific metadata (message windows, delivery receipts)

Core AI logic, policy evaluation, and operator workflows are **channel-agnostic**.

---

## 4. MVP AI Scope

### 4.1 AI Capabilities (MVP)

| Capability | Status | Description |
|---|---|---|
| **Reply** | ✅ MVP Core | Generate contextual, branded responses to customer messages |
| **Summarize** | ✅ MVP Core | Summarize conversation history for operator handoff |
| **Classify** | ✅ MVP Core | Classify inquiry intent (FAQ, booking, complaint, urgent) |
| **Extract** | ✅ MVP Core | Extract structured data from messages (dates, names, service types) |
| **Propose Action** | ✅ MVP Core | Propose structured actions (reserve, book, cancel) for backend validation |
| **Translate / Language Detection** | ✅ MVP Core | Detect customer language (Persian, English) and respond accordingly. Arabic is MVP-Plus |
| **Generate** | 🔴 Post-MVP | Generate marketing content, follow-ups, campaigns |

### 4.2 AI Provider Strategy

| Phase | Provider | Purpose |
|---|---|---|
| **Current** | `mock-sql` | Deterministic stub responses; no external API calls; safe for all testing |
| **MVP** | Single real provider (OpenAI GPT-4o or equivalent) | Production AI responses; gated behind governance |
| **Post-MVP** | Multi-provider with failover | Provider fallback ladder; cost optimization; model selection per capability |

> [!IMPORTANT]
> **No real AI provider is integrated until all of the following are implemented and tested:**
> - Token budget per tenant (daily/monthly caps)
> - Cost tracking per interaction
> - Rate limiting per tenant and per conversation
> - Content filtering (input and output)
> - Fallback ladder (primary → fallback → stub → handoff)
> - Provider secret management (Vault or equivalent, never in frontend)

### 4.3 AI Behavior Constraints

1. **AI never executes actions directly.** It proposes actions that the backend policy/action engine validates and executes.
2. **AI never stores or processes payment information.** Payment references are handled by backend integrations.
3. **AI never provides medical, legal, or financial advice.** It acknowledges the request and hands off to a human.
4. **AI always identifies itself when asked.** It does not pretend to be human.
5. **AI responses reflect the business's brand and tone**, configured in the business profile.
6. **AI confidence below threshold triggers fallback**, not a hallucinated response.

---

## 5. MVP Action Scope

Actions are structured operations that AI can propose and the backend can execute.

| Action | MVP Status | Description |
|---|---|---|
| **Create Reservation** | ✅ MVP Core | Propose reservation (date, time, party size, notes); backend checks availability |
| **Create Appointment** | ✅ MVP Core | Propose appointment (date, time, service, provider); backend checks availability |
| **Cancel Reservation/Appointment** | ✅ MVP Core | Propose cancellation; backend enforces cancellation policy |
| **Create Order** | ✅ MVP Core | Create order from conversation context; backend validates items and pricing |
| **Update Order Status** | ✅ MVP Core | Transition order status (confirmed → preparing → ready); server-enforced state machine |
| **Create Ticket** | 🟡 MVP-Plus | Create support ticket from conversation for tracking |
| **Send Notification** | 🔴 Post-MVP | Proactive notifications (appointment reminders, order updates) |
| **Process Payment** | 🔴 Post-MVP | Payment processing; requires PCI compliance and payment provider integration |
| **Dispatch Delivery** | 🔴 Post-MVP | Delivery dispatch; requires logistics provider integration |

### Action Execution Model

```
Customer Message → AI Classification → Action Proposal → Policy Check → Backend Validation → Execution → Response
```

AI proposes. Policy checks. Backend executes. AI never has direct write access to business data.

---

## 6. MVP Operator/Handoff Scope

### 6.1 Operator Workspace (MVP)

| Feature | MVP Status |
|---|---|
| Unified inbox across channels | ✅ MVP Core |
| Conversation list with status filtering | ✅ MVP Core |
| Conversation detail with message history | ✅ MVP Core |
| Operator reply | ✅ MVP Core |
| Assign / unassign conversation | ✅ MVP Core |
| Transfer conversation between operators | ✅ MVP Core |
| Take handoff from AI | ✅ MVP Core |
| Release back to AI | ✅ MVP Core |
| Customer profile sidebar | ✅ MVP Core |
| Order view / cancel from conversation | ✅ MVP Core |
| Canned responses / templates | 🟡 MVP-Plus |
| Operator presence / online status | 🔴 Post-MVP |
| Conversation SLA timers | 🔴 Post-MVP |
| Analytics dashboard | 🔴 Post-MVP |

### 6.2 Handoff Model (MVP)

#### Fallback Ladder

The fallback ladder defines what happens when AI cannot respond:

```
1. Primary AI Provider (e.g., GPT-4o)
   ↓ (fails: timeout, error, low confidence)
2. Fallback AI Provider (e.g., lighter model)
   ↓ (fails)
3. Stub/Template Response ("I'll connect you with a team member")
   ↓
4. Human Handoff (assign to available operator or queue)
```

> [!IMPORTANT]
> **Turn Aggregation** is MVP Core. When a customer sends multiple messages rapidly (common in WhatsApp), AIA must aggregate them into a single AI "turn" before processing. Without this, AI responds to partial messages and wastes tokens.

#### Handoff Triggers

| Trigger | Type | MVP |
|---|---|---|
| Customer requests human | Explicit | ✅ |
| AI confidence below threshold | Automatic | ✅ |
| AI provider error/timeout | Automatic | ✅ |
| Token budget exhausted | Automatic | ✅ |
| Content policy violation | Automatic | ✅ |
| Sensitive topic detected (medical, legal) | Automatic | ✅ |
| Operator manually takes over | Manual | ✅ |
| Scheduled handoff (business hours) | Scheduled | 🟡 MVP-Plus |

#### Re-entry After Handoff

When an operator releases a conversation back to AI:
1. AI receives full conversation context including operator messages.
2. AI acknowledges the handoff return naturally.
3. AI resumes from current state, not from scratch.
4. If AI fails again immediately, it does not re-trigger handoff loop (circuit breaker).

---

## 7. MVP Knowledge/Content Scope

### 7.1 Knowledge Base (MVP)

| Source | MVP Status | Description |
|---|---|---|
| **Business Profile** | ✅ MVP Core | Hours, location, contact, type-specific fields (menu categories, services, etc.) |
| **FAQ Documents** | ✅ MVP Core | Uploaded text/markdown; indexed for retrieval |
| **Menu / Service List** | ✅ MVP Core | Structured data per business type (items, prices, categories) |
| **Website Scraping** | 🔴 Post-MVP | Auto-extract knowledge from business website |
| **Document Upload (PDF)** | 🟡 MVP-Plus | Parse and index uploaded documents |
| **Google Business Profile Sync** | 🔴 Post-MVP | Auto-sync hours, reviews, photos |

### 7.2 Content Policy (MVP)

| Policy | MVP Status | Description |
|---|---|---|
| **Input filtering** | ✅ MVP Core | Block harmful/abusive content before AI processes it |
| **Output filtering** | ✅ MVP Core | Block AI responses that violate content policy |
| **Topic restrictions** | ✅ MVP Core | Per-business-type blocked topics (e.g., medical advice for clinics) |
| **Competitor mention policy** | 🟡 MVP-Plus | Policy for handling competitor inquiries |
| **PII handling policy** | ✅ MVP Core | Mask/redact PII in logs; do not store in AI context |

---

## 8. MVP Governance Scope

Governance is the system that controls AI behavior, cost, and risk. **Governance is MVP Core, not Post-MVP.**

| Governance Feature | MVP Status | Description |
|---|---|---|
| **Token budget per tenant** | ✅ MVP Core | Daily and monthly token caps; alerts at 80%, hard stop at 100% |
| **Cost tracking per interaction** | ✅ MVP Core | Record token count, estimated cost per AI interaction |
| **Rate limiting** | ✅ MVP Core | Max AI calls per minute per tenant; prevents abuse and runaway |
| **Turn aggregation** | ✅ MVP Core | Aggregate rapid customer messages before AI processing |
| **Content policy evaluation** | ✅ MVP Core | Evaluate input/output against tenant content policies |
| **AI settings contract** | ✅ MVP Core | `get_business_ai_settings` / `update_business_ai_settings` RPCs |
| **Provider mode lock** | ✅ MVP Core | `mock_sql` only until governance is fully tested |
| **Audit logging** | ✅ MVP Core | Every AI interaction, settings change, and policy evaluation logged |
| **Usage dashboard** | 🟡 MVP-Plus | Visual dashboard for business owners to see AI usage and costs |
| **Billing integration** | 🔴 Post-MVP | Automated billing based on usage; requires payment provider |

---

## 9. Non-MVP Scope (Explicit Exclusions)

The following are **intentionally excluded** from MVP. They are not forgotten — they are deferred.

| Feature | Why Excluded | When |
|---|---|---|
| **POS integration** | Complex integration; varies by provider; MVP validates AI reception, not operations | Post-MVP |
| **Payment processing** | PCI compliance; payment provider integration; separate product concern | Post-MVP |
| **Delivery dispatch** | Logistics provider integration; separate operational domain | Post-MVP |
| **Voice channel** | Different AI modality (STT/TTS); high latency requirements; separate UX | Post-MVP (unless pilot requires) |
| **Medical diagnosis** | Liability; regulatory; explicitly blocked by content policy | Never in AIA scope |
| **Legal advice** | Liability; explicitly blocked by content policy | Never in AIA scope |
| **E-commerce / product catalog** | Different product (online store); MVP is for service businesses | Post-MVP or separate product |
| **CRM integration** | Complex; varies by CRM; MVP stores customer data natively | Post-MVP |
| **Marketing automation** | Different product domain; proactive campaigns vs. reactive reception | Post-MVP |
| **Multi-language beyond FA/EN/AR** | Persian and English are MVP Core; Arabic is MVP-Plus; French, Urdu, Turkish in future | Post-MVP |
| **White-label / reseller** | Enterprise concern; MVP is direct SaaS | Post-MVP |
| **Mobile app** | Web-first; responsive design covers mobile operators | Post-MVP |
| **SSO / SAML** | Enterprise auth; MVP uses magic link / email auth | Post-MVP |
| **Custom AI model fine-tuning** | Requires significant data per tenant; base model with knowledge base is MVP | Post-MVP |
| **Workflow builder** | Visual flow builder; MVP uses profile-driven behavior, not user-built flows | Post-MVP |

---

## 10. User Stories

### Business Owner

| ID | Story | Priority |
|---|---|---|
| **BO-1** | As a business owner, I can sign up and create my business profile so AIA knows my business type, hours, and services. | MVP Core |
| **BO-2** | As a business owner, I can upload my menu/service list so AI can answer customer questions about offerings. | MVP Core |
| **BO-3** | As a business owner, I can enable/disable AI for my business so I control when AI responds. | MVP Core |
| **BO-4** | As a business owner, I can invite team members as operators so they can handle conversations. | MVP Core |
| **BO-5** | As a business owner, I can see conversation history so I can monitor quality. | MVP Core |
| **BO-6** | As a business owner, I can see AI usage metrics so I understand cost and value. | MVP-Plus |
| **BO-7** | As a business owner, I can embed a web chat widget on my website. | MVP Core |

### Operator

| ID | Story | Priority |
|---|---|---|
| **OP-1** | As an operator, I can see my inbox of assigned and unassigned conversations. | MVP Core |
| **OP-2** | As an operator, I can reply to a customer message. | MVP Core |
| **OP-3** | As an operator, I can take over a conversation from AI. | MVP Core |
| **OP-4** | As an operator, I can release a conversation back to AI when I'm done. | MVP Core |
| **OP-5** | As an operator, I can assign/transfer a conversation to another operator. | MVP Core |
| **OP-6** | As an operator, I can see the customer's profile and conversation history. | MVP Core |
| **OP-7** | As an operator, I can view and manage orders from the conversation workspace. | MVP Core |

### Customer

| ID | Story | Priority |
|---|---|---|
| **CU-1** | As a customer, I can message a business and get an immediate, relevant response. | MVP Core |
| **CU-2** | As a customer, I can request to speak to a human at any time. | MVP Core |
| **CU-3** | As a customer, I can ask about hours, menu, services, and get accurate answers. | MVP Core |
| **CU-4** | As a customer, I can request a reservation or appointment through the conversation. | MVP Core |
| **CU-5** | As a customer, I can ask about my order status. | MVP Core |

### Manager / Supervisor

| ID | Story | Priority | Acceptance Criteria |
|---|---|---|---|
| **MG-1** | As a manager, I can configure AI actions, approvals, and handoff rules so that AI follows business policy. | MVP Core | Manager can update AI settings; changes reflected in AI behavior within 1 minute |
| **MG-2** | As a manager, I can review AI conversation quality for my team. | MVP Core | Manager can view all conversations and filter by AI-handled vs. human-handled |

### Platform Admin

| ID | Story | Priority | Acceptance Criteria |
|---|---|---|---|
| **PA-1** | As a platform admin, I can onboard a new business and set its subscription tier. | MVP Core | Business created with correct profile type; AI settings defaulted to disabled |
| **PA-2** | As a platform admin, I can monitor tenant usage, AI failures, and system health. | MVP Core | Usage dashboard shows token consumption, error rate, and active conversations per tenant |

### Business Admin / Finance

| ID | Story | Priority | Acceptance Criteria |
|---|---|---|---|
| **BA-1** | As a business admin, I can see AI usage and budget status so that I can control cost. | MVP-Plus | Usage page shows daily/monthly token usage, remaining budget, and cost estimate |

---

## 11. Acceptance Criteria

### AC-1: AI Response Quality

- AI responds within 30 seconds of customer message.
- AI uses information from the business knowledge base, not hallucinated facts.
- AI maintains the business's configured tone and brand.
- AI correctly identifies when it cannot answer and triggers handoff.
- AI does not provide medical, legal, or financial advice.

### AC-2: Handoff Reliability

- Handoff from AI to human completes within 5 seconds.
- Operator receives full conversation context on handoff.
- Release back to AI resumes conversation naturally.
- Fallback ladder activates on provider failure within 10 seconds.
- Turn aggregation waits 3–5 seconds before processing rapid messages.

### AC-3: Governance

- Token budget enforcement prevents exceeding daily/monthly caps.
- Rate limiting prevents more than N AI calls per minute per tenant.
- Content policy blocks harmful input and output.
- All AI interactions are logged with token count and cost.
- Business owner can enable/disable AI through settings UI.

### AC-4: Tenant Isolation

- No business can see another business's conversations, customers, or settings.
- RLS policies are tested in every phase with role-based allow/deny proofs.
- Cross-tenant queries return empty results, not errors (no information leakage).

### AC-5: Operator Workspace

- Inbox loads within 3 seconds.
- Conversation list updates in real-time (or near-real-time with polling).
- Reply sends within 2 seconds.
- Assign/transfer/handoff actions complete within 3 seconds.
- No data is lost on page refresh.

---

## 12. Success Metrics

> [!NOTE]
> All numeric targets are **pilot hypotheses**, not commitments. They will be validated and adjusted during the first cohort of 5–15 pilot businesses.

### Primary Metrics (MVP Validation)

| Metric | Pilot Hypothesis | Measurement |
|---|---|---|
| **AI Resolution Rate** | 30–50% of FAQ-heavy inquiries resolved without human | `conversations where AI handled / total conversations` |
| **First Response Time** | < 5 seconds after turn closure (web chat) | `first AI response timestamp - turn closure timestamp` |
| **Pilot Business Retention** | ≥ 70% after 30 days | `businesses still active at day 30 / businesses onboarded` |
| **Zero Security Incidents** | 0 cross-tenant leaks | Audit log review + automated tests |
| **Duplicate Outbound Rate** | Near 0 critical message duplicates | `duplicate message count / total outbound` |

### Secondary Metrics

| Metric | Pilot Hypothesis | Measurement |
|---|---|---|
| **Handoff Rate** | < 60% of conversations (improving over time) | `conversations with human handoff / total conversations` |
| **AI Cost per Conversation** | < $0.10 average | `total AI token cost / total conversations` |
| **Operator Workload Reduction** | 20–30% reduction vs. no-AI baseline | `conversations per operator per hour, before/after` |
| **Turn Aggregation Efficiency** | Reduce AI calls from fragmented chats by ≥ 30% | `turns processed / raw messages received` |
| **Customer Satisfaction** | Qualitative positive feedback from pilot customers | Post-conversation survey (if implemented) |

---

## 13. Pricing Hypothesis

> [!NOTE]
> This is a hypothesis for pilot validation, not a final pricing model. Actual pricing will be informed by pilot data (cost per conversation, value delivered, willingness to pay). All prices will be validated in local currency (AED for UAE, IRR/USD for Iran) during pilot.

### Tier Structure (USD Reference)

| Tier | Price/Month (USD) | Included | Target |
|---|---|---|---|
| **Starter** | $49 | 500 AI conversations/month, 1 channel, 2 operators | Solo/small business |
| **Growth** | $149 | 2,000 AI conversations/month, 2 channels, 5 operators | Growing business |
| **Pro / Multi-Channel** | $299 | 5,000 AI conversations/month, all channels, unlimited operators | Multi-location |
| **Enterprise / BYOK** | Custom | Custom limits, SLA, dedicated support, bring-your-own-key option | Large organizations (Post-MVP) |

### Pilot Pricing Strategy

- **First cohort (5–15 businesses)**: Free or 50%-discounted access for 90 days.
- **Pilot scope**: Limited to Starter/Growth tier capabilities.
- **Feedback requirement**: Pilot businesses agree to provide structured feedback (weekly survey, monthly interview).
- **Conversion target**: Convert ≥ 50% of pilot businesses to paid after 90 days (hypothesis).
- **Local-market validation**: For Iran-based pilots, pricing will be validated in USD or local equivalent. For UAE pilots, AED pricing will be offered alongside USD.

### Pricing Principles

1. **Value-based, not token-based.** Customers pay per conversation, not per token. AIA manages token efficiency internally.
2. **Predictable monthly cost.** No surprise bills. Overage is handled by graceful degradation (stub responses, handoff), not billing spikes.
3. **Free trial with real AI.** 14-day free trial with full AI capability to demonstrate value.
4. **Upsell on channels and operators.** Base tier includes web chat; WhatsApp and additional operators are upsell.

### Cost Model (Internal)

| Component | Estimated Cost |
|---|---|
| AI token cost per conversation | $0.02–$0.08 (depending on length and model) |
| Infrastructure per tenant | $2–$5/month (Supabase, hosting) |
| Gross margin target | ≥ 70% |

---

## Appendix: Phase Mapping

This table maps MVP features to the engineering phase structure already in progress.

| Feature Area | Current Phase | Status |
|---|---|---|
| Auth + Tenant Context | Phase I–III | ✅ Complete |
| Business Settings + Members | Phase II-A | ✅ Complete |
| Messaging + Inbox | Phase IV | ✅ Complete |
| Operator Reply + Assignment | Phase V | ✅ Complete |
| Order Management | Phase VI | ✅ Complete |
| AI Reply + Handoff | Phase VIII-A | ✅ Complete |
| AI Settings Contract | Phase VIII-B | ✅ Complete |
| Token Governance | Phase IX (planned) | ⬜ Not started |
| Real AI Provider | Phase X (planned) | ⬜ Blocked by Phase IX |
| Native Web Chat Widget | Phase XI (planned) | ⬜ Not started |
| Knowledge Base | Phase XII (planned) | ⬜ Not started |
| Business Profiles (vertical) | Phase XIII (planned) | ⬜ Not started |
| Content Policy Engine | Phase XIV (planned) | ⬜ Not started |
| WhatsApp Official Adapter | Phase XV (planned) | ⬜ Not started |
