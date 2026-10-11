-- CHEESYOS NEXTGEN V1 MIGRATION: 005_functions_and_triggers.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: GENERATED_NOT_APPLIED
-- Security Remediation (Phase 2C): Added explicit search_path, caller authorization, atomicity, idempotency, and privilege restrictions.

-- ============================================================================
-- 1. ATTACH UPDATED_AT TRIGGERS (USING SINGLE REUSABLE FUNCTION)
-- ============================================================================

CREATE TRIGGER trg_categories_updated_at
  BEFORE UPDATE ON public.categories
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

CREATE TRIGGER trg_products_updated_at
  BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

CREATE TRIGGER trg_customers_updated_at
  BEFORE UPDATE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

CREATE TRIGGER trg_orders_updated_at
  BEFORE UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

CREATE TRIGGER trg_inventory_lite_updated_at
  BEFORE UPDATE ON public.inventory_lite
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

CREATE TRIGGER trg_staff_profiles_updated_at
  BEFORE UPDATE ON public.staff_profiles
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();


-- ============================================================================
-- 2. ESSENTIAL SECURITY & ATOMIC OPERATIONAL RPCS
-- ============================================================================

-- RPC: Atomic & Idempotent Inventory Deduction with Audit Movement Entry
CREATE OR REPLACE FUNCTION public.secure_deduct_inventory(
  p_product_id UUID,
  p_quantity INTEGER,
  p_created_by UUID DEFAULT NULL,
  p_movement_id UUID DEFAULT gen_random_uuid()
)
RETURNS BOOLEAN AS $$
DECLARE
  v_current_stock INTEGER;
  v_is_tracked BOOLEAN;
BEGIN
  -- 1. Caller Authorization Check (Server Enforced)
  IF NOT EXISTS (
    SELECT 1 FROM public.staff_profiles 
    WHERE id = auth.uid() 
      AND (has_pos_access = true OR has_admin_access = true) 
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Access Denied: Authorized POS or Admin staff permission required for inventory deduction';
  END IF;

  -- 2. Idempotency Check: Skip duplicate retry execution
  IF EXISTS (SELECT 1 FROM public.inventory_movements WHERE id = p_movement_id) THEN
    RETURN true;
  END IF;

  -- 3. Check if inventory tracking is enabled for this product
  SELECT is_tracked, current_stock INTO v_is_tracked, v_current_stock
  FROM public.inventory_lite
  WHERE product_id = p_product_id;

  IF NOT FOUND OR v_is_tracked = false THEN
    RETURN true; -- Stock not tracked, skip deduction
  END IF;

  -- 4. Quantity Validation: Prevent negative stock if required
  IF v_current_stock - p_quantity < 0 THEN
    RAISE EXCEPTION 'Insufficient stock for product ID % (Current: %, Requested: %)', p_product_id, v_current_stock, p_quantity;
  END IF;

  -- 5. Atomic Stock Update
  UPDATE public.inventory_lite
  SET current_stock = current_stock - p_quantity,
      updated_at = NOW()
  WHERE product_id = p_product_id;

  -- 6. Insert Audit Movement Entry (Reusing p_movement_id for idempotency)
  INSERT INTO public.inventory_movements (
    id,
    product_id,
    movement_type,
    quantity_change,
    created_by,
    created_at
  ) VALUES (
    p_movement_id,
    p_product_id,
    'SALE',
    -p_quantity,
    COALESCE(p_created_by, auth.uid()),
    NOW()
  );

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Revoke default public execution & grant strictly to authenticated users
REVOKE EXECUTE ON FUNCTION public.secure_deduct_inventory(UUID, INTEGER, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.secure_deduct_inventory(UUID, INTEGER, UUID, UUID) TO authenticated;
