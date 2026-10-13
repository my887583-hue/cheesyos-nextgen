-- CHEESYOS NEXTGEN V1 MIGRATION: 013_versioned_draft_order_replacement.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: TASK_3G_2_06B
-- Security: Versioned Pre-KOT Draft Replacement RPC + Initial Order Session Linkage

-- ============================================================================
-- 1. ADD ORDERS.VERSION COLUMN
-- ============================================================================
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

-- ============================================================================
-- 2. UPDATE INITIAL ORDER CREATION TO ATOMICALLY LINK TABLE SESSION & GUARD DUPLICATE
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
  v_session_id UUID;
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
  v_session_id := (p_order->>'table_session_id')::UUID;

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

    -- Ensure table session current_order_id link is maintained idempotently
    IF v_session_id IS NOT NULL THEN
      UPDATE public.table_sessions
      SET current_order_id = v_order_id
      WHERE id = v_session_id AND (current_order_id IS NULL OR current_order_id = v_order_id);
    END IF;

    RETURN true; -- Idempotent retry success
  END IF;

  -- E. One Active Order per Session Guard
  IF v_session_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM public.orders
      WHERE table_session_id = v_session_id
        AND id != v_order_id
        AND status NOT IN ('cancelled', 'closed')
    ) THEN
      RAISE EXCEPTION 'CONTRACT_CONFLICT: Table session % already has an active order', v_session_id;
    END IF;
  END IF;

  -- F. Atomic First-Submission Insert
  INSERT INTO public.orders (
    id, display_number, channel, order_type, customer_id, table_session_id,
    status, subtotal, tax_total, discount_total, delivery_charge, grand_total,
    device_id, version, created_at, updated_at
  ) VALUES (
    v_order_id,
    p_order->>'display_number',
    p_order->>'channel',
    p_order->>'order_type',
    (p_order->>'customer_id')::UUID,
    v_session_id,
    COALESCE(p_order->>'status', 'pending'),
    (p_order->>'subtotal')::NUMERIC,
    (p_order->>'tax_total')::NUMERIC,
    (p_order->>'discount_total')::NUMERIC,
    (p_order->>'delivery_charge')::NUMERIC,
    (p_order->>'grand_total')::NUMERIC,
    p_order->>'device_id',
    COALESCE((p_order->>'version')::INTEGER, 1),
    COALESCE((p_order->>'created_at')::TIMESTAMPTZ, NOW()),
    COALESCE((p_order->>'updated_at')::TIMESTAMPTZ, NOW())
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

  -- G. Atomically Link Table Session to Current Order
  IF v_session_id IS NOT NULL THEN
    UPDATE public.table_sessions
    SET current_order_id = v_order_id
    WHERE id = v_session_id;
  END IF;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

-- ============================================================================
-- 3. DEDICATED PRE-KOT DRAFT ORDER REPLACEMENT RPC
-- ============================================================================
CREATE OR REPLACE FUNCTION public.secure_replace_pos_draft_order(
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
  v_device_id UUID;
  v_order_id UUID;
  v_existing RECORD;
  v_incoming_version INTEGER;
  v_incoming_session_id UUID;
  v_item_count INTEGER;
  v_existing_item_count INTEGER;
  v_item JSONB;
BEGIN
  -- A. Staff Authorization
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Access Denied: Authentication required for draft order replacement';
  END IF;

  SELECT has_pos_access, has_admin_access
  INTO v_has_pos, v_has_admin
  FROM public.staff_profiles
  WHERE id = v_caller_id AND is_active = true;

  IF NOT FOUND OR NOT (v_has_pos = true OR v_has_admin = true) THEN
    RAISE EXCEPTION 'Access Denied: POS staff permission required for draft order replacement';
  END IF;

  -- B. Resolve & Enforce Device Possession Authorization
  v_device_id := COALESCE(p_device_id, (p_order->>'device_id')::UUID);
  PERFORM public.assert_authorized_pos_device(v_device_id, p_device_token);

  -- C. Validate Payload Basics
  IF p_order IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: p_order payload is required';
  END IF;

  v_order_id := (p_order->>'id')::UUID;
  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: order id is required';
  END IF;

  v_item_count := jsonb_array_length(p_order_items);
  IF v_item_count IS NULL OR v_item_count = 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Draft replacement aggregate must contain at least one order item';
  END IF;

  v_incoming_version := COALESCE((p_order->>'version')::INTEGER, 1);
  v_incoming_session_id := (p_order->>'table_session_id')::UUID;

  -- D. Lock Target Order FOR UPDATE
  SELECT id, table_session_id, status, subtotal, tax_total, discount_total,
         delivery_charge, grand_total, version, updated_at
  INTO v_existing
  FROM public.orders
  WHERE id = v_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND: Order % does not exist', v_order_id;
  END IF;

  -- E. Status Guard: ONLY draft status is editable
  IF v_existing.status != 'draft' THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: Order % has status %, only draft orders can be replaced',
      v_order_id, v_existing.status;
  END IF;

  -- F. KOT Snapshot Guard: Orders with dispatched KOTs cannot use draft replacement
  IF EXISTS (SELECT 1 FROM public.pos_kots WHERE order_id = v_order_id) THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: Order % already has dispatched KOTs, draft replacement prohibited',
      v_order_id;
  END IF;

  -- G. Invariant Guard: Table session linkage cannot be altered
  IF v_existing.table_session_id IS DISTINCT FROM v_incoming_session_id THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: Order % table_session_id cannot be changed during draft replacement',
      v_order_id;
  END IF;

  -- H. Version Concurrency & Idempotency Rules
  -- Case B: Same-Version Retry
  IF v_incoming_version = v_existing.version THEN
    -- Check if identical financial header
    IF v_existing.subtotal = (p_order->>'subtotal')::NUMERIC
      AND v_existing.tax_total = (p_order->>'tax_total')::NUMERIC
      AND v_existing.discount_total = (p_order->>'discount_total')::NUMERIC
      AND v_existing.delivery_charge = (p_order->>'delivery_charge')::NUMERIC
      AND v_existing.grand_total = (p_order->>'grand_total')::NUMERIC
    THEN
      -- Check item count
      SELECT COUNT(*) INTO v_existing_item_count
      FROM public.order_items
      WHERE order_id = v_order_id;

      IF v_existing_item_count = v_item_count THEN
        -- Verify identical items
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
            RAISE EXCEPTION 'VERSION_CONFLICT: Order % version % item mismatch on retry',
              v_order_id, v_incoming_version;
          END IF;
        END LOOP;

        RETURN true; -- Idempotent retry success
      END IF;
    END IF;

    RAISE EXCEPTION 'VERSION_CONFLICT: Order % version % already committed with different payload',
      v_order_id, v_incoming_version;

  -- Case C: Stale Version
  ELSIF v_incoming_version < v_existing.version THEN
    RAISE EXCEPTION 'STALE_VERSION: Incoming version % is older than current cloud version %',
      v_incoming_version, v_existing.version;

  -- Case D: Version Gap (> N + 1)
  ELSIF v_incoming_version > v_existing.version + 1 THEN
    RAISE EXCEPTION 'VERSION_GAP: Incoming version % skips expected version %',
      v_incoming_version, v_existing.version + 1;

  -- Case A: Valid Monotonic Revision (N -> N + 1)
  ELSIF v_incoming_version = v_existing.version + 1 THEN
    -- 1. Remove stale PRE-KOT draft order items
    DELETE FROM public.order_items WHERE order_id = v_order_id;

    -- 2. Insert complete replacement draft order items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_order_items) LOOP
      IF (v_item->>'order_id')::UUID != v_order_id THEN
        RAISE EXCEPTION 'VALIDATION_ERROR: Order item % order_id does not match order ID %',
          v_item->>'id', v_order_id;
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

    -- 3. Update Order Financial Header and Advance Version
    UPDATE public.orders
    SET subtotal = (p_order->>'subtotal')::NUMERIC,
        tax_total = (p_order->>'tax_total')::NUMERIC,
        discount_total = (p_order->>'discount_total')::NUMERIC,
        delivery_charge = (p_order->>'delivery_charge')::NUMERIC,
        grand_total = (p_order->>'grand_total')::NUMERIC,
        version = v_incoming_version,
        updated_at = NOW()
    WHERE id = v_order_id;

    RETURN true;
  END IF;

  RETURN false;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

-- Permissions
REVOKE EXECUTE ON FUNCTION public.secure_replace_pos_draft_order(JSONB, JSONB, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.secure_replace_pos_draft_order(JSONB, JSONB, UUID, TEXT) TO authenticated;
