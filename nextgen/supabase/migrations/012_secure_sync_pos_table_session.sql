-- CHEESYOS NEXTGEN V1 MIGRATION: 012_secure_sync_pos_table_session.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: TASK_3G_2_03B
-- Security: Device-Authorized Table Session Cloud Synchronization RPC (Option B)

-- ============================================================================
-- 1. SECURE POS TABLE SESSION SYNCHRONIZATION RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION public.secure_sync_pos_table_session(
  p_session JSONB,
  p_device_id UUID DEFAULT NULL,
  p_device_token TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_caller_id UUID;
  v_has_pos BOOLEAN;
  v_has_admin BOOLEAN;
  v_device_id UUID;
  v_session_id UUID;
  v_table_id UUID;
  v_current_order_id UUID;
  v_guest_count INTEGER;
  v_session_status TEXT;
  v_opened_at TIMESTAMPTZ;
  v_closed_at TIMESTAMPTZ;
  v_table_is_active BOOLEAN;
  v_existing RECORD;
  v_order_to_close UUID;
  v_order_status TEXT;
BEGIN
  -- A. Staff Authorization
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Access Denied: Authentication required for Table Session sync';
  END IF;

  SELECT has_pos_access, has_admin_access
  INTO v_has_pos, v_has_admin
  FROM public.staff_profiles
  WHERE id = v_caller_id AND is_active = true;

  IF NOT FOUND OR NOT (v_has_pos = true OR v_has_admin = true) THEN
    RAISE EXCEPTION 'Access Denied: POS staff permission required for Table Session sync';
  END IF;

  -- B. Resolve & Enforce Device Possession Authorization
  v_device_id := COALESCE(p_device_id, (p_session->>'device_id')::UUID);
  PERFORM public.assert_authorized_pos_device(v_device_id, p_device_token);

  -- C. Validate Canonical Payload Fields
  IF p_session IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: p_session payload is required';
  END IF;

  v_session_id := (p_session->>'id')::UUID;
  IF v_session_id IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: session id is required';
  END IF;

  v_table_id := (p_session->>'table_id')::UUID;
  IF v_table_id IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: table_id is required';
  END IF;

  v_session_status := p_session->>'session_status';
  IF v_session_status IS NULL OR v_session_status NOT IN ('open', 'billed', 'closed') THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Invalid session_status (received: %)', v_session_status;
  END IF;

  v_guest_count := COALESCE((p_session->>'guest_count')::INTEGER, 1);
  IF v_guest_count <= 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: guest_count must be greater than 0 (received: %)', v_guest_count;
  END IF;

  v_opened_at := (p_session->>'opened_at')::TIMESTAMPTZ;
  IF v_opened_at IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: opened_at timestamp is required';
  END IF;

  v_closed_at := (p_session->>'closed_at')::TIMESTAMPTZ;
  v_current_order_id := COALESCE(
    (p_session->>'current_order_id')::UUID,
    (p_session->>'order_id')::UUID
  );

  -- D. Validate Referenced Table
  SELECT is_active INTO v_table_is_active
  FROM public.pos_tables
  WHERE id = v_table_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: pos_table % does not exist', v_table_id;
  END IF;

  IF v_table_is_active = false THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: pos_table % is not active', v_table_id;
  END IF;

  -- E. Query Existing Session for Idempotency and Monotonicity Checks
  SELECT id, table_id, current_order_id, guest_count, session_status, opened_at, closed_at
  INTO v_existing
  FROM public.table_sessions
  WHERE id = v_session_id;

  IF NOT FOUND THEN
    -- First submission: Insert Canonical Session Snapshot
    INSERT INTO public.table_sessions (
      id, table_id, current_order_id, guest_count, session_status, opened_at, closed_at
    ) VALUES (
      v_session_id,
      v_table_id,
      v_current_order_id,
      v_guest_count,
      v_session_status,
      v_opened_at,
      v_closed_at
    );

    -- If closed session arrives with linked order, advance settled order to closed
    IF v_session_status = 'closed' AND v_current_order_id IS NOT NULL THEN
      UPDATE public.orders
      SET status = 'closed', updated_at = NOW()
      WHERE id = v_current_order_id AND status = 'settled';
    END IF;

    RETURN true;
  END IF;

  -- F. Existing Record: Validate Immutable Identity Attributes
  IF v_existing.table_id != v_table_id THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: Table session % table_id % does not match existing %',
      v_session_id, v_table_id, v_existing.table_id;
  END IF;

  IF date_trunc('second', v_existing.opened_at) != date_trunc('second', v_opened_at) THEN
    RAISE EXCEPTION 'CONTRACT_CONFLICT: Table session % opened_at does not match existing', v_session_id;
  END IF;

  -- G. Lifecycle Monotonicity Enforcement (open -> billed -> closed)
  IF v_existing.session_status = 'closed' THEN
    IF v_session_status = 'closed' THEN
      -- Idempotent retry of closed session
      RETURN true;
    ELSE
      RAISE EXCEPTION 'CONTRACT_CONFLICT: Cannot transition closed session % back to %',
        v_session_id, v_session_status;
    END IF;
  ELSIF v_existing.session_status = 'billed' THEN
    IF v_session_status = 'open' THEN
      RAISE EXCEPTION 'CONTRACT_CONFLICT: Cannot transition billed session % back to open', v_session_id;
    ELSIF v_session_status = 'billed' THEN
      -- Idempotent retry of billed session
      RETURN true;
    END IF;
    -- billed -> closed is permitted forward transition
  ELSIF v_existing.session_status = 'open' THEN
    IF v_session_status = 'open' THEN
      -- Idempotent retry: update current_order_id if newly bound
      IF v_current_order_id IS NOT NULL AND v_existing.current_order_id IS NULL THEN
        UPDATE public.table_sessions
        SET current_order_id = v_current_order_id
        WHERE id = v_session_id;
      END IF;
      RETURN true;
    END IF;
    -- open -> billed or open -> closed are permitted forward transitions
  END IF;

  -- H. Canonical Forward State Transition
  UPDATE public.table_sessions
  SET session_status = v_session_status,
      current_order_id = COALESCE(v_current_order_id, v_existing.current_order_id),
      guest_count = COALESCE(v_guest_count, v_existing.guest_count),
      closed_at = CASE
        WHEN v_session_status = 'closed' THEN COALESCE(v_closed_at, v_existing.closed_at, NOW())
        ELSE v_existing.closed_at
      END
  WHERE id = v_session_id;

  -- I. Authoritative Order Settlement Closure on Session Close
  IF v_session_status = 'closed' THEN
    v_order_to_close := COALESCE(v_current_order_id, v_existing.current_order_id);
    IF v_order_to_close IS NOT NULL THEN
      SELECT status INTO v_order_status
      FROM public.orders
      WHERE id = v_order_to_close;

      IF FOUND THEN
        IF v_order_status = 'settled' THEN
          UPDATE public.orders
          SET status = 'closed', updated_at = NOW()
          WHERE id = v_order_to_close;
        ELSIF v_order_status = 'closed' THEN
          -- Already closed, idempotent no-op
          NULL;
        ELSE
          RAISE EXCEPTION 'CONTRACT_CONFLICT: Cannot close session % linked order % in status % (must be settled)',
            v_session_id, v_order_to_close, v_order_status;
        END IF;
      END IF;
    END IF;
  END IF;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.secure_sync_pos_table_session(JSONB, UUID, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.secure_sync_pos_table_session(JSONB, UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.secure_sync_pos_table_session(JSONB, UUID, TEXT) TO authenticated;
