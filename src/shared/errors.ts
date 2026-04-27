// ============================================================
// Domain Error Types
// Structured errors for all domain operations.
// ============================================================

export class DomainError extends Error {
  constructor(
    message: string,
    public readonly code: string,
    public readonly domain: string,
    public readonly statusCode: number = 400,
    public readonly metadata?: Record<string, unknown>
  ) {
    super(message);
    this.name = 'DomainError';
  }
}

export class NotFoundError extends DomainError {
  constructor(domain: string, entityType: string, entityId: string) {
    super(
      `${entityType} not found: ${entityId}`,
      `${domain}.not_found`,
      domain,
      404
    );
    this.name = 'NotFoundError';
  }
}

export class PermissionDeniedError extends DomainError {
  constructor(domain: string, permission: string) {
    super(
      `Permission denied: ${permission}`,
      `${domain}.permission_denied`,
      domain,
      403,
      { permission }
    );
    this.name = 'PermissionDeniedError';
  }
}

export class ValidationError extends DomainError {
  constructor(
    domain: string,
    message: string,
    public readonly fields?: Record<string, string[]>
  ) {
    super(message, `${domain}.validation_error`, domain, 422, { fields });
    this.name = 'ValidationError';
  }
}

export class StateTransitionError extends DomainError {
  constructor(
    domain: string,
    entityType: string,
    fromState: string,
    toState: string
  ) {
    super(
      `Invalid ${entityType} status transition: ${fromState} → ${toState}`,
      `${domain}.invalid_transition`,
      domain,
      409,
      { fromState, toState }
    );
    this.name = 'StateTransitionError';
  }
}

export class SecurityViolationError extends DomainError {
  constructor(domain: string, message: string) {
    super(message, `${domain}.security_violation`, domain, 403);
    this.name = 'SecurityViolationError';
  }
}

/**
 * Parse a Supabase RPC error into a structured DomainError.
 */
export function parseRpcError(
  error: { message: string; code?: string },
  domain: string
): DomainError {
  const msg = error.message || 'Unknown error';

  if (msg.includes('Permission denied')) {
    return new PermissionDeniedError(domain, msg);
  }
  if (msg.includes('not found')) {
    return new NotFoundError(domain, 'entity', msg);
  }
  if (msg.includes('Invalid') && msg.includes('transition')) {
    return new StateTransitionError(domain, 'entity', 'unknown', 'unknown');
  }
  if (msg.includes('SECURITY VIOLATION')) {
    return new SecurityViolationError(domain, msg);
  }

  return new DomainError(msg, error.code || `${domain}.error`, domain);
}
