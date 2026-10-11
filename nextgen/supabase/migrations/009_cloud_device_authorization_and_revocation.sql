-- CHEESYOS NEXTGEN V1 MIGRATION: 009_cloud_device_authorization_and_revocation.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: PREPARED_FOR_PHASE_3G_1B
-- Security: Trusted Device Possession Verification, Revocation Hardening, and Provisioning Contract.

-- ============================================================================
-- 1. POS DEVICES REGISTRY SCHEMA HARDENING
-- ============================================================================

-- Add device_secret_hash column if not exists
ALTER TABLE public.pos_devices
  ADD COLUMN IF NOT EXISTS device_secret_hash TEXT NULL;

-- Enforce uppercase normalized terminal_code
ALTER TABLE public.pos_devices
  DROP CONSTRAINT IF EXISTS chk_pos_devices_terminal_code_format;

ALTER TABLE public.pos_devices
  ADD CONSTRAINT chk_pos_devices_terminal_code_format CHECK (
    length(trim(terminal_code)) >= 2 
    AND terminal_code ~ '^[A-Z0-9_-]+$'
    AND terminal_code = upper(terminal_code)
  );

-- ============================================================================
-- 2. SHARED SERVER-SIDE DEVICE AUTHORIZATION HELPER
-- ============================================================================

CREATE OR REPLACE FUNCTION public.assert_authorized_pos_device(
  p_device_id UUID,
  p_device_token TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
  v_stored_hash TEXT;
  v_is_active BOOLEAN;
  v_revoked_at TIMESTAMPTZ;
  v_computed_hash TEXT;
BEGIN
  IF p_device_id IS NULL THEN
    RAISE EXCEPTION 'DEVICE_AUTH_FAILED: device_id is required';
  END IF;

  IF p_device_token IS NULL OR trim(p_device_token) = '' THEN
    RAISE EXCEPTION 'DEVICE_AUTH_FAILED: device_token possession proof is required';
  END IF;

  SELECT is_active, revoked_at, device_secret_hash
  INTO v_is_active, v_revoked_at, v_stored_hash
  FROM public.pos_devices
  WHERE id = p_device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DEVICE_NOT_PROVISIONED: Device ID % does not exist', p_device_id;
  END IF;

  IF v_is_active = false OR v_revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'DEVICE_REVOKED: Device ID % has been revoked', p_device_id;
  END IF;

  -- 256-bit token SHA-256 computation
  v_computed_hash := encode(public.digest(p_device_token, 'sha256'), 'hex');

  IF v_stored_hash IS NULL OR v_stored_hash != v_computed_hash THEN
    RAISE EXCEPTION 'DEVICE_AUTH_FAILED: Invalid device possession token';
  END IF;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.assert_authorized_pos_device(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_authorized_pos_device(UUID, TEXT) TO authenticated;


-- ============================================================================
-- 3. TRUSTED DEVICE PROVISIONING RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION public.secure_provision_pos_device(
  p_terminal_code TEXT,
  p_device_name TEXT
)
RETURNS JSONB AS $$
DECLARE
  v_caller_id UUID;
  v_has_admin BOOLEAN;
  v_norm_code TEXT;
  v_device_id UUID;
  v_raw_token TEXT;
  v_secret_hash TEXT;
BEGIN
  -- A. Verify Authenticated Admin Identity
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Access Denied: Authentication required for device provisioning';
  END IF;

  SELECT has_admin_access INTO v_has_admin
  FROM public.staff_profiles
  WHERE id = v_caller_id AND is_active = true;

  IF NOT FOUND OR v_has_admin IS NOT TRUE THEN
    RAISE EXCEPTION 'Access Denied: Admin authorization required for device provisioning';
  END IF;

  -- B. Normalize & Validate Terminal Code
  v_norm_code := upper(trim(p_terminal_code));
  IF length(v_norm_code) < 2 OR v_norm_code !~ '^[A-Z0-9_-]+$' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Terminal code must be at least 2 alphanumeric characters';
  END IF;

  IF trim(p_device_name) = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Device name cannot be empty';
  END IF;

  IF EXISTS (SELECT 1 FROM public.pos_devices WHERE terminal_code = v_norm_code) THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Terminal code % is already registered', v_norm_code;
  END IF;

  -- C. Generate 256-bit CSPRNG token (32 random bytes)
  v_raw_token := 'cb_dev_sec_' || encode(public.gen_random_bytes(32), 'hex');
  v_secret_hash := encode(public.digest(v_raw_token, 'sha256'), 'hex');
  v_device_id := pg_catalog.gen_random_uuid();

  -- D. Insert Registry Record with Verifier Hash
  INSERT INTO public.pos_devices (
    id, terminal_code, device_name, is_active, device_secret_hash, created_at
  ) VALUES (
    v_device_id, v_norm_code, trim(p_device_name), true, v_secret_hash, now()
  );

  -- E. Return One-Time Credentials Payload
  RETURN jsonb_build_object(
    'device_id', v_device_id,
    'terminal_code', v_norm_code,
    'device_name', trim(p_device_name),
    'device_token', v_raw_token,
    'created_at', now()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.secure_provision_pos_device(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_provision_pos_device(TEXT, TEXT) TO authenticated;


-- ============================================================================
-- 4. HARDENED ORDER SYNC RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION public.secure_sync_pos_order(
  p_order JSONB,
  p_order_items JSONB,
  p_device_id UUID DEFAULT NULL,
  p_device_token TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_caller_id UUID;
  v_has_pos BOOLEAN;
  v_has_admin BOOLEAN;
  v_order_id UUID;
  v_device_id UUID;
  v_item JSONB;
  v_existing_item_count INTEGER;
  v_item_count INTEGER;
BEGIN
  -- A. Staff Authorization
  v_caller_id := auth.uid();
  IF v_caller_id IS NOT NULL THEN
    SELECT has_pos_access, has_admin_access
    INTO v_has_pos, v_has_admin
    FROM public.staff_profiles
    WHERE id = v_caller_id AND is_active = true;

    IF NOT FOUND OR NOT (v_has_pos = true OR v_has_admin = true) THEN
      RAISE EXCEPTION 'Access Denied: POS staff permission required for Order sync';
    END IF;
  END IF;

  -- B. Resolve & Enforce Device Possession Authorization
  v_device_id := COALESCE(p_device_id, (p_order->>'device_id')::UUID);
  PERFORM public.assert_authorized_pos_device(v_device_id, p_device_token);

  -- C. Channel restriction
  IF COALESCE(p_order->>'channel', '') != 'POS' THEN
    RAISE EXCEPTION 'Invalid Channel: POS sync RPC accepts only POS channel orders (Received: %)', p_order->>'channel';
  END IF;

  -- D. Validate non-empty items payload
  v_item_count := jsonb_array_length(p_order_items);
  IF v_item_count IS NULL OR v_item_count = 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: POS Order aggregate must contain at least one order item';
  END IF;

  v_order_id := (p_order->>'id')::UUID;

  -- E. Idempotency Check & Payload Mismatch Protection
  IF EXISTS (SELECT 1 FROM public.orders WHERE id = v_order_id) THEN
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

    RETURN true;
  END IF;

  -- F. Atomic First-Submission Insert
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
    v_device_id::TEXT,
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.secure_sync_pos_order(JSONB, JSONB, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_sync_pos_order(JSONB, JSONB, UUID, TEXT) TO authenticated;


-- ============================================================================
-- 5. HARDENED KOT SYNC RPC
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
  v_item JSONB;
  v_existing_item_count INTEGER;
  v_item_count INTEGER;
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
    v_device_id::TEXT,
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.secure_sync_pos_kot(JSONB, JSONB, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_sync_pos_kot(JSONB, JSONB, UUID, TEXT) TO authenticated;


-- ============================================================================
-- 6. HARDENED KOT CORRECTION SYNC RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION public.secure_sync_kot_correction(
  p_correction JSONB,
  p_device_id UUID DEFAULT NULL,
  p_device_token TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_correction_id UUID;
  v_order_id UUID;
  v_device_id UUID;
BEGIN
  -- A. Staff Authorization
  IF auth.uid() IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.staff_profiles 
      WHERE id = auth.uid() AND (has_pos_access = true OR has_admin_access = true) AND is_active = true
    ) THEN
      RAISE EXCEPTION 'Access Denied: Active staff profile required for KOT correction sync';
    END IF;
  END IF;

  -- B. Resolve & Enforce Device Possession Authorization
  v_device_id := COALESCE(p_device_id, (p_correction->>'device_id')::UUID);
  PERFORM public.assert_authorized_pos_device(v_device_id, p_device_token);

  v_correction_id := (p_correction->>'id')::UUID;
  v_order_id := (p_correction->>'order_id')::UUID;

  IF NOT EXISTS (SELECT 1 FROM public.orders WHERE id = v_order_id) THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Referenced order ID % does not exist for KOT correction', v_order_id;
  END IF;

  -- C. Idempotency Check & Payload Mismatch Protection
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

  -- D. Insert Audit Entry
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.secure_sync_kot_correction(JSONB, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_sync_kot_correction(JSONB, UUID, TEXT) TO authenticated;


-- ============================================================================
-- 7. HARDENED BILL SYNC RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION public.secure_sync_pos_bill(
  p_bill JSONB,
  p_device_id UUID DEFAULT NULL,
  p_device_token TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_bill_id UUID;
  v_order_id UUID;
  v_device_id UUID;
BEGIN
  -- A. Staff Authorization
  IF auth.uid() IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.staff_profiles 
      WHERE id = auth.uid() AND (has_pos_access = true OR has_admin_access = true) AND is_active = true
    ) THEN
      RAISE EXCEPTION 'Access Denied: Active staff profile required for Bill sync';
    END IF;
  END IF;

  -- B. Resolve & Enforce Device Possession Authorization
  v_device_id := COALESCE(p_device_id, (p_bill->>'device_id')::UUID);
  PERFORM public.assert_authorized_pos_device(v_device_id, p_device_token);

  v_bill_id := (p_bill->>'id')::UUID;
  v_order_id := (p_bill->>'order_id')::UUID;

  IF NOT EXISTS (SELECT 1 FROM public.orders WHERE id = v_order_id) THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Referenced order ID % does not exist for Bill sync', v_order_id;
  END IF;

  -- C. Idempotency Check & Payload Mismatch Protection
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

  -- D. Insert Finalized Bill Snapshot
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
    v_device_id::TEXT
  );

  UPDATE public.orders
  SET status = 'billed', updated_at = NOW()
  WHERE id = v_order_id AND status IN ('pending', 'kot_sent');

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.secure_sync_pos_bill(JSONB, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_sync_pos_bill(JSONB, UUID, TEXT) TO authenticated;


-- ============================================================================
-- 8. HARDENED PAYMENT SYNC RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION public.secure_sync_pos_payment(
  p_payment JSONB,
  p_device_id UUID DEFAULT NULL,
  p_device_token TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_payment_id UUID;
  v_bill_id UUID;
  v_order_id UUID;
  v_device_id UUID;
  v_amount_paid NUMERIC(10,2);
  v_bill_grand_total NUMERIC(10,2);
  v_existing_total_paid NUMERIC(10,2);
  v_new_total_paid NUMERIC(10,2);
  v_new_status TEXT;
BEGIN
  -- A. Staff Authorization
  IF auth.uid() IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.staff_profiles 
      WHERE id = auth.uid() AND (has_pos_access = true OR has_admin_access = true) AND is_active = true
    ) THEN
      RAISE EXCEPTION 'Access Denied: Active staff profile required for Payment sync';
    END IF;
  END IF;

  -- B. Resolve & Enforce Device Possession Authorization
  v_device_id := COALESCE(p_device_id, (p_payment->>'device_id')::UUID);
  PERFORM public.assert_authorized_pos_device(v_device_id, p_device_token);

  v_payment_id := (p_payment->>'id')::UUID;
  v_bill_id := (p_payment->>'bill_id')::UUID;
  v_order_id := (p_payment->>'order_id')::UUID;
  v_amount_paid := (p_payment->>'amount_paid')::NUMERIC;

  -- C. Lock Bill Row FOR UPDATE to serialize concurrent payments against same bill
  SELECT grand_total INTO v_bill_grand_total
  FROM public.bills
  WHERE id = v_bill_id AND order_id = v_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Bill ID % for Order % does not exist for Payment sync', v_bill_id, v_order_id;
  END IF;

  -- D. Idempotency Check & Payload Mismatch Protection
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

  -- E. Calculate existing payments & Overpayment Protection
  SELECT COALESCE(SUM(amount_paid), 0.00) INTO v_existing_total_paid
  FROM public.payments
  WHERE bill_id = v_bill_id;

  v_new_total_paid := v_existing_total_paid + v_amount_paid;

  IF v_new_total_paid > v_bill_grand_total + 0.01 THEN
    RAISE EXCEPTION 'Overpayment Denied: Total payment % exceeds bill grand total %', v_new_total_paid, v_bill_grand_total;
  END IF;

  -- F. Insert Confirmed Payment Entry
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

  -- G. Atomic Bill & Order Status Update
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.secure_sync_pos_payment(JSONB, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_sync_pos_payment(JSONB, UUID, TEXT) TO authenticated;


-- ============================================================================
-- 9. HARDENED INVENTORY MOVEMENT RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION public.secure_apply_inventory_movement(
  p_product_id UUID,
  p_movement_type TEXT,
  p_quantity_change INTEGER,
  p_created_by UUID DEFAULT NULL,
  p_movement_id UUID DEFAULT gen_random_uuid(),
  p_reference_movement_id UUID DEFAULT NULL,
  p_device_id UUID DEFAULT NULL,
  p_device_token TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_current_stock INTEGER;
  v_is_tracked BOOLEAN;
  v_caller_id UUID;
  v_has_pos BOOLEAN;
  v_has_admin BOOLEAN;
  v_orig_sale_qty INTEGER;
  v_already_restored INTEGER;
BEGIN
  -- A. Get authenticated caller identity
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    v_caller_id := p_created_by;
  END IF;
  
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Access Denied: Authentication required for inventory movement';
  END IF;

  -- B. Authorization & Role Check
  SELECT has_pos_access, has_admin_access
  INTO v_has_pos, v_has_admin
  FROM public.staff_profiles
  WHERE id = v_caller_id AND is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Access Denied: Active staff profile required';
  END IF;

  -- C. Validate movement type authorization boundaries
  IF p_movement_type IN ('SALE', 'CANCEL_RESTORE') THEN
    IF NOT (v_has_pos = true OR v_has_admin = true) THEN
      RAISE EXCEPTION 'Access Denied: POS or Admin authorization required for movement type %', p_movement_type;
    END IF;

    -- POS inventory mutations require authorized device possession
    PERFORM public.assert_authorized_pos_device(p_device_id, p_device_token);

  ELSIF p_movement_type IN ('MANUAL_ADD', 'MANUAL_REMOVE', 'ADJUSTMENT') THEN
    IF NOT (v_has_admin = true) THEN
      RAISE EXCEPTION 'Access Denied: Admin authorization required for management movement type %', p_movement_type;
    END IF;
  ELSE
    RAISE EXCEPTION 'Invalid movement type: %', p_movement_type;
  END IF;

  -- D. Idempotency Check & Payload Mismatch Protection
  IF EXISTS (SELECT 1 FROM public.inventory_movements WHERE id = p_movement_id) THEN
    IF EXISTS (
      SELECT 1 FROM public.inventory_movements
      WHERE id = p_movement_id
        AND product_id = p_product_id
        AND movement_type = p_movement_type
        AND quantity_change = p_quantity_change
        AND (reference_movement_id IS NOT DISTINCT FROM p_reference_movement_id)
    ) THEN
      RETURN true;
    ELSE
      RAISE EXCEPTION 'Idempotency Payload Mismatch: Movement ID % already exists with different payload parameters', p_movement_id;
    END IF;
  END IF;

  -- E. Validate quantity_change direction matches movement_type
  IF p_movement_type = 'SALE' AND p_quantity_change >= 0 THEN
    RAISE EXCEPTION 'Invalid SALE movement: quantity_change must be negative (Deduction)';
  ELSIF p_movement_type = 'CANCEL_RESTORE' AND p_quantity_change <= 0 THEN
    RAISE EXCEPTION 'Invalid CANCEL_RESTORE movement: quantity_change must be positive (Restoration)';
  ELSIF p_movement_type = 'MANUAL_ADD' AND p_quantity_change <= 0 THEN
    RAISE EXCEPTION 'Invalid MANUAL_ADD movement: quantity_change must be positive';
  ELSIF p_movement_type = 'MANUAL_REMOVE' AND p_quantity_change >= 0 THEN
    RAISE EXCEPTION 'Invalid MANUAL_REMOVE movement: quantity_change must be negative';
  END IF;

  -- F. Check inventory tracking status with FOR UPDATE lock
  SELECT is_tracked, current_stock INTO v_is_tracked, v_current_stock
  FROM public.inventory_lite
  WHERE product_id = p_product_id
  FOR UPDATE;

  IF NOT FOUND OR v_is_tracked = false THEN
    RETURN true;
  END IF;

  -- G. Negative Stock Protection on Deduction
  IF p_movement_type IN ('SALE', 'MANUAL_REMOVE') THEN
    IF (v_current_stock + p_quantity_change) < 0 THEN
      RAISE EXCEPTION 'Insufficient stock: Current stock (%) is insufficient for deduction (%)', v_current_stock, p_quantity_change;
    END IF;
  END IF;

  -- H. Restoration Over-Credit Protection on CANCEL_RESTORE
  IF p_movement_type = 'CANCEL_RESTORE' THEN
    IF p_reference_movement_id IS NULL THEN
      RAISE EXCEPTION 'Missing reference movement: CANCEL_RESTORE requires reference_movement_id pointing to original SALE';
    END IF;

    SELECT quantity_change INTO v_orig_sale_qty
    FROM public.inventory_movements
    WHERE id = p_reference_movement_id
      AND product_id = p_product_id
      AND movement_type = 'SALE';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Invalid reference movement: Original SALE movement % not found for product %', p_reference_movement_id, p_product_id;
    END IF;

    SELECT COALESCE(SUM(quantity_change), 0) INTO v_already_restored
    FROM public.inventory_movements
    WHERE reference_movement_id = p_reference_movement_id
      AND movement_type = 'CANCEL_RESTORE';

    IF (v_already_restored + p_quantity_change) > abs(v_orig_sale_qty) THEN
      RAISE EXCEPTION 'Restoration Over-Credit Denied: Total restored (%) exceeds original sale quantity (%)', (v_already_restored + p_quantity_change), abs(v_orig_sale_qty);
    END IF;
  END IF;

  -- I. Atomic Stock Mutation & Audit Insert
  UPDATE public.inventory_lite
  SET current_stock = current_stock + p_quantity_change,
      updated_at = NOW()
  WHERE product_id = p_product_id;

  INSERT INTO public.inventory_movements (
    id, product_id, movement_type, quantity_change,
    created_by, reference_movement_id, created_at
  ) VALUES (
    p_movement_id,
    p_product_id,
    p_movement_type,
    p_quantity_change,
    v_caller_id,
    p_reference_movement_id,
    NOW()
  );

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.secure_apply_inventory_movement(UUID, TEXT, INTEGER, UUID, UUID, UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_apply_inventory_movement(UUID, TEXT, INTEGER, UUID, UUID, UUID, UUID, TEXT) TO authenticated;
