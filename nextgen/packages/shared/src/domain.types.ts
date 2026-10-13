/**
 * CHEESYOS NEXTGEN — CANONICAL DOMAIN TYPES
 * Shared source of truth for domain enums, bounded states, and entity interfaces.
 */

// Bounded State Union Types (Matching Deployed Database CHECK Constraints)
export type OrderChannel = 'POS' | 'WEBSITE';
export type OrderType = 'DINE_IN' | 'TAKEAWAY' | 'DELIVERY' | 'PICKUP';
export type OrderStatus = 'draft' | 'pending' | 'kot_sent' | 'billed' | 'settled' | 'cancelled' | 'closed';

export type PaymentMode = 'CASH' | 'UPI' | 'CARD' | 'OTHER';
export type PaymentStatus = 'unpaid' | 'paid' | 'partially_paid' | 'refunded';

export type KotStatus = 'printed' | 'cancelled';
export type TableSessionStatus = 'open' | 'billed' | 'closed';
export type InventoryMovementType = 'SALE' | 'CANCEL_RESTORE' | 'MANUAL_ADD' | 'MANUAL_REMOVE' | 'ADJUSTMENT';

export type BannerTargetSurface = 'WEBSITE' | 'QR_MENU' | 'BOTH';
export type BannerDiscountType = 'PERCENTAGE' | 'FLAT';
export type StaffRole = 'cashier' | 'manager' | 'admin' | 'owner';

// Primary Identifier Types
export type EntityId = string; // UUIDv4 string
export type DisplayNumber = string; // e.g. "CB-K01-000123" or "KOT-101"

// Financial Value Strategy:
// All monetary values in domain interfaces are numeric (number) rounded to 2 decimal places.
// Frontend/Core calculations must use roundMoney(val) before persisting.
export type MoneyAmount = number;
export type TaxRatePercent = number;

export function roundMoney(amount: number): MoneyAmount {
  return Math.round((amount + Number.EPSILON) * 100) / 100;
}

// Core Entity Domain Interfaces
export interface CategoryDomain {
  id: EntityId;
  name: string;
  slug: string;
  display_order: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface ProductDomain {
  id: EntityId;
  category_id: EntityId;
  name: string;
  description?: string | null;
  image_url?: string | null;
  base_price: MoneyAmount;
  is_available: boolean;
  tax_rate: TaxRatePercent;
  is_inventory_tracked: boolean;
  created_at: string;
  updated_at: string;
}

export interface ProductVariantDomain {
  id: EntityId;
  product_id: EntityId;
  variant_name: string;
  price_override?: MoneyAmount | null;
  is_available: boolean;
  created_at: string;
}

export interface CustomerDomain {
  id: EntityId;
  phone: string;
  full_name?: string | null;
  email?: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface CustomerAddressDomain {
  id: EntityId;
  customer_id: EntityId;
  address_label: string;
  street_address: string;
  city: string;
  latitude?: number | null;
  longitude?: number | null;
  is_default: boolean;
  created_at: string;
}

export interface OrderDomain {
  id: EntityId;
  display_number?: DisplayNumber | null;
  channel: OrderChannel;
  order_type: OrderType;
  customer_id?: EntityId | null;
  table_session_id?: EntityId | null;
  status: OrderStatus;
  subtotal: MoneyAmount;
  tax_total: MoneyAmount;
  discount_total: MoneyAmount;
  delivery_charge: MoneyAmount;
  grand_total: MoneyAmount;
  device_id?: string | null;
  version?: number;
  created_at: string;
  updated_at: string;
}

export interface OrderItemDomain {
  id: EntityId;
  order_id: EntityId;
  product_id: EntityId;
  variant_id?: EntityId | null;
  product_name: string;
  unit_price: MoneyAmount;
  quantity: number;
  tax_rate: TaxRatePercent;
  discount_amount: MoneyAmount;
  line_total: MoneyAmount;
  notes?: string | null;
  created_at: string;
}

export interface PosTableDomain {
  id: EntityId;
  table_number: string;
  section: string;
  capacity: number;
  is_active: boolean;
  created_at: string;
}

export interface TableSessionDomain {
  id: EntityId;
  table_id: EntityId;
  current_order_id?: EntityId | null;
  guest_count: number;
  session_status: TableSessionStatus;
  opened_at: string;
  closed_at?: string | null;
}

export interface PosKotDomain {
  id: EntityId;
  order_id: EntityId;
  kot_number: number;
  device_id?: string | null;
  status: KotStatus;
  printed_at: string;
}

export interface KotItemDomain {
  id: EntityId;
  kot_id: EntityId;
  order_item_id?: EntityId | null;
  product_id: EntityId;
  variant_id?: EntityId | null;
  product_name: string;
  quantity: number;
  notes?: string | null;
}

export interface AppendOrderItemsAndKotParams {
  order: OrderDomain;
  newItems: OrderItemDomain[];
  kot: PosKotDomain;
  kotItems: KotItemDomain[];
}

export interface AppendOrderItemsAndKotResult {
  order: OrderDomain;
  newItems: OrderItemDomain[];
  kot: PosKotDomain;
  kotItems: KotItemDomain[];
}

export interface KotCorrectionDomain {
  id: EntityId;
  order_id: EntityId;
  kot_id?: EntityId | null;
  kot_item_id?: EntityId | null;
  order_item_id?: EntityId | null;
  product_name: string;
  cancelled_qty: number;
  reason: string;
  authorized_by_staff_id: EntityId;
  created_at: string;
}

export interface ApplyKotCorrectionParams {
  correction: KotCorrectionDomain;
  updatedOrderItem: OrderItemDomain;
  updatedOrder: OrderDomain;
}

export interface ApplyKotCorrectionResult {
  correction: KotCorrectionDomain;
  updatedOrderItem: OrderItemDomain;
  updatedOrder: OrderDomain;
}

export interface BillDomain {
  id: EntityId;
  order_id: EntityId;
  bill_number: DisplayNumber;
  subtotal: MoneyAmount;
  cgst_total: MoneyAmount;
  sgst_total: MoneyAmount;
  discount_total: MoneyAmount;
  grand_total: MoneyAmount;
  payment_status: PaymentStatus;
  finalized_at: string;
  device_id?: string | null;
}

export interface PaymentDomain {
  id: EntityId;
  bill_id: EntityId;
  order_id: EntityId;
  payment_mode: PaymentMode;
  amount_paid: MoneyAmount;
  confirmed_by_staff_id?: EntityId | null;
  confirmed_at: string;
  notes?: string | null;
}

export interface InventoryLiteDomain {
  id: EntityId;
  product_id: EntityId;
  current_stock: number;
  low_stock_threshold: number;
  is_tracked: boolean;
  updated_at: string;
}

export interface InventoryMovementDomain {
  id: EntityId;
  product_id: EntityId;
  movement_type: InventoryMovementType;
  quantity_change: number;
  created_by?: EntityId | null;
  reference_movement_id?: EntityId | null;
  created_at: string;
}

export interface OffersBannerDomain {
  id: EntityId;
  title: string;
  image_url: string;
  coupon_code?: string | null;
  discount_type?: BannerDiscountType | null;
  discount_value?: MoneyAmount | null;
  min_order_value: MoneyAmount;
  target_surface: BannerTargetSurface;
  start_date?: string | null;
  end_date?: string | null;
  is_active: boolean;
  display_order: number;
  destination_product_id?: EntityId | null;
  created_at: string;
}

export interface StaffProfileDomain {
  id: EntityId; // Maps to auth.users.id
  full_name: string;
  phone?: string | null;
  role: StaffRole;
  has_pos_access: boolean;
  has_admin_access: boolean;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface SpinCampaignDomain {
  id: EntityId;
  campaign_name: string;
  start_date?: string | null;
  end_date?: string | null;
  is_active: boolean;
  prizes_json: Array<{ prize_name: string; coupon_code?: string; probability: number }>;
  created_at: string;
}

export interface SpinRedemptionDomain {
  id: EntityId;
  campaign_id: EntityId;
  customer_id?: EntityId | null;
  phone: string;
  prize_won: string;
  coupon_code?: string | null;
  is_redeemed: boolean;
  spun_at: string;
  redeemed_at?: string | null;
}

export interface PosDeviceDomain {
  id: EntityId;
  terminal_code: string;
  device_name: string;
  is_active: boolean;
  created_at: string;
  revoked_at?: string | null;
}

export interface PosDeviceConfigDomain {
  device_id: EntityId;
  terminal_code: string;
  device_name: string;
  created_at: string;
}

