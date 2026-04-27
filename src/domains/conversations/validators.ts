// ============================================================
// Conversation Domain — Validators
// ============================================================

import { z } from 'zod';

export const sendMessageInputSchema = z.object({
  conversation_id: z.string().uuid(),
  direction: z.enum(['inbound', 'outbound']),
  sender_type: z.enum(['customer', 'operator', 'ai', 'system']),
  sender_id: z.string().uuid().optional(),
  content: z.string().max(65536).optional(),
  content_type: z
    .enum([
      'text', 'image', 'audio', 'video', 'file',
      'location', 'template', 'system_event',
    ])
    .default('text'),
  content_metadata: z.record(z.unknown()).optional().default({}),
  is_internal: z.boolean().default(false),
  reply_to_id: z.string().uuid().optional(),
});

export const createConversationInputSchema = z.object({
  business_id: z.string().uuid(),
  customer_id: z.string().uuid(),
  channel_type: z.enum([
    'whatsapp', 'sms', 'email', 'web_chat', 'voice', 'in_app',
  ]),
  channel_id: z.string().uuid().optional(),
  subject: z.string().max(255).optional(),
});

export type ValidatedSendMessageInput = z.infer<typeof sendMessageInputSchema>;
export type ValidatedCreateConversationInput = z.infer<
  typeof createConversationInputSchema
>;
