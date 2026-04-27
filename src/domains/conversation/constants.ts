// ============================================================
// Conversation Domain — Constants
// ============================================================

export const CONVERSATION_DOMAIN = 'conversation' as const;

/** Valid conversation status transitions */
export const VALID_CONVERSATION_TRANSITIONS: Record<string, string[]> = {
  open: ['assigned', 'waiting', 'resolved', 'closed'],
  assigned: ['open', 'waiting', 'resolved', 'closed'],
  waiting: ['open', 'assigned', 'resolved', 'closed'],
  resolved: ['open', 'closed'],
  closed: ['open'],
};
