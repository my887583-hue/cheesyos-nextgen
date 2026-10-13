import React from 'react';
import type { KotItemDomain } from '@cheesyos/nextgen-shared';
import type { LocalOrderItem } from '@cheesyos/pos-local';

export interface KotCorrectionModalProps {
  isOpen: boolean;
  kotNumber: number;
  kotItem: KotItemDomain;
  linkedOrderItem: LocalOrderItem;
  cancelledQty: number;
  onCancelledQtyChange: (qty: number) => void;
  reason: string;
  onReasonChange: (reason: string) => void;
  onConfirm: () => void;
  onClose: () => void;
  isSubmitting: boolean;
  errorMessage?: string | null;
  isDirtyCartBlocked?: boolean;
}

export function validateCancelQuantity(qty: number, maxQty: number): string | null {
  if (isNaN(qty)) return 'Quantity must be a valid number.';
  if (!Number.isInteger(qty)) return 'Quantity must be a whole integer.';
  if (qty <= 0) return 'Cancelled quantity must be greater than 0.';
  if (qty > maxQty) return `Cancelled quantity cannot exceed remaining quantity (${maxQty}).`;
  return null;
}

export function validateReason(reason: string): string | null {
  if (!reason || reason.trim().length === 0) {
    return 'Reason is required for KOT correction.';
  }
  return null;
}

export function KotCorrectionModal({
  isOpen,
  kotNumber,
  kotItem,
  linkedOrderItem,
  cancelledQty,
  onCancelledQtyChange,
  reason,
  onReasonChange,
  onConfirm,
  onClose,
  isSubmitting,
  errorMessage,
  isDirtyCartBlocked = false,
}: KotCorrectionModalProps): React.ReactElement | null {
  if (!isOpen) return null;

  const maxQty = linkedOrderItem.quantity;
  const qtyError = validateCancelQuantity(cancelledQty, maxQty);
  const reasonError = validateReason(reason);
  const hasValidationError = Boolean(qtyError || reasonError);
  const isConfirmDisabled = isSubmitting || isDirtyCartBlocked || hasValidationError;

  return (
    <div
      id="kot-correction-modal"
      style={{
        position: 'fixed',
        inset: 0,
        backgroundColor: 'rgba(15, 23, 42, 0.65)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 1100,
        fontFamily: 'system-ui, -apple-system, sans-serif',
      }}
    >
      <div
        id="kot-correction-dialog-content"
        style={{
          backgroundColor: '#ffffff',
          borderRadius: '10px',
          padding: '24px',
          width: '420px',
          boxShadow: '0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04)',
          color: '#0f172a',
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '16px' }}>
          <h3 style={{ margin: 0, fontSize: '18px', fontWeight: '700', color: '#0f172a' }}>
            Correct / Cancel KOT Item
          </h3>
          <button
            type="button"
            id="correction-close-header-button"
            onClick={onClose}
            disabled={isSubmitting}
            style={{
              background: 'none',
              border: 'none',
              fontSize: '20px',
              cursor: isSubmitting ? 'not-allowed' : 'pointer',
              color: '#64748b',
            }}
          >
            ×
          </button>
        </div>

        {/* Selected Item Summary */}
        <div
          style={{
            backgroundColor: '#f8fafc',
            border: '1px solid #e2e8f0',
            borderRadius: '6px',
            padding: '12px',
            marginBottom: '16px',
            fontSize: '13px',
          }}
        >
          <div style={{ fontWeight: '700', fontSize: '15px', color: '#1e293b', marginBottom: '4px' }}>
            <span id="correction-product-name">{kotItem.product_name}</span>
          </div>
          <div style={{ color: '#64748b', display: 'flex', flexDirection: 'column', gap: '2px' }}>
            <span id="correction-kot-number">KOT #{kotNumber}</span>
            <span id="correction-sent-qty">Originally Sent: {kotItem.quantity}</span>
            <span id="correction-remaining-qty" style={{ fontWeight: '600', color: '#0f172a' }}>
              Current Remaining: {linkedOrderItem.quantity}
            </span>
          </div>
        </div>

        {isDirtyCartBlocked && (
          <div
            id="correction-dirty-cart-warning"
            style={{
              backgroundColor: '#fef2f2',
              color: '#991b1b',
              border: '1px solid #fecaca',
              padding: '10px 12px',
              borderRadius: '6px',
              fontSize: '12px',
              marginBottom: '14px',
              lineHeight: '1.4',
            }}
          >
            Unsent items are currently staged in cart. Please send or remove them before making a correction.
          </div>
        )}

        {errorMessage && (
          <div
            id="correction-error-message"
            style={{
              backgroundColor: '#fef2f2',
              color: '#b91c1c',
              border: '1px solid #fecaca',
              padding: '8px 12px',
              borderRadius: '6px',
              fontSize: '12px',
              marginBottom: '14px',
            }}
          >
            {errorMessage}
          </div>
        )}

        {/* Cancellation Quantity Input */}
        <div style={{ marginBottom: '14px' }}>
          <label
            htmlFor="correction-qty-input"
            style={{ display: 'block', fontSize: '12px', fontWeight: '600', color: '#334155', marginBottom: '6px' }}
          >
            Quantity to Cancel (Max: {maxQty})
          </label>
          <input
            id="correction-qty-input"
            type="number"
            min={1}
            max={maxQty}
            step={1}
            value={isNaN(cancelledQty) ? '' : cancelledQty}
            disabled={isSubmitting}
            onChange={(e) => {
              const val = e.target.value === '' ? NaN : Number(e.target.value);
              onCancelledQtyChange(val);
            }}
            style={{
              width: '100%',
              padding: '8px 12px',
              border: `1px solid ${qtyError ? '#ef4444' : '#cbd5e1'}`,
              borderRadius: '6px',
              fontSize: '14px',
              boxSizing: 'border-box',
            }}
          />
          {qtyError && (
            <span id="correction-qty-error" style={{ color: '#ef4444', fontSize: '11px', marginTop: '4px', display: 'block' }}>
              {qtyError}
            </span>
          )}
        </div>

        {/* Reason Text Input */}
        <div style={{ marginBottom: '20px' }}>
          <label
            htmlFor="correction-reason-input"
            style={{ display: 'block', fontSize: '12px', fontWeight: '600', color: '#334155', marginBottom: '6px' }}
          >
            Reason for Correction
          </label>
          <textarea
            id="correction-reason-input"
            rows={2}
            value={reason}
            disabled={isSubmitting}
            placeholder="e.g., Customer changed mind, wrong item prepared..."
            onChange={(e) => onReasonChange(e.target.value)}
            style={{
              width: '100%',
              padding: '8px 12px',
              border: `1px solid ${reasonError && reason.length > 0 ? '#ef4444' : '#cbd5e1'}`,
              borderRadius: '6px',
              fontSize: '13px',
              boxSizing: 'border-box',
              resize: 'vertical',
            }}
          />
          {reasonError && (
            <span id="correction-reason-error" style={{ color: '#ef4444', fontSize: '11px', marginTop: '4px', display: 'block' }}>
              {reasonError}
            </span>
          )}
        </div>

        {/* Action Buttons */}
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '10px' }}>
          <button
            type="button"
            id="correction-cancel-button"
            onClick={onClose}
            disabled={isSubmitting}
            style={{
              padding: '8px 16px',
              backgroundColor: '#f1f5f9',
              color: '#334155',
              border: '1px solid #cbd5e1',
              borderRadius: '6px',
              fontSize: '13px',
              fontWeight: '600',
              cursor: isSubmitting ? 'not-allowed' : 'pointer',
            }}
          >
            Close
          </button>
          <button
            type="button"
            id="correction-confirm-button"
            onClick={onConfirm}
            disabled={isConfirmDisabled}
            style={{
              padding: '8px 18px',
              backgroundColor: isConfirmDisabled ? '#94a3b8' : '#dc2626',
              color: '#ffffff',
              border: 'none',
              borderRadius: '6px',
              fontSize: '13px',
              fontWeight: '600',
              cursor: isConfirmDisabled ? 'not-allowed' : 'pointer',
              transition: 'background 0.15s',
            }}
          >
            {isSubmitting ? 'Confirming...' : 'Confirm Correction'}
          </button>
        </div>
      </div>
    </div>
  );
}

export default KotCorrectionModal;
