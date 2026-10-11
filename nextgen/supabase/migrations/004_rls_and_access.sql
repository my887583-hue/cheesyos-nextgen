-- CHEESYOS NEXTGEN V1 MIGRATION: 004_rls_and_access.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: GENERATED_NOT_APPLIED
-- Security Remediation (Phase 2C): Refined RLS policies and staff profile access control.

-- ============================================================================
-- 1. ENABLE ROW LEVEL SECURITY ON ALL 20 TABLES (100% COVERAGE)
-- ============================================================================

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.table_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_kots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kot_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kot_corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bills ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_lite ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offers_banners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.spin_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.spin_redemptions ENABLE ROW LEVEL SECURITY;


-- ============================================================================
-- 2. PUBLIC & ANONYMOUS CUSTOMER READ POLICIES (WEBSITE & SMART QR MENU)
-- ============================================================================

-- Public can read active categories
CREATE POLICY "Public read active categories" ON public.categories
  FOR SELECT USING (is_active = true);

-- Public can read available products
CREATE POLICY "Public read available products" ON public.products
  FOR SELECT USING (is_available = true);

-- Public can read available variants
CREATE POLICY "Public read available variants" ON public.product_variants
  FOR SELECT USING (is_available = true);

-- Public can read active offers/banners
CREATE POLICY "Public read active banners" ON public.offers_banners
  FOR SELECT USING (is_active = true);

-- Public can read active spin campaigns
CREATE POLICY "Public read active spin campaigns" ON public.spin_campaigns
  FOR SELECT USING (is_active = true);


-- ============================================================================
-- 3. CUSTOMER SCOPED POLICIES (AUTHENTICATED CUSTOMERS: customer_id = auth.uid())
-- ============================================================================

-- Customers can view/manage their own addresses
CREATE POLICY "Customers manage own addresses" ON public.customer_addresses
  FOR ALL USING (customer_id = auth.uid());

-- Customers can view their own orders
CREATE POLICY "Customers view own orders" ON public.orders
  FOR SELECT USING (customer_id = auth.uid());

-- Customers can view items for their own orders
CREATE POLICY "Customers view own order items" ON public.order_items
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.orders WHERE orders.id = order_items.order_id AND orders.customer_id = auth.uid())
  );

-- Customers can view their own spin redemptions
CREATE POLICY "Customers view own spin redemptions" ON public.spin_redemptions
  FOR SELECT USING (customer_id = auth.uid());


-- ============================================================================
-- 4. POS STAFF POLICIES (HAS_POS_ACCESS = TRUE)
-- ============================================================================

CREATE POLICY "POS staff operational orders" ON public.orders
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_pos_access = true AND is_active = true)
  );

CREATE POLICY "POS staff order items" ON public.order_items
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_pos_access = true AND is_active = true)
  );

CREATE POLICY "POS staff tables and sessions" ON public.pos_tables
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_pos_access = true AND is_active = true)
  );

CREATE POLICY "POS staff table sessions" ON public.table_sessions
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_pos_access = true AND is_active = true)
  );

CREATE POLICY "POS staff kots" ON public.pos_kots
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_pos_access = true AND is_active = true)
  );

CREATE POLICY "POS staff kot items" ON public.kot_items
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_pos_access = true AND is_active = true)
  );

CREATE POLICY "POS staff kot corrections" ON public.kot_corrections
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_pos_access = true AND is_active = true)
  );

CREATE POLICY "POS staff bills" ON public.bills
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_pos_access = true AND is_active = true)
  );

CREATE POLICY "POS staff payments" ON public.payments
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_pos_access = true AND is_active = true)
  );

CREATE POLICY "POS staff customer lookup" ON public.customers
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_pos_access = true AND is_active = true)
  );

CREATE POLICY "POS staff inventory lite" ON public.inventory_lite
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_pos_access = true AND is_active = true)
  );

-- Staff can view their own profile row (for self identity & access check)
CREATE POLICY "Staff read own profile" ON public.staff_profiles
  FOR SELECT USING (id = auth.uid());


-- ============================================================================
-- 5. ADMIN FULL ACCESS POLICIES (HAS_ADMIN_ACCESS = TRUE)
-- ============================================================================

CREATE POLICY "Admin full manage categories" ON public.categories
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_admin_access = true AND is_active = true)
  );

CREATE POLICY "Admin full manage products" ON public.products
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_admin_access = true AND is_active = true)
  );

CREATE POLICY "Admin full manage variants" ON public.product_variants
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_admin_access = true AND is_active = true)
  );

CREATE POLICY "Admin full manage inventory movements" ON public.inventory_movements
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_admin_access = true AND is_active = true)
  );

CREATE POLICY "Admin full manage offers banners" ON public.offers_banners
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_admin_access = true AND is_active = true)
  );

CREATE POLICY "Admin full manage staff profiles" ON public.staff_profiles
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_admin_access = true AND is_active = true)
  );

CREATE POLICY "Admin full manage spin campaigns" ON public.spin_campaigns
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_admin_access = true AND is_active = true)
  );

CREATE POLICY "Admin full manage spin redemptions" ON public.spin_redemptions
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.staff_profiles WHERE id = auth.uid() AND has_admin_access = true AND is_active = true)
  );
