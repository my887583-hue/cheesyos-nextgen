-- CHEESYOS NEXTGEN V1 MIGRATION: 014_atomic_additional_kot_contract.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: TASK_3G_2_08A
-- Security: Atomic Post-KOT Commercial Order Append & Additional Immutable KOT Contract

-- ============================================================================
-- 1. DEDICATED ATOMIC POST-KOT COMMERCIAL APPEND & KOT RPC
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

    -- Verify KOT items content
    FOR v_kitem IN SELECT * FROM jsonb_array_elements(p_kot_items) LOOP
      IF NOT EXISTS (
        SELECT 1 FROM public.kot_items
        WHERE id = (v_kitem->>'id')::UUID
          AND kot_id = v_kot_id
          AND product_id = (v_kitem->>'product_id')::UUID
          AND quantity = (v_kitem->>'quantity')::INTEGER
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

  -- K. Update Cumulative Order Financial Header (status remains kot_sent, version unchanged)
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

  -- M. Insert KOT Items
  FOR v_kitem IN SELECT * FROM jsonb_array_elements(p_kot_items) LOOP
    INSERT INTO public.kot_items (
      id, kot_id, product_id, variant_id, product_name, quantity, notes
    ) VALUES (
      (v_kitem->>'id')::UUID,
      v_kot_id,
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

-- Permissions
REVOKE EXECUTE ON FUNCTION public.secure_append_pos_order_items_and_kot(JSONB, JSONB, JSONB, JSONB, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.secure_append_pos_order_items_and_kot(JSONB, JSONB, JSONB, JSONB, UUID, TEXT) TO authenticated;
