-- CHEESYOS NEXTGEN V1 MIGRATION: 007_pos_sync_cloud_contracts.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: PREPARED_FOR_APPLY
-- Security & Integrity: Trusted POS Cloud Write Contracts for Orders, KOTs, KOT Corrections, Bills, and Payments.

-- ============================================================================
-- 1. ATOMIC & IDEMPOTENT ORDER SYNC RPC
-- ============================================================================
CREATE OR REPLACE FUNCTION public.secure_sync_pos_order(
  p_order JSONB,
  p_order_items JSONB
)
RETURNS BOOLEAN AS $$
DECLARE
  v_caller_id UUID;
  v_has_pos BOOLEAN;
  v_has_admin BOOLEAN;
  v_order_id UUID;
  v_item JSONB;
  v_existing_item_count INTEGER;
  v_item_count INTEGER;
BEGIN
  -- A. Get caller & internal authorization
  v_caller_id := auth.uid();

  IF v_caller_id IS NOT NULL THEN
    SELECT has_pos_access, has_admin_access
    INTO v_has_pos, v_has_admin
    FROM public.staff_profiles
    WHERE id = v_caller_id AND is_active = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Access Denied: Active staff profile required for POS Order sync';
    END IF;

    IF NOT (v_has_pos = true OR v_has_admin = true) THEN
      RAISE EXCEPTION 'Access Denied: POS staff permission required for Order sync';
    END IF;
  END IF;

  -- B. Channel restriction: POS Sync RPC accepts only POS channel orders
  IF COALESCE(p_order->>'channel', '') != 'POS' THEN
    RAISE EXCEPTION 'Invalid Channel: POS sync RPC accepts only POS channel orders (Received: %)', p_order->>'channel';
  END IF;

  -- C. Validate non-empty items payload
  v_item_count := jsonb_array_length(p_order_items);
  IF v_item_count IS NULL OR v_item_count = 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: POS Order aggregate must contain at least one order item';
  END IF;

  v_order_id := (p_order->>'id')::UUID;

  -- D. Idempotency Check & Payload Mismatch Protection
  IF EXISTS (SELECT 1 FROM public.orders WHERE id = v_order_id) THEN
    -- 1. Verify order header canonical payload match
    IF NOT EXISTS (
      SELECT 1 FROM public.orders
      WHERE id = v_order_id
        AND channel = p_order->>'channel'
        AND order_type = p_order->>'order_type'
        AND subtotal = (p_order->>'subtotal')::NUMERIC
        AND tax_total = (p_order->>'tax_total')::NUMERIC
        AND discount_total = (p_order->>'discount_total')::NUMERIC
        AND delivery_charge = (p_order->>'delivery_charge')::NUMERIC
        AND grand_total = (p_order->>'grand_total')::NUMERIC
    ) THEN
      RAISE EXCEPTION 'CONTRACT_CONFLICT: Order ID % already exists with mismatched header payload', v_order_id;
    END IF;

    -- 2. Verify order items set equality
    SELECT COUNT(*) INTO v_existing_item_count
    FROM public.order_items
    WHERE order_id = v_order_id;

    IF v_existing_item_count != v_item_count THEN
      RAISE EXCEPTION 'CONTRACT_CONFLICT: Order ID % already exists with % items (incoming % items)', v_order_id, v_existing_item_count, v_item_count;
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_order_items) LOOP
      IF NOT EXISTS (
        SELECT 1 FROM public.order_items
        WHERE id = (v_item->>'id')::UUID
          AND order_id = v_order_id
          AND product_id = (v_item->>'product_id')::UUID
          AND unit_price = (v_item->>'unit_price')::NUMERIC
          AND quantity = (v_item->>'quantity')::INTEGER
          AND line_total = (v_item->>'line_total')::NUMERIC
      ) THEN
        RAISE EXCEPTION 'CONTRACT_CONFLICT: Order ID % item % mismatched in existing aggregate', v_order_id, v_item->>'id';
      END IF;
    END LOOP;

    RETURN true; -- Idempotent retry success
  END IF;

  -- E. Atomic First-Submission Insert
  INSERT INTO public.orders (
    id, display_number, channel, order_type, customer_id, table_session_id,
    status, subtotal, tax_total, discount_total, delivery_charge, grand_total,
    device_id, created_at
  ) VALUES (
    v_order_id,
    p_order->>'display_number',
    p_order->>'channel',
    p_order->>'order_type',
    (p_order->>'customer_id')::UUID,
    (p_order->>'table_session_id')::UUID,
    COALESCE(p_order->>'status', 'pending'),
    (p_order->>'subtotal')::NUMERIC,
    (p_order->>'tax_total')::NUMERIC,
    (p_order->>'discount_total')::NUMERIC,
    (p_order->>'delivery_charge')::NUMERIC,
    (p_order->>'grand_total')::NUMERIC,
    p_order->>'device_id',
    COALESCE((p_order->>'created_at')::TIMESTAMPTZ, NOW())
  );

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_order_items) LOOP
    IF (v_item->>'order_id')::UUID != v_order_id THEN
      RAISE EXCEPTION 'VALIDATION_ERROR: Order item % order_id does not match order ID %', v_item->>'id', v_order_id;
    END IF;

    INSERT INTO public.order_items (
      id, order_id, product_id, variant_id, product_name,
      unit_price, quantity, tax_rate, discount_amount, line_total, notes, created_at
    ) VALUES (
      (v_item->>'id')::UUID,
      v_order_id,
      (v_item->>'product_id')::UUID,
      (v_item->>'variant_id')::UUID,
      v_item->>'product_name',
      (v_item->>'unit_price')::NUMERIC,
      (v_item->>'quantity')::INTEGER,
      COALESCE((v_item->>'tax_rate')::NUMERIC, 5.00),
      COALESCE((v_item->>'discount_amount')::NUMERIC, 0.00),
      (v_item->>'line_total')::NUMERIC,
      v_item->>'notes',
      COALESCE((v_item->>'created_at')::TIMESTAMPTZ, NOW())
    );
  END LOOP;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE EXECUTE ON FUNCTION public.secure_sync_pos_order(JSONB, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_sync_pos_order(JSONB, JSONB) TO authenticated;


-- ============================================================================
-- 2. ATOMIC & IDEMPOTENT KOT SYNC RPC
-- ============================================================================
CREATE OR REPLACE FUNCTION public.secure_sync_pos_kot(
  p_kot JSONB,
  p_kot_items JSONB
)
RETURNS BOOLEAN AS $$
DECLARE
  v_kot_id UUID;
  v_order_id UUID;
  v_item JSONB;
  v_existing_item_count INTEGER;
  v_item_count INTEGER;
BEGIN
  -- A. Authorization Check
  IF auth.uid() IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.staff_profiles 
      WHERE id = auth.uid() AND (has_pos_access = true OR has_admin_access = true) AND is_active = true
    ) THEN
      RAISE EXCEPTION 'Access Denied: Active staff profile required for KOT sync';
    END IF;
  END IF;

  v_kot_id := (p_kot->>'id')::UUID;
  v_order_id := (p_kot->>'order_id')::UUID;

  -- B. Referenced Order Existence Check
  IF NOT EXISTS (SELECT 1 FROM public.orders WHERE id = v_order_id) THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Referenced order ID % does not exist for KOT sync', v_order_id;
  END IF;

  v_item_count := jsonb_array_length(p_kot_items);
  IF v_item_count IS NULL OR v_item_count = 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: KOT aggregate must contain at least one item';
  END IF;

  -- C. Idempotency Check & Payload Mismatch Protection
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
      ) THEN
        RAISE EXCEPTION 'CONTRACT_CONFLICT: KOT ID % item % mismatched in existing aggregate', v_kot_id, v_item->>'id';
      END IF;
    END LOOP;

    RETURN true;
  END IF;

  -- D. Atomic First-Submission Insert
  INSERT INTO public.pos_kots (
    id, order_id, kot_number, device_id, status, printed_at
  ) VALUES (
    v_kot_id,
    v_order_id,
    (p_kot->>'kot_number')::INTEGER,
    p_kot->>'device_id',
    COALESCE(p_kot->>'status', 'printed'),
    COALESCE((p_kot->>'printed_at')::TIMESTAMPTZ, NOW())
  );

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_kot_items) LOOP
    IF (v_item->>'kot_id')::UUID != v_kot_id THEN
      RAISE EXCEPTION 'VALIDATION_ERROR: KOT item % kot_id does not match KOT ID %', v_item->>'id', v_kot_id;
    END IF;

    INSERT INTO public.kot_items (
      id, kot_id, product_id, variant_id, product_name, quantity, notes
    ) VALUES (
      (v_item->>'id')::UUID,
      v_kot_id,
      (v_item->>'product_id')::UUID,
      (v_item->>'variant_id')::UUID,
      v_item->>'product_name',
      (v_item->>'quantity')::INTEGER,
      v_item->>'notes'
    );
  END LOOP;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE EXECUTE ON FUNCTION public.secure_sync_pos_kot(JSONB, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_sync_pos_kot(JSONB, JSONB) TO authenticated;


-- ============================================================================
-- 3. ATOMIC & IDEMPOTENT KOT CORRECTION SYNC RPC
-- ============================================================================
CREATE OR REPLACE FUNCTION public.secure_sync_kot_correction(
  p_correction JSONB
)
RETURNS BOOLEAN AS $$
DECLARE
  v_correction_id UUID;
  v_order_id UUID;
BEGIN
  -- A. Authorization Check
  IF auth.uid() IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.staff_profiles 
      WHERE id = auth.uid() AND (has_pos_access = true OR has_admin_access = true) AND is_active = true
    ) THEN
      RAISE EXCEPTION 'Access Denied: Active staff profile required for KOT correction sync';
    END IF;
  END IF;

  v_correction_id := (p_correction->>'id')::UUID;
  v_order_id := (p_correction->>'order_id')::UUID;

  IF NOT EXISTS (SELECT 1 FROM public.orders WHERE id = v_order_id) THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Referenced order ID % does not exist for KOT correction', v_order_id;
  END IF;

  -- B. Idempotency Check & Payload Mismatch Protection
  IF EXISTS (SELECT 1 FROM public.kot_corrections WHERE id = v_correction_id) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.kot_corrections
      WHERE id = v_correction_id
        AND order_id = v_order_id
        AND product_name = p_correction->>'product_name'
        AND cancelled_qty = (p_correction->>'cancelled_qty')::INTEGER
        AND reason = p_correction->>'reason'
    ) THEN
      RAISE EXCEPTION 'CONTRACT_CONFLICT: KOT Correction ID % already exists with mismatched payload', v_correction_id;
    END IF;

    RETURN true;
  END IF;

  -- C. Insert Audit Entry
  INSERT INTO public.kot_corrections (
    id, order_id, kot_id, product_name, cancelled_qty, reason, authorized_by_staff_id, created_at
  ) VALUES (
    v_correction_id,
    v_order_id,
    (p_correction->>'kot_id')::UUID,
    p_correction->>'product_name',
    (p_correction->>'cancelled_qty')::INTEGER,
    p_correction->>'reason',
    (p_correction->>'authorized_by_staff_id')::UUID,
    COALESCE((p_correction->>'created_at')::TIMESTAMPTZ, NOW())
  );

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE EXECUTE ON FUNCTION public.secure_sync_kot_correction(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_sync_kot_correction(JSONB) TO authenticated;


-- ============================================================================
-- 4. ATOMIC & IDEMPOTENT BILL SYNC RPC
-- ============================================================================
CREATE OR REPLACE FUNCTION public.secure_sync_pos_bill(
  p_bill JSONB
)
RETURNS BOOLEAN AS $$
DECLARE
  v_bill_id UUID;
  v_order_id UUID;
BEGIN
  -- A. Authorization Check
  IF auth.uid() IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.staff_profiles 
      WHERE id = auth.uid() AND (has_pos_access = true OR has_admin_access = true) AND is_active = true
    ) THEN
      RAISE EXCEPTION 'Access Denied: Active staff profile required for Bill sync';
    END IF;
  END IF;

  v_bill_id := (p_bill->>'id')::UUID;
  v_order_id := (p_bill->>'order_id')::UUID;

  IF NOT EXISTS (SELECT 1 FROM public.orders WHERE id = v_order_id) THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Referenced order ID % does not exist for Bill sync', v_order_id;
  END IF;

  -- B. Idempotency Check & Payload Mismatch Protection
  IF EXISTS (SELECT 1 FROM public.bills WHERE id = v_bill_id) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.bills
      WHERE id = v_bill_id
        AND order_id = v_order_id
        AND bill_number = p_bill->>'bill_number'
        AND subtotal = (p_bill->>'subtotal')::NUMERIC
        AND cgst_total = (p_bill->>'cgst_total')::NUMERIC
        AND sgst_total = (p_bill->>'sgst_total')::NUMERIC
        AND discount_total = (p_bill->>'discount_total')::NUMERIC
        AND grand_total = (p_bill->>'grand_total')::NUMERIC
    ) THEN
      RAISE EXCEPTION 'CONTRACT_CONFLICT: Bill ID % already exists with mismatched financial payload', v_bill_id;
    END IF;

    RETURN true;
  END IF;

  -- C. Insert Finalized Bill Snapshot
  INSERT INTO public.bills (
    id, order_id, bill_number, subtotal, cgst_total, sgst_total,
    discount_total, grand_total, payment_status, finalized_at, device_id
  ) VALUES (
    v_bill_id,
    v_order_id,
    p_bill->>'bill_number',
    (p_bill->>'subtotal')::NUMERIC,
    (p_bill->>'cgst_total')::NUMERIC,
    (p_bill->>'sgst_total')::NUMERIC,
    COALESCE((p_bill->>'discount_total')::NUMERIC, 0.00),
    (p_bill->>'grand_total')::NUMERIC,
    COALESCE(p_bill->>'payment_status', 'unpaid'),
    COALESCE((p_bill->>'finalized_at')::TIMESTAMPTZ, NOW()),
    p_bill->>'device_id'
  );

  -- Update order status to billed if currently pending/kot_sent
  UPDATE public.orders
  SET status = 'billed', updated_at = NOW()
  WHERE id = v_order_id AND status IN ('pending', 'kot_sent');

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE EXECUTE ON FUNCTION public.secure_sync_pos_bill(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_sync_pos_bill(JSONB) TO authenticated;


-- ============================================================================
-- 5. ATOMIC, CONCURRENCY-SAFE PAYMENT SYNC RPC
-- ============================================================================
CREATE OR REPLACE FUNCTION public.secure_sync_pos_payment(
  p_payment JSONB
)
RETURNS BOOLEAN AS $$
DECLARE
  v_payment_id UUID;
  v_bill_id UUID;
  v_order_id UUID;
  v_amount_paid NUMERIC(10,2);
  v_bill_grand_total NUMERIC(10,2);
  v_existing_total_paid NUMERIC(10,2);
  v_new_total_paid NUMERIC(10,2);
  v_new_status TEXT;
BEGIN
  -- A. Authorization Check
  IF auth.uid() IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.staff_profiles 
      WHERE id = auth.uid() AND (has_pos_access = true OR has_admin_access = true) AND is_active = true
    ) THEN
      RAISE EXCEPTION 'Access Denied: Active staff profile required for Payment sync';
    END IF;
  END IF;

  v_payment_id := (p_payment->>'id')::UUID;
  v_bill_id := (p_payment->>'bill_id')::UUID;
  v_order_id := (p_payment->>'order_id')::UUID;
  v_amount_paid := (p_payment->>'amount_paid')::NUMERIC;

  -- B. Lock Bill Row FOR UPDATE to serialize concurrent payments against same bill
  SELECT grand_total INTO v_bill_grand_total
  FROM public.bills
  WHERE id = v_bill_id AND order_id = v_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Bill ID % for Order % does not exist for Payment sync', v_bill_id, v_order_id;
  END IF;

  -- C. Idempotency Check & Payload Mismatch Protection
  IF EXISTS (SELECT 1 FROM public.payments WHERE id = v_payment_id) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.payments
      WHERE id = v_payment_id
        AND bill_id = v_bill_id
        AND order_id = v_order_id
        AND payment_mode = p_payment->>'payment_mode'
        AND amount_paid = v_amount_paid
    ) THEN
      RAISE EXCEPTION 'CONTRACT_CONFLICT: Payment ID % already exists with mismatched payload', v_payment_id;
    END IF;

    RETURN true;
  END IF;

  -- D. Calculate existing payments & Overpayment Protection
  SELECT COALESCE(SUM(amount_paid), 0.00) INTO v_existing_total_paid
  FROM public.payments
  WHERE bill_id = v_bill_id;

  v_new_total_paid := v_existing_total_paid + v_amount_paid;

  IF v_new_total_paid > v_bill_grand_total + 0.01 THEN
    RAISE EXCEPTION 'Overpayment Denied: Total payment % exceeds bill grand total %', v_new_total_paid, v_bill_grand_total;
  END IF;

  -- E. Insert Confirmed Payment Entry
  INSERT INTO public.payments (
    id, bill_id, order_id, payment_mode, amount_paid,
    confirmed_by_staff_id, confirmed_at, notes
  ) VALUES (
    v_payment_id,
    v_bill_id,
    v_order_id,
    p_payment->>'payment_mode',
    v_amount_paid,
    (p_payment->>'confirmed_by_staff_id')::UUID,
    COALESCE((p_payment->>'confirmed_at')::TIMESTAMPTZ, NOW()),
    p_payment->>'notes'
  );

  -- F. Atomic Bill & Order Status Update
  IF v_new_total_paid >= v_bill_grand_total - 0.01 THEN
    v_new_status := 'paid';
  ELSE
    v_new_status := 'partially_paid';
  END IF;

  UPDATE public.bills
  SET payment_status = v_new_status
  WHERE id = v_bill_id;

  IF v_new_status = 'paid' THEN
    UPDATE public.orders
    SET status = 'settled', updated_at = NOW()
    WHERE id = v_order_id;
  END IF;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE EXECUTE ON FUNCTION public.secure_sync_pos_payment(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_sync_pos_payment(JSONB) TO authenticated;
