-- CHEESYOS NEXTGEN V1 MIGRATION: 003_constraints_and_indexes.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: GENERATED_NOT_APPLIED

-- ============================================================================
-- FOREIGN KEY CONSTRAINTS (OPERATIONAL SAFETY: PRESERVE HISTORICAL RECORDS)
-- ============================================================================

-- PRODUCTS -> CATEGORIES
ALTER TABLE ONLY public.products
  ADD CONSTRAINT fk_products_category FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE RESTRICT;

-- PRODUCT VARIANTS -> PRODUCTS
ALTER TABLE ONLY public.product_variants
  ADD CONSTRAINT fk_product_variants_product FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;

-- CUSTOMER ADDRESSES -> CUSTOMERS
ALTER TABLE ONLY public.customer_addresses
  ADD CONSTRAINT fk_customer_addresses_customer FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;

-- ORDERS -> CUSTOMERS & TABLE SESSIONS
ALTER TABLE ONLY public.orders
  ADD CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL,
  ADD CONSTRAINT fk_orders_table_session FOREIGN KEY (table_session_id) REFERENCES public.table_sessions(id) ON DELETE SET NULL;

-- ORDER ITEMS -> ORDERS, PRODUCTS, VARIANTS
ALTER TABLE ONLY public.order_items
  ADD CONSTRAINT fk_order_items_order FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_order_items_product FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_order_items_variant FOREIGN KEY (variant_id) REFERENCES public.product_variants(id) ON DELETE SET NULL;

-- TABLE SESSIONS -> POS TABLES & ORDERS
ALTER TABLE ONLY public.table_sessions
  ADD CONSTRAINT fk_table_sessions_table FOREIGN KEY (table_id) REFERENCES public.pos_tables(id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_table_sessions_order FOREIGN KEY (current_order_id) REFERENCES public.orders(id) ON DELETE SET NULL;

-- POS KOTS -> ORDERS
ALTER TABLE ONLY public.pos_kots
  ADD CONSTRAINT fk_pos_kots_order FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;

-- KOT ITEMS -> POS KOTS, PRODUCTS, VARIANTS
ALTER TABLE ONLY public.kot_items
  ADD CONSTRAINT fk_kot_items_kot FOREIGN KEY (kot_id) REFERENCES public.pos_kots(id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_kot_items_product FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_kot_items_variant FOREIGN KEY (variant_id) REFERENCES public.product_variants(id) ON DELETE SET NULL;

-- KOT CORRECTIONS -> ORDERS, POS KOTS, STAFF PROFILES
ALTER TABLE ONLY public.kot_corrections
  ADD CONSTRAINT fk_kot_corrections_order FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_kot_corrections_kot FOREIGN KEY (kot_id) REFERENCES public.pos_kots(id) ON DELETE SET NULL,
  ADD CONSTRAINT fk_kot_corrections_staff FOREIGN KEY (authorized_by_staff_id) REFERENCES public.staff_profiles(id) ON DELETE RESTRICT;

-- BILLS -> ORDERS
ALTER TABLE ONLY public.bills
  ADD CONSTRAINT fk_bills_order FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE RESTRICT;

-- PAYMENTS -> BILLS, ORDERS, STAFF PROFILES
ALTER TABLE ONLY public.payments
  ADD CONSTRAINT fk_payments_bill FOREIGN KEY (bill_id) REFERENCES public.bills(id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_payments_order FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_payments_staff FOREIGN KEY (confirmed_by_staff_id) REFERENCES public.staff_profiles(id) ON DELETE SET NULL;

-- INVENTORY LITE -> PRODUCTS
ALTER TABLE ONLY public.inventory_lite
  ADD CONSTRAINT fk_inventory_lite_product FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;

-- INVENTORY MOVEMENTS -> PRODUCTS & STAFF
ALTER TABLE ONLY public.inventory_movements
  ADD CONSTRAINT fk_inventory_movements_product FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_inventory_movements_staff FOREIGN KEY (created_by) REFERENCES public.staff_profiles(id) ON DELETE SET NULL;

-- OFFERS BANNERS -> PRODUCTS
ALTER TABLE ONLY public.offers_banners
  ADD CONSTRAINT fk_offers_banners_product FOREIGN KEY (destination_product_id) REFERENCES public.products(id) ON DELETE SET NULL;

-- SPIN REDEMPTIONS -> CAMPAIGNS & CUSTOMERS
ALTER TABLE ONLY public.spin_redemptions
  ADD CONSTRAINT fk_spin_redemptions_campaign FOREIGN KEY (campaign_id) REFERENCES public.spin_campaigns(id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_spin_redemptions_customer FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;


-- ============================================================================
-- PERFORMANCE INDEXES (OPTIMIZED FOR V1 ACCESS PATHS ONLY)
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_products_category_id ON public.products(category_id);
CREATE INDEX IF NOT EXISTS idx_product_variants_product_id ON public.product_variants(product_id);
CREATE INDEX IF NOT EXISTS idx_customers_phone ON public.customers(phone);
CREATE INDEX IF NOT EXISTS idx_customer_addresses_customer_id ON public.customer_addresses(customer_id);

CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON public.orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_channel_status ON public.orders(channel, status);
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON public.orders(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON public.order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_table_sessions_table_status ON public.table_sessions(table_id, session_status);

CREATE INDEX IF NOT EXISTS idx_pos_kots_order_id ON public.pos_kots(order_id);
CREATE INDEX IF NOT EXISTS idx_kot_items_kot_id ON public.kot_items(kot_id);
CREATE INDEX IF NOT EXISTS idx_kot_corrections_order_id ON public.kot_corrections(order_id);

CREATE INDEX IF NOT EXISTS idx_bills_order_id ON public.bills(order_id);
CREATE INDEX IF NOT EXISTS idx_payments_bill_id ON public.payments(bill_id);
CREATE INDEX IF NOT EXISTS idx_payments_order_id ON public.payments(order_id);

CREATE INDEX IF NOT EXISTS idx_inventory_lite_product_id ON public.inventory_lite(product_id);
CREATE INDEX IF NOT EXISTS idx_inventory_movements_product_date ON public.inventory_movements(product_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_offers_banners_active_surface ON public.offers_banners(is_active, target_surface);
CREATE INDEX IF NOT EXISTS idx_staff_profiles_role_access ON public.staff_profiles(role, has_pos_access, has_admin_access);
CREATE INDEX IF NOT EXISTS idx_spin_redemptions_customer ON public.spin_redemptions(customer_id, phone);
