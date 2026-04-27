// ============================================================
// Shared Type Utilities
// ============================================================

/** UUID string type alias for clarity */
export type UUID = string;

/** ISO 8601 timestamp string */
export type Timestamp = string;

/** Generic JSON value */
export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

/** Generic JSONB object */
export type JsonObject = Record<string, JsonValue>;

/** Pagination parameters */
export interface PaginationParams {
  page?: number;
  pageSize?: number;
  cursor?: string;
}

/** Paginated response wrapper */
export interface PaginatedResponse<T> {
  data: T[];
  total: number;
  page: number;
  pageSize: number;
  hasMore: boolean;
}

/** Sort direction */
export type SortDirection = 'asc' | 'desc';

/** Generic sort parameter */
export interface SortParam {
  field: string;
  direction: SortDirection;
}
