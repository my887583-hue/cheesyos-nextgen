-- CHEESYOS NEXTGEN — TASK 3G.2-08A CLOUD RPC VERIFICATION SCRIPT
-- Runs on NextGen Dev (sdbnibyzqtgpbexlznat)

DO $$
DECLARE
  v_test_user_id UUID := '00000000-0000-0000-0000-000000000079'::UUID;
  v_test_device_id UUID := '00000000-0000-0000-0000-000000000078'::UUID;
  v_test_device_token TEXT := 'test-additional-kot-device-token-secret-79';
  v_token_hash TEXT;
  v_table_id UUID := '00000000-0000-0000-0000-000000000077'::UUID;
  v_session_id UUID := '00000000-0000-0000-0000-000000000076'::UUID;
  v_order_id UUID := '00000000-0000-0000-0000-000000000075'::UUID;
  v_item1_id UUID := '00000000-0000-0000-0000-000000000074'::UUID;
  v_item2_id UUID := '00000000-0000-0000-0000-000000000073'::UUID;
  v_item3_id UUID := '00000000-0000-0000-0000-000000000072'::UUID;
  v_kot1_id UUID := '00000000-0000-0000-0000-000000000071'::UUID;
  v_kot2_id UUID := '00000000-0000-0000-0000-000000000070'::UUID;
  v_kitem1_id UUID := '00000000-0000-0000-0000-000000000068'::UUID;
  v_kitem2_id UUID := '00000000-0000-0000-0000-000000000067'::UUID;
  v_prod1_id UUID := '00000000-0000-0000-0000-000000000065'::UUID;
  v_prod2_id UUID := '00000000-0000-0000-0000-000000000064'::UUID;
  v_cat_id UUID := '00000000-0000-0000-0000-000000000063'::UUID;

  v_res BOOLEAN;
  v_item_count INTEGER;
  v_kot_count INTEGER;
  v_item1_qty INTEGER;
  v_order_subtotal NUMERIC;
  v_order_grand NUMERIC;
  v_order_status TEXT;
  v_order_ver INTEGER;
  v_err_caught BOOLEAN;

  v_order_payload JSONB;
  v_order_items_payload JSONB;
  v_kot_payload JSONB;
  v_kot_items_payload JSONB;
BEGIN
  RAISE NOTICE '=== STARTING TASK 3G.2-08A CLOUD RPC VERIFICATION ===';

  -- 1. Setup Auth & Device Fixtures
  v_token_hash := encode(extensions.digest(v_test_device_token, 'sha256'), 'hex');

  -- Ensure auth user exists
  INSERT INTO auth.users (id, email, raw_user_meta_data)
  VALUES (v_test_user_id, 'pos-test-staff-79@cheesyos.internal', '{"full_name": "Test POS Staff 79"}'::JSONB)
  ON CONFLICT (id) DO NOTHING;

  -- Ensure staff profile exists
  INSERT INTO public.staff_profiles (id, full_name, role, is_active, has_pos_access)
  VALUES (v_test_user_id, 'Test POS Staff 79', 'cashier', TRUE, TRUE)
  ON CONFLICT (id) DO UPDATE SET is_active = TRUE, has_pos_access = TRUE;

  -- Ensure device exists and authorized
  INSERT INTO public.pos_devices (id, terminal_code, device_name, is_active, device_secret_hash, revoked_at)
  VALUES (v_test_device_id, 'T79', 'Cloud Test Terminal 79', TRUE, v_token_hash, NULL)
  ON CONFLICT (id) DO UPDATE SET is_active = TRUE, device_secret_hash = v_token_hash, revoked_at = NULL;

  -- Ensure Category and Products exist
  INSERT INTO public.categories (id, name, slug, is_active)
  VALUES (v_cat_id, 'Test Cat 79', 'test-cat-79', TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.products (id, category_id, name, base_price, is_available)
  VALUES (v_prod1_id, v_cat_id, 'Test Pizza 79-1', 100.00, TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.products (id, category_id, name, base_price, is_available)
  VALUES (v_prod2_id, v_cat_id, 'Test Pizza 79-2', 200.00, TRUE)
  ON CONFLICT (id) DO NOTHING;

  -- Ensure Table and Open Table Session exist
  INSERT INTO public.pos_tables (id, table_number, section, capacity, is_active)
  VALUES (v_table_id, 'TEST-79', 'Main', 4, TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.table_sessions (id, table_id, guest_count, session_status, opened_at, current_order_id)
  VALUES (v_session_id, v_table_id, 2, 'open', NOW(), NULL)
  ON CONFLICT (id) DO NOTHING;

  -- Insert initial order already in status = 'kot_sent'
  INSERT INTO public.orders (
    id, display_number, channel, order_type, table_session_id,
    status, subtotal, tax_total, discount_total, delivery_charge, grand_total,
    device_id, version, created_at, updated_at
  ) VALUES (
    v_order_id, 'ORD-79', 'POS', 'DINE_IN', v_session_id,
    'kot_sent', 100.00, 5.00, 0.00, 0.00, 105.00,
    v_test_device_id::TEXT, 1, NOW(), NOW()
  ) ON CONFLICT (id) DO UPDATE SET
    status = 'kot_sent', subtotal = 100.00, tax_total = 5.00, grand_total = 105.00, version = 1;

  UPDATE public.table_sessions SET current_order_id = v_order_id WHERE id = v_session_id;

  -- Insert initial order item 1
  INSERT INTO public.order_items (
    id, order_id, product_id, product_name, unit_price, quantity, tax_rate, discount_amount, line_total
  ) VALUES (
    v_item1_id, v_order_id, v_prod1_id, 'Test Pizza 79-1', 100.00, 1, 5.00, 0.00, 100.00
  ) ON CONFLICT (id) DO NOTHING;

  -- Insert initial KOT 1
  INSERT INTO public.pos_kots (
    id, order_id, kot_number, device_id, status, printed_at
  ) VALUES (
    v_kot1_id, v_order_id, 1, v_test_device_id::TEXT, 'printed', NOW()
  ) ON CONFLICT (id) DO NOTHING;

  -- Insert initial KOT item 1
  INSERT INTO public.kot_items (
    id, kot_id, product_id, product_name, quantity
  ) VALUES (
    v_kitem1_id, v_kot1_id, v_prod1_id, 'Test Pizza 79-1', 1
  ) ON CONFLICT (id) DO NOTHING;

  -- Prepare payloads for additional KOT #2
  v_order_payload := jsonb_build_object(
    'id', v_order_id,
    'table_session_id', v_session_id,
    'subtotal', 300.00,
    'tax_total', 15.00,
    'discount_total', 0.00,
    'delivery_charge', 0.00,
    'grand_total', 315.00,
    'device_id', v_test_device_id
  );

  v_order_items_payload := jsonb_build_array(
    jsonb_build_object(
      'id', v_item2_id,
      'order_id', v_order_id,
      'product_id', v_prod2_id,
      'product_name', 'Test Pizza 79-2',
      'unit_price', 200.00,
      'quantity', 1,
      'tax_rate', 5.00,
      'discount_amount', 0.00,
      'line_total', 200.00
    )
  );

  v_kot_payload := jsonb_build_object(
    'id', v_kot2_id,
    'order_id', v_order_id,
    'kot_number', 2,
    'device_id', v_test_device_id,
    'status', 'printed'
  );

  v_kot_items_payload := jsonb_build_array(
    jsonb_build_object(
      'id', v_kitem2_id,
      'kot_id', v_kot2_id,
      'product_id', v_prod2_id,
      'product_name', 'Test Pizza 79-2',
      'quantity', 1
    )
  );

  -- Set JWT claims to authenticated test staff
  PERFORM set_config('request.jwt.claim.sub', v_test_user_id::TEXT, TRUE);

  -- ==========================================================================
  -- 2. TEST AUTH GUARDS
  -- ==========================================================================

  -- A. Unauthenticated reject
  PERFORM set_config('request.jwt.claim.sub', '', TRUE);
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      v_order_payload, v_order_items_payload, v_kot_payload, v_kot_items_payload,
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Access Denied%' OR SQLERRM LIKE '%42501%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Unauthenticated request must be rejected'; END IF;
  RAISE NOTICE 'PASS: RPC_UNAUTHENTICATED_REJECT_PASS';

  -- Restore auth
  PERFORM set_config('request.jwt.claim.sub', v_test_user_id::TEXT, TRUE);

  -- B. Inactive staff reject
  UPDATE public.staff_profiles SET is_active = FALSE WHERE id = v_test_user_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      v_order_payload, v_order_items_payload, v_kot_payload, v_kot_items_payload,
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Access Denied%' OR SQLERRM LIKE '%42501%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Inactive staff must be rejected'; END IF;
  RAISE NOTICE 'PASS: RPC_INACTIVE_STAFF_REJECT_PASS';
  UPDATE public.staff_profiles SET is_active = TRUE WHERE id = v_test_user_id;

  -- C. Unauthorized device (wrong token) reject
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      v_order_payload, v_order_items_payload, v_kot_payload, v_kot_items_payload,
      v_test_device_id, 'wrong-token-abc'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%DEVICE_AUTH_FAILED%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Wrong device token must be rejected with DEVICE_AUTH_FAILED'; END IF;
  RAISE NOTICE 'PASS: RPC_UNAUTHORIZED_DEVICE_REJECT_PASS';

  -- D. Revoked device reject
  UPDATE public.pos_devices SET is_active = FALSE, revoked_at = NOW() WHERE id = v_test_device_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      v_order_payload, v_order_items_payload, v_kot_payload, v_kot_items_payload,
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%DEVICE_REVOKED%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Revoked device must be rejected with DEVICE_REVOKED'; END IF;
  RAISE NOTICE 'PASS: RPC_REVOKED_DEVICE_REJECT_PASS';
  UPDATE public.pos_devices SET is_active = TRUE, revoked_at = NULL WHERE id = v_test_device_id;

  -- ==========================================================================
  -- 3. TEST STATUS GUARDS
  -- ==========================================================================

  -- A. Draft reject
  UPDATE public.orders SET status = 'draft' WHERE id = v_order_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      v_order_payload, v_order_items_payload, v_kot_payload, v_kot_items_payload,
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%CONTRACT_CONFLICT%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Draft order must reject additional KOT append'; END IF;
  RAISE NOTICE 'PASS: RPC_DRAFT_REJECT_PASS';

  -- B. Billed reject
  UPDATE public.orders SET status = 'billed' WHERE id = v_order_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      v_order_payload, v_order_items_payload, v_kot_payload, v_kot_items_payload,
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%CONTRACT_CONFLICT%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Billed order must reject additional KOT append'; END IF;
  RAISE NOTICE 'PASS: RPC_BILLED_REJECT_PASS';

  -- C. Settled reject
  UPDATE public.orders SET status = 'settled' WHERE id = v_order_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      v_order_payload, v_order_items_payload, v_kot_payload, v_kot_items_payload,
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%CONTRACT_CONFLICT%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Settled order must reject additional KOT append'; END IF;
  RAISE NOTICE 'PASS: RPC_SETTLED_REJECT_PASS';

  -- D. Closed reject
  UPDATE public.orders SET status = 'closed' WHERE id = v_order_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      v_order_payload, v_order_items_payload, v_kot_payload, v_kot_items_payload,
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%CONTRACT_CONFLICT%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Closed order must reject additional KOT append'; END IF;
  RAISE NOTICE 'PASS: RPC_CLOSED_REJECT_PASS';

  -- E. Cancelled reject
  UPDATE public.orders SET status = 'cancelled' WHERE id = v_order_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      v_order_payload, v_order_items_payload, v_kot_payload, v_kot_items_payload,
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%CONTRACT_CONFLICT%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Cancelled order must reject additional KOT append'; END IF;
  RAISE NOTICE 'PASS: RPC_CANCELLED_REJECT_PASS';

  -- Restore order status to 'kot_sent'
  UPDATE public.orders SET status = 'kot_sent' WHERE id = v_order_id;

  -- ==========================================================================
  -- 4. TEST NUMBERING VALIDATION (NUMBERING_CONFLICT)
  -- ==========================================================================

  -- Attempt to append with kot_number = 3 when existing max is 1 (gap)
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      v_order_payload, v_order_items_payload,
      jsonb_build_object('id', v_kot2_id, 'order_id', v_order_id, 'kot_number', 3, 'device_id', v_test_device_id, 'status', 'printed'),
      v_kot_items_payload,
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%NUMBERING_CONFLICT%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'KOT number gap (skipping next) must be rejected with NUMBERING_CONFLICT'; END IF;

  -- Attempt to append with kot_number = 1 when existing max is 1 (duplicate number, different operation)
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      v_order_payload, v_order_items_payload,
      jsonb_build_object('id', v_kot2_id, 'order_id', v_order_id, 'kot_number', 1, 'device_id', v_test_device_id, 'status', 'printed'),
      v_kot_items_payload,
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%NUMBERING_CONFLICT%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Duplicate KOT number for different operation must be rejected with NUMBERING_CONFLICT'; END IF;
  RAISE NOTICE 'PASS: RPC_DUPLICATE_KOT_NUMBER_DIFFERENT_OPERATION_REJECT_PASS';

  -- ==========================================================================
  -- 5. TEST SUCCESSFUL APPEND (GENUINELY NEW OPERATION KOT #2)
  -- ==========================================================================
  v_res := public.secure_append_pos_order_items_and_kot(
    v_order_payload, v_order_items_payload, v_kot_payload, v_kot_items_payload,
    v_test_device_id, v_test_device_token
  );
  IF v_res IS NOT TRUE THEN RAISE EXCEPTION 'secure_append_pos_order_items_and_kot should succeed'; END IF;
  RAISE NOTICE 'PASS: RPC_KOT_SENT_ORDER_PASS';
  RAISE NOTICE 'PASS: RPC_NEXT_KOT_NUMBER_PASS';

  -- Verify order items appended
  SELECT COUNT(*) INTO v_item_count FROM public.order_items WHERE order_id = v_order_id;
  IF v_item_count != 2 THEN
    RAISE EXCEPTION 'Order items count must be 2, found %', v_item_count;
  END IF;
  RAISE NOTICE 'PASS: RPC_APPEND_ITEMS_PASS';

  -- Verify sent order item 1 is completely unchanged
  SELECT quantity INTO v_item1_qty FROM public.order_items WHERE id = v_item1_id;
  IF v_item1_qty != 1 THEN
    RAISE EXCEPTION 'Original sent order item 1 was modified! Found quantity %', v_item1_qty;
  END IF;
  RAISE NOTICE 'PASS: RPC_SENT_ITEMS_UNCHANGED_PASS';

  -- Verify cumulative financial header & version unchanged
  SELECT subtotal, grand_total, status, version
  INTO v_order_subtotal, v_order_grand, v_order_status, v_order_ver
  FROM public.orders WHERE id = v_order_id;

  IF v_order_subtotal != 300.00 OR v_order_grand != 315.00 THEN
    RAISE EXCEPTION 'Cumulative totals incorrect: subtotal=%, grand=%', v_order_subtotal, v_order_grand;
  END IF;
  IF v_order_status != 'kot_sent' THEN
    RAISE EXCEPTION 'Order status should remain kot_sent, found %', v_order_status;
  END IF;
  IF v_order_ver != 1 THEN
    RAISE EXCEPTION 'Order version must not change on additional KOT! Found version %', v_order_ver;
  END IF;
  RAISE NOTICE 'PASS: RPC_CUMULATIVE_TOTALS_PASS';

  -- Verify KOT #2 created
  SELECT COUNT(*) INTO v_kot_count FROM public.pos_kots WHERE order_id = v_order_id;
  IF v_kot_count != 2 THEN
    RAISE EXCEPTION 'KOT count must be 2, found %', v_kot_count;
  END IF;

  -- ==========================================================================
  -- 6. TEST IDEMPOTENT RETRY & IDEMPOTENCY CONFLICT
  -- ==========================================================================

  -- Identical retry succeeds without duplicate rows
  v_res := public.secure_append_pos_order_items_and_kot(
    v_order_payload, v_order_items_payload, v_kot_payload, v_kot_items_payload,
    v_test_device_id, v_test_device_token
  );
  IF v_res IS NOT TRUE THEN RAISE EXCEPTION 'Identical retry must return true'; END IF;

  SELECT COUNT(*) INTO v_item_count FROM public.order_items WHERE order_id = v_order_id;
  IF v_item_count != 2 THEN RAISE EXCEPTION 'Retry duplicated order items! Count is %', v_item_count; END IF;

  SELECT COUNT(*) INTO v_kot_count FROM public.pos_kots WHERE order_id = v_order_id;
  IF v_kot_count != 2 THEN RAISE EXCEPTION 'Retry duplicated pos_kots! Count is %', v_kot_count; END IF;
  RAISE NOTICE 'PASS: RPC_IDENTICAL_RETRY_PASS';

  -- Conflict retry: same KOT ID but different payload (e.g. mismatched grand_total)
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_append_pos_order_items_and_kot(
      jsonb_build_object(
        'id', v_order_id,
        'table_session_id', v_session_id,
        'subtotal', 300.00,
        'tax_total', 15.00,
        'discount_total', 0.00,
        'delivery_charge', 0.00,
        'grand_total', 999.00,
        'device_id', v_test_device_id
      ),
      v_order_items_payload, v_kot_payload, v_kot_items_payload,
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%IDEMPOTENCY_CONFLICT%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Different payload retry must reject with IDEMPOTENCY_CONFLICT'; END IF;
  RAISE NOTICE 'PASS: RPC_IDEMPOTENCY_CONFLICT_PASS';

  -- ==========================================================================
  -- 7. TEST ATOMIC FAILURE ROLLBACK
  -- ==========================================================================
  v_err_caught := FALSE;
  BEGIN
    -- Attempt KOT #3 with invalid foreign key product
    PERFORM public.secure_append_pos_order_items_and_kot(
      jsonb_build_object(
        'id', v_order_id,
        'table_session_id', v_session_id,
        'subtotal', 500.00,
        'tax_total', 25.00,
        'discount_total', 0.00,
        'delivery_charge', 0.00,
        'grand_total', 525.00,
        'device_id', v_test_device_id
      ),
      jsonb_build_array(
        jsonb_build_object(
          'id', v_item3_id,
          'order_id', v_order_id,
          'product_id', '00000000-0000-0000-0000-ffffffffffff'::UUID, -- Non-existent product!
          'product_name', 'Invalid Product',
          'unit_price', 200.00,
          'quantity', 1,
          'line_total', 200.00
        )
      ),
      jsonb_build_object(
        'id', '00000000-0000-0000-0000-000000000069'::UUID,
        'order_id', v_order_id,
        'kot_number', 3,
        'device_id', v_test_device_id,
        'status', 'printed'
      ),
      jsonb_build_array(
        jsonb_build_object(
          'id', '00000000-0000-0000-0000-000000000066'::UUID,
          'kot_id', '00000000-0000-0000-0000-000000000069'::UUID,
          'product_id', '00000000-0000-0000-0000-ffffffffffff'::UUID,
          'product_name', 'Invalid Product',
          'quantity', 1
        )
      ),
      v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := TRUE;
  END;

  IF NOT v_err_caught THEN RAISE EXCEPTION 'Invalid product must fail transaction'; END IF;

  -- Verify total order items is STILL 2 and KOTs count is STILL 2 (no partial writes survived)
  SELECT COUNT(*) INTO v_item_count FROM public.order_items WHERE order_id = v_order_id;
  SELECT COUNT(*) INTO v_kot_count FROM public.pos_kots WHERE order_id = v_order_id;
  IF v_item_count != 2 OR v_kot_count != 2 THEN
    RAISE EXCEPTION 'Atomic rollback failed! Items: %, KOTs: %', v_item_count, v_kot_count;
  END IF;
  RAISE NOTICE 'PASS: RPC_ATOMIC_FAILURE_ROLLBACK_PASS';

  -- ==========================================================================
  -- 8. FULL FIXTURE CLEANUP & VERIFICATION
  -- ==========================================================================
  DELETE FROM public.kot_items WHERE kot_id IN (v_kot1_id, v_kot2_id);
  DELETE FROM public.pos_kots WHERE id IN (v_kot1_id, v_kot2_id);
  DELETE FROM public.order_items WHERE order_id = v_order_id;
  DELETE FROM public.orders WHERE id = v_order_id;
  DELETE FROM public.table_sessions WHERE id = v_session_id;
  DELETE FROM public.pos_tables WHERE id = v_table_id;
  DELETE FROM public.products WHERE id IN (v_prod1_id, v_prod2_id);
  DELETE FROM public.categories WHERE id = v_cat_id;
  DELETE FROM public.pos_devices WHERE id = v_test_device_id;
  DELETE FROM public.staff_profiles WHERE id = v_test_user_id;
  DELETE FROM auth.users WHERE id = v_test_user_id;

  -- Ensure zero leftover fixtures
  IF EXISTS (SELECT 1 FROM public.orders WHERE id = v_order_id)
     OR EXISTS (SELECT 1 FROM public.pos_kots WHERE id IN (v_kot1_id, v_kot2_id))
     OR EXISTS (SELECT 1 FROM public.pos_devices WHERE id = v_test_device_id)
     OR EXISTS (SELECT 1 FROM public.pos_tables WHERE id = v_table_id)
  THEN
    RAISE EXCEPTION 'FIXTURE CLEANUP FAILED: Remnants detected in database';
  END IF;

  RAISE NOTICE '=== ALL CLOUD RPC VERIFICATION TESTS PASSED — FIXTURES 100 PERCENT CLEANED ===';
END $$;
