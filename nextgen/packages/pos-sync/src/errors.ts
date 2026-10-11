/**
 * CHEESYOS NEXTGEN POS SYNC — MINIMAL ERROR CLASSIFICATION
 */

export type PushSyncErrorCode = 
  | 'RETRYABLE'
  | 'AUTH_REQUIRED'
  | 'CONTRACT_CONFLICT'
  | 'QUEUE_CONFLICT';

export class PushSyncError extends Error {
  public readonly code: PushSyncErrorCode;
  public readonly details?: unknown;

  constructor(code: PushSyncErrorCode, message: string, details?: unknown) {
    super(message);
    this.name = 'PushSyncError';
    this.code = code;
    this.details = details;
  }
}
