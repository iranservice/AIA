// ============================================================
// Identity Domain — Constants
// ============================================================

export const IDENTITY_DOMAIN = 'identity' as const;

export const DEFAULT_LANGUAGE = 'en';
export const DEFAULT_TIMEZONE = 'UTC';

export const SUPPORTED_LANGUAGES = ['en', 'fa', 'ar'] as const;
export type SupportedLanguage = (typeof SUPPORTED_LANGUAGES)[number];
