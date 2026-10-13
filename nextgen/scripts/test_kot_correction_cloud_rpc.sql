-- CHEESYOS NEXTGEN — TASK 3G.2-09B CLOUD RPC VERIFICATION SCRIPT
-- Runs on NextGen Dev (sdbnibyzqtgpbexlznat)

DO $$
DECLARE
  v_test_user_id UUID := '00000000-0000-0000-0000-000000000059'::UUID;
  v_test_device_id UUID := '00000000-0000-0000-0000-000000000058'::UUID;
  v_test_device_token TEXT := 'test-cloud-device-token-secret-59';
  v_token_hash TEXT;
  v_table1_id UUID := '00000000-0000-0000-0000-000000000057'::UUID;
  v_table2_id UUID := '00000000-0000-0000-0000-000000000056'::UUID;
  v_session1_id UUID := '00000000-0000-0000-0000-000000000055'::UUID;
  v_session2_id UUID := '00000000-0000-0000-0000-000000000054'::UUID;
  v_order1_id UUID := '00000000-0000-0000-0000-000000000053'::UUID;
  v_order2_id UUID := '00000000-0000-0000-0000-000000000052'::UUID;
  v_item1_id UUID := '00000000-0000-0000-0000-000000000051'::UUID;
  v_item2_id UUID := '00000000-0000-0000-0000-000000000050'::UUID;
  v_kot1_id UUID := '00000000-0000-0000-0000-000000000049'::UUID;
  v_kot2_id UUID := '00000000-0000-0000-0000-000000000048'::UUID;
  v_kitem1_id UUID := '00000000-0000-0000-0000-000000000047'::UUID;
  v_kitem2_id UUID := '00000000-0000-0000-0000-000000000046'::UUID;
  v_prod1_id UUID := '00000000-0000-0000-0000-000000000045'::UUID;
  v_cat_id UUID := '00000000-0000-0000-0000-000000000044'::UUID;

  v_corr1_id UUID := '00000000-0000-0000-0000-000000000043'::UUID;
  v_corr2_id UUID := '00000000-0000-0000-0000-000000000042'::UUID;

  v_res BOOLEAN;
  v_item_qty INTEGER;
  v_order_grand NUMERIC;
  v_kot_qty INTEGER;
  v_err_caught BOOLEAN;
BEGIN
  RAISE NOTICE '=== STARTING TASK 3G.2-09B CLOUD RPC VERIFICATION ===';

  -- 1. Setup Auth & Device Fixtures
  v_token_hash := encode(extensions.digest(v_test_device_token, 'sha256'), 'hex');

  INSERT INTO auth.users (id, email, raw_user_meta_data)
  VALUES (v_test_user_id, 'pos-test-staff-59@cheesyos.internal', '{"full_name": "Test POS Staff 59"}'::JSONB)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.staff_profiles (id, full_name, role, is_active, has_pos_access)
  VALUES (v_test_user_id, 'Test POS Staff 59', 'cashier', TRUE, TRUE)
  ON CONFLICT (id) DO UPDATE SET is_active = TRUE, has_pos_access = TRUE;

  INSERT INTO public.pos_devices (id, terminal_code, device_name, is_active, device_secret_hash, revoked_at)
  VALUES (v_test_device_id, 'T59', 'Cloud Test Terminal 59', TRUE, v_token_hash, NULL)
  ON CONFLICT (id) DO UPDATE SET is_active = TRUE, device_secret_hash = v_token_hash, revoked_at = NULL;

  INSERT INTO public.categories (id, name, slug, is_active)
  VALUES (v_cat_id, 'Test Cat 59', 'test-cat-59', TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.products (id, category_id, name, base_price, is_available)
  VALUES (v_prod1_id, v_cat_id, 'Test Burger 59', 100.00, TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.pos_tables (id, table_number, section, capacity, is_active)
  VALUES (v_table1_id, 'TEST-59-1', 'Main', 4, TRUE),
         (v_table2_id, 'TEST-59-2', 'Main', 4, TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.table_sessions (id, table_id, guest_count, session_status, opened_at, current_order_id)
  VALUES (v_session1_id, v_table1_id, 2, 'open', NOW(), NULL),
         (v_session2_id, v_table2_id, 2, 'open', NOW(), NULL)
  ON CONFLICT (id) DO NOTHING;

  -- Order 1: kot_sent, 3 Burgers @ 100 + 5% tax = 315
  INSERT INTO public.orders (
    id, display_number, channel, order_type, table_session_id,
    status, subtotal, tax_total, discount_total, delivery_charge, grand_total,
    device_id, version, created_at, updated_at
  ) VALUES (
    v_order1_id, 'ORD-59-1', 'POS', 'DINE_IN', v_session1_id,
    'kot_sent', 300.00, 15.00, 0.00, 0.00, 315.00,
    v_test_device_id::TEXT, 1, NOW(), NOW()
  ) ON CONFLICT (id) DO UPDATE SET
    status = 'kot_sent', subtotal = 300.00, tax_total = 15.00, grand_total = 315.00, version = 1;

  -- Order 2: kot_sent, 1 Burger @ 100 + 5% tax = 105
  INSERT INTO public.orders (
    id, display_number, channel, order_type, table_session_id,
    status, subtotal, tax_total, discount_total, delivery_charge, grand_total,
    device_id, version, created_at, updated_at
  ) VALUES (
    v_order2_id, 'ORD-59-2', 'POS', 'DINE_IN', v_session2_id,
    'kot_sent', 100.00, 5.00, 0.00, 0.00, 105.00,
    v_test_device_id::TEXT, 1, NOW(), NOW()
  ) ON CONFLICT (id) DO UPDATE SET
    status = 'kot_sent', subtotal = 100.00, tax_total = 5.00, grand_total = 105.00, version = 1;

  UPDATE public.table_sessions SET current_order_id = v_order1_id WHERE id = v_session1_id;
  UPDATE public.table_sessions SET current_order_id = v_order2_id WHERE id = v_session2_id;

  -- Order item 1 on Order 1
  INSERT INTO public.order_items (
    id, order_id, product_id, product_name, unit_price, quantity, tax_rate, discount_amount, line_total
  ) VALUES (
    v_item1_id, v_order1_id, v_prod1_id, 'Test Burger 59', 100.00, 3, 5.00, 0.00, 315.00
  ) ON CONFLICT (id) DO NOTHING;

  -- Order item 2 on Order 2
  INSERT INTO public.order_items (
    id, order_id, product_id, product_name, unit_price, quantity, tax_rate, discount_amount, line_total
  ) VALUES (
    v_item2_id, v_order2_id, v_prod1_id, 'Test Burger 59', 100.00, 1, 5.00, 0.00, 105.00
  ) ON CONFLICT (id) DO NOTHING;

  -- KOT 1 on Order 1
  INSERT INTO public.pos_kots (
    id, order_id, kot_number, device_id, status, printed_at
  ) VALUES (
    v_kot1_id, v_order1_id, 1, v_test_device_id::TEXT, 'printed', NOW()
  ) ON CONFLICT (id) DO NOTHING;

  -- KOT 2 on Order 2
  INSERT INTO public.pos_kots (
    id, order_id, kot_number, device_id, status, printed_at
  ) VALUES (
    v_kot2_id, v_order2_id, 1, v_test_device_id::TEXT, 'printed', NOW()
  ) ON CONFLICT (id) DO NOTHING;

  -- KOT item 1 carrying order_item_id = item1 (LINEAGE)
  INSERT INTO public.kot_items (
    id, kot_id, order_item_id, product_id, product_name, quantity
  ) VALUES (
    v_kitem1_id, v_kot1_id, v_item1_id, v_prod1_id, 'Test Burger 59', 3
  ) ON CONFLICT (id) DO UPDATE SET order_item_id = v_item1_id;

  -- KOT item 2 carrying order_item_id = item2
  INSERT INTO public.kot_items (
    id, kot_id, order_item_id, product_id, product_name, quantity
  ) VALUES (
    v_kitem2_id, v_kot2_id, v_item2_id, v_prod1_id, 'Test Burger 59', 1
  ) ON CONFLICT (id) DO UPDATE SET order_item_id = v_item2_id;

  -- ==========================================================================
  -- 2. AUTH & PERMISSION CHECKS
  -- ==========================================================================

  -- Test: Unauthenticated caller fails
  PERFORM set_config('request.jwt.claim.sub', '', true);
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_save_kot_correction(
      jsonb_build_object(
        'id', v_corr1_id,
        'order_id', v_order1_id,
        'kot_id', v_kot1_id,
        'kot_item_id', v_kitem1_id,
        'order_item_id', v_item1_id,
        'cancelled_qty', 1,
        'reason', 'Customer test',
        'authorized_by_staff_id', v_test_user_id
      ),
      jsonb_build_object('id', v_item1_id, 'quantity', 2, 'line_total', 210.00),
      jsonb_build_object('id', v_order1_id, 'subtotal', 200.00, 'tax_total', 10.00, 'grand_total', 210.00),
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := TRUE;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Unauthenticated call must fail'; END IF;
  RAISE NOTICE 'PASS: AUTH_REQUIRED_PASS';

  -- Set valid staff auth context
  PERFORM set_config('request.jwt.claim.sub', v_test_user_id::TEXT, true);

  -- Test: Device Authorization failure (wrong token)
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_save_kot_correction(
      jsonb_build_object(
        'id', v_corr1_id,
        'order_id', v_order1_id,
        'kot_id', v_kot1_id,
        'kot_item_id', v_kitem1_id,
        'order_item_id', v_item1_id,
        'cancelled_qty', 1,
        'reason', 'Customer test',
        'authorized_by_staff_id', v_test_user_id
      ),
      jsonb_build_object('id', v_item1_id, 'quantity', 2, 'line_total', 210.00),
      jsonb_build_object('id', v_order1_id, 'subtotal', 200.00, 'tax_total', 10.00, 'grand_total', 210.00),
      v_test_device_id, 'invalid-secret-token'
    );
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := TRUE;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Invalid device token must fail'; END IF;
  RAISE NOTICE 'PASS: DEVICE_AUTHORIZATION_PASS';

  -- ==========================================================================
  -- 3. LINEAGE & GUARD CHECKS
  -- ==========================================================================

  -- A. Historical null lineage rejection
  UPDATE public.kot_items SET order_item_id = NULL WHERE id = v_kitem1_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_save_kot_correction(
      jsonb_build_object(
        'id', v_corr1_id,
        'order_id', v_order1_id,
        'kot_id', v_kot1_id,
        'kot_item_id', v_kitem1_id,
        'order_item_id', v_item1_id,
        'cancelled_qty', 1,
        'reason', 'Customer test',
        'authorized_by_staff_id', v_test_user_id
      ),
      jsonb_build_object('id', v_item1_id, 'quantity', 2, 'line_total', 210.00),
      jsonb_build_object('id', v_order1_id, 'subtotal', 200.00, 'tax_total', 10.00, 'grand_total', 210.00),
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := TRUE;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Null order_item_id must be rejected'; END IF;
  RAISE NOTICE 'PASS: HISTORICAL_NULL_LINEAGE_REJECT_PASS';

  -- Restore lineage
  UPDATE public.kot_items SET order_item_id = v_item1_id WHERE id = v_kitem1_id;

  -- B. Wrong KOT item rejection
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_save_kot_correction(
      jsonb_build_object(
        'id', v_corr1_id,
        'order_id', v_order1_id,
        'kot_id', v_kot1_id,
        'kot_item_id', v_kitem2_id, -- belongs to kot 2
        'order_item_id', v_item1_id,
        'cancelled_qty', 1,
        'reason', 'Wrong kot item',
        'authorized_by_staff_id', v_test_user_id
      ),
      jsonb_build_object('id', v_item1_id, 'quantity', 2, 'line_total', 210.00),
      jsonb_build_object('id', v_order1_id, 'subtotal', 200.00, 'tax_total', 10.00, 'grand_total', 210.00),
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := TRUE;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Mismatched kot item must fail'; END IF;
  RAISE NOTICE 'PASS: WRONG_KOT_ITEM_REJECT_PASS';

  -- C. Wrong Order Item rejection
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_save_kot_correction(
      jsonb_build_object(
        'id', v_corr1_id,
        'order_id', v_order1_id,
        'kot_id', v_kot1_id,
        'kot_item_id', v_kitem1_id,
        'order_item_id', '00000000-0000-0000-0000-ffffffffffff'::UUID,
        'cancelled_qty', 1,
        'reason', 'Wrong order item',
        'authorized_by_staff_id', v_test_user_id
      ),
      jsonb_build_object('id', v_item1_id, 'quantity', 2, 'line_total', 210.00),
      jsonb_build_object('id', v_order1_id, 'subtotal', 200.00, 'tax_total', 10.00, 'grand_total', 210.00),
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := TRUE;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Mismatched order item must fail'; END IF;
  RAISE NOTICE 'PASS: WRONG_ORDER_ITEM_REJECT_PASS';

  -- D. Cross-Order rejection
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_save_kot_correction(
      jsonb_build_object(
        'id', v_corr1_id,
        'order_id', v_order1_id,
        'kot_id', v_kot1_id,
        'kot_item_id', v_kitem1_id,
        'order_item_id', v_item2_id, -- belongs to order 2
        'cancelled_qty', 1,
        'reason', 'Cross order',
        'authorized_by_staff_id', v_test_user_id
      ),
      jsonb_build_object('id', v_item2_id, 'quantity', 0, 'line_total', 0.00),
      jsonb_build_object('id', v_order1_id, 'subtotal', 200.00, 'tax_total', 10.00, 'grand_total', 210.00),
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := TRUE;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Cross-order item linkage must fail'; END IF;
  RAISE NOTICE 'PASS: CROSS_ORDER_REJECT_PASS';

  -- E. Over-Correction rejection
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_save_kot_correction(
      jsonb_build_object(
        'id', v_corr1_id,
        'order_id', v_order1_id,
        'kot_id', v_kot1_id,
        'kot_item_id', v_kitem1_id,
        'order_item_id', v_item1_id,
        'cancelled_qty', 4, -- current qty is 3
        'reason', 'Over cancel',
        'authorized_by_staff_id', v_test_user_id
      ),
      jsonb_build_object('id', v_item1_id, 'quantity', 0, 'line_total', 0.00),
      jsonb_build_object('id', v_order1_id, 'subtotal', 0.00, 'tax_total', 0.00, 'discount_total', 0.00, 'delivery_charge', 0.00, 'grand_total', 0.00),
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := TRUE;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Over-correction must fail'; END IF;
  RAISE NOTICE 'PASS: OVER_CORRECTION_REJECT_PASS';

  -- ==========================================================================
  -- 4. PARTIAL CORRECTION EXECUTION
  -- ==========================================================================
  v_res := public.secure_save_kot_correction(
    jsonb_build_object(
      'id', v_corr1_id,
      'order_id', v_order1_id,
      'kot_id', v_kot1_id,
      'kot_item_id', v_kitem1_id,
      'order_item_id', v_item1_id,
      'cancelled_qty', 1,
      'reason', 'Customer changed mind',
      'authorized_by_staff_id', v_test_user_id
    ),
    jsonb_build_object('id', v_item1_id, 'quantity', 2, 'line_total', 210.00),
    jsonb_build_object('id', v_order1_id, 'subtotal', 200.00, 'tax_total', 10.00, 'discount_total', 0.00, 'delivery_charge', 0.00, 'grand_total', 210.00),
    v_test_device_id, v_test_device_token
  );
  IF NOT v_res THEN RAISE EXCEPTION 'Correction RPC failed'; END IF;

  SELECT quantity INTO v_item_qty FROM public.order_items WHERE id = v_item1_id;
  SELECT grand_total INTO v_order_grand FROM public.orders WHERE id = v_order1_id;
  SELECT quantity INTO v_kot_qty FROM public.kot_items WHERE id = v_kitem1_id;

  IF v_item_qty != 2 THEN RAISE EXCEPTION 'Expected quantity 2, got %', v_item_qty; END IF;
  IF v_order_grand != 210.00 THEN RAISE EXCEPTION 'Expected grand total 210, got %', v_order_grand; END IF;
  IF v_kot_qty != 3 THEN RAISE EXCEPTION 'Original KOT item must remain 3, got %', v_kot_qty; END IF;

  RAISE NOTICE 'PASS: PARTIAL_CORRECTION_PASS';
  RAISE NOTICE 'PASS: ORIGINAL_KOT_IMMUTABLE_PASS';
  RAISE NOTICE 'PASS: ORDER_TOTALS_CORRECTED_PASS';

  -- ==========================================================================
  -- 5. IDEMPOTENT RETRY & NO DOUBLE DEDUCTION
  -- ==========================================================================
  -- Identical retry with same ID
  v_res := public.secure_save_kot_correction(
    jsonb_build_object(
      'id', v_corr1_id,
      'order_id', v_order1_id,
      'kot_id', v_kot1_id,
      'kot_item_id', v_kitem1_id,
      'order_item_id', v_item1_id,
      'cancelled_qty', 1,
      'reason', 'Customer changed mind',
      'authorized_by_staff_id', v_test_user_id
    ),
    jsonb_build_object('id', v_item1_id, 'quantity', 2, 'line_total', 210.00),
    jsonb_build_object('id', v_order1_id, 'subtotal', 200.00, 'tax_total', 10.00, 'discount_total', 0.00, 'delivery_charge', 0.00, 'grand_total', 210.00),
    v_test_device_id, v_test_device_token
  );
  IF NOT v_res THEN RAISE EXCEPTION 'Idempotent retry must return true'; END IF;

  -- Ensure quantity was NOT deducted again (still 2)
  SELECT quantity INTO v_item_qty FROM public.order_items WHERE id = v_item1_id;
  IF v_item_qty != 2 THEN RAISE EXCEPTION 'Idempotent retry double-deducted quantity to %', v_item_qty; END IF;

  RAISE NOTICE 'PASS: IDENTICAL_RETRY_PASS';
  RAISE NOTICE 'PASS: RETRY_NO_DOUBLE_DEDUCTION_PASS';

  -- Conflicting retry with same ID
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_save_kot_correction(
      jsonb_build_object(
        'id', v_corr1_id,
        'order_id', v_order1_id,
        'kot_id', v_kot1_id,
        'kot_item_id', v_kitem1_id,
        'order_item_id', v_item1_id,
        'cancelled_qty', 2, -- conflicting
        'reason', 'Customer changed mind',
        'authorized_by_staff_id', v_test_user_id
      ),
      jsonb_build_object('id', v_item1_id, 'quantity', 1, 'line_total', 105.00),
      jsonb_build_object('id', v_order1_id, 'subtotal', 100.00, 'tax_total', 5.00, 'discount_total', 0.00, 'delivery_charge', 0.00, 'grand_total', 105.00),
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := TRUE;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Conflicting retry must fail with IDEMPOTENCY_CONFLICT'; END IF;
  RAISE NOTICE 'PASS: CONFLICTING_RETRY_PASS';

  -- ==========================================================================
  -- 6. FULL CANCELLATION (QUANTITY = 0)
  -- ==========================================================================
  v_res := public.secure_save_kot_correction(
    jsonb_build_object(
      'id', v_corr2_id,
      'order_id', v_order1_id,
      'kot_id', v_kot1_id,
      'kot_item_id', v_kitem1_id,
      'order_item_id', v_item1_id,
      'cancelled_qty', 2, -- cancel remaining 2
      'reason', 'Cancelled rest',
      'authorized_by_staff_id', v_test_user_id
    ),
    jsonb_build_object('id', v_item1_id, 'quantity', 0, 'line_total', 0.00),
    jsonb_build_object('id', v_order1_id, 'subtotal', 0.00, 'tax_total', 0.00, 'discount_total', 0.00, 'delivery_charge', 0.00, 'grand_total', 0.00),
    v_test_device_id, v_test_device_token
  );
  IF NOT v_res THEN RAISE EXCEPTION 'Full cancel RPC failed'; END IF;

  SELECT quantity INTO v_item_qty FROM public.order_items WHERE id = v_item1_id;
  IF v_item_qty != 0 THEN RAISE EXCEPTION 'Expected quantity 0, got %', v_item_qty; END IF;

  -- Ensure row still exists
  IF NOT EXISTS (SELECT 1 FROM public.order_items WHERE id = v_item1_id) THEN
    RAISE EXCEPTION 'Order item row must NOT be deleted upon full cancellation';
  END IF;

  RAISE NOTICE 'PASS: FULL_CORRECTION_ZERO_QTY_PASS';

  -- ==========================================================================
  -- 7. CLEANUP FIXTURES & PROVE ZERO RESIDUE
  -- ==========================================================================
  DELETE FROM public.kot_corrections WHERE order_id IN (v_order1_id, v_order2_id);
  DELETE FROM public.kot_items WHERE kot_id IN (v_kot1_id, v_kot2_id);
  DELETE FROM public.pos_kots WHERE id IN (v_kot1_id, v_kot2_id);
  DELETE FROM public.order_items WHERE order_id IN (v_order1_id, v_order2_id);
  DELETE FROM public.orders WHERE id IN (v_order1_id, v_order2_id);
  DELETE FROM public.table_sessions WHERE id IN (v_session1_id, v_session2_id);
  DELETE FROM public.pos_tables WHERE id IN (v_table1_id, v_table2_id);
  DELETE FROM public.products WHERE id = v_prod1_id;
  DELETE FROM public.categories WHERE id = v_cat_id;
  DELETE FROM public.pos_devices WHERE id = v_test_device_id;
  DELETE FROM public.staff_profiles WHERE id = v_test_user_id;
  DELETE FROM auth.users WHERE id = v_test_user_id;

  IF EXISTS (SELECT 1 FROM public.orders WHERE id IN (v_order1_id, v_order2_id))
     OR EXISTS (SELECT 1 FROM public.kot_corrections WHERE id IN (v_corr1_id, v_corr2_id))
     OR EXISTS (SELECT 1 FROM public.pos_devices WHERE id = v_test_device_id)
  THEN
    RAISE EXCEPTION 'FIXTURE CLEANUP FAILED: Remnants detected in database';
  END IF;

  RAISE NOTICE '=== ALL CLOUD RPC VERIFICATION TESTS PASSED — FIXTURES 100 PERCENT CLEANED ===';
END $$;
