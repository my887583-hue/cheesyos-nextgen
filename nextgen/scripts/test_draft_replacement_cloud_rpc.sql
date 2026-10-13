-- CHEESYOS NEXTGEN — TASK 3G.2-06B CLOUD RPC VERIFICATION SCRIPT
-- Runs on NextGen Dev (sdbnibyzqtgpbexlznat)

DO $$
DECLARE
  v_test_user_id UUID := '00000000-0000-0000-0000-000000000099'::UUID;
  v_test_device_id UUID := '00000000-0000-0000-0000-000000000098'::UUID;
  v_test_device_token TEXT := 'test-cloud-device-token-secret-99';
  v_token_hash TEXT;
  v_table_id UUID := '00000000-0000-0000-0000-000000000097'::UUID;
  v_session_id UUID := '00000000-0000-0000-0000-000000000096'::UUID;
  v_order_id UUID := '00000000-0000-0000-0000-000000000095'::UUID;
  v_order2_id UUID := '00000000-0000-0000-0000-000000000094'::UUID;
  v_item1_id UUID := '00000000-0000-0000-0000-000000000093'::UUID;
  v_item2_id UUID := '00000000-0000-0000-0000-000000000092'::UUID;
  v_item3_id UUID := '00000000-0000-0000-0000-000000000091'::UUID;
  v_prod1_id UUID := '00000000-0000-0000-0000-000000000090'::UUID;
  v_prod2_id UUID := '00000000-0000-0000-0000-000000000089'::UUID;
  v_cat_id UUID := '00000000-0000-0000-0000-000000000088'::UUID;
  v_res BOOLEAN;
  v_curr_order UUID;
  v_ver INTEGER;
  v_item_count INTEGER;
  v_kot_id UUID := '00000000-0000-0000-0000-000000000087'::UUID;
  v_err_caught BOOLEAN;
  v_valid_items JSONB;
BEGIN
  RAISE NOTICE '=== STARTING TASK 3G.2-06B CLOUD RPC VERIFICATION ===';

  -- 1. Setup Auth & Device Fixtures
  v_token_hash := encode(extensions.digest(v_test_device_token, 'sha256'), 'hex');

  -- Ensure auth user exists
  INSERT INTO auth.users (id, email, raw_user_meta_data)
  VALUES (v_test_user_id, 'pos-test-staff@cheesyos.internal', '{"full_name": "Test POS Staff"}'::JSONB)
  ON CONFLICT (id) DO NOTHING;

  -- Ensure staff profile exists
  INSERT INTO public.staff_profiles (id, full_name, role, is_active, has_pos_access)
  VALUES (v_test_user_id, 'Test POS Staff', 'cashier', TRUE, TRUE)
  ON CONFLICT (id) DO UPDATE SET is_active = TRUE, has_pos_access = TRUE;

  -- Ensure device exists and authorized
  INSERT INTO public.pos_devices (id, terminal_code, device_name, is_active, device_secret_hash, revoked_at)
  VALUES (v_test_device_id, 'T99', 'Cloud Test Terminal', TRUE, v_token_hash, NULL)
  ON CONFLICT (id) DO UPDATE SET is_active = TRUE, device_secret_hash = v_token_hash, revoked_at = NULL;

  -- Ensure Category and Products exist
  INSERT INTO public.categories (id, name, slug, is_active)
  VALUES (v_cat_id, 'Test Cat', 'test-cat-99', TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.products (id, category_id, name, base_price, is_available)
  VALUES (v_prod1_id, v_cat_id, 'Test Pizza 1', 250.00, TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.products (id, category_id, name, base_price, is_available)
  VALUES (v_prod2_id, v_cat_id, 'Test Pizza 2', 350.00, TRUE)
  ON CONFLICT (id) DO NOTHING;

  -- Ensure Table and Open Table Session exist
  INSERT INTO public.pos_tables (id, table_number, section, capacity, is_active)
  VALUES (v_table_id, 'TEST-99', 'Main', 4, TRUE)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.table_sessions (id, table_id, guest_count, session_status, opened_at)
  VALUES (v_session_id, v_table_id, 2, 'open', NOW())
  ON CONFLICT (id) DO NOTHING;

  -- Simulate authenticated user context
  PERFORM set_config('request.jwt.claim.sub', v_test_user_id::TEXT, TRUE);

  -- 2. Test Initial Order Sync via secure_sync_pos_order
  v_res := public.secure_sync_pos_order(
    jsonb_build_object(
      'id', v_order_id,
      'order_type', 'DINE_IN',
      'table_session_id', v_session_id,
      'status', 'draft',
      'subtotal', 250.00,
      'tax_total', 12.50,
      'discount_total', 0.00,
      'delivery_charge', 0.00,
      'grand_total', 262.50,
      'channel', 'POS',
      'version', 1
    ),
    jsonb_build_array(
      jsonb_build_object(
        'id', v_item1_id,
        'order_id', v_order_id,
        'product_id', v_prod1_id,
        'product_name', 'Test Pizza 1',
        'unit_price', 250.00,
        'quantity', 1,
        'line_total', 250.00
      )
    ),
    v_test_device_id,
    v_test_device_token
  );
  IF v_res IS NOT TRUE THEN
    RAISE EXCEPTION 'secure_sync_pos_order should succeed';
  END IF;

  -- Verify initial order version = 1
  SELECT version INTO v_ver FROM public.orders WHERE id = v_order_id;
  IF v_ver != 1 THEN
    RAISE EXCEPTION 'Initial order version must be 1, found %', v_ver;
  END IF;
  RAISE NOTICE 'PASS: RPC_INITIAL_ORDER_VERSION_ONE';

  -- Verify CLOUD_CURRENT_ORDER_LINK_PASS: table_sessions.current_order_id = order.id
  SELECT current_order_id INTO v_curr_order FROM public.table_sessions WHERE id = v_session_id;
  IF v_curr_order != v_order_id THEN
    RAISE EXCEPTION 'table_sessions.current_order_id must link to initial order atomically';
  END IF;
  RAISE NOTICE 'PASS: CLOUD_CURRENT_ORDER_LINK_PASS';

  -- Verify CLOUD_SECOND_ACTIVE_ORDER_REJECT_PASS: attempting second active order for same session fails
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_sync_pos_order(
      jsonb_build_object(
        'id', v_order2_id,
        'order_type', 'DINE_IN',
        'table_session_id', v_session_id,
        'status', 'draft',
        'subtotal', 350.00,
        'tax_total', 17.50,
        'discount_total', 0.00,
        'delivery_charge', 0.00,
        'grand_total', 367.50,
        'channel', 'POS',
        'version', 1
      ),
      jsonb_build_array(
        jsonb_build_object(
          'id', gen_random_uuid(),
          'order_id', v_order2_id,
          'product_id', v_prod2_id,
          'product_name', 'Test Pizza 2',
          'unit_price', 350.00,
          'quantity', 1,
          'line_total', 350.00
        )
      ),
      v_test_device_id,
      v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%CONTRACT_CONFLICT%' THEN
      v_err_caught := TRUE;
    END IF;
  END;
  IF NOT v_err_caught THEN
    RAISE EXCEPTION 'Second active order for same session must be rejected with CONTRACT_CONFLICT';
  END IF;
  RAISE NOTICE 'PASS: CLOUD_SECOND_ACTIVE_ORDER_REJECT_PASS';

  -- Common valid items payload for tests on v_order_id
  v_valid_items := jsonb_build_array(
    jsonb_build_object(
      'id', v_item2_id,
      'order_id', v_order_id,
      'product_id', v_prod1_id,
      'product_name', 'Test Pizza 1',
      'unit_price', 250.00,
      'quantity', 1,
      'line_total', 250.00
    )
  );

  -- 3. Test Version Rules for secure_replace_pos_draft_order

  -- Test Case D: Version Gap (version 3 when current is 1)
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object(
        'id', v_order_id,
        'table_session_id', v_session_id,
        'version', 3,
        'subtotal', 350.00,
        'tax_total', 17.50,
        'discount_total', 0.00,
        'delivery_charge', 0.00,
        'grand_total', 367.50
      ),
      v_valid_items,
      v_test_device_id,
      v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%VERSION_GAP%' THEN
      v_err_caught := TRUE;
    END IF;
  END;
  IF NOT v_err_caught THEN
    RAISE EXCEPTION 'Version gap must be rejected with VERSION_GAP';
  END IF;
  RAISE NOTICE 'PASS: RPC_VERSION_GAP_REJECT_PASS';

  -- Test Case B: Same Version Different Aggregate (version 1 when current is 1 with changed subtotal)
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object(
        'id', v_order_id,
        'table_session_id', v_session_id,
        'version', 1,
        'subtotal', 999.00,
        'tax_total', 0.00,
        'discount_total', 0.00,
        'delivery_charge', 0.00,
        'grand_total', 999.00
      ),
      v_valid_items,
      v_test_device_id,
      v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%VERSION_CONFLICT%' THEN
      v_err_caught := TRUE;
    END IF;
  END;
  IF NOT v_err_caught THEN
    RAISE EXCEPTION 'Same version different aggregate must be rejected with VERSION_CONFLICT';
  END IF;
  RAISE NOTICE 'PASS: RPC_SAME_VERSION_DIFFERENT_REJECT_PASS';

  -- Test Case A: N -> N + 1 Replacement (version 1 -> 2)
  v_res := public.secure_replace_pos_draft_order(
    jsonb_build_object(
      'id', v_order_id,
      'table_session_id', v_session_id,
      'version', 2,
      'subtotal', 600.00,
      'grand_total', 630.00,
      'tax_total', 30.00,
      'discount_total', 0.00,
      'delivery_charge', 0.00
    ),
    jsonb_build_array(
      jsonb_build_object(
        'id', v_item2_id,
        'order_id', v_order_id,
        'product_id', v_prod1_id,
        'product_name', 'Test Pizza 1',
        'unit_price', 250.00,
        'quantity', 1,
        'line_total', 250.00
      ),
      jsonb_build_object(
        'id', v_item3_id,
        'order_id', v_order_id,
        'product_id', v_prod2_id,
        'product_name', 'Test Pizza 2',
        'unit_price', 350.00,
        'quantity', 1,
        'line_total', 350.00
      )
    ),
    v_test_device_id,
    v_test_device_token
  );
  IF v_res IS NOT TRUE THEN
    RAISE EXCEPTION 'Replacement 1 -> 2 must succeed';
  END IF;

  -- Verify version advanced to 2
  SELECT version INTO v_ver FROM public.orders WHERE id = v_order_id;
  IF v_ver != 2 THEN
    RAISE EXCEPTION 'Order version must advance to 2, found %', v_ver;
  END IF;

  -- Verify RPC_ITEM_REPLACEMENT_ATOMIC_PASS: old item1 deleted, item2 and item3 exist
  SELECT COUNT(*) INTO v_item_count FROM public.order_items WHERE order_id = v_order_id;
  IF v_item_count != 2 THEN
    RAISE EXCEPTION 'Order items must be exactly 2, found %', v_item_count;
  END IF;
  IF EXISTS (SELECT 1 FROM public.order_items WHERE id = v_item1_id) THEN
    RAISE EXCEPTION 'Old item1 must be deleted';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.order_items WHERE id = v_item2_id) THEN
    RAISE EXCEPTION 'New item2 must exist';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.order_items WHERE id = v_item3_id) THEN
    RAISE EXCEPTION 'New item3 must exist';
  END IF;
  RAISE NOTICE 'PASS: RPC_DRAFT_N_TO_N_PLUS_ONE_PASS and RPC_ITEM_REPLACEMENT_ATOMIC_PASS';

  -- Test Case B: Same Version Identical Retry (version 2 with exact same aggregate)
  v_res := public.secure_replace_pos_draft_order(
    jsonb_build_object(
      'id', v_order_id,
      'table_session_id', v_session_id,
      'version', 2,
      'subtotal', 600.00,
      'grand_total', 630.00,
      'tax_total', 30.00,
      'discount_total', 0.00,
      'delivery_charge', 0.00
    ),
    jsonb_build_array(
      jsonb_build_object(
        'id', v_item2_id,
        'order_id', v_order_id,
        'product_id', v_prod1_id,
        'product_name', 'Test Pizza 1',
        'unit_price', 250.00,
        'quantity', 1,
        'line_total', 250.00
      ),
      jsonb_build_object(
        'id', v_item3_id,
        'order_id', v_order_id,
        'product_id', v_prod2_id,
        'product_name', 'Test Pizza 2',
        'unit_price', 350.00,
        'quantity', 1,
        'line_total', 350.00
      )
    ),
    v_test_device_id,
    v_test_device_token
  );
  IF v_res IS NOT TRUE THEN
    RAISE EXCEPTION 'Identical version 2 retry must return TRUE without error';
  END IF;
  RAISE NOTICE 'PASS: RPC_SAME_VERSION_IDENTICAL_RETRY_PASS';

  -- Test Case C: Stale Version (version 1 when current is 2)
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object(
        'id', v_order_id,
        'table_session_id', v_session_id,
        'version', 1,
        'subtotal', 250.00,
        'tax_total', 12.50,
        'discount_total', 0.00,
        'delivery_charge', 0.00,
        'grand_total', 262.50
      ),
      v_valid_items,
      v_test_device_id,
      v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%STALE_VERSION%' THEN
      v_err_caught := TRUE;
    END IF;
  END;
  IF NOT v_err_caught THEN
    RAISE EXCEPTION 'Stale version must be rejected with STALE_VERSION';
  END IF;
  RAISE NOTICE 'PASS: RPC_STALE_VERSION_REJECT_PASS';

  -- 4. Test KOT Boundary and Status Guards

  -- Insert a KOT snapshot
  INSERT INTO public.pos_kots (id, order_id, kot_number, status, printed_at)
  VALUES (v_kot_id, v_order_id, 1, 'printed', NOW());

  INSERT INTO public.kot_items (id, kot_id, product_id, product_name, quantity)
  VALUES (gen_random_uuid(), v_kot_id, v_prod1_id, 'Test Pizza 1', 1);

  -- POST_KOT draft replace rejected
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object(
        'id', v_order_id,
        'table_session_id', v_session_id,
        'version', 3,
        'subtotal', 700.00,
        'tax_total', 35.00,
        'discount_total', 0.00,
        'delivery_charge', 0.00,
        'grand_total', 735.00
      ),
      v_valid_items,
      v_test_device_id,
      v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%CONTRACT_CONFLICT%' THEN
      v_err_caught := TRUE;
    END IF;
  END;
  IF NOT v_err_caught THEN
    RAISE EXCEPTION 'Draft replacement after KOT must be rejected with CONTRACT_CONFLICT';
  END IF;
  RAISE NOTICE 'PASS: RPC_POST_KOT_REJECT_PASS';

  -- RPC_KOT_SNAPSHOT_UNCHANGED_PASS: pos_kots and kot_items intact
  IF NOT EXISTS (SELECT 1 FROM public.pos_kots WHERE id = v_kot_id AND status = 'printed') THEN
    RAISE EXCEPTION 'KOT snapshot must remain unchanged';
  END IF;
  RAISE NOTICE 'PASS: RPC_KOT_SNAPSHOT_UNCHANGED_PASS';

  -- Test Billed, Settled, Closed, Cancelled status rejects
  DELETE FROM public.kot_items WHERE kot_id = v_kot_id;
  DELETE FROM public.pos_kots WHERE id = v_kot_id;

  -- Billed status
  UPDATE public.orders SET status = 'billed' WHERE id = v_order_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object('id', v_order_id, 'table_session_id', v_session_id, 'version', 3),
      v_valid_items, v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN v_err_caught := TRUE; END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Billed order must reject replacement'; END IF;
  RAISE NOTICE 'PASS: RPC_BILLED_REJECT_PASS';

  -- Settled status
  UPDATE public.orders SET status = 'settled' WHERE id = v_order_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object('id', v_order_id, 'table_session_id', v_session_id, 'version', 3),
      v_valid_items, v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN v_err_caught := TRUE; END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Settled order must reject replacement'; END IF;
  RAISE NOTICE 'PASS: RPC_SETTLED_REJECT_PASS';

  -- Closed status
  UPDATE public.orders SET status = 'closed' WHERE id = v_order_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object('id', v_order_id, 'table_session_id', v_session_id, 'version', 3),
      v_valid_items, v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN v_err_caught := TRUE; END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Closed order must reject replacement'; END IF;
  RAISE NOTICE 'PASS: RPC_CLOSED_REJECT_PASS';

  -- Cancelled status
  UPDATE public.orders SET status = 'cancelled' WHERE id = v_order_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object('id', v_order_id, 'table_session_id', v_session_id, 'version', 3),
      v_valid_items, v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN v_err_caught := TRUE; END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Cancelled order must reject replacement'; END IF;
  RAISE NOTICE 'PASS: RPC_CANCELLED_REJECT_PASS';

  -- 5. Test Device & Staff Authorization Guards

  -- Revoked device
  UPDATE public.pos_devices SET is_active = FALSE, revoked_at = NOW() WHERE id = v_test_device_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object('id', v_order_id, 'table_session_id', v_session_id, 'version', 3),
      v_valid_items, v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%DEVICE_REVOKED%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Revoked device must be rejected with DEVICE_REVOKED'; END IF;
  RAISE NOTICE 'PASS: RPC_REVOKED_DEVICE_REJECT_PASS';

  -- Unauthorized device (wrong token)
  UPDATE public.pos_devices SET is_active = TRUE, revoked_at = NULL WHERE id = v_test_device_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object('id', v_order_id, 'table_session_id', v_session_id, 'version', 3),
      v_valid_items, v_test_device_id, 'wrong-token'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%DEVICE_AUTH_FAILED%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Wrong device token must be rejected with DEVICE_AUTH_FAILED'; END IF;
  RAISE NOTICE 'PASS: RPC_UNAUTHORIZED_DEVICE_REJECT_PASS';

  -- Inactive staff
  UPDATE public.staff_profiles SET is_active = FALSE WHERE id = v_test_user_id;
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object('id', v_order_id, 'table_session_id', v_session_id, 'version', 3),
      v_valid_items, v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Access Denied%' OR SQLERRM LIKE '%42501%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Inactive staff must be rejected'; END IF;
  RAISE NOTICE 'PASS: RPC_INACTIVE_STAFF_REJECT_PASS';

  -- Unauthenticated user
  UPDATE public.staff_profiles SET is_active = TRUE WHERE id = v_test_user_id;
  PERFORM set_config('request.jwt.claim.sub', '', TRUE);
  v_err_caught := FALSE;
  BEGIN
    PERFORM public.secure_replace_pos_draft_order(
      jsonb_build_object('id', v_order_id, 'table_session_id', v_session_id, 'version', 3),
      v_valid_items, v_test_device_id, v_test_device_token
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Access Denied%' OR SQLERRM LIKE '%42501%' THEN v_err_caught := TRUE; END IF;
  END;
  IF NOT v_err_caught THEN RAISE EXCEPTION 'Unauthenticated user must be rejected'; END IF;
  RAISE NOTICE 'PASS: RPC_UNAUTHENTICATED_REJECT_PASS';

  -- 6. FULL FIXTURE CLEANUP
  DELETE FROM public.order_items WHERE order_id IN (v_order_id, v_order2_id);
  DELETE FROM public.orders WHERE id IN (v_order_id, v_order2_id);
  DELETE FROM public.table_sessions WHERE id = v_session_id;
  DELETE FROM public.pos_tables WHERE id = v_table_id;
  DELETE FROM public.products WHERE id IN (v_prod1_id, v_prod2_id);
  DELETE FROM public.categories WHERE id = v_cat_id;
  DELETE FROM public.pos_devices WHERE id = v_test_device_id;
  DELETE FROM public.staff_profiles WHERE id = v_test_user_id;
  DELETE FROM auth.users WHERE id = v_test_user_id;

  RAISE NOTICE '=== ALL CLOUD RPC VERIFICATION TESTS PASSED — FIXTURES 100 PERCENT CLEANED ===';
END $$;
