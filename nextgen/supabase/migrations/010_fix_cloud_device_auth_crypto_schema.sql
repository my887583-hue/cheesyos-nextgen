-- CHEESYOS NEXTGEN V1 MIGRATION: 010_fix_cloud_device_auth_crypto_schema.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: PHASE_3G_1E2_FORWARD_MIGRATION
-- Purpose: Correct hosted Supabase pgcrypto namespace (extensions.*) in device-auth SECURITY DEFINER functions.

-- ============================================================================
-- 1. REPAIR SHARED SERVER-SIDE DEVICE AUTHORIZATION HELPER
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

  -- 256-bit token SHA-256 computation using hosted Supabase extensions schema
  v_computed_hash := encode(extensions.digest(p_device_token, 'sha256'), 'hex');

  IF v_stored_hash IS NULL OR v_stored_hash != v_computed_hash THEN
    RAISE EXCEPTION 'DEVICE_AUTH_FAILED: Invalid device possession token';
  END IF;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

REVOKE EXECUTE ON FUNCTION public.assert_authorized_pos_device(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_authorized_pos_device(UUID, TEXT) TO authenticated;


-- ============================================================================
-- 2. REPAIR TRUSTED DEVICE PROVISIONING RPC
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

  -- C. Generate 256-bit CSPRNG token (32 random bytes) using hosted Supabase extensions schema
  v_raw_token := 'cb_dev_sec_' || encode(extensions.gen_random_bytes(32), 'hex');
  v_secret_hash := encode(extensions.digest(v_raw_token, 'sha256'), 'hex');
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
