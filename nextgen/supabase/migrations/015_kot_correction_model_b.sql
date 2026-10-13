-- CHEESYOS NEXTGEN V1 MIGRATION: 015_kot_correction_model_b.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: TASK_3G_2_09B
-- Purpose: Canonical KOT Lineage, Commercial Order Item Quantity Relaxation, and Atomic Model-B Correction Contract

-- ============================================================================
-- 1. ADD CANONICAL KOT -> ORDER ITEM LINEAGE
-- ============================================================================
ALTER TABLE public.kot_items
  ADD COLUMN IF NOT EXISTS order_item_id UUID REFERENCES public.order_items(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_kot_items_order_item_id ON public.kot_items(order_item_id);

-- ============================================================================
-- 2. ADD CORRECTION PROVENANCE (KOT ITEM + ORDER ITEM LINKAGE)
-- ============================================================================
ALTER TABLE public.kot_corrections
  ADD COLUMN IF NOT EXISTS kot_item_id UUID REFERENCES public.kot_items(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS order_item_id UUID REFERENCES public.order_items(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_kot_corrections_kot_item_id ON public.kot_corrections(kot_item_id);
CREATE INDEX IF NOT EXISTS idx_kot_corrections_order_item_id ON public.kot_corrections(order_item_id);

-- ============================================================================
-- 3. RELAX COMMERCIAL QUANTITY CONSTRAINT TO ALLOW ZERO-BILLABLE CORRECTION STATE
-- ============================================================================
ALTER TABLE public.order_items DROP CONSTRAINT IF EXISTS order_items_quantity_check;
ALTER TABLE public.order_items ADD CONSTRAINT order_items_quantity_check CHECK (quantity >= 0);

-- ============================================================================
-- 4. REDEFINE secure_sync_pos_kot (PERSISTS & VALIDATES kot_items.order_item_id)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.secure_sync_pos_kot(
  p_kot JSONB,
  p_kot_items JSONB,
  p_device_id UUID DEFAULT NULL,
  p_device_token TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_kot_id UUID;
  v_order_id UUID;
  v_device_id UUID;
  v_item_count INTEGER;
  v_existing_item_count INTEGER;
  v_item JSONB;
BEGIN
  -- A. Staff Authorization
  IF auth.uid() IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.staff_profiles 
      WHERE id = auth.uid() AND (has_pos_access = true OR has_admin_access = true) AND is_active = true
    ) THEN
      RAISE EXCEPTION 'Access Denied: Active staff profile required for KOT sync';
    END IF;
  END IF;

  -- B. Resolve & Enforce Device Possession Authorization
  v_device_id := COALESCE(p_device_id, (p_kot->>'device_id')::UUID);
  PERFORM public.assert_authorized_pos_device(v_device_id, p_device_token);

  v_kot_id := (p_kot->>'id')::UUID;
  v_order_id := (p_kot->>'order_id')::UUID;

  IF NOT EXISTS (SELECT 1 FROM public.orders WHERE id = v_order_id) THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Referenced order ID % does not exist for KOT sync', v_order_id;
  END IF;

  v_item_count := jsonb_array_length(p_kot_items);
  IF v_item_count IS NULL OR v_item_count = 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: KOT aggregate must contain at least one item';
  END IF;

  -- C. Validate Lineage for Items Belonging to This Order
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_kot_items) LOOP
    IF (v_item->>'order_item_id') IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.order_items
        WHERE id = (v_item->>'order_item_id')::UUID AND order_id = v_order_id
      ) THEN
        RAISE EXCEPTION 'VALIDATION_ERROR: KOT item % references order_item % that does not belong to order %',
          v_item->>'id', v_item->>'order_item_id', v_order_id;
      END IF;
    END IF;
  END LOOP;

  -- D. Idempotency Check & Payload Mismatch Protection
  IF EXISTS (SELECT 1 FROM public.pos_kots WHERE id = v_kot_id) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.pos_kots
      WHERE id = v_kot_id
        AND order_id = v_order_id
        AND kot_number = (p_kot->>'kot_number')::INTEGER
    ) THEN
      RAISE EXCEPTION 'CONTRACT_CONFLICT: KOT ID % already exists with mismatched header payload', v_kot_id;
    END IF;

    SELECT COUNT(*) INTO v_existing_item_count
    FROM public.kot_items
    WHERE kot_id = v_kot_id;

    IF v_existing_item_count != v_item_count THEN
      RAISE EXCEPTION 'CONTRACT_CONFLICT: KOT ID % already exists with % items (incoming % items)', v_kot_id, v_existing_item_count, v_item_count;
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_kot_items) LOOP
      IF NOT EXISTS (
        SELECT 1 FROM public.kot_items
        WHERE id = (v_item->>'id')::UUID
          AND kot_id = v_kot_id
          AND product_id = (v_item->>'product_id')::UUID
          AND quantity = (v_item->>'quantity')::INTEGER
          AND (
            (order_item_id IS NULL AND (v_item->>'order_item_id') IS NULL) OR
            order_item_id = (v_item->>'order_item_id')::UUID
          )
      ) THEN
        RAISE EXCEPTION 'CONTRACT_CONFLICT: KOT ID % item % mismatched in existing aggregate', v_kot_id, v_item->>'id';
      END IF;
    END LOOP;

    RETURN true;
  END IF;

  -- E. Atomic First-Submission Insert
  INSERT INTO public.pos_kots (
    id, order_id, kot_number, device_id, status, printed_at
  ) VALUES (
    v_kot_id,
    v_order_id,
    (p_kot->>'kot_number')::INTEGER,
    v_device_id::TEXT,
    COALESCE(p_kot->>'status', 'printed'),
    COALESCE((p_kot->>'printed_at')::TIMESTAMPTZ, NOW())
  );

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_kot_items) LOOP
    IF (v_item->>'kot_id')::UUID != v_kot_id THEN
      RAISE EXCEPTION 'VALIDATION_ERROR: KOT item % kot_id does not match KOT ID %', v_item->>'id', v_kot_id;
    END IF;

    INSERT INTO public.kot_items (
      id, kot_id, order_item_id, product_id, variant_id, product_name, quantity, notes
    ) VALUES (
      (v_item->>'id')::UUID,
      v_kot_id,
      (v_item->>'order_item_id')::UUID,
      (v_item->>'product_id')::UUID,
      (v_item->>'variant_id')::UUID,
      v_item->>'product_name',
      (v_item->>'quantity')::INTEGER,
      v_item->>'notes'
    );
  END LOOP;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.secure_sync_pos_kot(JSONB, JSONB, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_sync_pos_kot(JSONB, JSONB, UUID, TEXT) TO authenticated;

-- ============================================================================
-- 5. REDEFINE secure_append_pos_order_items_and_kot (INCLUDES order_item_id)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.secure_append_pos_order_items_and_kot(
  p_order JSONB,
  p_order_items JSONB,
  p_kot JSONB,
  p_kot_items JSONB,
  p_device_id UUID DEFAULT NULL,
  p_device_token TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_caller_id UUID;
  v_has_pos BOOLEAN;
  v_has_admin BOOLEAN;
  v_device_id UUID;
  v_order_id UUID;
  v_kot_id UUID;
  v_existing_order RECORD;
  v_session_status TEXT;
  v_existing_kot_item_count INTEGER;
  v_expected_kot_number INTEGER;
  v_incoming_kot_number INTEGER;
  v_kitem JSONB;
  v_oitem JSONB;
BEGIN
  -- A. Staff Authorization
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Access Denied: Authentication required for additional KOT append';
  END IF;

  SELECT has_pos_access, has_admin_access
  INTO v_has_pos, v_has_admin
  FROM public.staff_profiles
  WHERE id = v_caller_id AND is_active = true;

  IF NOT FOUND OR NOT (v_has_pos = true OR v_has_admin = true) THEN
    RAISE EXCEPTION 'Access Denied: POS staff permission required for additional KOT append';
  END IF;

  -- B. Resolve & Enforce Device Possession Authorization
  v_device_id := COALESCE(p_device_id, (p_kot->>'device_id')::UUID, (p_order->>'device_id')::UUID);
  PERFORM public.assert_authorized_pos_device(v_device_id, p_device_token);

  -- C. Validate Basic Payloads
  IF p_order IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: p_order payload is required';
  END IF;

  IF p_kot IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: p_kot payload is required';
  END IF;

  v_order_id := (p_order->>'id')::UUID;
  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: order id is required';
  END IF;

  v_kot_id := (p_kot->>'id')::UUID;
  IF v_kot_id IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: kot id is required';
  END IF;

  IF (p_kot->>'order_id')::UUID != v_order_id THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: KOT order_id % does not match order ID %', p_kot->>'order_id', v_order_id;
  END IF;

  IF p_order_items IS NULL OR jsonb_array_length(p_order_items) = 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Additional order items list cannot be empty';
  END IF;

  IF p_kot_items IS NULL OR jsonb_array_length(p_kot_items) = 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: KOT items list cannot be empty';
  END IF;

  FOR v_oitem IN SELECT * FROM jsonb_array_elements(p_order_items) LOOP
    IF (v_oitem->>'order_id')::UUID != v_order_id THEN
      RAISE EXCEPTION 'VALIDATION_ERROR: Order item % order_id does not match order ID %', v_oitem->>'id', v_order_id;
    END IF;
  END LOOP;

  FOR v_kitem IN SELECT * FROM jsonb_array_elements(p_kot_items) LOOP
    IF (v_kitem->>'kot_id')::UUID != v_kot_id THEN
      RAISE EXCEPTION 'VALIDATION_ERROR: KOT item % kot_id does not match KOT ID %', v_kitem->>'id', v_kot_id;
    END IF;
  END LOOP;

  -- D. Lock Target Order FOR UPDATE
  SELECT id, table_session_id, status, subtotal, tax_total, discount_total,
         delivery_charge, grand_total, version, updated_at
  INTO v_existing_order
  FROM public.orders
  WHERE id = v_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND: Order % does not exist', v_order_id;
  END IF;

  -- E. Status Verification: strictly kot_sent
  IF v_existing_order.status != 'kot_sent' THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: Order % has status %, additional KOT allowed only for kot_sent orders',
      v_order_id, v_existing_order.status;
  END IF;

  -- F. Verify Active Table Session
  IF v_existing_order.table_session_id IS NOT NULL THEN
    SELECT session_status INTO v_session_status
    FROM public.table_sessions
    WHERE id = v_existing_order.table_session_id;

    IF NOT FOUND OR v_session_status != 'open' THEN
      RAISE EXCEPTION 'CONTRACT_CONFLICT: Table session % is not active (status: %)',
        v_existing_order.table_session_id, COALESCE(v_session_status, 'not_found');
    END IF;
  END IF;

  -- G. Operation-Level Idempotency Check (Canonical identity = kot.id)
  IF EXISTS (SELECT 1 FROM public.pos_kots WHERE id = v_kot_id) THEN
    -- Verify KOT header
    IF NOT EXISTS (
      SELECT 1 FROM public.pos_kots
      WHERE id = v_kot_id
        AND order_id = v_order_id
        AND kot_number = (p_kot->>'kot_number')::INTEGER
    ) THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: KOT % exists with different header payload', v_kot_id;
    END IF;

    -- Verify KOT items count
    SELECT COUNT(*) INTO v_existing_kot_item_count
    FROM public.kot_items
    WHERE kot_id = v_kot_id;

    IF v_existing_kot_item_count != jsonb_array_length(p_kot_items) THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: KOT % exists with % items (incoming %)',
        v_kot_id, v_existing_kot_item_count, jsonb_array_length(p_kot_items);
    END IF;

    -- Verify KOT items content (including order_item_id if present)
    FOR v_kitem IN SELECT * FROM jsonb_array_elements(p_kot_items) LOOP
      IF NOT EXISTS (
        SELECT 1 FROM public.kot_items
        WHERE id = (v_kitem->>'id')::UUID
          AND kot_id = v_kot_id
          AND product_id = (v_kitem->>'product_id')::UUID
          AND quantity = (v_kitem->>'quantity')::INTEGER
          AND (
            (order_item_id IS NULL AND (v_kitem->>'order_item_id') IS NULL) OR
            order_item_id = (v_kitem->>'order_item_id')::UUID
          )
      ) THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: KOT % item % mismatched on retry', v_kot_id, v_kitem->>'id';
      END IF;
    END LOOP;

    -- Verify appended order items existence and match
    FOR v_oitem IN SELECT * FROM jsonb_array_elements(p_order_items) LOOP
      IF NOT EXISTS (
        SELECT 1 FROM public.order_items
        WHERE id = (v_oitem->>'id')::UUID
          AND order_id = v_order_id
          AND product_id = (v_oitem->>'product_id')::UUID
          AND unit_price = (v_oitem->>'unit_price')::NUMERIC
          AND quantity = (v_oitem->>'quantity')::INTEGER
          AND line_total = (v_oitem->>'line_total')::NUMERIC
      ) THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: Appended order item % missing or mismatched on retry', v_oitem->>'id';
      END IF;
    END LOOP;

    -- Verify cumulative financial header
    IF v_existing_order.subtotal != (p_order->>'subtotal')::NUMERIC
       OR v_existing_order.tax_total != (p_order->>'tax_total')::NUMERIC
       OR v_existing_order.discount_total != (p_order->>'discount_total')::NUMERIC
       OR v_existing_order.delivery_charge != (p_order->>'delivery_charge')::NUMERIC
       OR v_existing_order.grand_total != (p_order->>'grand_total')::NUMERIC
    THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: Order % financial totals mismatch on retry', v_order_id;
    END IF;

    RETURN true; -- Idempotent retry success/no-op
  END IF;

  -- H. Next KOT Number Cloud Validation
  SELECT COALESCE(MAX(kot_number), 0) + 1 INTO v_expected_kot_number
  FROM public.pos_kots
  WHERE order_id = v_order_id;

  v_incoming_kot_number := (p_kot->>'kot_number')::INTEGER;
  IF v_incoming_kot_number != v_expected_kot_number THEN
    RAISE EXCEPTION 'NUMBERING_CONFLICT: Incoming KOT number % does not match expected next KOT number %',
      v_incoming_kot_number, v_expected_kot_number;
  END IF;

  -- I. Verify New Order Item IDs Do Not Conflict
  FOR v_oitem IN SELECT * FROM jsonb_array_elements(p_order_items) LOOP
    IF EXISTS (SELECT 1 FROM public.order_items WHERE id = (v_oitem->>'id')::UUID) THEN
      RAISE EXCEPTION 'CONTRACT_CONFLICT: Order item ID % already exists in database', v_oitem->>'id';
    END IF;
  END LOOP;

  -- J. Insert ONLY New Order Items
  FOR v_oitem IN SELECT * FROM jsonb_array_elements(p_order_items) LOOP
    INSERT INTO public.order_items (
      id, order_id, product_id, variant_id, product_name,
      unit_price, quantity, tax_rate, discount_amount, line_total, notes, created_at
    ) VALUES (
      (v_oitem->>'id')::UUID,
      v_order_id,
      (v_oitem->>'product_id')::UUID,
      (v_oitem->>'variant_id')::UUID,
      v_oitem->>'product_name',
      (v_oitem->>'unit_price')::NUMERIC,
      (v_oitem->>'quantity')::INTEGER,
      COALESCE((v_oitem->>'tax_rate')::NUMERIC, 5.00),
      COALESCE((v_oitem->>'discount_amount')::NUMERIC, 0.00),
      (v_oitem->>'line_total')::NUMERIC,
      v_oitem->>'notes',
      COALESCE((v_oitem->>'created_at')::TIMESTAMPTZ, NOW())
    );
  END LOOP;

  -- K. Update Cumulative Order Financial Header
  UPDATE public.orders
  SET subtotal = (p_order->>'subtotal')::NUMERIC,
      tax_total = (p_order->>'tax_total')::NUMERIC,
      discount_total = (p_order->>'discount_total')::NUMERIC,
      delivery_charge = (p_order->>'delivery_charge')::NUMERIC,
      grand_total = (p_order->>'grand_total')::NUMERIC,
      updated_at = NOW()
  WHERE id = v_order_id;

  -- L. Insert KOT
  INSERT INTO public.pos_kots (
    id, order_id, kot_number, device_id, status, printed_at
  ) VALUES (
    v_kot_id,
    v_order_id,
    v_incoming_kot_number,
    v_device_id::TEXT,
    COALESCE(p_kot->>'status', 'printed'),
    COALESCE((p_kot->>'printed_at')::TIMESTAMPTZ, NOW())
  );

  -- M. Insert KOT Items (Includes order_item_id)
  FOR v_kitem IN SELECT * FROM jsonb_array_elements(p_kot_items) LOOP
    INSERT INTO public.kot_items (
      id, kot_id, order_item_id, product_id, variant_id, product_name, quantity, notes
    ) VALUES (
      (v_kitem->>'id')::UUID,
      v_kot_id,
      (v_kitem->>'order_item_id')::UUID,
      (v_kitem->>'product_id')::UUID,
      (v_kitem->>'variant_id')::UUID,
      v_kitem->>'product_name',
      (v_kitem->>'quantity')::INTEGER,
      v_kitem->>'notes'
    );
  END LOOP;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.secure_append_pos_order_items_and_kot(JSONB, JSONB, JSONB, JSONB, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.secure_append_pos_order_items_and_kot(JSONB, JSONB, JSONB, JSONB, UUID, TEXT) TO authenticated;

-- ============================================================================
-- 6. DEDICATED ATOMIC KOT CORRECTION MODEL-B CLOUD RPC
-- ============================================================================
CREATE OR REPLACE FUNCTION public.secure_save_kot_correction(
  p_correction JSONB,
  p_updated_order_item JSONB,
  p_updated_order JSONB,
  p_device_id UUID DEFAULT NULL,
  p_device_token TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_caller_id UUID;
  v_has_pos BOOLEAN;
  v_has_admin BOOLEAN;
  v_device_id UUID;
  v_correction_id UUID;
  v_order_id UUID;
  v_kot_id UUID;
  v_kot_item_id UUID;
  v_order_item_id UUID;
  v_cancelled_qty INTEGER;
  v_reason TEXT;
  v_authorized_by UUID;
  v_existing_order RECORD;
  v_existing_item RECORD;
  v_existing_kitem RECORD;
  v_kot_order_id UUID;
  v_expected_new_qty INTEGER;
BEGIN
  -- A. Staff Authorization
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Access Denied: Authentication required for KOT correction';
  END IF;

  SELECT has_pos_access, has_admin_access
  INTO v_has_pos, v_has_admin
  FROM public.staff_profiles
  WHERE id = v_caller_id AND is_active = true;

  IF NOT FOUND OR NOT (v_has_pos = true OR v_has_admin = true) THEN
    RAISE EXCEPTION 'Access Denied: POS staff permission required for KOT correction';
  END IF;

  -- B. Resolve & Enforce Device Possession Authorization
  v_device_id := COALESCE(p_device_id, (p_correction->>'device_id')::UUID);
  PERFORM public.assert_authorized_pos_device(v_device_id, p_device_token);

  -- C. Validate Required Payloads
  IF p_correction IS NULL OR p_updated_order_item IS NULL OR p_updated_order IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: All correction aggregate payloads are required';
  END IF;

  v_correction_id := (p_correction->>'id')::UUID;
  v_order_id := (p_correction->>'order_id')::UUID;
  v_kot_id := (p_correction->>'kot_id')::UUID;
  v_kot_item_id := (p_correction->>'kot_item_id')::UUID;
  v_order_item_id := (p_correction->>'order_item_id')::UUID;
  v_cancelled_qty := (p_correction->>'cancelled_qty')::INTEGER;
  v_reason := TRIM(COALESCE(p_correction->>'reason', ''));
  v_authorized_by := (p_correction->>'authorized_by_staff_id')::UUID;

  IF v_correction_id IS NULL OR v_order_id IS NULL OR v_kot_id IS NULL OR
     v_kot_item_id IS NULL OR v_order_item_id IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Missing required UUID identifiers in correction payload';
  END IF;

  IF v_cancelled_qty IS NULL OR v_cancelled_qty <= 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Cancelled quantity must be greater than 0';
  END IF;

  IF LENGTH(v_reason) = 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Correction reason cannot be empty';
  END IF;

  IF v_authorized_by IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Staff ID is required to authorize KOT correction';
  END IF;

  -- D. Operation-Level Idempotency Check (Canonical identity = correction.id)
  IF EXISTS (SELECT 1 FROM public.kot_corrections WHERE id = v_correction_id) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.kot_corrections
      WHERE id = v_correction_id
        AND order_id = v_order_id
        AND kot_id = v_kot_id
        AND kot_item_id = v_kot_item_id
        AND order_item_id = v_order_item_id
        AND cancelled_qty = v_cancelled_qty
        AND reason = v_reason
        AND authorized_by_staff_id = v_authorized_by
    ) THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: KOT correction % exists with different payload', v_correction_id;
    END IF;

    -- Verify current order and item already reflect this correction's target state
    SELECT quantity, line_total INTO v_existing_item
    FROM public.order_items WHERE id = v_order_item_id;

    IF v_existing_item.quantity != (p_updated_order_item->>'quantity')::INTEGER
       OR v_existing_item.line_total != (p_updated_order_item->>'line_total')::NUMERIC
    THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: Order item % state mismatch on correction retry', v_order_item_id;
    END IF;

    SELECT subtotal, tax_total, discount_total, grand_total INTO v_existing_order
    FROM public.orders WHERE id = v_order_id;

    IF v_existing_order.grand_total != (p_updated_order->>'grand_total')::NUMERIC THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: Order % totals mismatch on correction retry', v_order_id;
    END IF;

    RETURN true; -- Idempotent retry success/no-op
  END IF;

  -- E. Lock Target Order FOR UPDATE
  SELECT id, status INTO v_existing_order
  FROM public.orders
  WHERE id = v_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND: Order % does not exist', v_order_id;
  END IF;

  IF v_existing_order.status != 'kot_sent' THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: Order % has status %, corrections allowed only for kot_sent orders',
      v_order_id, v_existing_order.status;
  END IF;

  -- F. Lock Target Commercial Order Item FOR UPDATE
  SELECT id, order_id, product_id, variant_id, product_name, unit_price, quantity, tax_rate, discount_amount, line_total
  INTO v_existing_item
  FROM public.order_items
  WHERE id = v_order_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND: Order item % does not exist', v_order_item_id;
  END IF;

  IF v_existing_item.order_id != v_order_id THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: Order item % does not belong to order %', v_order_item_id, v_order_id;
  END IF;

  -- G. Validate KOT and KOT Item Lineage
  SELECT order_id INTO v_kot_order_id
  FROM public.pos_kots
  WHERE id = v_kot_id;

  IF NOT FOUND OR v_kot_order_id != v_order_id THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: KOT % does not belong to order %', v_kot_id, v_order_id;
  END IF;

  SELECT id, kot_id, order_item_id, quantity INTO v_existing_kitem
  FROM public.kot_items
  WHERE id = v_kot_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'KOT_ITEM_NOT_FOUND: KOT item % does not exist', v_kot_item_id;
  END IF;

  IF v_existing_kitem.kot_id != v_kot_id THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: KOT item % does not belong to KOT %', v_kot_item_id, v_kot_id;
  END IF;

  IF v_existing_kitem.order_item_id IS NULL THEN
    RAISE EXCEPTION 'CORRECTION_LINEAGE_UNAVAILABLE: Historical KOT item % does not carry order_item_id', v_kot_item_id;
  END IF;

  IF v_existing_kitem.order_item_id != v_order_item_id THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: KOT item % links to order item %, not requested %',
      v_kot_item_id, v_existing_kitem.order_item_id, v_order_item_id;
  END IF;

  -- H. Over-Correction Protection (Current Billable Authority = order_items.quantity)
  IF v_cancelled_qty > v_existing_item.quantity THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: Cannot cancel % units when current billable quantity is %',
      v_cancelled_qty, v_existing_item.quantity;
  END IF;

  v_expected_new_qty := v_existing_item.quantity - v_cancelled_qty;

  -- Verify incoming projection consistency
  IF (p_updated_order_item->>'quantity')::INTEGER != v_expected_new_qty THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Target order item quantity mismatch (expected %, got %)',
      v_expected_new_qty, (p_updated_order_item->>'quantity')::INTEGER;
  END IF;

  IF (p_updated_order_item->>'id')::UUID != v_order_item_id THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Target order item ID mismatch';
  END IF;

  IF (p_updated_order->>'id')::UUID != v_order_id THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Order ID mismatch';
  END IF;

  -- I. Insert Append-Only Correction Audit Record
  INSERT INTO public.kot_corrections (
    id, order_id, kot_id, kot_item_id, order_item_id,
    product_name, cancelled_qty, reason, authorized_by_staff_id, created_at
  ) VALUES (
    v_correction_id,
    v_order_id,
    v_kot_id,
    v_kot_item_id,
    v_order_item_id,
    v_existing_item.product_name,
    v_cancelled_qty,
    v_reason,
    v_authorized_by,
    COALESCE((p_correction->>'created_at')::TIMESTAMPTZ, NOW())
  );

  -- J. Mutate Target Commercial Order Item (Preserved even if quantity = 0)
  UPDATE public.order_items
  SET quantity = v_expected_new_qty,
      line_total = (p_updated_order_item->>'line_total')::NUMERIC
  WHERE id = v_order_item_id;

  -- K. Mutate Parent Order Cumulative Financial Totals
  UPDATE public.orders
  SET subtotal = (p_updated_order->>'subtotal')::NUMERIC,
      tax_total = (p_updated_order->>'tax_total')::NUMERIC,
      discount_total = COALESCE((p_updated_order->>'discount_total')::NUMERIC, discount_total, 0.00),
      delivery_charge = COALESCE((p_updated_order->>'delivery_charge')::NUMERIC, delivery_charge, 0.00),
      grand_total = (p_updated_order->>'grand_total')::NUMERIC,
      updated_at = NOW()
  WHERE id = v_order_id;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.secure_save_kot_correction(JSONB, JSONB, JSONB, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.secure_save_kot_correction(JSONB, JSONB, JSONB, UUID, TEXT) TO authenticated;
