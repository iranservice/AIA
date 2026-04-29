// ============================================================
// AI Runtime Domain — Reply Service
//
// Orchestrates the AI reply flow:
//   1. Collect context via SQL RPC
//   2. Check safety (ownership, policy)
//   3. Call AI provider
//   4. Persist result via SQL RPC (reply, handoff, or blocked)
//
// This service is the ONLY entry point for AI interactions.
// It does NOT own message persistence or routing — those are
// handled by the SQL RPCs it calls.
//
// Boundary: ai_runtime owns orchestration.
//           SQL RPCs own atomic DB operations.
// ============================================================

import type { PoolClient } from 'pg';
import type { AiProvider, AiProviderInput, AiContextMessage } from './provider';

export interface AiReplyResult {
  decision: 'replied' | 'handoff' | 'blocked' | 'failed';
  message_id?: string;
  conversation_id: string;
  reason_code?: string;
  delivery_status?: string;
}

export class AiReplyService {
  constructor(private provider: AiProvider) {}

  /**
   * Process a conversation for AI reply.
   * Call this when a message window is ready for AI processing.
   */
  async processConversation(
    client: PoolClient,
    conversationId: string
  ): Promise<AiReplyResult> {
    // Step 1: Collect context
    const ctxRes = await client.query(
      `SELECT collect_ai_context($1) as result`,
      [conversationId]
    );
    const context = ctxRes.rows[0].result;

    // Step 2: If context has error, log as blocked
    if (context.error) {
      await client.query(
        `SELECT log_ai_blocked($1, $2, 'blocked', 'message_window', $3) as result`,
        [conversationId, context.reason_code ?? context.error, this.provider.name]
      );
      return {
        decision: 'blocked',
        conversation_id: conversationId,
        reason_code: context.reason_code ?? context.error,
      };
    }

    // Step 3: Map context to provider input
    const providerInput = this.mapToProviderInput(context);

    // Step 4: Call provider
    let output;
    try {
      output = await this.provider.generateReply(providerInput);
    } catch (err) {
      // Provider threw — log as failed
      await client.query(
        `SELECT log_ai_blocked($1, 'provider_exception', 'failed', 'message_window', $2) as result`,
        [conversationId, this.provider.name]
      );
      return {
        decision: 'failed',
        conversation_id: conversationId,
        reason_code: 'provider_exception',
      };
    }

    // Step 5: Act on decision
    switch (output.decision) {
      case 'reply': {
        const replyRes = await client.query(
          `SELECT persist_ai_reply($1, $2, 'text', $3, $4, $5, $6, $7) as result`,
          [
            conversationId,
            output.content,
            this.provider.name,
            output.model ?? null,
            output.tokens_in ?? 0,
            output.tokens_out ?? 0,
            output.latency_ms ?? 0,
          ]
        );
        const replyResult = replyRes.rows[0].result;
        if (replyResult.error) {
          return {
            decision: 'failed',
            conversation_id: conversationId,
            reason_code: replyResult.error,
          };
        }
        return {
          decision: 'replied',
          message_id: replyResult.message_id,
          conversation_id: conversationId,
          delivery_status: replyResult.delivery_status,
        };
      }

      case 'handoff': {
        await client.query(
          `SELECT persist_ai_handoff($1, $2, $3, $4, $5) as result`,
          [
            conversationId,
            output.reason_code ?? 'ai_uncertain',
            output.reason_text ?? null,
            this.provider.name,
            output.model ?? null,
          ]
        );
        return {
          decision: 'handoff',
          conversation_id: conversationId,
          reason_code: output.reason_code,
        };
      }

      case 'blocked':
      case 'failed': {
        await client.query(
          `SELECT log_ai_blocked($1, $2, $3, 'message_window', $4) as result`,
          [
            conversationId,
            output.reason_code ?? output.decision,
            output.decision,
            this.provider.name,
          ]
        );
        return {
          decision: output.decision,
          conversation_id: conversationId,
          reason_code: output.reason_code,
        };
      }
    }
  }

  /** Map SQL context to provider input format */
  private mapToProviderInput(context: Record<string, unknown>): AiProviderInput {
    const conv = context.conversation as Record<string, unknown>;
    const customer = context.customer as Record<string, unknown>;
    const rawMessages = (context.messages ?? []) as Array<Record<string, unknown>>;

    const messages: AiContextMessage[] = rawMessages.map(m => ({
      role: m.sender_type === 'customer' ? 'user' as const
        : m.sender_type === 'ai' ? 'assistant' as const
        : 'system' as const,
      content: (m.content as string) ?? '',
      sender_type: m.sender_type as string,
      created_at: m.created_at as string,
    }));

    return {
      conversation_id: conv.id as string,
      business_id: conv.business_id as string,
      messages,
      system_prompt: 'You are a helpful AI assistant for this business. Respond helpfully and concisely.',
      customer_summary: {
        name: (customer.name as string) ?? null,
        phone: (customer.phone as string) ?? null,
        email: (customer.email as string) ?? null,
      },
      business_context: {},
      ai_policy: (context.ai_policy as Record<string, string | number | boolean | null>) ?? null,
    };
  }
}
