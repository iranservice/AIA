-- ============================================================
-- Migration 00002: Enums
-- All domain-level enums for the AIA platform.
-- Grouped by domain for clarity.
-- ============================================================

-- ── Tenancy ─────────────────────────────────────────────────

-- Extensible business categorization; not locked to restaurants
create type business_type as enum (
  'restaurant',
  'clinic',
  'salon',
  'supermarket',
  'general'
);

-- Roles within a tenant business (Level B)
create type membership_role as enum (
  'owner',
  'manager',
  'operator',
  'viewer'
);

-- Platform-level roles (Level A)
create type platform_role as enum (
  'super_admin',
  'platform_admin',
  'support'
);

-- ── Channels ────────────────────────────────────────────────

create type channel_type as enum (
  'whatsapp',
  'sms',
  'email',
  'web_chat',
  'voice',
  'in_app'
);

-- ── Conversation ────────────────────────────────────────────

create type conversation_status as enum (
  'open',
  'assigned',
  'waiting',
  'resolved',
  'closed'
);

create type message_direction as enum (
  'inbound',
  'outbound'
);

create type message_sender_type as enum (
  'customer',
  'operator',
  'ai',
  'system'
);

create type message_content_type as enum (
  'text',
  'image',
  'audio',
  'video',
  'file',
  'location',
  'template',
  'system_event'
);

-- ── Orders ──────────────────────────────────────────────────

create type order_status as enum (
  'draft',
  'pending_confirmation',
  'confirmed',
  'preparing',
  'ready',
  'delivering',
  'delivered',
  'cancelled',
  'refunded'
);

create type order_type as enum (
  'dine_in',
  'takeaway',
  'delivery'
);

create type payment_status as enum (
  'unpaid',
  'pending',
  'paid',
  'partially_refunded',
  'refunded',
  'failed'
);

-- ── Reservations ────────────────────────────────────────────

create type reservation_status as enum (
  'pending',
  'confirmed',
  'seated',
  'completed',
  'cancelled',
  'no_show'
);

-- ── Tickets ─────────────────────────────────────────────────

create type ticket_status as enum (
  'open',
  'in_progress',
  'waiting_customer',
  'resolved',
  'closed'
);

create type ticket_priority as enum (
  'low',
  'medium',
  'high',
  'urgent'
);

-- ── Action Engine ───────────────────────────────────────────

create type action_type as enum (
  'send_message',
  'create_order',
  'update_order',
  'create_reservation',
  'update_reservation',
  'create_ticket',
  'escalate',
  'transfer',
  'custom'
);

create type action_trigger_source as enum (
  'ai',
  'operator',
  'system',
  'automation'
);

create type approval_status as enum (
  'pending',
  'approved',
  'rejected',
  'escalated'
);

-- ── Provider Registry ───────────────────────────────────────

create type provider_type as enum (
  'ai',
  'sms',
  'email',
  'whatsapp',
  'voice',
  'payment'
);

-- Level A (platform) vs Level B (tenant)
create type provider_scope as enum (
  'platform',
  'tenant'
);

create type provider_health_status as enum (
  'healthy',
  'degraded',
  'unhealthy',
  'unknown'
);

-- ── Audit ───────────────────────────────────────────────────

create type audit_severity as enum (
  'info',
  'warning',
  'error',
  'critical'
);

-- ── Billing ─────────────────────────────────────────────────

create type usage_meter_type as enum (
  'ai_tokens',
  'messages_sent',
  'api_calls',
  'storage_bytes',
  'voice_minutes'
);

create type billing_event_type as enum (
  'subscription',
  'overage',
  'addon',
  'credit',
  'refund'
);
