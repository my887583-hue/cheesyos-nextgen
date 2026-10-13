/**
 * CHEESYOS NEXTGEN — DATABASE CONTRACT TYPES
 * Strongly typed representation of the 20 canonical public schema tables and RPCs
 * in NextGen Supabase Database (Project: sdbnibyzqtgpbexlznat).
 */

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export interface Database {
  public: {
    Tables: {
      categories: {
        Row: {
          id: string;
          name: string;
          slug: string;
          display_order: number;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          name: string;
          slug: string;
          display_order?: number;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          name?: string;
          slug?: string;
          display_order?: number;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [];
      };

      products: {
        Row: {
          id: string;
          category_id: string;
          name: string;
          description: string | null;
          image_url: string | null;
          base_price: number;
          is_available: boolean;
          tax_rate: number;
          is_inventory_tracked: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          category_id: string;
          name: string;
          description?: string | null;
          image_url?: string | null;
          base_price?: number;
          is_available?: boolean;
          tax_rate?: number;
          is_inventory_tracked?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          category_id?: string;
          name?: string;
          description?: string | null;
          image_url?: string | null;
          base_price?: number;
          is_available?: boolean;
          tax_rate?: number;
          is_inventory_tracked?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_products_category';
            columns: ['category_id'];
            isOneToOne: false;
            referencedRelation: 'categories';
            referencedColumns: ['id'];
          }
        ];
      };

      product_variants: {
        Row: {
          id: string;
          product_id: string;
          variant_name: string;
          price_override: number | null;
          is_available: boolean;
          created_at: string;
        };
        Insert: {
          id?: string;
          product_id: string;
          variant_name: string;
          price_override?: number | null;
          is_available?: boolean;
          created_at?: string;
        };
        Update: {
          id?: string;
          product_id?: string;
          variant_name?: string;
          price_override?: number | null;
          is_available?: boolean;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_variants_product';
            columns: ['product_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id'];
          }
        ];
      };

      customers: {
        Row: {
          id: string;
          phone: string;
          full_name: string | null;
          email: string | null;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          phone: string;
          full_name?: string | null;
          email?: string | null;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          phone?: string;
          full_name?: string | null;
          email?: string | null;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [];
      };

      customer_addresses: {
        Row: {
          id: string;
          customer_id: string;
          address_label: string;
          street_address: string;
          city: string;
          latitude: number | null;
          longitude: number | null;
          is_default: boolean;
          created_at: string;
        };
        Insert: {
          id?: string;
          customer_id: string;
          address_label?: string;
          street_address: string;
          city?: string;
          latitude?: number | null;
          longitude?: number | null;
          is_default?: boolean;
          created_at?: string;
        };
        Update: {
          id?: string;
          customer_id?: string;
          address_label?: string;
          street_address?: string;
          city?: string;
          latitude?: number | null;
          longitude?: number | null;
          is_default?: boolean;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_customer_addresses_customer';
            columns: ['customer_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id'];
          }
        ];
      };

      orders: {
        Row: {
          id: string;
          display_number: string | null;
          channel: 'POS' | 'WEBSITE';
          order_type: 'DINE_IN' | 'TAKEAWAY' | 'DELIVERY' | 'PICKUP';
          customer_id: string | null;
          table_session_id: string | null;
          status: 'draft' | 'pending' | 'kot_sent' | 'billed' | 'settled' | 'cancelled' | 'closed';
          subtotal: number;
          tax_total: number;
          discount_total: number;
          delivery_charge: number;
          grand_total: number;
          device_id: string | null;
          version: number;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          display_number?: string | null;
          channel: 'POS' | 'WEBSITE';
          order_type: 'DINE_IN' | 'TAKEAWAY' | 'DELIVERY' | 'PICKUP';
          customer_id?: string | null;
          table_session_id?: string | null;
          status?: 'draft' | 'pending' | 'kot_sent' | 'billed' | 'settled' | 'cancelled' | 'closed';
          subtotal?: number;
          tax_total?: number;
          discount_total?: number;
          delivery_charge?: number;
          grand_total?: number;
          device_id?: string | null;
          version?: number;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          display_number?: string | null;
          channel?: 'POS' | 'WEBSITE';
          order_type?: 'DINE_IN' | 'TAKEAWAY' | 'DELIVERY' | 'PICKUP';
          customer_id?: string | null;
          table_session_id?: string | null;
          status?: 'draft' | 'pending' | 'kot_sent' | 'billed' | 'settled' | 'cancelled' | 'closed';
          subtotal?: number;
          tax_total?: number;
          discount_total?: number;
          delivery_charge?: number;
          grand_total?: number;
          device_id?: string | null;
          version?: number;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_orders_customer';
            columns: ['customer_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fk_orders_table_session';
            columns: ['table_session_id'];
            isOneToOne: false;
            referencedRelation: 'table_sessions';
            referencedColumns: ['id'];
          }
        ];
      };

      order_items: {
        Row: {
          id: string;
          order_id: string;
          product_id: string;
          variant_id: string | null;
          product_name: string;
          unit_price: number;
          quantity: number;
          tax_rate: number;
          discount_amount: number;
          line_total: number;
          notes: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          order_id: string;
          product_id: string;
          variant_id?: string | null;
          product_name: string;
          unit_price: number;
          quantity: number;
          tax_rate?: number;
          discount_amount?: number;
          line_total: number;
          notes?: string | null;
          created_at?: string;
        };
        Update: {
          id?: string;
          order_id?: string;
          product_id?: string;
          variant_id?: string | null;
          product_name?: string;
          unit_price?: number;
          quantity?: number;
          tax_rate?: number;
          discount_amount?: number;
          line_total?: number;
          notes?: string | null;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_order_items_order';
            columns: ['order_id'];
            isOneToOne: false;
            referencedRelation: 'orders';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fk_order_items_product';
            columns: ['product_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fk_order_items_variant';
            columns: ['variant_id'];
            isOneToOne: false;
            referencedRelation: 'product_variants';
            referencedColumns: ['id'];
          }
        ];
      };

      pos_tables: {
        Row: {
          id: string;
          table_number: string;
          section: string;
          capacity: number;
          is_active: boolean;
          created_at: string;
        };
        Insert: {
          id?: string;
          table_number: string;
          section?: string;
          capacity?: number;
          is_active?: boolean;
          created_at?: string;
        };
        Update: {
          id?: string;
          table_number?: string;
          section?: string;
          capacity?: number;
          is_active?: boolean;
          created_at?: string;
        };
        Relationships: [];
      };

      table_sessions: {
        Row: {
          id: string;
          table_id: string;
          current_order_id: string | null;
          guest_count: number;
          session_status: 'open' | 'billed' | 'closed';
          opened_at: string;
          closed_at: string | null;
        };
        Insert: {
          id?: string;
          table_id: string;
          current_order_id?: string | null;
          guest_count?: number;
          session_status?: 'open' | 'billed' | 'closed';
          opened_at?: string;
          closed_at?: string | null;
        };
        Update: {
          id?: string;
          table_id?: string;
          current_order_id?: string | null;
          guest_count?: number;
          session_status?: 'open' | 'billed' | 'closed';
          opened_at?: string;
          closed_at?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_table_sessions_table';
            columns: ['table_id'];
            isOneToOne: false;
            referencedRelation: 'pos_tables';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fk_table_sessions_order';
            columns: ['current_order_id'];
            isOneToOne: false;
            referencedRelation: 'orders';
            referencedColumns: ['id'];
          }
        ];
      };

      pos_kots: {
        Row: {
          id: string;
          order_id: string;
          kot_number: number;
          device_id: string | null;
          status: 'printed' | 'cancelled';
          printed_at: string;
        };
        Insert: {
          id?: string;
          order_id: string;
          kot_number: number;
          device_id?: string | null;
          status?: 'printed' | 'cancelled';
          printed_at?: string;
        };
        Update: {
          id?: string;
          order_id?: string;
          kot_number?: number;
          device_id?: string | null;
          status?: 'printed' | 'cancelled';
          printed_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_kots_order';
            columns: ['order_id'];
            isOneToOne: false;
            referencedRelation: 'orders';
            referencedColumns: ['id'];
          }
        ];
      };

      kot_items: {
        Row: {
          id: string;
          kot_id: string;
          order_item_id: string | null;
          product_id: string;
          variant_id: string | null;
          product_name: string;
          quantity: number;
          notes: string | null;
        };
        Insert: {
          id?: string;
          kot_id: string;
          order_item_id?: string | null;
          product_id: string;
          variant_id?: string | null;
          product_name: string;
          quantity: number;
          notes?: string | null;
        };
        Update: {
          id?: string;
          kot_id?: string;
          order_item_id?: string | null;
          product_id?: string;
          variant_id?: string | null;
          product_name?: string;
          quantity?: number;
          notes?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_kot_items_kot';
            columns: ['kot_id'];
            isOneToOne: false;
            referencedRelation: 'pos_kots';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fk_kot_items_product';
            columns: ['product_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fk_kot_items_variant';
            columns: ['variant_id'];
            isOneToOne: false;
            referencedRelation: 'product_variants';
            referencedColumns: ['id'];
          }
        ];
      };

      kot_corrections: {
        Row: {
          id: string;
          order_id: string;
          kot_id: string | null;
          kot_item_id: string | null;
          order_item_id: string | null;
          product_name: string;
          cancelled_qty: number;
          reason: string;
          authorized_by_staff_id: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          order_id: string;
          kot_id?: string | null;
          kot_item_id?: string | null;
          order_item_id?: string | null;
          product_name: string;
          cancelled_qty: number;
          reason: string;
          authorized_by_staff_id: string;
          created_at?: string;
        };
        Update: {
          id?: string;
          order_id?: string;
          kot_id?: string | null;
          kot_item_id?: string | null;
          order_item_id?: string | null;
          product_name?: string;
          cancelled_qty?: number;
          reason?: string;
          authorized_by_staff_id?: string;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_kot_corrections_order';
            columns: ['order_id'];
            isOneToOne: false;
            referencedRelation: 'orders';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fk_kot_corrections_kot';
            columns: ['kot_id'];
            isOneToOne: false;
            referencedRelation: 'pos_kots';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fk_kot_corrections_staff';
            columns: ['authorized_by_staff_id'];
            isOneToOne: false;
            referencedRelation: 'staff_profiles';
            referencedColumns: ['id'];
          }
        ];
      };

      bills: {
        Row: {
          id: string;
          order_id: string;
          bill_number: string;
          subtotal: number;
          cgst_total: number;
          sgst_total: number;
          discount_total: number;
          grand_total: number;
          payment_status: 'unpaid' | 'paid' | 'partially_paid' | 'refunded';
          finalized_at: string;
          device_id: string | null;
        };
        Insert: {
          id?: string;
          order_id: string;
          bill_number: string;
          subtotal: number;
          cgst_total: number;
          sgst_total: number;
          discount_total?: number;
          grand_total: number;
          payment_status?: 'unpaid' | 'paid' | 'partially_paid' | 'refunded';
          finalized_at?: string;
          device_id?: string | null;
        };
        Update: {
          id?: string;
          order_id?: string;
          bill_number?: string;
          subtotal?: number;
          cgst_total?: number;
          sgst_total?: number;
          discount_total?: number;
          grand_total?: number;
          payment_status?: 'unpaid' | 'paid' | 'partially_paid' | 'refunded';
          finalized_at?: string;
          device_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_bills_order';
            columns: ['order_id'];
            isOneToOne: true;
            referencedRelation: 'orders';
            referencedColumns: ['id'];
          }
        ];
      };

      payments: {
        Row: {
          id: string;
          bill_id: string;
          order_id: string;
          payment_mode: 'CASH' | 'UPI' | 'CARD' | 'OTHER';
          amount_paid: number;
          confirmed_by_staff_id: string | null;
          confirmed_at: string;
          notes: string | null;
        };
        Insert: {
          id?: string;
          bill_id: string;
          order_id: string;
          payment_mode: 'CASH' | 'UPI' | 'CARD' | 'OTHER';
          amount_paid: number;
          confirmed_by_staff_id?: string | null;
          confirmed_at?: string;
          notes?: string | null;
        };
        Update: {
          id?: string;
          bill_id?: string;
          order_id?: string;
          payment_mode?: 'CASH' | 'UPI' | 'CARD' | 'OTHER';
          amount_paid?: number;
          confirmed_by_staff_id?: string | null;
          confirmed_at?: string;
          notes?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_payments_bill';
            columns: ['bill_id'];
            isOneToOne: false;
            referencedRelation: 'bills';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fk_payments_order';
            columns: ['order_id'];
            isOneToOne: false;
            referencedRelation: 'orders';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fk_payments_staff';
            columns: ['confirmed_by_staff_id'];
            isOneToOne: false;
            referencedRelation: 'staff_profiles';
            referencedColumns: ['id'];
          }
        ];
      };

      inventory_lite: {
        Row: {
          id: string;
          product_id: string;
          current_stock: number;
          low_stock_threshold: number;
          is_tracked: boolean;
          updated_at: string;
        };
        Insert: {
          id?: string;
          product_id: string;
          current_stock?: number;
          low_stock_threshold?: number;
          is_tracked?: boolean;
          updated_at?: string;
        };
        Update: {
          id?: string;
          product_id?: string;
          current_stock?: number;
          low_stock_threshold?: number;
          is_tracked?: boolean;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_inventory_lite_product';
            columns: ['product_id'];
            isOneToOne: true;
            referencedRelation: 'products';
            referencedColumns: ['id'];
          }
        ];
      };

      inventory_movements: {
        Row: {
          id: string;
          product_id: string;
          movement_type: 'SALE' | 'CANCEL_RESTORE' | 'MANUAL_ADD' | 'MANUAL_REMOVE' | 'ADJUSTMENT';
          quantity_change: number;
          created_by: string | null;
          reference_movement_id: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          product_id: string;
          movement_type: 'SALE' | 'CANCEL_RESTORE' | 'MANUAL_ADD' | 'MANUAL_REMOVE' | 'ADJUSTMENT';
          quantity_change: number;
          created_by?: string | null;
          reference_movement_id?: string | null;
          created_at?: string;
        };
        Update: {
          id?: string;
          product_id?: string;
          movement_type?: 'SALE' | 'CANCEL_RESTORE' | 'MANUAL_ADD' | 'MANUAL_REMOVE' | 'ADJUSTMENT';
          quantity_change?: number;
          created_by?: string | null;
          reference_movement_id?: string | null;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_inventory_movements_product';
            columns: ['product_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id'];
          }
        ];
      };

      offers_banners: {
        Row: {
          id: string;
          title: string;
          image_url: string;
          coupon_code: string | null;
          discount_type: 'PERCENTAGE' | 'FLAT' | null;
          discount_value: number | null;
          min_order_value: number;
          target_surface: 'WEBSITE' | 'QR_MENU' | 'BOTH';
          start_date: string | null;
          end_date: string | null;
          is_active: boolean;
          display_order: number;
          destination_product_id: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          title: string;
          image_url: string;
          coupon_code?: string | null;
          discount_type?: 'PERCENTAGE' | 'FLAT' | null;
          discount_value?: number | null;
          min_order_value?: number;
          target_surface?: 'WEBSITE' | 'QR_MENU' | 'BOTH';
          start_date?: string | null;
          end_date?: string | null;
          is_active?: boolean;
          display_order?: number;
          destination_product_id?: string | null;
          created_at?: string;
        };
        Update: {
          id?: string;
          title?: string;
          image_url?: string;
          coupon_code?: string | null;
          discount_type?: 'PERCENTAGE' | 'FLAT' | null;
          discount_value?: number | null;
          min_order_value?: number;
          target_surface?: 'WEBSITE' | 'QR_MENU' | 'BOTH';
          start_date?: string | null;
          end_date?: string | null;
          is_active?: boolean;
          display_order?: number;
          destination_product_id?: string | null;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_offers_banners_product';
            columns: ['destination_product_id'];
            isOneToOne: false;
            referencedRelation: 'products';
            referencedColumns: ['id'];
          }
        ];
      };

      staff_profiles: {
        Row: {
          id: string;
          full_name: string;
          phone: string | null;
          role: 'cashier' | 'manager' | 'admin' | 'owner';
          has_pos_access: boolean;
          has_admin_access: boolean;
          offline_pin_hash: string | null;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id: string; // Auth users identity
          full_name: string;
          phone?: string | null;
          role?: 'cashier' | 'manager' | 'admin' | 'owner';
          has_pos_access?: boolean;
          has_admin_access?: boolean;
          offline_pin_hash?: string | null;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          full_name?: string;
          phone?: string | null;
          role?: 'cashier' | 'manager' | 'admin' | 'owner';
          has_pos_access?: boolean;
          has_admin_access?: boolean;
          offline_pin_hash?: string | null;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [];
      };

      spin_campaigns: {
        Row: {
          id: string;
          campaign_name: string;
          start_date: string | null;
          end_date: string | null;
          is_active: boolean;
          prizes_json: Json;
          created_at: string;
        };
        Insert: {
          id?: string;
          campaign_name: string;
          start_date?: string | null;
          end_date?: string | null;
          is_active?: boolean;
          prizes_json?: Json;
          created_at?: string;
        };
        Update: {
          id?: string;
          campaign_name?: string;
          start_date?: string | null;
          end_date?: string | null;
          is_active?: boolean;
          prizes_json?: Json;
          created_at?: string;
        };
        Relationships: [];
      };

      spin_redemptions: {
        Row: {
          id: string;
          campaign_id: string;
          customer_id: string | null;
          phone: string;
          prize_won: string;
          coupon_code: string | null;
          is_redeemed: boolean;
          spun_at: string;
          redeemed_at: string | null;
        };
        Insert: {
          id?: string;
          campaign_id: string;
          customer_id?: string | null;
          phone: string;
          prize_won: string;
          coupon_code?: string | null;
          is_redeemed?: boolean;
          spun_at?: string;
          redeemed_at?: string | null;
        };
        Update: {
          id?: string;
          campaign_id?: string;
          customer_id?: string | null;
          phone?: string;
          prize_won?: string;
          coupon_code?: string | null;
          is_redeemed?: boolean;
          spun_at?: string;
          redeemed_at?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: 'fk_spin_redemptions_campaign';
            columns: ['campaign_id'];
            isOneToOne: false;
            referencedRelation: 'spin_campaigns';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'fk_spin_redemptions_customer';
            columns: ['customer_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id'];
          }
        ];
      };

      pos_devices: {
        Row: {
          id: string;
          terminal_code: string;
          device_name: string;
          is_active: boolean;
          created_at: string;
          revoked_at: string | null;
        };
        Insert: {
          id?: string;
          terminal_code: string;
          device_name: string;
          is_active?: boolean;
          created_at?: string;
          revoked_at?: string | null;
        };
        Update: {
          id?: string;
          terminal_code?: string;
          device_name?: string;
          is_active?: boolean;
          created_at?: string;
          revoked_at?: string | null;
        };
        Relationships: [];
      };
    };

    Views: {
      [_ in never]: never;
    };
    Functions: {
      secure_apply_inventory_movement: {
        Args: {
          p_product_id: string;
          p_movement_type: string;
          p_quantity_change: number;
          p_created_by?: string;
          p_movement_id?: string;
          p_reference_movement_id?: string;
        };
        Returns: boolean;
      };
      secure_deduct_inventory: {
        Args: {
          p_product_id: string;
          p_quantity: number;
          p_created_by?: string;
          p_movement_id?: string;
        };
        Returns: boolean;
      };
      secure_sync_pos_order: {
        Args: {
          p_order: Record<string, unknown>;
          p_order_items: Array<Record<string, unknown>>;
        };
        Returns: boolean;
      };
      secure_sync_pos_kot: {
        Args: {
          p_kot: Record<string, unknown>;
          p_kot_items: Array<Record<string, unknown>>;
        };
        Returns: boolean;
      };
      secure_sync_kot_correction: {
        Args: {
          p_correction: Record<string, unknown>;
        };
        Returns: boolean;
      };
      secure_sync_pos_bill: {
        Args: {
          p_bill: Record<string, unknown>;
        };
        Returns: boolean;
      };
      secure_sync_pos_payment: {
        Args: {
          p_payment: Record<string, unknown>;
        };
        Returns: boolean;
      };
      secure_sync_pos_table_session: {
        Args: {
          p_session: Record<string, unknown>;
          p_device_id?: string;
          p_device_token?: string;
        };
        Returns: boolean;
      };
      secure_replace_pos_draft_order: {
        Args: {
          p_order: Record<string, unknown>;
          p_order_items: Array<Record<string, unknown>>;
          p_device_id?: string;
          p_device_token?: string;
        };
        Returns: boolean;
      };
      secure_save_kot_correction: {
        Args: {
          p_correction: Record<string, unknown>;
          p_updated_order_item: Record<string, unknown>;
          p_updated_order: Record<string, unknown>;
          p_device_id?: string;
          p_device_token?: string;
        };
        Returns: boolean;
      };
    };
    Enums: {
      [_ in never]: never;
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
}
