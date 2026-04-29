// ============================================================
// AI Runtime Domain — Mock Provider
//
// Deterministic mock provider for testing.
// Decision is driven by message content keywords:
//   - contains "handoff" → decision=handoff
//   - contains "block"   → decision=blocked
//   - contains "error"   → decision=failed
//   - otherwise          → decision=reply with echo response
//
// This provider never makes HTTP calls.
// ============================================================

import type { AiProvider, AiProviderInput, AiProviderOutput } from './provider';

export class MockAiProvider implements AiProvider {
  readonly name = 'mock';

  async generateReply(input: AiProviderInput): Promise<AiProviderOutput> {
    const startTime = Date.now();

    // Get the last user message to drive decision
    const lastUserMessage = [...input.messages]
      .reverse()
      .find(m => m.role === 'user');

    const content = lastUserMessage?.content?.toLowerCase() ?? '';

    // Keyword-driven decisions for deterministic testing
    if (content.includes('handoff')) {
      return {
        decision: 'handoff',
        reason_code: 'customer_requested_human',
        reason_text: 'Customer requested to speak with a human operator',
        model: 'mock-v1',
        tokens_in: 10,
        tokens_out: 0,
        latency_ms: Date.now() - startTime,
      };
    }

    if (content.includes('block')) {
      return {
        decision: 'blocked',
        reason_code: 'unsafe_content',
        reason_text: 'Content flagged as potentially unsafe',
        model: 'mock-v1',
        tokens_in: 10,
        tokens_out: 0,
        latency_ms: Date.now() - startTime,
      };
    }

    if (content.includes('error')) {
      return {
        decision: 'failed',
        reason_code: 'provider_error',
        reason_text: 'Mock provider simulated error',
        model: 'mock-v1',
        tokens_in: 10,
        tokens_out: 0,
        latency_ms: Date.now() - startTime,
      };
    }

    // Default: reply with echo
    const replyContent = `[AI] Thank you for your message, ${input.customer_summary.name ?? 'valued customer'}. ` +
      `I received: "${lastUserMessage?.content ?? ''}"`;

    return {
      decision: 'reply',
      content: replyContent,
      model: 'mock-v1',
      tokens_in: 15,
      tokens_out: 25,
      latency_ms: Date.now() - startTime,
    };
  }
}

/** Singleton instance for convenience */
export const mockAiProvider = new MockAiProvider();
