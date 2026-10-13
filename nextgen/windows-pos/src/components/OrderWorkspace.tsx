import React, { useState, useRef, useMemo, useCallback, useEffect } from 'react';
import type {
  IPosPersistence,
  PosCatalog,
  LocalOrderHeader,
  LocalOrderItem,
  ProductCatalogDomain,
  ProductVariantCatalogDomain,
  OrderKotHeaderWithItems,
  LocalBill,
} from '@cheesyos/pos-local';
import {
  PosCart,
  createOrderDraft,
  createKotDispatchSnapshot,
  calculateKotCorrectionFinancials,
  finalizeBill,
  toRupees,
  toPaise,
  addPaise,
  CartItem,
  CartTotals,
} from '@cheesyos/pos-core';
import type {
  OrderDomain,
  OrderItemDomain,
  PosKotDomain,
  KotItemDomain,
  KotCorrectionDomain,
  BillDomain,
} from '@cheesyos/nextgen-shared';
import type { SelectedOrderContext } from './TableFloor';
import { MenuCatalog } from './MenuCatalog';
import { CartPanel } from './CartPanel';
import { KotCorrectionModal, validateCancelQuantity, validateReason } from './KotCorrectionModal';

export interface OrderWorkspaceProps {
  db: IPosPersistence;
  context: SelectedOrderContext;
  terminalCode?: string;
  staffName?: string;
  staffId?: string;
  onBack: () => void;
  onSignOut?: () => void;
  initialCatalog?: PosCatalog;
  initialKots?: OrderKotHeaderWithItems[];
  initialBill?: LocalBill | null;
}

interface PendingAdditionalKotAggregate {
  cumulativeOrder: OrderDomain;
  newItems: OrderItemDomain[];
  kot: PosKotDomain;
  kotItems: KotItemDomain[];
}

interface PendingCorrectionOperation {
  id: string;
  kotItemId: string;
  orderItemId: string;
  cancelledQty: number;
  reason: string;
}

export function OrderWorkspace({
  db,
  context,
  terminalCode,
  staffName,
  staffId,
  onBack,
  onSignOut,
  initialCatalog,
  initialKots,
  initialBill,
}: OrderWorkspaceProps): React.ReactElement {
  // Authoritative persisted state tracked from local persistence
  const [persistedOrder, setPersistedOrder] = useState<LocalOrderHeader | null>(context.order);
  const [persistedItems, setPersistedItems] = useState<LocalOrderItem[]>(context.items);

  // KOT History State
  const [kotHistory, setKotHistory] = useState<OrderKotHeaderWithItems[]>(initialKots || []);
  const [isLoadingKots, setIsLoadingKots] = useState<boolean>(false);
  const [kotHistoryError, setKotHistoryError] = useState<string | null>(null);

  // KOT Correction Modal State
  const [isCorrectionModalOpen, setIsCorrectionModalOpen] = useState<boolean>(false);
  const [selectedKot, setSelectedKot] = useState<PosKotDomain | null>(null);
  const [selectedKotItem, setSelectedKotItem] = useState<KotItemDomain | null>(null);
  const [selectedLinkedOrderItem, setSelectedLinkedOrderItem] = useState<LocalOrderItem[]>([]);
  const [activeLinkedOrderItem, setActiveLinkedOrderItem] = useState<LocalOrderItem | null>(null);
  const [correctionCancelQty, setCorrectionCancelQty] = useState<number>(1);
  const [correctionReason, setCorrectionReason] = useState<string>('');
  const [correctionError, setCorrectionError] = useState<string | null>(null);
  const [isSubmittingCorrection, setIsSubmittingCorrection] = useState<boolean>(false);
  const [pendingCorrectionOperation, setPendingCorrectionOperation] = useState<PendingCorrectionOperation | null>(null);

  // Local session status state so billed transition updates workspace header immediately
  const [sessionStatus, setSessionStatus] = useState<string>(context.session.session_status);

  // Authoritative persisted Bill (if order is billed)
  const [persistedBill, setPersistedBill] = useState<LocalBill | null>(initialBill || null);

  // Bill Finalization State
  const [isFinalizingBill, setIsFinalizingBill] = useState<boolean>(false);
  const [showFinalizeConfirmDialog, setShowFinalizeConfirmDialog] = useState<boolean>(false);
  const [finalizeError, setFinalizeError] = useState<string | null>(null);
  const [pendingBillDomain, setPendingBillDomain] = useState<BillDomain | null>(null);

  // Operational status checks: ONLY draft orders are editable; all others are read-only
  const isBilled = sessionStatus === 'billed' || persistedOrder?.status === 'billed';
  const isLockedStatus = persistedOrder !== null && ['billed', 'settled', 'closed', 'cancelled'].includes(persistedOrder.status);
  const isPostKot = persistedOrder !== null && persistedOrder.status === 'kot_sent';
  const isMenuReadOnly = isBilled || isLockedStatus;
  const isReadOnly = isBilled || (persistedOrder !== null && persistedOrder.status !== 'draft');

  // Single-source-of-truth PosCart instance from @cheesyos/pos-core for draft orders
  const cartRef = useRef<PosCart | null>(null);
  if (!cartRef.current) {
    const initialCart = new PosCart({
      orderType: persistedOrder?.order_type || 'DINE_IN',
      tableSessionId: context.session.id,
    });

    // Hydrate editable draft from existing canonical order item snapshot
    if (persistedOrder && persistedOrder.status === 'draft' && context.items.length > 0) {
      for (const item of context.items) {
        initialCart.addItem({
          productId: item.product_id,
          variantId: item.variant_id,
          productName: item.product_name,
          unitPriceRupees: toRupees(item.unit_price_paise),
          quantity: item.quantity,
          taxRatePercent: item.tax_rate,
          discountAmountRupees: toRupees(item.discount_amount_paise),
          notes: item.notes,
        });
      }
    }
    cartRef.current = initialCart;
  }

  // Additional staging PosCart instance for post-KOT items (starts EMPTY)
  const additionalCartRef = useRef<PosCart | null>(null);
  if (!additionalCartRef.current) {
    additionalCartRef.current = new PosCart({
      orderType: persistedOrder?.order_type || 'DINE_IN',
      tableSessionId: context.session.id,
    });
  }

  // Minimal UI dirty state: tracks whether current cart differs from last persisted draft
  const [isDirty, setIsDirty] = useState<boolean>(false);
  const [, setCartRevision] = useState<number>(0);
  const [isSaving, setIsSaving] = useState<boolean>(false);
  const [isSendingKot, setIsSendingKot] = useState<boolean>(false);
  const [isSendingAdditionalKot, setIsSendingAdditionalKot] = useState<boolean>(false);
  const [pendingAdditionalAggregate, setPendingAdditionalAggregate] = useState<PendingAdditionalKotAggregate | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [showUnsavedDialog, setShowUnsavedDialog] = useState<boolean>(false);

  // Demand-driven KOT history load
  const loadKotHistory = useCallback(
    async (orderId: string) => {
      setIsLoadingKots(true);
      setKotHistoryError(null);
      try {
        const kots = await db.getKotsForOrder(orderId);
        setKotHistory(kots);
      } catch (err: any) {
        const msg = typeof err === 'string' ? err : err?.message || String(err);
        setKotHistoryError(`Failed to load KOT history: ${msg}`);
      } finally {
        setIsLoadingKots(false);
      }
    },
    [db]
  );

  // Automatically load KOT history on entering a kot_sent order
  useEffect(() => {
    if (persistedOrder && persistedOrder.status === 'kot_sent' && !initialKots) {
      loadKotHistory(persistedOrder.id);
    }
  }, [persistedOrder?.id, persistedOrder?.status, loadKotHistory, initialKots]);

  // Automatically load authoritative bill if order is in billed status
  useEffect(() => {
    if (persistedOrder && persistedOrder.status === 'billed' && !persistedBill) {
      db.getBillForOrder(persistedOrder.id)
        .then((bill) => {
          if (bill) setPersistedBill(bill);
        })
        .catch(() => {});
    }
  }, [db, persistedOrder?.id, persistedOrder?.status, persistedBill]);

  const cart = cartRef.current;
  const additionalCart = additionalCartRef.current;

  // Calculate canonical items & financial totals from pos-core PosCart authority
  const cartState = cart.getState();
  const cartTotals = useMemo(() => cart.calculateTotals(), [cart, cartState.items]);

  // Read-only projection of persisted commercial items
  const sentDisplayItems: CartItem[] = useMemo(() => {
    return persistedItems.map((item) => ({
      id: item.id,
      productId: item.product_id,
      variantId: item.variant_id,
      productName: item.product_name,
      unitPricePaise: item.unit_price_paise,
      quantity: item.quantity,
      taxRatePercent: item.tax_rate,
      discountAmountPaise: item.discount_amount_paise,
      taxableLinePaise: item.line_total_paise,
      taxLinePaise: 0,
      lineTotalPaise: item.line_total_paise,
      notes: item.notes,
    }));
  }, [persistedItems]);

  const stagedDisplayItems: CartItem[] = useMemo(() => {
    return additionalCart.getState().items;
  }, [additionalCart, additionalCart.getState().items]);

  // For read-only post-KOT/billed orders, project the immutable persisted snapshot
  const displayItems: CartItem[] = useMemo(() => {
    if (isReadOnly && persistedOrder && persistedOrder.status !== 'draft') {
      return sentDisplayItems;
    }
    return cartState.items;
  }, [isReadOnly, persistedOrder, sentDisplayItems, cartState.items]);

  const displayTotals: CartTotals = useMemo(() => {
    if (isPostKot && persistedOrder) {
      const stagedTotals = additionalCart.calculateTotals();
      const subtotalPaise = addPaise(persistedOrder.subtotal_paise, stagedTotals.subtotalPaise);
      const discountTotalPaise = addPaise(persistedOrder.discount_total_paise, stagedTotals.discountTotalPaise);
      const taxTotalPaise = addPaise(persistedOrder.tax_total_paise, stagedTotals.taxTotalPaise);
      const deliveryChargePaise = addPaise(persistedOrder.delivery_charge_paise, stagedTotals.deliveryChargePaise);
      const grandTotalPaise = addPaise(persistedOrder.grand_total_paise, stagedTotals.grandTotalPaise);

      return {
        subtotalPaise,
        discountTotalPaise,
        taxTotalPaise,
        deliveryChargePaise,
        grandTotalPaise,
        subtotalRupees: toRupees(subtotalPaise),
        discountTotalRupees: toRupees(discountTotalPaise),
        taxTotalRupees: toRupees(taxTotalPaise),
        deliveryChargeRupees: toRupees(deliveryChargePaise),
        grandTotalRupees: toRupees(grandTotalPaise),
      };
    }
    if (isReadOnly && persistedOrder && persistedOrder.status !== 'draft') {
      return {
        subtotalPaise: persistedOrder.subtotal_paise,
        discountTotalPaise: persistedOrder.discount_total_paise,
        taxTotalPaise: persistedOrder.tax_total_paise,
        deliveryChargePaise: persistedOrder.delivery_charge_paise,
        grandTotalPaise: persistedOrder.grand_total_paise,
        subtotalRupees: persistedOrder.subtotal_paise / 100,
        discountTotalRupees: persistedOrder.discount_total_paise / 100,
        taxTotalRupees: persistedOrder.tax_total_paise / 100,
        deliveryChargeRupees: persistedOrder.delivery_charge_paise / 100,
        grandTotalRupees: persistedOrder.grand_total_paise / 100,
      };
    }
    return cartTotals;
  }, [additionalCart, cartTotals, isPostKot, isReadOnly, persistedOrder, additionalCart.getState().items]);

  // Handle adding product or canonical variant to cart
  const handleAddToCart = useCallback(
    (product: ProductCatalogDomain, variant?: ProductVariantCatalogDomain | null) => {
      if (isMenuReadOnly) return;
      if (!product.is_available) return;

      const targetCart = isPostKot ? additionalCart : cart;
      if (isPostKot) {
        setPendingAdditionalAggregate(null);
      } else if (isReadOnly) {
        return;
      }

      if (variant) {
        if (!variant.is_available) return;
        const pricePaise =
          variant.price_override_paise !== null ? variant.price_override_paise : product.base_price_paise;
        targetCart.addItem({
          productId: product.id,
          variantId: variant.id,
          productName: `${product.name} (${variant.variant_name})`,
          unitPriceRupees: toRupees(pricePaise),
          taxRatePercent: product.tax_rate,
        });
      } else {
        targetCart.addItem({
          productId: product.id,
          productName: product.name,
          unitPriceRupees: toRupees(product.base_price_paise),
          taxRatePercent: product.tax_rate,
        });
      }

      if (!isPostKot) {
        setIsDirty(true);
      }
      setErrorMessage(null);
      setSuccessMessage(null);
      setCartRevision((r) => r + 1);
    },
    [additionalCart, cart, isMenuReadOnly, isPostKot, isReadOnly]
  );

  // Handle updating item quantity
  const handleUpdateQuantity = useCallback(
    (itemId: string, newQty: number) => {
      if (isPostKot) {
        setPendingAdditionalAggregate(null);
        additionalCart.updateQuantity(itemId, newQty);
        setErrorMessage(null);
        setSuccessMessage(null);
        setCartRevision((r) => r + 1);
        return;
      }
      if (isReadOnly) return;
      cart.updateQuantity(itemId, newQty);
      setIsDirty(true);
      setErrorMessage(null);
      setSuccessMessage(null);
      setCartRevision((r) => r + 1);
    },
    [additionalCart, cart, isPostKot, isReadOnly]
  );

  // Handle removing item from cart
  const handleRemoveItem = useCallback(
    (itemId: string) => {
      if (isPostKot) {
        setPendingAdditionalAggregate(null);
        additionalCart.removeItem(itemId);
        setErrorMessage(null);
        setSuccessMessage(null);
        setCartRevision((r) => r + 1);
        return;
      }
      if (isReadOnly) return;
      cart.removeItem(itemId);
      setIsDirty(true);
      setErrorMessage(null);
      setSuccessMessage(null);
      setCartRevision((r) => r + 1);
    },
    [additionalCart, cart, isPostKot, isReadOnly]
  );

  // Initial order save (for table session with no existing order)
  const handleSaveOrder = useCallback(async () => {
    if (isSaving || isReadOnly || persistedOrder !== null) return;
    if (cart.getState().items.length === 0) {
      setErrorMessage('Cannot save an empty order draft.');
      return;
    }

    setIsSaving(true);
    setErrorMessage(null);
    setSuccessMessage(null);

    try {
      // 1. Construct canonical initial order draft (version = 1)
      const draft = createOrderDraft(cart, {
        status: 'draft',
        deviceId: terminalCode || null,
      });
      draft.order.table_session_id = context.session.id;
      draft.order.version = 1;

      // 2. Persist through accepted semantic persistence contract
      await db.saveOrderAggregate(draft.order, draft.items);

      // 3. Re-read authoritative persisted active order
      const fresh = await db.getActiveOrderForTable(context.table.id);
      if (fresh) {
        setPersistedOrder(fresh.order);
        setPersistedItems(fresh.items);
        setIsDirty(false);
        setSuccessMessage('Order saved locally (v1).');
      }
    } catch (err: any) {
      const msg = typeof err === 'string' ? err : err?.message || String(err);
      setErrorMessage(`Failed to save initial order: ${msg}`);
    } finally {
      setIsSaving(false);
    }
  }, [cart, context, db, isReadOnly, isSaving, persistedOrder, terminalCode]);

  // Existing draft replacement save (version N -> N + 1)
  const handleSaveChanges = useCallback(async () => {
    if (isSaving || isReadOnly || !persistedOrder || persistedOrder.status !== 'draft') return;
    if (cart.getState().items.length === 0) {
      setErrorMessage('Cannot save an empty order draft.');
      return;
    }

    setIsSaving(true);
    setErrorMessage(null);
    setSuccessMessage(null);

    try {
      // 1. Next version derived strictly from authoritative persisted order
      const nextVersion = (persistedOrder.version || 1) + 1;

      // 2. Construct canonical draft replacement aggregate
      const draft = createOrderDraft(cart, {
        orderId: persistedOrder.id,
        displayNumber: persistedOrder.display_number,
        status: 'draft',
        deviceId: persistedOrder.device_id || terminalCode || null,
      });
      draft.order.table_session_id = persistedOrder.table_session_id;
      draft.order.version = nextVersion;

      // 3. Call accepted semantic replaceDraftOrderAggregate contract
      await db.replaceDraftOrderAggregate(draft.order, draft.items);

      // 4. Re-read authoritative persisted active order
      const fresh = await db.getActiveOrderForTable(context.table.id);
      if (fresh) {
        setPersistedOrder(fresh.order);
        setPersistedItems(fresh.items);
        setIsDirty(false);
        setSuccessMessage(`Draft updated locally (v${fresh.order.version}).`);
      }
    } catch (err: any) {
      const msg = typeof err === 'string' ? err : err?.message || String(err);
      setErrorMessage(`Failed to update draft: ${msg}`);
    } finally {
      setIsSaving(false);
    }
  }, [cart, context, db, isReadOnly, isSaving, persistedOrder, terminalCode]);

  // Dispatch canonical KOT snapshot for saved clean draft order
  const handleSendKot = useCallback(async () => {
    if (isSendingKot || isSaving || !persistedOrder || persistedOrder.status !== 'draft') return;
    if (isDirty) {
      setErrorMessage('Save changes before sending KOT.');
      return;
    }
    if (persistedItems.length === 0) {
      setErrorMessage('Cannot send KOT for an empty order.');
      return;
    }

    setIsSendingKot(true);
    setErrorMessage(null);
    setSuccessMessage(null);

    try {
      // 1. Convert persisted items to OrderItemDomain format for createKotDispatchSnapshot
      const orderItemsDomain: OrderItemDomain[] = persistedItems.map((item) => ({
        id: item.id,
        order_id: item.order_id,
        product_id: item.product_id,
        variant_id: item.variant_id ?? null,
        product_name: item.product_name,
        unit_price: toRupees(item.unit_price_paise),
        quantity: item.quantity,
        tax_rate: item.tax_rate,
        discount_amount: toRupees(item.discount_amount_paise),
        line_total: toRupees(item.line_total_paise),
        notes: item.notes ?? null,
        created_at: item.created_at,
      }));

      // 2. Create canonical immutable KOT snapshot via pos-core
      const kotSnapshot = createKotDispatchSnapshot(
        persistedOrder.id,
        orderItemsDomain,
        {
          kotNumber: 1,
          deviceId: persistedOrder.device_id || terminalCode || null,
        }
      );

      // 3. Persist atomically through accepted semantic persistence contract
      await db.saveKotAggregate(kotSnapshot.kot, kotSnapshot.items);

      // 4. Re-read authoritative persisted active order from local persistence
      const fresh = await db.getActiveOrderForTable(context.table.id);
      if (fresh) {
        setPersistedOrder(fresh.order);
        setPersistedItems(fresh.items);
        setIsDirty(false);
        setSuccessMessage(`KOT #${kotSnapshot.kot.kot_number} sent to kitchen.`);

        // Authoritatively refresh KOT history after initial KOT dispatch
        const freshKots = await db.getKotsForOrder(persistedOrder.id);
        setKotHistory(freshKots);
      }
    } catch (err: any) {
      const msg = typeof err === 'string' ? err : err?.message || String(err);
      setErrorMessage(`Failed to send KOT: ${msg}`);
    } finally {
      setIsSendingKot(false);
    }
  }, [context, db, isDirty, isSaving, isSendingKot, persistedItems, persistedOrder, terminalCode]);

  // Append new order items and additional KOT for kot_sent orders
  const handleSendAdditionalKot = useCallback(async () => {
    if (isSendingAdditionalKot || isSaving || !persistedOrder || persistedOrder.status !== 'kot_sent') return;
    const stagedState = additionalCart.getState();
    if (stagedState.items.length === 0) {
      setErrorMessage('Cannot send additional KOT with an empty cart.');
      return;
    }

    setIsSendingAdditionalKot(true);
    setErrorMessage(null);
    setSuccessMessage(null);

    try {
      let aggregate = pendingAdditionalAggregate;
      if (!aggregate) {
        const stagedTotals = additionalCart.calculateTotals();
        const subtotalPaise = addPaise(persistedOrder.subtotal_paise, stagedTotals.subtotalPaise);
        const taxTotalPaise = addPaise(persistedOrder.tax_total_paise, stagedTotals.taxTotalPaise);
        const discountTotalPaise = addPaise(persistedOrder.discount_total_paise, stagedTotals.discountTotalPaise);
        const deliveryChargePaise = addPaise(persistedOrder.delivery_charge_paise, stagedTotals.deliveryChargePaise);
        const grandTotalPaise = addPaise(persistedOrder.grand_total_paise, stagedTotals.grandTotalPaise);

        const cumulativeOrder: OrderDomain = {
          ...persistedOrder,
          status: 'kot_sent',
          subtotal: toRupees(subtotalPaise),
          tax_total: toRupees(taxTotalPaise),
          discount_total: toRupees(discountTotalPaise),
          delivery_charge: toRupees(deliveryChargePaise),
          grand_total: toRupees(grandTotalPaise),
          updated_at: new Date().toISOString(),
        };

        const draftResult = createOrderDraft(additionalCart, {
          orderId: persistedOrder.id,
          status: 'kot_sent',
          deviceId: persistedOrder.device_id || terminalCode || null,
        });
        const newItems = draftResult.items;

        const kotSnapshot = createKotDispatchSnapshot(persistedOrder.id, newItems, {
          kotNumber: 1, // Allocated canonically by persistence transaction
          deviceId: persistedOrder.device_id || terminalCode || null,
        });

        aggregate = {
          cumulativeOrder,
          newItems,
          kot: kotSnapshot.kot,
          kotItems: kotSnapshot.items,
        };
        setPendingAdditionalAggregate(aggregate);
      }

      await db.appendOrderItemsAndKot(
        aggregate.cumulativeOrder,
        aggregate.newItems,
        aggregate.kot,
        aggregate.kotItems
      );

      const fresh = await db.getActiveOrderForTable(context.table.id);
      if (fresh) {
        setPersistedOrder(fresh.order);
        setPersistedItems(fresh.items);
        additionalCart.clear();
        setPendingAdditionalAggregate(null);
        setSuccessMessage(`Additional KOT sent to kitchen.`);

        // Authoritatively refresh KOT history after additional KOT dispatch
        const freshKots = await db.getKotsForOrder(persistedOrder.id);
        setKotHistory(freshKots);
      }
    } catch (err: any) {
      const msg = typeof err === 'string' ? err : err?.message || String(err);
      setErrorMessage(`Failed to send additional KOT: ${msg}`);
    } finally {
      setIsSendingAdditionalKot(false);
    }
  }, [
    additionalCart,
    context.table.id,
    db,
    isSaving,
    isSendingAdditionalKot,
    pendingAdditionalAggregate,
    persistedOrder,
    terminalCode,
  ]);

  // Handle opening KOT correction dialog
  const handleOpenCorrection = useCallback(
    (kot: PosKotDomain, kotItem: KotItemDomain, linkedOrderItem: LocalOrderItem) => {
      // DIRTY_ADDITIONAL_CART_CORRECTION_POLICY=BLOCK
      if (additionalCart.getState().items.length > 0) {
        setErrorMessage('Unsent additional items in cart. Please send or remove them before making a correction.');
        return;
      }
      setSelectedKot(kot);
      setSelectedKotItem(kotItem);
      setActiveLinkedOrderItem(linkedOrderItem);
      setCorrectionCancelQty(1);
      setCorrectionReason('');
      setCorrectionError(null);
      setPendingCorrectionOperation(null);
      setIsCorrectionModalOpen(true);
    },
    [additionalCart]
  );

  // Handle closing KOT correction dialog
  const handleCloseCorrectionModal = useCallback(() => {
    if (isSubmittingCorrection) return;
    setIsCorrectionModalOpen(false);
    setSelectedKot(null);
    setSelectedKotItem(null);
    setActiveLinkedOrderItem(null);
    setCorrectionError(null);
  }, [isSubmittingCorrection]);

  // Handle cancel quantity changes in dialog
  const handleCancelQtyChange = useCallback((qty: number) => {
    setCorrectionCancelQty(qty);
    // Invalidate pending retry operation if inputs change
    setPendingCorrectionOperation((prev) => (prev && prev.cancelledQty !== qty ? null : prev));
  }, []);

  // Handle reason changes in dialog
  const handleReasonChange = useCallback((reason: string) => {
    setCorrectionReason(reason);
    // Invalidate pending retry operation if inputs change
    setPendingCorrectionOperation((prev) => (prev && prev.reason !== reason.trim() ? null : prev));
  }, []);

  // Handle confirming KOT correction with canonical financials and local-first persistence
  const handleConfirmCorrection = useCallback(async () => {
    if (
      isSubmittingCorrection ||
      !persistedOrder ||
      persistedOrder.status !== 'kot_sent' ||
      !selectedKot ||
      !selectedKotItem ||
      !activeLinkedOrderItem
    ) {
      return;
    }

    // 1. DIRTY_ADDITIONAL_CART_CORRECTION_POLICY=BLOCK
    if (additionalCart.getState().items.length > 0) {
      setCorrectionError('Unsent additional items in cart. Please send or remove them before making a correction.');
      return;
    }

    // 2. Validate quantity & reason
    const maxQty = activeLinkedOrderItem.quantity;
    const qtyErr = validateCancelQuantity(correctionCancelQty, maxQty);
    if (qtyErr) {
      setCorrectionError(qtyErr);
      return;
    }

    const trimmedReason = correctionReason.trim();
    const reasonErr = validateReason(trimmedReason);
    if (reasonErr) {
      setCorrectionError(reasonErr);
      return;
    }

    setIsSubmittingCorrection(true);
    setCorrectionError(null);
    setErrorMessage(null);
    setSuccessMessage(null);

    // 3. Stable Retry Operation ID
    let operation = pendingCorrectionOperation;
    if (
      !operation ||
      operation.kotItemId !== selectedKotItem.id ||
      operation.orderItemId !== activeLinkedOrderItem.id ||
      operation.cancelledQty !== correctionCancelQty ||
      operation.reason !== trimmedReason
    ) {
      operation = {
        id: crypto.randomUUID(),
        kotItemId: selectedKotItem.id,
        orderItemId: activeLinkedOrderItem.id,
        cancelledQty: correctionCancelQty,
        reason: trimmedReason,
      };
      setPendingCorrectionOperation(operation);
    }

    try {
      // 4. Map persisted data to canonical pos-core domains
      const orderDomain: OrderDomain = {
        ...persistedOrder,
        subtotal: toRupees(persistedOrder.subtotal_paise),
        tax_total: toRupees(persistedOrder.tax_total_paise),
        discount_total: toRupees(persistedOrder.discount_total_paise),
        delivery_charge: toRupees(persistedOrder.delivery_charge_paise),
        grand_total: toRupees(persistedOrder.grand_total_paise),
      };

      const orderItemsDomain: OrderItemDomain[] = persistedItems.map((item) => ({
        id: item.id,
        order_id: item.order_id,
        product_id: item.product_id,
        variant_id: item.variant_id ?? null,
        product_name: item.product_name,
        unit_price: toRupees(item.unit_price_paise),
        quantity: item.quantity,
        tax_rate: item.tax_rate,
        discount_amount: toRupees(item.discount_amount_paise),
        line_total: toRupees(item.line_total_paise),
        notes: item.notes ?? null,
        created_at: item.created_at,
      }));

      // 5. Calculate canonical financials using pos-core helper (persisted items ONLY)
      const calcResult = calculateKotCorrectionFinancials({
        order: orderDomain,
        orderItems: orderItemsDomain,
        targetOrderItemId: activeLinkedOrderItem.id,
        cancelledQty: correctionCancelQty,
      });

      const targetItemDomain = orderItemsDomain.find((it) => it.id === activeLinkedOrderItem.id)!;
      const fullUpdatedOrderItem: OrderItemDomain = {
        ...targetItemDomain,
        quantity: calcResult.updatedOrderItem.quantity,
        line_total: calcResult.updatedOrderItem.line_total,
      };

      const fullUpdatedOrder: OrderDomain = {
        ...orderDomain,
        subtotal: calcResult.updatedOrder.subtotal,
        tax_total: calcResult.updatedOrder.tax_total,
        discount_total: calcResult.updatedOrder.discount_total,
        delivery_charge: calcResult.updatedOrder.delivery_charge,
        grand_total: calcResult.updatedOrder.grand_total,
        updated_at: new Date().toISOString(),
      };

      const correctionDomain: KotCorrectionDomain = {
        id: operation.id,
        order_id: persistedOrder.id,
        kot_id: selectedKot.id,
        kot_item_id: selectedKotItem.id,
        order_item_id: selectedKotItem.order_item_id,
        product_name: selectedKotItem.product_name,
        cancelled_qty: correctionCancelQty,
        reason: trimmedReason,
        authorized_by_staff_id: staffId || 'staff-pos-cashier',
        created_at: new Date().toISOString(),
      };

      // 6. Apply local-first persistence transaction
      await db.applyKotCorrection({
        correction: correctionDomain,
        updatedOrderItem: fullUpdatedOrderItem,
        updatedOrder: fullUpdatedOrder,
      });

      // 7. Authoritative reread from local persistence
      const freshOrder = await db.getActiveOrderForTable(context.table.id);
      if (freshOrder) {
        setPersistedOrder(freshOrder.order);
        setPersistedItems(freshOrder.items);
      }

      const freshKots = await db.getKotsForOrder(persistedOrder.id);
      setKotHistory(freshKots);

      // 8. Reset modal and clear pending operation
      setIsCorrectionModalOpen(false);
      setSelectedKot(null);
      setSelectedKotItem(null);
      setActiveLinkedOrderItem(null);
      setPendingCorrectionOperation(null);
      setSuccessMessage(`Cancelled ${correctionCancelQty}x ${selectedKotItem.product_name}.`);
    } catch (err: any) {
      const msg = typeof err === 'string' ? err : err?.message || String(err);
      setCorrectionError(`Failed to apply correction: ${msg}`);
      // KEEP modal open, KEEP operation ID stable for retry!
    } finally {
      setIsSubmittingCorrection(false);
    }
  }, [
    activeLinkedOrderItem,
    additionalCart,
    context.table.id,
    correctionCancelQty,
    correctionReason,
    db,
    isSubmittingCorrection,
    pendingCorrectionOperation,
    persistedItems,
    persistedOrder,
    selectedKot,
    selectedKotItem,
    staffId,
  ]);

  // Handle opening Finalize Bill confirmation dialog
  const handleOpenFinalizeBill = useCallback(() => {
    if (!persistedOrder || persistedOrder.status !== 'kot_sent') return;
    if (additionalCart.getState().items.length > 0) {
      setErrorMessage('Send or remove unsent items before finalizing bill.');
      return;
    }
    setFinalizeError(null);
    setShowFinalizeConfirmDialog(true);
  }, [additionalCart, persistedOrder]);

  // Handle closing Finalize Bill confirmation dialog
  const handleCloseFinalizeConfirmDialog = useCallback(() => {
    if (isFinalizingBill) return;
    setShowFinalizeConfirmDialog(false);
    setFinalizeError(null);
  }, [isFinalizingBill]);

  // Handle confirming Bill Finalization with canonical pos-core engine and local-first persistence
  const handleConfirmFinalizeBill = useCallback(async () => {
    if (isFinalizingBill || !persistedOrder || persistedOrder.status !== 'kot_sent') {
      return;
    }

    // 1. DIRTY_ADDITIONAL_CART_BILL_POLICY=BLOCK
    if (additionalCart.getState().items.length > 0) {
      setFinalizeError('Send or remove unsent items before finalizing bill.');
      return;
    }

    setIsFinalizingBill(true);
    setFinalizeError(null);
    setErrorMessage(null);
    setSuccessMessage(null);

    try {
      // Step 7: AUTHORITATIVE REREAD BEFORE FINALIZATION
      const fresh = await db.getActiveOrderForTable(context.table.id);
      if (!fresh || !fresh.order) {
        setFinalizeError('Active order not found for table. Please refresh.');
        return;
      }

      if (fresh.order.status !== 'kot_sent') {
        setPersistedOrder(fresh.order);
        setPersistedItems(fresh.items);
        setFinalizeError(`Cannot finalize bill: order status is '${fresh.order.status}', must be 'kot_sent'.`);
        return;
      }

      if (additionalCart.getState().items.length > 0) {
        setFinalizeError('Send or remove unsent items before finalizing bill.');
        return;
      }

      // Update local authoritative reference
      setPersistedOrder(fresh.order);
      setPersistedItems(fresh.items);

      // Step 8: CANONICAL BILL CREATION using @cheesyos/pos-core::finalizeBill
      const orderDomain: OrderDomain = {
        ...fresh.order,
        subtotal: toRupees(fresh.order.subtotal_paise),
        tax_total: toRupees(fresh.order.tax_total_paise),
        discount_total: toRupees(fresh.order.discount_total_paise),
        delivery_charge: toRupees(fresh.order.delivery_charge_paise),
        grand_total: toRupees(fresh.order.grand_total_paise),
      };

      // Stable operation UUID for idempotency retry
      let billToSave = pendingBillDomain;
      if (!billToSave || billToSave.order_id !== orderDomain.id) {
        billToSave = finalizeBill(orderDomain, {
          billNumber: 'PENDING',
          deviceId: terminalCode || fresh.order.device_id || null,
        });
        setPendingBillDomain(billToSave);
      }

      // Step 10: LOCAL-FIRST PERSISTENCE
      const saveResult = await db.saveBillWithSequence(billToSave);

      // Step 13: AUTHORITATIVE SUCCESS REREAD
      const freshBill = await db.getBillForOrder(fresh.order.id);
      setPersistedBill(
        freshBill || {
          id: saveResult.bill.id,
          order_id: saveResult.bill.order_id,
          bill_number: saveResult.bill.bill_number,
          subtotal_paise: fresh.order.subtotal_paise,
          cgst_total_paise: toPaise(saveResult.bill.cgst_total),
          sgst_total_paise: toPaise(saveResult.bill.sgst_total),
          discount_total_paise: fresh.order.discount_total_paise,
          grand_total_paise: fresh.order.grand_total_paise,
          payment_status: saveResult.bill.payment_status,
          finalized_at: saveResult.bill.finalized_at,
          device_id: saveResult.bill.device_id || null,
        }
      );

      const freshActive = await db.getActiveOrderForTable(context.table.id);
      if (freshActive) {
        setPersistedOrder(freshActive.order);
        setPersistedItems(freshActive.items);
      }
      setSessionStatus('billed');

      setShowFinalizeConfirmDialog(false);
      setPendingBillDomain(null);
      setSuccessMessage(`Bill finalized: ${freshBill?.bill_number || saveResult.bill.bill_number}. Awaiting Payment.`);
    } catch (err: any) {
      // Step 12: AMBIGUOUS FAILURE / RETRY
      try {
        const existingBill = await db.getBillForOrder(persistedOrder.id);
        if (existingBill) {
          setPersistedBill(existingBill);
          const freshActive = await db.getActiveOrderForTable(context.table.id);
          if (freshActive) {
            setPersistedOrder(freshActive.order);
            setPersistedItems(freshActive.items);
          }
          setSessionStatus('billed');
          setShowFinalizeConfirmDialog(false);
          setPendingBillDomain(null);
          setSuccessMessage(`Bill finalized: ${existingBill.bill_number}. Awaiting Payment.`);
          return;
        }
      } catch {
        // Ignore read error
      }

      const msg = typeof err === 'string' ? err : err?.message || String(err);
      setFinalizeError(`Failed to finalize bill: ${msg}`);
    } finally {
      setIsFinalizingBill(false);
    }
  }, [
    additionalCart,
    context.table.id,
    db,
    isFinalizingBill,
    pendingBillDomain,
    persistedOrder,
    terminalCode,
  ]);

  // Navigation Guard: check for unsaved cart modifications before returning to tables
  const handleBackToTables = useCallback(() => {
    if (isPostKot) {
      if (additionalCart.getState().items.length > 0) {
        setShowUnsavedDialog(true);
        return;
      }
    } else {
      if (isDirty && cart.getState().items.length > 0) {
        setShowUnsavedDialog(true);
        return;
      }
    }
    onBack();
  }, [additionalCart, cart, isDirty, isPostKot, onBack]);

  const hasActiveOrder = persistedOrder !== null;
  const orderDisplayId = persistedOrder
    ? persistedOrder.display_number || persistedOrder.id.slice(0, 8)
    : null;

  return (
    <div
      id="order-workspace"
      style={{
        display: 'flex',
        flexDirection: 'column',
        height: '100vh',
        backgroundColor: '#f8fafc',
        color: '#0f172a',
        fontFamily: 'system-ui, -apple-system, sans-serif',
      }}
    >
      {/* Top Header Bar */}
      <header
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '12px 20px',
          backgroundColor: '#0f172a',
          color: '#ffffff',
          boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: '14px' }}>
          <button
            id="back-to-tables-button"
            type="button"
            onClick={handleBackToTables}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
              backgroundColor: '#1e293b',
              color: '#f8fafc',
              border: '1px solid #334155',
              padding: '6px 12px',
              borderRadius: '6px',
              fontSize: '13px',
              fontWeight: '600',
              cursor: 'pointer',
              transition: 'background 0.15s',
            }}
          >
            ← Tables
          </button>

          <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
            <span style={{ fontSize: '17px', fontWeight: '700', color: '#f8fafc' }}>
              {`Table ${context.table.table_number}`}
            </span>

            <span
              style={{
                backgroundColor: '#1e293b',
                color: '#94a3b8',
                padding: '3px 8px',
                borderRadius: '4px',
                fontSize: '12px',
                fontWeight: '500',
                border: '1px solid #334155',
              }}
            >
              {`${context.table.section || 'General'} • Guests: ${context.session.guest_count}`}
            </span>

            <span
              id="workspace-session-status"
              style={{
                backgroundColor: isBilled ? '#fef3c7' : '#dcfce7',
                color: isBilled ? '#92400e' : '#166534',
                padding: '3px 8px',
                borderRadius: '4px',
                fontSize: '11px',
                fontWeight: '700',
                textTransform: 'uppercase',
                letterSpacing: '0.05em',
              }}
            >
              {sessionStatus}
            </span>

            {persistedBill && (
              <span
                id="workspace-bill-badge"
                style={{
                  backgroundColor: '#0f766e',
                  color: '#ffffff',
                  padding: '3px 8px',
                  borderRadius: '4px',
                  fontSize: '11px',
                  fontWeight: '700',
                }}
              >
                {`Bill: ${persistedBill.bill_number}`}
              </span>
            )}

            {hasActiveOrder ? (
              <span
                id="workspace-order-badge"
                style={{
                  backgroundColor: '#0284c7',
                  color: '#ffffff',
                  padding: '3px 8px',
                  borderRadius: '4px',
                  fontSize: '11px',
                  fontWeight: '700',
                }}
              >
                {`Order: ${orderDisplayId} (${persistedOrder!.status}${
                  persistedOrder!.version ? ` v${persistedOrder!.version}` : ''
                })`}
              </span>
            ) : (
              <span
                id="workspace-new-order-badge"
                style={{
                  backgroundColor: '#059669',
                  color: '#ffffff',
                  padding: '3px 8px',
                  borderRadius: '4px',
                  fontSize: '11px',
                  fontWeight: '700',
                }}
              >
                New Order
              </span>
            )}
          </div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
          {terminalCode && (
            <span style={{ fontSize: '12px', color: '#94a3b8' }}>
              {`Terminal: ${terminalCode}`}
            </span>
          )}

          {staffName && (
            <span style={{ fontSize: '13px', fontWeight: '600', color: '#f1f5f9' }}>
              {staffName}
            </span>
          )}

          {onSignOut && (
            <button
              id="workspace-signout-button"
              type="button"
              onClick={onSignOut}
              style={{
                backgroundColor: '#dc2626',
                color: '#ffffff',
                border: 'none',
                padding: '6px 12px',
                borderRadius: '6px',
                fontSize: '12px',
                fontWeight: '600',
                cursor: 'pointer',
              }}
            >
              Sign Out
            </button>
          )}
        </div>
      </header>

      {/* Main Workspace Body */}
      <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>
        {/* Menu Catalog Panel (Left) */}
        <main style={{ flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
          <MenuCatalog
            db={db}
            initialCatalog={initialCatalog}
            isReadOnly={isMenuReadOnly}
            onAddToCart={handleAddToCart}
          />
        </main>

        {/* Sent KOTs Panel (Middle) */}
        {(isPostKot || kotHistory.length > 0) && (
          <aside
            id="sent-kots-panel"
            style={{
              width: '320px',
              backgroundColor: '#ffffff',
              borderLeft: '1px solid #e2e8f0',
              display: 'flex',
              flexDirection: 'column',
              overflowY: 'auto',
              padding: '16px',
              fontFamily: 'system-ui, -apple-system, sans-serif',
            }}
          >
            <div style={{ borderBottom: '1px solid #e2e8f0', paddingBottom: '10px', marginBottom: '14px' }}>
              <h3 style={{ margin: 0, fontSize: '16px', fontWeight: '700', color: '#0f172a' }}>
                Sent KOTs
              </h3>
              <span style={{ fontSize: '12px', color: '#64748b' }}>
                {kotHistory.length} ticket{kotHistory.length === 1 ? '' : 's'} dispatched
              </span>
            </div>

            {isLoadingKots && (
              <div id="loading-kots-indicator" style={{ padding: '12px 0', color: '#64748b', fontSize: '13px' }}>
                Loading KOT history...
              </div>
            )}

            {kotHistoryError && (
              <div
                id="kots-error-message"
                style={{
                  padding: '10px',
                  backgroundColor: '#fef2f2',
                  color: '#b91c1c',
                  borderRadius: '6px',
                  fontSize: '12px',
                  marginBottom: '10px',
                }}
              >
                {kotHistoryError}
              </div>
            )}

            {kotHistory.length === 0 && !isLoadingKots && !kotHistoryError && (
              <div id="no-kots-message" style={{ color: '#94a3b8', fontSize: '13px', fontStyle: 'italic', padding: '12px 0' }}>
                No KOTs dispatched yet.
              </div>
            )}

            {kotHistory.map((kotHeader) => (
              <div
                key={kotHeader.kot.id}
                id={`sent-kot-group-${kotHeader.kot.kot_number}`}
                style={{
                  border: '1px solid #e2e8f0',
                  borderRadius: '8px',
                  marginBottom: '12px',
                  overflow: 'hidden',
                }}
              >
                <div
                  style={{
                    backgroundColor: '#f1f5f9',
                    padding: '8px 12px',
                    fontWeight: '700',
                    fontSize: '13px',
                    color: '#1e293b',
                    display: 'flex',
                    justifyContent: 'space-between',
                    alignItems: 'center',
                  }}
                >
                  <span>KOT #{kotHeader.kot.kot_number}</span>
                  <span style={{ fontSize: '11px', color: '#64748b', fontWeight: 'normal' }}>
                    {kotHeader.kot.printed_at ? 'Dispatched' : 'Pending'}
                  </span>
                </div>

                <div style={{ padding: '8px 12px', display: 'flex', flexDirection: 'column', gap: '8px' }}>
                  {kotHeader.items.map((kotItem) => {
                    // Resolve linked commercial item strictly by order_item_id UUID
                    const linkedOrderItem = kotItem.order_item_id
                      ? persistedItems.find((oi) => oi.id === kotItem.order_item_id)
                      : null;

                    const isUnlinked = kotItem.order_item_id === null;
                    const isMissingLinked = !isUnlinked && !linkedOrderItem;
                    const remainingQty = linkedOrderItem ? linkedOrderItem.quantity : 0;
                    const isCancelled = linkedOrderItem ? remainingQty === 0 : false;

                    // Correction action eligibility
                    const isCorrectionEligible =
                      persistedOrder?.status === 'kot_sent' &&
                      !isUnlinked &&
                      !isMissingLinked &&
                      remainingQty > 0;

                    return (
                      <div
                        key={kotItem.id}
                        id={`sent-kot-item-${kotItem.id}`}
                        style={{
                          display: 'flex',
                          justifyContent: 'space-between',
                          alignItems: 'center',
                          borderBottom: '1px dashed #f1f5f9',
                          paddingBottom: '6px',
                        }}
                      >
                        <div style={{ display: 'flex', flexDirection: 'column', gap: '2px', flex: 1, marginRight: '8px' }}>
                          <span style={{ fontSize: '13px', fontWeight: '600', color: '#0f172a' }}>
                            {kotItem.product_name}
                          </span>
                          <div style={{ fontSize: '11px', color: '#64748b', display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
                            <span id={`sent-qty-${kotItem.id}`}>{`Sent: ${kotItem.quantity}`}</span>
                            {isUnlinked ? (
                              <span id={`unlinked-status-${kotItem.id}`} style={{ color: '#d97706', fontWeight: '600' }}>
                                Correction unavailable for older KOT
                              </span>
                            ) : isMissingLinked ? (
                              <span id={`missing-status-${kotItem.id}`} style={{ color: '#ef4444', fontWeight: '600' }}>
                                Linked item unavailable
                              </span>
                            ) : isCancelled ? (
                              <span id={`cancelled-status-${kotItem.id}`} style={{ color: '#dc2626', fontWeight: '700' }}>
                                Cancelled
                              </span>
                            ) : (
                              <span id={`remaining-qty-${kotItem.id}`}>{`Remaining: ${remainingQty}`}</span>
                            )}
                          </div>
                        </div>

                        {/* Correction Action: ONLY rendered when order is kot_sent */}
                        {persistedOrder?.status === 'kot_sent' && (
                          <button
                            type="button"
                            id={`correct-btn-${kotItem.id}`}
                            disabled={!isCorrectionEligible}
                            onClick={() => {
                              if (isCorrectionEligible && linkedOrderItem) {
                                handleOpenCorrection(kotHeader.kot, kotItem, linkedOrderItem);
                              }
                            }}
                            style={{
                              padding: '4px 8px',
                              backgroundColor: isCorrectionEligible ? '#fef2f2' : '#f1f5f9',
                              color: isCorrectionEligible ? '#dc2626' : '#94a3b8',
                              border: `1px solid ${isCorrectionEligible ? '#fecaca' : '#cbd5e1'}`,
                              borderRadius: '4px',
                              fontSize: '11px',
                              fontWeight: '600',
                              cursor: isCorrectionEligible ? 'pointer' : 'not-allowed',
                            }}
                          >
                            Correct
                          </button>
                        )}
                      </div>
                    );
                  })}
                </div>
              </div>
            ))}
          </aside>
        )}

        {/* Operational Cart Panel (Right) */}
        <CartPanel
          items={isPostKot ? sentDisplayItems : displayItems}
          totals={displayTotals}
          sentItems={sentDisplayItems}
          stagedItems={stagedDisplayItems}
          onUpdateQuantity={handleUpdateQuantity}
          onRemoveItem={handleRemoveItem}
          onSaveOrder={handleSaveOrder}
          onSaveChanges={handleSaveChanges}
          onSendKot={handleSendKot}
          onSendAdditionalKot={isPostKot ? handleSendAdditionalKot : undefined}
          onFinalizeBill={isPostKot ? handleOpenFinalizeBill : undefined}
          isSaving={isSaving}
          isSendingKot={isSendingKot}
          isSendingAdditionalKot={isSendingAdditionalKot}
          isFinalizingBill={isFinalizingBill}
          billNumber={persistedBill?.bill_number || null}
          isDirty={isDirty}
          isReadOnly={isReadOnly}
          hasActiveOrder={hasActiveOrder}
          orderStatus={persistedOrder?.status || null}
          orderVersion={persistedOrder?.version || null}
          orderDisplayId={orderDisplayId}
          tableNumber={context.table.table_number}
          guestCount={context.session.guest_count}
          errorMessage={errorMessage}
          successMessage={successMessage}
        />
      </div>

      {/* Unsaved Changes Confirmation Modal */}
      {showUnsavedDialog && (
        <div
          id="unsaved-changes-dialog"
          style={{
            position: 'fixed',
            inset: 0,
            backgroundColor: 'rgba(15, 23, 42, 0.65)',
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
              width: '380px',
              boxShadow: '0 10px 25px rgba(0,0,0,0.2)',
            }}
          >
            <h3 style={{ margin: '0 0 10px 0', fontSize: '17px', fontWeight: '700', color: '#0f172a' }}>
              Discard unsaved changes?
            </h3>
            <p style={{ margin: '0 0 20px 0', fontSize: '13px', color: '#64748b', lineHeight: '1.5' }}>
              You have unsaved changes in your cart. Returning to the table floor will discard any uncommitted edits.
            </p>
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '10px' }}>
              <button
                type="button"
                id="unsaved-stay-button"
                onClick={() => setShowUnsavedDialog(false)}
                style={{
                  padding: '8px 16px',
                  backgroundColor: '#f1f5f9',
                  color: '#334155',
                  border: '1px solid #cbd5e1',
                  borderRadius: '6px',
                  fontSize: '13px',
                  fontWeight: '600',
                  cursor: 'pointer',
                }}
              >
                Stay
              </button>
              <button
                type="button"
                id="unsaved-discard-button"
                onClick={() => {
                  setShowUnsavedDialog(false);
                  onBack();
                }}
                style={{
                  padding: '8px 16px',
                  backgroundColor: '#ef4444',
                  color: '#ffffff',
                  border: 'none',
                  borderRadius: '6px',
                  fontSize: '13px',
                  fontWeight: '600',
                  cursor: 'pointer',
                }}
              >
                Discard & Return
              </button>
            </div>
          </div>
        </div>
      )}

      {/* KOT Item Correction Modal */}
      {selectedKot && selectedKotItem && activeLinkedOrderItem && (
        <KotCorrectionModal
          isOpen={isCorrectionModalOpen}
          kotNumber={selectedKot.kot_number}
          kotItem={selectedKotItem}
          linkedOrderItem={activeLinkedOrderItem}
          cancelledQty={correctionCancelQty}
          onCancelledQtyChange={handleCancelQtyChange}
          reason={correctionReason}
          onReasonChange={handleReasonChange}
          onConfirm={handleConfirmCorrection}
          onClose={handleCloseCorrectionModal}
          isSubmitting={isSubmittingCorrection}
          errorMessage={correctionError}
          isDirtyCartBlocked={additionalCart.getState().items.length > 0}
        />
      )}

      {/* Finalize Bill Confirmation Modal */}
      {showFinalizeConfirmDialog && persistedOrder && (
        <div
          id="finalize-bill-confirm-dialog"
          style={{
            position: 'fixed',
            inset: 0,
            backgroundColor: 'rgba(15, 23, 42, 0.65)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            zIndex: 1000,
          }}
        >
          <div
            style={{
              backgroundColor: '#ffffff',
              borderRadius: '10px',
              padding: '24px',
              width: '420px',
              maxWidth: '90vw',
              boxShadow: '0 20px 25px -5px rgba(0, 0, 0, 0.1)',
            }}
          >
            <h3 id="finalize-bill-modal-title" style={{ margin: '0 0 12px 0', fontSize: '18px', fontWeight: '700', color: '#0f172a' }}>
              Finalize Bill
            </h3>
            <div style={{ fontSize: '13px', color: '#64748b', marginBottom: '16px' }}>
              Table {context.table.table_number} • Order #{orderDisplayId || persistedOrder.id.slice(0, 8)}
            </div>

            <div
              style={{
                backgroundColor: '#f8fafc',
                border: '1px solid #e2e8f0',
                borderRadius: '8px',
                padding: '14px',
                marginBottom: '16px',
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '6px', fontSize: '13px', color: '#475569' }}>
                <span>Subtotal:</span>
                <span>₹{toRupees(persistedOrder.subtotal_paise).toFixed(2)}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '6px', fontSize: '13px', color: '#475569' }}>
                <span>Taxes:</span>
                <span>₹{toRupees(persistedOrder.tax_total_paise).toFixed(2)}</span>
              </div>
              {persistedOrder.discount_total_paise > 0 && (
                <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '6px', fontSize: '13px', color: '#16a34a' }}>
                  <span>Discount:</span>
                  <span>-₹{toRupees(persistedOrder.discount_total_paise).toFixed(2)}</span>
                </div>
              )}
              <div
                id="finalize-bill-grand-total"
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  paddingTop: '8px',
                  borderTop: '1px dashed #cbd5e1',
                  fontSize: '16px',
                  fontWeight: '700',
                  color: '#0f172a',
                }}
              >
                <span>Grand Total:</span>
                <span>₹{toRupees(persistedOrder.grand_total_paise).toFixed(2)}</span>
              </div>
            </div>

            <div style={{ fontSize: '12px', color: '#475569', marginBottom: '16px', lineHeight: '1.4' }}>
              Finalizing this bill will advance the order and table session to <strong>Billed</strong>. Post-bill modifications, Additional KOTs, and cancellations will be locked.
            </div>

            {finalizeError && (
              <div
                id="finalize-bill-error-message"
                style={{
                  padding: '10px',
                  backgroundColor: '#fef2f2',
                  border: '1px solid #fecaca',
                  color: '#991b1b',
                  borderRadius: '6px',
                  fontSize: '12px',
                  marginBottom: '16px',
                }}
              >
                {finalizeError}
              </div>
            )}

            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '10px' }}>
              <button
                type="button"
                id="cancel-finalize-bill-button"
                disabled={isFinalizingBill}
                onClick={handleCloseFinalizeConfirmDialog}
                style={{
                  padding: '9px 16px',
                  backgroundColor: '#f1f5f9',
                  color: '#475569',
                  border: '1px solid #cbd5e1',
                  borderRadius: '6px',
                  fontSize: '13px',
                  fontWeight: '600',
                  cursor: isFinalizingBill ? 'not-allowed' : 'pointer',
                }}
              >
                Cancel
              </button>
              <button
                type="button"
                id="confirm-finalize-bill-button"
                disabled={isFinalizingBill}
                onClick={handleConfirmFinalizeBill}
                style={{
                  padding: '9px 18px',
                  backgroundColor: isFinalizingBill ? '#94a3b8' : '#0f766e',
                  color: '#ffffff',
                  border: 'none',
                  borderRadius: '6px',
                  fontSize: '13px',
                  fontWeight: '700',
                  cursor: isFinalizingBill ? 'not-allowed' : 'pointer',
                }}
              >
                {isFinalizingBill ? 'Finalizing Bill...' : 'Confirm & Finalize'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

export default OrderWorkspace;
