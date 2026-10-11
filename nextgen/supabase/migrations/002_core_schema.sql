-- CHEESYOS NEXTGEN V1 MIGRATION: 002_core_schema.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: GENERATED_NOT_APPLIED

-- 1. CATEGORIES
CREATE TABLE IF NOT EXISTS public.categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  display_order INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 2. PRODUCTS
CREATE TABLE IF NOT EXISTS public.products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id UUID NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  image_url TEXT,
  base_price NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (base_price >= 0),
  is_available BOOLEAN DEFAULT true,
  tax_rate NUMERIC(5,2) DEFAULT 5.00 CHECK (tax_rate >= 0),
  is_inventory_tracked BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 3. PRODUCT VARIANTS
CREATE TABLE IF NOT EXISTS public.product_variants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL,
  variant_name TEXT NOT NULL,
  price_override NUMERIC(10,2) CHECK (price_override >= 0),
  is_available BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 4. CUSTOMERS
CREATE TABLE IF NOT EXISTS public.customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone TEXT NOT NULL UNIQUE,
  full_name TEXT,
  email TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 5. CUSTOMER ADDRESSES
CREATE TABLE IF NOT EXISTS public.customer_addresses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL,
  address_label TEXT DEFAULT 'Home',
  street_address TEXT NOT NULL,
  city TEXT DEFAULT 'Mohali',
  latitude NUMERIC(10,8),
  longitude NUMERIC(11,8),
  is_default BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 6. ORDERS
CREATE TABLE IF NOT EXISTS public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  display_number TEXT,
  channel TEXT NOT NULL CHECK (channel IN ('POS', 'WEBSITE')),
  order_type TEXT NOT NULL CHECK (order_type IN ('DINE_IN', 'TAKEAWAY', 'DELIVERY', 'PICKUP')),
  customer_id UUID,
  table_session_id UUID,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending', 'kot_sent', 'billed', 'settled', 'cancelled', 'closed')),
  subtotal NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (subtotal >= 0),
  tax_total NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (tax_total >= 0),
  discount_total NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (discount_total >= 0),
  delivery_charge NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (delivery_charge >= 0),
  grand_total NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (grand_total >= 0),
  device_id TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 7. ORDER ITEMS
CREATE TABLE IF NOT EXISTS public.order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL,
  product_id UUID NOT NULL,
  variant_id UUID,
  product_name TEXT NOT NULL,
  unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  tax_rate NUMERIC(5,2) DEFAULT 5.00 CHECK (tax_rate >= 0),
  discount_amount NUMERIC(10,2) DEFAULT 0.00 CHECK (discount_amount >= 0),
  line_total NUMERIC(10,2) NOT NULL CHECK (line_total >= 0),
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 8. POS TABLES
CREATE TABLE IF NOT EXISTS public.pos_tables (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_number TEXT NOT NULL UNIQUE,
  section TEXT DEFAULT 'Main Floor',
  capacity INTEGER DEFAULT 4 CHECK (capacity > 0),
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 9. TABLE SESSIONS
CREATE TABLE IF NOT EXISTS public.table_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_id UUID NOT NULL,
  current_order_id UUID,
  guest_count INTEGER DEFAULT 1 CHECK (guest_count > 0),
  session_status TEXT NOT NULL DEFAULT 'open' CHECK (session_status IN ('open', 'billed', 'closed')),
  opened_at TIMESTAMPTZ DEFAULT now(),
  closed_at TIMESTAMPTZ
);

-- 10. POS KOTS
CREATE TABLE IF NOT EXISTS public.pos_kots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL,
  kot_number INTEGER NOT NULL,
  device_id TEXT,
  status TEXT NOT NULL DEFAULT 'printed' CHECK (status IN ('printed', 'cancelled')),
  printed_at TIMESTAMPTZ DEFAULT now()
);

-- 11. KOT ITEMS
CREATE TABLE IF NOT EXISTS public.kot_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kot_id UUID NOT NULL,
  product_id UUID NOT NULL,
  variant_id UUID,
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  notes TEXT
);

-- 12. KOT CORRECTIONS
CREATE TABLE IF NOT EXISTS public.kot_corrections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL,
  kot_id UUID,
  product_name TEXT NOT NULL,
  cancelled_qty INTEGER NOT NULL CHECK (cancelled_qty > 0),
  reason TEXT NOT NULL,
  authorized_by_staff_id UUID NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 13. BILLS
CREATE TABLE IF NOT EXISTS public.bills (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL UNIQUE,
  bill_number TEXT NOT NULL UNIQUE,
  subtotal NUMERIC(10,2) NOT NULL CHECK (subtotal >= 0),
  cgst_total NUMERIC(10,2) NOT NULL CHECK (cgst_total >= 0),
  sgst_total NUMERIC(10,2) NOT NULL CHECK (sgst_total >= 0),
  discount_total NUMERIC(10,2) DEFAULT 0.00 CHECK (discount_total >= 0),
  grand_total NUMERIC(10,2) NOT NULL CHECK (grand_total >= 0),
  payment_status TEXT NOT NULL DEFAULT 'unpaid' CHECK (payment_status IN ('unpaid', 'paid', 'partially_paid', 'refunded')),
  finalized_at TIMESTAMPTZ DEFAULT now(),
  device_id TEXT
);

-- 14. PAYMENTS
CREATE TABLE IF NOT EXISTS public.payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bill_id UUID NOT NULL,
  order_id UUID NOT NULL,
  payment_mode TEXT NOT NULL CHECK (payment_mode IN ('CASH', 'UPI', 'CARD', 'OTHER')),
  amount_paid NUMERIC(10,2) NOT NULL CHECK (amount_paid > 0),
  confirmed_by_staff_id UUID,
  confirmed_at TIMESTAMPTZ DEFAULT now(),
  notes TEXT
);

-- 15. INVENTORY LITE
CREATE TABLE IF NOT EXISTS public.inventory_lite (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL UNIQUE,
  current_stock INTEGER NOT NULL DEFAULT 0,
  low_stock_threshold INTEGER DEFAULT 5,
  is_tracked BOOLEAN DEFAULT true,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 16. INVENTORY MOVEMENTS
CREATE TABLE IF NOT EXISTS public.inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL,
  movement_type TEXT NOT NULL CHECK (movement_type IN ('SALE', 'CANCEL_RESTORE', 'MANUAL_ADD', 'MANUAL_REMOVE', 'ADJUSTMENT')),
  quantity_change INTEGER NOT NULL,
  created_by UUID,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 17. OFFERS BANNERS
CREATE TABLE IF NOT EXISTS public.offers_banners (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  image_url TEXT NOT NULL,
  coupon_code TEXT,
  discount_type TEXT CHECK (discount_type IN ('PERCENTAGE', 'FLAT')),
  discount_value NUMERIC(10,2) CHECK (discount_value >= 0),
  min_order_value NUMERIC(10,2) DEFAULT 0.00,
  target_surface TEXT NOT NULL DEFAULT 'BOTH' CHECK (target_surface IN ('WEBSITE', 'QR_MENU', 'BOTH')),
  start_date TIMESTAMPTZ,
  end_date TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT true,
  display_order INTEGER DEFAULT 0,
  destination_product_id UUID,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 18. STAFF PROFILES
CREATE TABLE IF NOT EXISTS public.staff_profiles (
  id UUID PRIMARY KEY, -- Maps directly to auth.users.id
  full_name TEXT NOT NULL,
  phone TEXT,
  role TEXT NOT NULL DEFAULT 'cashier' CHECK (role IN ('cashier', 'manager', 'admin', 'owner')),
  has_pos_access BOOLEAN DEFAULT true,
  has_admin_access BOOLEAN DEFAULT false,
  offline_pin_hash TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 19. SPIN CAMPAIGNS
CREATE TABLE IF NOT EXISTS public.spin_campaigns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_name TEXT NOT NULL,
  start_date TIMESTAMPTZ,
  end_date TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT true,
  prizes_json JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 20. SPIN REDEMPTIONS
CREATE TABLE IF NOT EXISTS public.spin_redemptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id UUID NOT NULL,
  customer_id UUID,
  phone TEXT NOT NULL,
  prize_won TEXT NOT NULL,
  coupon_code TEXT,
  is_redeemed BOOLEAN DEFAULT false,
  spun_at TIMESTAMPTZ DEFAULT now(),
  redeemed_at TIMESTAMPTZ
);
