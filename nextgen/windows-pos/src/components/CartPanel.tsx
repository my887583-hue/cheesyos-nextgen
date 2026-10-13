import React from 'react';
import type { CartItem, CartTotals } from '@cheesyos/pos-core';
import { formatPaise } from './MenuCatalog';

export interface CartPanelProps {
  items: CartItem[];
  totals: CartTotals;
  sentItems?: CartItem[];
  stagedItems?: CartItem[];
  onUpdateQuantity: (itemId: string, newQty: number) => void;
  onRemoveItem: (itemId: string) => void;
  onSaveOrder?: () => void;
  onSaveChanges?: () => void;
  onSendKot?: () => void;
  onSendAdditionalKot?: () => void;
  onFinalizeBill?: () => void;
  isSaving?: boolean;
  isSendingKot?: boolean;
  isSendingAdditionalKot?: boolean;
  isFinalizingBill?: boolean;
  billNumber?: string | null;
  isDirty?: boolean;
  isReadOnly?: boolean;
  hasActiveOrder?: boolean;
  orderStatus?: string | null;
  orderVersion?: number | null;
  orderDisplayId?: string | null;
  tableNumber: string | number;
  guestCount: number;
  errorMessage?: string | null;
  successMessage?: string | null;
}

export function CartPanel({
  items,
  totals,
  sentItems,
  stagedItems,
  onUpdateQuantity,
  onRemoveItem,
  onSaveOrder,
  onSaveChanges,
  onSendKot,
  onSendAdditionalKot,
  onFinalizeBill,
  isSaving = false,
  isSendingKot = false,
  isSendingAdditionalKot = false,
  isFinalizingBill = false,
  billNumber = null,
  isDirty = false,
  isReadOnly = false,
  hasActiveOrder = false,
  orderStatus,
  orderVersion,
  orderDisplayId,
  tableNumber,
  guestCount,
  errorMessage,
  successMessage,
}: CartPanelProps): React.ReactElement {
  const isPostKot = orderStatus === 'kot_sent' && Boolean(onSendAdditionalKot);
  const isEditable = !isReadOnly && (orderStatus === 'draft' || !hasActiveOrder);
  const isBilled = orderStatus === 'billed';
  const effectiveSentItems = sentItems ?? items;
  const effectiveStagedItems = stagedItems ?? [];

  return (
    <aside
      id="order-summary-sidebar"
      style={{
        width: '380px',
        backgroundColor: '#ffffff',
        borderLeft: '1px solid #e2e8f0',
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'space-between',
        overflowY: 'auto',
        padding: '18px',
        fontFamily: 'system-ui, -apple-system, sans-serif',
      }}
    >
      <div id="cart-panel">
        {/* Header Section */}
        <div style={{ borderBottom: '1px solid #e2e8f0', paddingBottom: '12px', marginBottom: '14px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <h3 style={{ margin: 0, fontSize: '16px', fontWeight: '700', color: '#0f172a' }}>
              {hasActiveOrder ? 'Active Order Summary' : 'New Order'}
            </h3>
            {isBilled ? (
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: '2px' }}>
                <span
                  id="billed-status-badge"
                  style={{
                    backgroundColor: '#fef3c7',
                    color: '#92400e',
                    fontSize: '11px',
                    fontWeight: '700',
                    padding: '3px 8px',
                    borderRadius: '4px',
                  }}
                >
                  Awaiting Payment
                </span>
                {billNumber && (
                  <span
                    id="header-bill-number"
                    style={{ fontSize: '11px', fontWeight: '700', color: '#0f766e' }}
                  >
                    #{billNumber}
                  </span>
                )}
              </div>
            ) : hasActiveOrder && orderStatus ? (
              <span
                id="cart-order-status-badge"
                style={{
                  backgroundColor: orderStatus === 'draft' ? '#e0f2fe' : '#fef3c7',
                  color: orderStatus === 'draft' ? '#0369a1' : '#92400e',
                  fontSize: '11px',
                  fontWeight: '700',
                  padding: '3px 8px',
                  borderRadius: '4px',
                  textTransform: 'uppercase',
                }}
              >
                {`${orderStatus}${orderVersion ? ` (v${orderVersion})` : ''}`}
              </span>
            ) : null}
          </div>
          <div style={{ fontSize: '12px', color: '#64748b', marginTop: '4px' }}>
            {`Table ${tableNumber} • Guests: ${guestCount}`}
            {orderDisplayId && <span> • Ref: <strong>{orderDisplayId}</strong></span>}
          </div>
        </div>

        {/* Feedback Messages */}
        {errorMessage && (
          <div
            id="cart-error-message"
            style={{
              backgroundColor: '#fef2f2',
              border: '1px solid #fecaca',
              color: '#991b1b',
              padding: '8px 12px',
              borderRadius: '6px',
              fontSize: '12px',
              marginBottom: '12px',
            }}
          >
            {errorMessage}
          </div>
        )}

        {successMessage && (
          <div
            id="cart-success-message"
            style={{
              backgroundColor: '#f0fdf4',
              border: '1px solid #bbf7d0',
              color: '#166534',
              padding: '8px 12px',
              borderRadius: '6px',
              fontSize: '12px',
              marginBottom: '12px',
            }}
          >
            {successMessage}
          </div>
        )}

        {/* Read-Only Notice if billed or non-editable */}
        {isBilled && (
          <div
            id="billed-order-warning"
            style={{
              marginTop: '4px',
              marginBottom: '14px',
              backgroundColor: '#fffbeb',
              border: '1px solid #fde68a',
              color: '#92400e',
              padding: '10px 12px',
              borderRadius: '6px',
              fontSize: '12px',
              lineHeight: '1.4',
            }}
          >
            <strong>Awaiting Payment</strong>
            <p style={{ margin: '4px 0 0 0' }}>
              Ordering is locked until payment is settled.
            </p>
          </div>
        )}

        {!isEditable && !isBilled && !isPostKot && (
          <div
            id="cart-readonly-notice"
            style={{
              backgroundColor: '#fffbeb',
              border: '1px solid #fde68a',
              color: '#92400e',
              padding: '10px 12px',
              borderRadius: '6px',
              fontSize: '12px',
              marginBottom: '14px',
              lineHeight: '1.4',
            }}
          >
            <strong>Order Locked ({orderStatus || 'Read-Only'})</strong>
            <p style={{ margin: '4px 0 0 0' }}>
              Draft editing is disabled for {orderStatus || 'this order'}. Modifications require cashier/manager authorization.
            </p>
          </div>
        )}

        {/* Case: Open Session with zero items */}
        {!hasActiveOrder && items.length === 0 ? (
          <div id="new-order-placeholder" style={{ padding: '20px 0', textAlign: 'center' }}>
            <div style={{ fontSize: '32px', marginBottom: '8px' }}>📋</div>
            <h4 style={{ margin: '0 0 6px 0', fontSize: '15px', color: '#1e293b' }}>
              No items yet
            </h4>
            <p style={{ margin: 0, fontSize: '13px', color: '#64748b', lineHeight: '1.4' }}>
              Browse menu categories on the left. Add products to compose a draft order.
            </p>
            <div
              id="cart-empty-message"
              style={{
                marginTop: '16px',
                backgroundColor: '#f0fdf4',
                border: '1px solid #bbf7d0',
                color: '#166534',
                padding: '8px 10px',
                borderRadius: '6px',
                fontSize: '11px',
              }}
            >
              Table session open • Zero empty orders persisted
            </div>
          </div>
        ) : isPostKot ? (
          /* Post-KOT View: Sent Items (Read-Only) + Additional Staged Items */
          <div
            id="active-order-summary-content"
            style={{ display: 'flex', flexDirection: 'column', gap: '8px', marginBottom: '16px' }}
          >
            {/* 1. SENT ITEMS (Read-Only) */}
            <div id="sent-items-section" style={{ marginBottom: '14px' }}>
              <div
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  paddingBottom: '6px',
                  borderBottom: '1px solid #e2e8f0',
                  marginBottom: '8px',
                }}
              >
                <span
                  style={{
                    fontSize: '12px',
                    fontWeight: '700',
                    color: '#475569',
                    textTransform: 'uppercase',
                    letterSpacing: '0.05em',
                  }}
                >
                  Sent Items (Kitchen History)
                </span>
                <span style={{ fontSize: '11px', color: '#64748b' }}>
                  {effectiveSentItems.length} item{effectiveSentItems.length === 1 ? '' : 's'} (Read-only)
                </span>
              </div>
              <div id="sent-items-list" style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
                {effectiveSentItems.map((item) => (
                  <div
                    key={item.id}
                    id={`sent-item-${item.id}`}
                    style={{
                      backgroundColor: '#f8fafc',
                      border: '1px solid #e2e8f0',
                      borderRadius: '6px',
                      padding: '10px 12px',
                      display: 'flex',
                      justifyContent: 'space-between',
                      alignItems: 'center',
                    }}
                  >
                    <div
                      id={`sent-item-info-${item.id}`}
                      style={{ display: 'flex', flexDirection: 'column', gap: '2px', flex: 1, marginRight: '10px' }}
                    >
                      <span style={{ fontSize: '13px', fontWeight: '600', color: '#1e293b' }}>
                        {item.productName}
                      </span>
                      <span style={{ fontSize: '11px', color: '#64748b' }}>
                        {formatPaise(item.unitPricePaise)}
                      </span>
                    </div>

                    <span style={{ fontSize: '12px', fontWeight: '600', color: '#475569' }}>
                      {`${item.quantity} × ${formatPaise(item.unitPricePaise)}`}
                    </span>

                    <span
                      id={`sent-line-total-${item.id}`}
                      style={{
                        fontSize: '13px',
                        fontWeight: '700',
                        color: '#0f172a',
                        marginLeft: '12px',
                        minWidth: '55px',
                        textAlign: 'right',
                      }}
                    >
                      {formatPaise(item.lineTotalPaise)}
                    </span>
                  </div>
                ))}
              </div>
            </div>

            {/* 2. ADDITIONAL ITEMS (Editable Staged Items) */}
            <div id="additional-items-section" style={{ marginBottom: '14px' }}>
              <div
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  paddingBottom: '6px',
                  borderBottom: '1px solid #bae6fd',
                  marginBottom: '8px',
                }}
              >
                <span
                  style={{
                    fontSize: '12px',
                    fontWeight: '700',
                    color: '#0369a1',
                    textTransform: 'uppercase',
                    letterSpacing: '0.05em',
                  }}
                >
                  Additional Items (Staged)
                </span>
                <span
                  style={{
                    fontSize: '11px',
                    fontWeight: '600',
                    color: effectiveStagedItems.length > 0 ? '#0284c7' : '#94a3b8',
                  }}
                >
                  {`${effectiveStagedItems.length} item${effectiveStagedItems.length === 1 ? '' : 's'} staged`}
                </span>
              </div>

              {effectiveStagedItems.length === 0 ? (
                <div
                  id="staged-empty-placeholder"
                  style={{
                    padding: '14px',
                    border: '1px dashed #cbd5e1',
                    borderRadius: '6px',
                    textAlign: 'center',
                    fontSize: '12px',
                    color: '#64748b',
                    backgroundColor: '#f8fafc',
                  }}
                >
                  No additional items staged. Select items from the menu to add.
                </div>
              ) : (
                <div id="staged-items-list" style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
                  {effectiveStagedItems.map((item) => (
                    <div
                      key={item.id}
                      id={`staged-item-${item.id}`}
                      style={{
                        backgroundColor: '#f0f9ff',
                        border: '1px solid #bae6fd',
                        borderRadius: '6px',
                        padding: '10px 12px',
                        display: 'flex',
                        justifyContent: 'space-between',
                        alignItems: 'center',
                      }}
                    >
                      <div
                        id={`cart-item-${item.id}`}
                        style={{ display: 'flex', flexDirection: 'column', gap: '2px', flex: 1, marginRight: '10px' }}
                      >
                        <span style={{ fontSize: '13px', fontWeight: '600', color: '#0369a1' }}>
                          {item.productName}
                        </span>
                        <span style={{ fontSize: '11px', color: '#0284c7' }}>
                          {formatPaise(item.unitPricePaise)}
                        </span>
                      </div>

                      {/* Staged Item Quantity Controls */}
                      <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                        <button
                          type="button"
                          id={`cart-dec-${item.id}`}
                          onClick={() => onUpdateQuantity(item.id, item.quantity - 1)}
                          disabled={isSendingAdditionalKot}
                          style={{
                            width: '26px',
                            height: '26px',
                            display: 'flex',
                            alignItems: 'center',
                            justifyContent: 'center',
                            backgroundColor: '#ffffff',
                            border: '1px solid #cbd5e1',
                            borderRadius: '4px',
                            fontSize: '14px',
                            fontWeight: '700',
                            color: '#334155',
                            cursor: isSendingAdditionalKot ? 'not-allowed' : 'pointer',
                          }}
                        >
                          −
                        </button>
                        <span
                          id={`cart-qty-${item.id}`}
                          style={{ fontSize: '13px', fontWeight: '700', minWidth: '20px', textAlign: 'center' }}
                        >
                          {item.quantity}
                        </span>
                        <button
                          type="button"
                          id={`cart-inc-${item.id}`}
                          onClick={() => onUpdateQuantity(item.id, item.quantity + 1)}
                          disabled={isSendingAdditionalKot}
                          style={{
                            width: '26px',
                            height: '26px',
                            display: 'flex',
                            alignItems: 'center',
                            justifyContent: 'center',
                            backgroundColor: '#ffffff',
                            border: '1px solid #cbd5e1',
                            borderRadius: '4px',
                            fontSize: '14px',
                            fontWeight: '700',
                            color: '#334155',
                            cursor: isSendingAdditionalKot ? 'not-allowed' : 'pointer',
                          }}
                        >
                          +
                        </button>
                        <button
                          type="button"
                          id={`cart-remove-${item.id}`}
                          onClick={() => onRemoveItem(item.id)}
                          disabled={isSendingAdditionalKot}
                          title="Remove"
                          style={{
                            marginLeft: '4px',
                            border: 'none',
                            background: 'transparent',
                            color: '#ef4444',
                            cursor: isSendingAdditionalKot ? 'not-allowed' : 'pointer',
                            fontSize: '14px',
                            padding: '2px',
                          }}
                        >
                          🗑
                        </button>
                      </div>

                      {/* Line Total */}
                      <span
                        id={`cart-line-total-${item.id}`}
                        style={{
                          fontSize: '13px',
                          fontWeight: '700',
                          color: '#0f172a',
                          marginLeft: '12px',
                          minWidth: '55px',
                          textAlign: 'right',
                        }}
                      >
                        {formatPaise(item.lineTotalPaise)}
                      </span>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Financial Summary */}
            <div
              id="active-order-totals"
              style={{
                backgroundColor: '#f1f5f9',
                borderRadius: '6px',
                padding: '12px',
                display: 'flex',
                flexDirection: 'column',
                gap: '6px',
                fontSize: '13px',
              }}
            >
              <div id="cart-totals" style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', color: '#475569' }}>
                  <span>Subtotal:</span>
                  <span id="cart-subtotal">{formatPaise(totals.subtotalPaise)}</span>
                </div>
                <div style={{ display: 'flex', justifyContent: 'space-between', color: '#475569' }}>
                  <span>Tax:</span>
                  <span id="cart-tax">{formatPaise(totals.taxTotalPaise)}</span>
                </div>
                {totals.discountTotalPaise > 0 && (
                  <div style={{ display: 'flex', justifyContent: 'space-between', color: '#16a34a' }}>
                    <span>Discount:</span>
                    <span id="cart-discount">{`-${formatPaise(totals.discountTotalPaise)}`}</span>
                  </div>
                )}
                <div
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    fontWeight: '700',
                    fontSize: '15px',
                    color: '#0f172a',
                    borderTop: '1px solid #cbd5e1',
                    paddingTop: '6px',
                    marginTop: '2px',
                  }}
                >
                  <span>Grand Total:</span>
                  <span id="active-order-grand-total">
                    <span id="cart-grand-total">{formatPaise(totals.grandTotalPaise)}</span>
                  </span>
                </div>
              </div>
            </div>
          </div>
        ) : (
          /* Items List */
          <div
            id="active-order-summary-content"
            style={{ display: 'flex', flexDirection: 'column', gap: '8px', marginBottom: '16px' }}
          >
            <div id="active-order-items-list" style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
              {items.map((item) => (
                <div
                  key={item.id}
                  id={`order-item-${item.id}`}
                  style={{
                    backgroundColor: '#f8fafc',
                    border: '1px solid #e2e8f0',
                    borderRadius: '6px',
                    padding: '10px 12px',
                    display: 'flex',
                    justifyContent: 'space-between',
                    alignItems: 'center',
                  }}
                >
                  <div
                    id={`cart-item-${item.id}`}
                    style={{ display: 'flex', flexDirection: 'column', gap: '2px', flex: 1, marginRight: '10px' }}
                  >
                    <span style={{ fontSize: '13px', fontWeight: '600', color: '#1e293b' }}>
                      {item.productName}
                    </span>
                    <span style={{ fontSize: '11px', color: '#64748b' }}>
                      {formatPaise(item.unitPricePaise)}
                    </span>
                  </div>

                  {/* Quantity Controls or Static Display */}
                  {isEditable ? (
                    <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                      <button
                        type="button"
                        id={`cart-dec-${item.id}`}
                        onClick={() => onUpdateQuantity(item.id, item.quantity - 1)}
                        disabled={isSaving}
                        style={{
                          width: '26px',
                          height: '26px',
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                          backgroundColor: '#ffffff',
                          border: '1px solid #cbd5e1',
                          borderRadius: '4px',
                          fontSize: '14px',
                          fontWeight: '700',
                          color: '#334155',
                          cursor: isSaving ? 'not-allowed' : 'pointer',
                        }}
                      >
                        −
                      </button>
                      <span
                        id={`cart-qty-${item.id}`}
                        style={{ fontSize: '13px', fontWeight: '700', minWidth: '20px', textAlign: 'center' }}
                      >
                        {item.quantity}
                      </span>
                      <button
                        type="button"
                        id={`cart-inc-${item.id}`}
                        onClick={() => onUpdateQuantity(item.id, item.quantity + 1)}
                        disabled={isSaving}
                        style={{
                          width: '26px',
                          height: '26px',
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                          backgroundColor: '#ffffff',
                          border: '1px solid #cbd5e1',
                          borderRadius: '4px',
                          fontSize: '14px',
                          fontWeight: '700',
                          color: '#334155',
                          cursor: isSaving ? 'not-allowed' : 'pointer',
                        }}
                      >
                        +
                      </button>
                      <button
                        type="button"
                        id={`cart-remove-${item.id}`}
                        onClick={() => onRemoveItem(item.id)}
                        disabled={isSaving}
                        title="Remove"
                        style={{
                          marginLeft: '4px',
                          border: 'none',
                          background: 'transparent',
                          color: '#ef4444',
                          cursor: isSaving ? 'not-allowed' : 'pointer',
                          fontSize: '14px',
                          padding: '2px',
                        }}
                      >
                        🗑
                      </button>
                    </div>
                  ) : (
                    <span style={{ fontSize: '12px', fontWeight: '600', color: '#475569' }}>
                      {`${item.quantity} × ${formatPaise(item.unitPricePaise)}`}
                    </span>
                  )}

                  {/* Line Total */}
                  <span
                    id={`cart-line-total-${item.id}`}
                    style={{
                      fontSize: '13px',
                      fontWeight: '700',
                      color: '#0f172a',
                      marginLeft: '12px',
                      minWidth: '55px',
                      textAlign: 'right',
                    }}
                  >
                    {formatPaise(item.lineTotalPaise)}
                  </span>
                </div>
              ))}
            </div>

            {/* Financial Summary */}
            <div
              id="active-order-totals"
              style={{
                backgroundColor: '#f1f5f9',
                borderRadius: '6px',
                padding: '12px',
                display: 'flex',
                flexDirection: 'column',
                gap: '6px',
                fontSize: '13px',
              }}
            >
              <div id="cart-totals" style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', color: '#475569' }}>
                  <span>Subtotal:</span>
                  <span id="cart-subtotal">{formatPaise(totals.subtotalPaise)}</span>
                </div>
                <div style={{ display: 'flex', justifyContent: 'space-between', color: '#475569' }}>
                  <span>Tax:</span>
                  <span id="cart-tax">{formatPaise(totals.taxTotalPaise)}</span>
                </div>
                {totals.discountTotalPaise > 0 && (
                  <div style={{ display: 'flex', justifyContent: 'space-between', color: '#16a34a' }}>
                    <span>Discount:</span>
                    <span id="cart-discount">{`-${formatPaise(totals.discountTotalPaise)}`}</span>
                  </div>
                )}
                <div
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    fontWeight: '700',
                    fontSize: '15px',
                    color: '#0f172a',
                    borderTop: '1px solid #cbd5e1',
                    paddingTop: '6px',
                    marginTop: '2px',
                  }}
                >
                  <span>Grand Total:</span>
                  <span id="active-order-grand-total">
                    <span id="cart-grand-total">{formatPaise(totals.grandTotalPaise)}</span>
                  </span>
                </div>
              </div>
            </div>

            {!isEditable && (
              <div
                style={{
                  marginTop: '6px',
                  backgroundColor: '#eff6ff',
                  border: '1px solid #bfdbfe',
                  color: '#1e40af',
                  padding: '8px 10px',
                  borderRadius: '6px',
                  fontSize: '11px',
                  textAlign: 'center',
                }}
              >
                Read-only active order view (Cart mutation in Task 3G.2-06)
              </div>
            )}
          </div>
        )}
      </div>

      {/* Action Footer */}
      <div style={{ borderTop: '1px solid #e2e8f0', paddingTop: '14px', marginTop: '14px' }}>
        {isPostKot ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
            <button
              type="button"
              id="send-additional-kot-button"
              disabled={isSendingAdditionalKot || isSaving || isFinalizingBill || effectiveStagedItems.length === 0}
              onClick={onSendAdditionalKot}
              style={{
                width: '100%',
                padding: '12px',
                backgroundColor:
                  isSendingAdditionalKot || effectiveStagedItems.length === 0 ? '#94a3b8' : '#ea580c',
                color: '#ffffff',
                border: 'none',
                borderRadius: '6px',
                fontSize: '14px',
                fontWeight: '700',
                cursor:
                  isSendingAdditionalKot || effectiveStagedItems.length === 0 ? 'not-allowed' : 'pointer',
                transition: 'background 0.15s',
              }}
            >
              {isSendingAdditionalKot ? 'Sending Additional KOT...' : 'Send Additional KOT'}
            </button>
            {effectiveStagedItems.length === 0 && (
              <div
                id="send-additional-kot-empty-hint"
                style={{ fontSize: '11px', color: '#64748b', textAlign: 'center' }}
              >
                Add items from the menu to send an additional KOT.
              </div>
            )}

            {onFinalizeBill && (
              <div style={{ marginTop: '2px' }}>
                <button
                  type="button"
                  id="finalize-bill-button"
                  disabled={
                    isFinalizingBill ||
                    isSendingAdditionalKot ||
                    isSaving ||
                    effectiveStagedItems.length > 0
                  }
                  onClick={onFinalizeBill}
                  style={{
                    width: '100%',
                    padding: '12px',
                    backgroundColor:
                      isFinalizingBill || effectiveStagedItems.length > 0 ? '#94a3b8' : '#0f766e',
                    color: '#ffffff',
                    border: 'none',
                    borderRadius: '6px',
                    fontSize: '14px',
                    fontWeight: '700',
                    cursor:
                      isFinalizingBill || effectiveStagedItems.length > 0 ? 'not-allowed' : 'pointer',
                    transition: 'background 0.15s',
                  }}
                >
                  {isFinalizingBill ? 'Finalizing Bill...' : 'Finalize Bill'}
                </button>
                {effectiveStagedItems.length > 0 && (
                  <div
                    id="finalize-bill-dirty-hint"
                    style={{ fontSize: '11px', color: '#b45309', textAlign: 'center', marginTop: '4px' }}
                  >
                    Send or remove unsent items before finalizing bill.
                  </div>
                )}
              </div>
            )}
          </div>
        ) : isBilled ? (
          <div
            id="billed-awaiting-payment-panel"
            style={{
              backgroundColor: '#fef3c7',
              border: '1px solid #fde68a',
              borderRadius: '6px',
              padding: '12px',
              textAlign: 'center',
            }}
          >
            <div style={{ fontWeight: '700', color: '#92400e', fontSize: '14px', marginBottom: '4px' }}>
              Bill Finalized • Awaiting Payment
            </div>
            {billNumber && (
              <div id="persisted-bill-number" style={{ fontSize: '12px', color: '#78350f', fontWeight: '600' }}>
                Bill #{billNumber}
              </div>
            )}
            <div style={{ fontSize: '11px', color: '#92400e', marginTop: '4px' }}>
              Table remains occupied until payment settlement.
            </div>
          </div>
        ) : isEditable && (
          <div>
            {!hasActiveOrder ? (
              <button
                type="button"
                id="save-order-button"
                disabled={isSaving || items.length === 0}
                onClick={onSaveOrder}
                style={{
                  width: '100%',
                  padding: '12px',
                  backgroundColor: isSaving || items.length === 0 ? '#94a3b8' : '#059669',
                  color: '#ffffff',
                  border: 'none',
                  borderRadius: '6px',
                  fontSize: '14px',
                  fontWeight: '700',
                  cursor: isSaving || items.length === 0 ? 'not-allowed' : 'pointer',
                  transition: 'background 0.15s',
                }}
              >
                {isSaving ? 'Saving Order...' : 'Save Order'}
              </button>
            ) : (
              <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
                <button
                  type="button"
                  id="save-changes-button"
                  disabled={isSaving || isSendingKot || !isDirty || items.length === 0}
                  onClick={onSaveChanges}
                  style={{
                    width: '100%',
                    padding: '10px 12px',
                    backgroundColor: isSaving || isSendingKot || !isDirty || items.length === 0 ? '#94a3b8' : '#0284c7',
                    color: '#ffffff',
                    border: 'none',
                    borderRadius: '6px',
                    fontSize: '13px',
                    fontWeight: '700',
                    cursor: isSaving || isSendingKot || !isDirty || items.length === 0 ? 'not-allowed' : 'pointer',
                    transition: 'background 0.15s',
                  }}
                >
                  {isSaving ? 'Saving Changes...' : isDirty ? 'Save Changes' : 'No Changes'}
                </button>

                <button
                  type="button"
                  id="send-kot-button"
                  disabled={isSaving || isSendingKot || isDirty || items.length === 0}
                  onClick={onSendKot}
                  style={{
                    width: '100%',
                    padding: '12px',
                    backgroundColor: isSaving || isSendingKot || isDirty || items.length === 0 ? '#94a3b8' : '#ea580c',
                    color: '#ffffff',
                    border: 'none',
                    borderRadius: '6px',
                    fontSize: '14px',
                    fontWeight: '700',
                    cursor: isSaving || isSendingKot || isDirty || items.length === 0 ? 'not-allowed' : 'pointer',
                    transition: 'background 0.15s',
                  }}
                >
                  {isSendingKot ? 'Sending KOT...' : 'Send KOT'}
                </button>

                {isDirty && (
                  <div
                    id="send-kot-dirty-hint"
                    style={{ fontSize: '11px', color: '#b45309', textAlign: 'center', marginTop: '2px' }}
                  >
                    Save changes before sending KOT.
                  </div>
                )}
              </div>
            )}
          </div>
        )}

        <div style={{ fontSize: '11px', color: '#94a3b8', textAlign: 'center', marginTop: '10px' }}>
          CheesyOS NextGen POS • Step 3G.2-07 Send KOT
        </div>
      </div>
    </aside>
  );
}

export default CartPanel;
