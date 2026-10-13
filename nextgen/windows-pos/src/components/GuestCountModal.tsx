import React from 'react';
import type { PosTableDomain } from '@cheesyos/nextgen-shared';

export interface GuestCountModalProps {
  table: PosTableDomain;
  guestCount: number;
  guestCountError: string | null;
  actionError: string | null;
  isSubmitting: boolean;
  onGuestCountChange: (count: number) => void;
  onConfirm: (e?: React.FormEvent) => void;
  onCancel: () => void;
}

export function GuestCountModal({
  table,
  guestCount,
  guestCountError,
  actionError,
  isSubmitting,
  onGuestCountChange,
  onConfirm,
  onCancel,
}: GuestCountModalProps): React.ReactElement {
  return (
    <div
      id="guest-count-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="guest-dialog-title"
      style={{
        position: 'fixed',
        inset: 0,
        backgroundColor: 'rgba(15, 23, 42, 0.6)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 1000,
      }}
    >
      <div
        style={{
          backgroundColor: '#ffffff',
          borderRadius: '8px',
          padding: '24px',
          width: '100%',
          maxWidth: '380px',
          boxShadow: '0 20px 25px -5px rgba(0, 0, 0, 0.2)',
        }}
      >
        <h3 id="guest-dialog-title" style={{ margin: '0 0 8px 0', fontSize: '18px', color: '#0f172a' }}>
          Open Table {table.table_number}
        </h3>
        <p style={{ margin: '0 0 16px 0', fontSize: '13px', color: '#64748b' }}>
          Enter guest count to seat customers and open a dine-in session.
        </p>

        {actionError && (
          <div
            id="guest-dialog-action-error"
            style={{
              backgroundColor: '#fef2f2',
              border: '1px solid #fecaca',
              color: '#991b1b',
              padding: '8px 12px',
              borderRadius: '4px',
              fontSize: '13px',
              marginBottom: '14px',
            }}
          >
            {actionError}
          </div>
        )}

        <form onSubmit={onConfirm}>
          <div style={{ marginBottom: '16px' }}>
            <label
              htmlFor="guest-count-input"
              style={{ display: 'block', fontSize: '13px', fontWeight: '600', color: '#334155', marginBottom: '6px' }}
            >
              Guest Count
            </label>
            <div style={{ display: 'flex', gap: '8px' }}>
              <button
                type="button"
                onClick={() => onGuestCountChange(Math.max(1, guestCount - 1))}
                disabled={isSubmitting || guestCount <= 1}
                style={{
                  width: '40px',
                  height: '40px',
                  fontSize: '18px',
                  fontWeight: 'bold',
                  backgroundColor: '#f1f5f9',
                  border: '1px solid #cbd5e1',
                  borderRadius: '4px',
                  cursor: guestCount <= 1 || isSubmitting ? 'not-allowed' : 'pointer',
                }}
              >
                -
              </button>

              <input
                id="guest-count-input"
                type="number"
                min="1"
                step="1"
                value={guestCount}
                onChange={(e) => {
                  const val = parseInt(e.target.value, 10);
                  onGuestCountChange(isNaN(val) ? 0 : val);
                }}
                disabled={isSubmitting}
                required
                style={{
                  flex: 1,
                  textAlign: 'center',
                  fontSize: '18px',
                  fontWeight: '700',
                  border: guestCountError ? '2px solid #dc2626' : '1px solid #cbd5e1',
                  borderRadius: '4px',
                  padding: '8px',
                }}
              />

              <button
                type="button"
                onClick={() => onGuestCountChange(guestCount + 1)}
                disabled={isSubmitting}
                style={{
                  width: '40px',
                  height: '40px',
                  fontSize: '18px',
                  fontWeight: 'bold',
                  backgroundColor: '#f1f5f9',
                  border: '1px solid #cbd5e1',
                  borderRadius: '4px',
                  cursor: isSubmitting ? 'not-allowed' : 'pointer',
                }}
              >
                +
              </button>
            </div>

            {guestCountError && (
              <div id="guest-count-validation-error" style={{ color: '#dc2626', fontSize: '12px', marginTop: '6px' }}>
                {guestCountError}
              </div>
            )}
          </div>

          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '10px' }}>
            <button
              id="cancel-open-table-button"
              type="button"
              onClick={onCancel}
              disabled={isSubmitting}
              style={{
                backgroundColor: '#ffffff',
                border: '1px solid #cbd5e1',
                color: '#475569',
                padding: '8px 16px',
                borderRadius: '4px',
                fontSize: '13px',
                fontWeight: '600',
                cursor: isSubmitting ? 'not-allowed' : 'pointer',
              }}
            >
              Cancel
            </button>

            <button
              id="confirm-open-table-button"
              type="submit"
              disabled={isSubmitting}
              style={{
                backgroundColor: isSubmitting ? '#94a3b8' : '#16a34a',
                border: 'none',
                color: '#ffffff',
                padding: '8px 18px',
                borderRadius: '4px',
                fontSize: '13px',
                fontWeight: '700',
                cursor: isSubmitting ? 'not-allowed' : 'pointer',
              }}
            >
              {isSubmitting ? 'Opening...' : 'Confirm & Open'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

export default GuestCountModal;
