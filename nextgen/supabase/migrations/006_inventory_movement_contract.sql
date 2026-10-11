-- CHEESYOS NEXTGEN V1 MIGRATION: 006_inventory_movement_contract.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: PREPARED_FOR_APPLY
-- Security & Integrity Correction: Trusted Inventory Movement RPC with Over-Credit Protection, Concurrency Row Locking & Role Authorization.

-- 1. Add reference_movement_id column to inventory_movements if not exists
ALTER TABLE public.inventory_movements
  ADD COLUMN IF NOT EXISTS reference_movement_id UUID REFERENCES public.inventory_movements(id);

-- Create index for reference movement lookups
CREATE INDEX IF NOT EXISTS idx_inventory_movements_ref
  ON public.inventory_movements(reference_movement_id);

-- 2. Trusted Inventory Movement RPC covering SALE, CANCEL_RESTORE, MANUAL_ADD, MANUAL_REMOVE, ADJUSTMENT
CREATE OR REPLACE FUNCTION public.secure_apply_inventory_movement(
  p_product_id UUID,
  p_movement_type TEXT,
  p_quantity_change INTEGER,
  p_created_by UUID DEFAULT NULL,
  p_movement_id UUID DEFAULT gen_random_uuid(),
  p_reference_movement_id UUID DEFAULT NULL
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

  -- F. Check inventory tracking status with FOR UPDATE lock to prevent race conditions on concurrent SALE requests
  SELECT is_tracked, current_stock INTO v_is_tracked, v_current_stock
  FROM public.inventory_lite
  WHERE product_id = p_product_id
  FOR UPDATE;

  IF NOT FOUND OR v_is_tracked = false THEN
    RETURN true; -- Stock not tracked, skip mutation
  END IF;

  -- G. Check stock lower bound for SALE deductions
  IF p_movement_type = 'SALE' AND (v_current_stock + p_quantity_change < 0) THEN
    RAISE EXCEPTION 'Insufficient stock for product ID % (Current: %, Requested change: %)',
      p_product_id, v_current_stock, p_quantity_change;
  END IF;

  -- H. Restore Over-Credit Protection (for CANCEL_RESTORE movements)
  IF p_movement_type = 'CANCEL_RESTORE' THEN
    IF p_reference_movement_id IS NULL THEN
      RAISE EXCEPTION 'Invalid CANCEL_RESTORE movement: reference_movement_id is required';
    END IF;

    -- Verify original SALE movement and acquire row lock on original sale to serialize concurrent restore requests
    SELECT quantity_change INTO v_orig_sale_qty
    FROM public.inventory_movements
    WHERE id = p_reference_movement_id
      AND product_id = p_product_id
      AND movement_type = 'SALE'
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Invalid reference movement ID % for CANCEL_RESTORE: Sale record not found for product ID %', p_reference_movement_id, p_product_id;
    END IF;

    -- Calculate total already restored for this sale
    SELECT COALESCE(SUM(quantity_change), 0) INTO v_already_restored
    FROM public.inventory_movements
    WHERE reference_movement_id = p_reference_movement_id
      AND movement_type = 'CANCEL_RESTORE';

    IF (v_already_restored + p_quantity_change) > ABS(v_orig_sale_qty) THEN
      RAISE EXCEPTION 'Restoration Over-Credit Denied: Attempted to restore % units, but original sale deducted % units (% already restored)',
        p_quantity_change, ABS(v_orig_sale_qty), v_already_restored;
    END IF;
  END IF;

  -- I. Atomic Stock Update
  UPDATE public.inventory_lite
  SET current_stock = current_stock + p_quantity_change,
      updated_at = NOW()
  WHERE product_id = p_product_id;

  -- J. Insert Audit Movement Entry
  INSERT INTO public.inventory_movements (
    id,
    product_id,
    movement_type,
    quantity_change,
    created_by,
    reference_movement_id,
    created_at
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Revoke default public execution & grant strictly to authenticated users
REVOKE EXECUTE ON FUNCTION public.secure_apply_inventory_movement FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_apply_inventory_movement TO authenticated;

-- Compatibility Wrapper for legacy secure_deduct_inventory
CREATE OR REPLACE FUNCTION public.secure_deduct_inventory(
  p_product_id UUID,
  p_quantity INTEGER,
  p_created_by UUID DEFAULT NULL,
  p_movement_id UUID DEFAULT gen_random_uuid()
)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN public.secure_apply_inventory_movement(
    p_product_id := p_product_id,
    p_movement_type := 'SALE',
    p_quantity_change := -p_quantity,
    p_created_by := p_created_by,
    p_movement_id := p_movement_id,
    p_reference_movement_id := NULL
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

