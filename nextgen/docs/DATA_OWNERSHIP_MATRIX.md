# CHEESYOS NEXTGEN — DATA OWNERSHIP MATRIX (FINAL SPECIFICATION)

**Status**: FROZEN DOMAIN OWNERSHIP SPECIFICATION (PHASE 1.2 COMPLETE)  
**Scope**: All database entities across Cloud Supabase and Windows POS SQLite

---

## DOMAIN OWNERSHIP MATRIX (20 CANONICAL TABLES)

| Table Name | Canonical Owner | Authorized Readers | Authorized Writers | Windows SQLite Role | Sync Direction | Security Requirement |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`categories`** | Cloud Supabase | Admin, POS (Win/Web), Website, QR | Admin | Read-Only Local Cache | Cloud -> Local (Pull) | RLS Public Read, Admin Write |
| **`products`** | Cloud Supabase | Admin, POS (Win/Web), Website, QR | Admin | Read-Only Local Cache | Cloud -> Local (Pull) | RLS Public Read, Admin Write |
| **`product_variants`** | Cloud Supabase | Admin, POS (Win/Web), Website, QR | Admin | Read-Only Local Cache | Cloud -> Local (Pull) | RLS Public Read, Admin Write |
| **`customers`** | Cloud Supabase | Admin, POS (Win/Web), Website | POS, Website, Admin | Cached Read/Write Copy | Bi-directional | Auth RLS + PII Protection |
| **`customer_addresses`**| Cloud Supabase | Website, POS, Admin | Website, Customer | Cached Read-Only Copy | Cloud -> Local (Pull) | Customer Scoped RLS |
| **`orders`** | POS (Dine-in) / Cloud (Web) | Admin, POS, Website, Customer | POS (Dine-in), Website RPC | Full Local Copy | Windows POS <-> Cloud | RLS + RPC Validation |
| **`order_items`** | POS (Dine-in) / Cloud (Web) | Admin, POS, Website, Customer | POS (Dine-in), Website RPC | Full Local Copy | Windows POS <-> Cloud | RLS + RPC Validation |
| **`pos_tables`** | POS (Win) / Cloud | POS (Win/Web), Admin | Admin, POS | Full Local Copy | Windows POS <-> Cloud | POS Scoped RLS |
| **`table_sessions`** | POS (Win) / Cloud | POS (Win/Web), Admin | POS (Win/Web) | Full Local Copy | Windows POS <-> Cloud | POS Scoped RLS |
| **`pos_kots`** | POS (Win) / Cloud | POS (Win/Web), Admin | POS (Win/Web) | Full Local Copy | Windows POS -> Cloud (Push) | Immutable Audit Ledger |
| **`kot_items`** | POS (Win) / Cloud | POS (Win/Web), Admin | POS (Win/Web) | Full Local Copy | Windows POS -> Cloud (Push) | Immutable Audit Ledger |
| **`kot_corrections`** | POS (Win) / Cloud | POS (Win/Web), Admin | POS (Manager Auth) | Full Local Copy | Windows POS -> Cloud (Push) | Immutable Audit Ledger |
| **`bills`** | POS (Win) / Cloud | POS (Win/Web), Admin, Customer | POS (Win/Web) | Full Local Copy | Windows POS -> Cloud (Push) | Immutable Fiscal Ledger |
| **`payments`** | POS (Win) / Cloud | POS (Win/Web), Admin | POS Cashier, Webhook | Full Local Copy | Windows POS <-> Cloud | Financial Audit Ledger |
| **`inventory_lite`** | Cloud Supabase | Admin, POS (Win/Web) | Admin, POS Stock RPC | Cached Stock Copy | Windows POS <-> Cloud | Admin Write, POS Deduct RPC |
| **`inventory_movements`**| Cloud Supabase | Admin | Admin, POS Stock RPC | None (Cloud Only) | Cloud Only | Admin Scoped RLS |
| **`offers_banners`** | Cloud Supabase | Admin, Website, QR, POS | Admin | Read-Only Local Cache | Cloud -> Local (Pull) | RLS Public Read, Admin Write |
| **`staff_profiles`** | Cloud Supabase | Admin, Auth RPCs | Admin | Read-Only Staff Profiles | Cloud -> Local (Pull) | Admin RLS + PIN Hash Guard |
| **`spin_campaigns`** | Cloud Supabase | Spin App, Admin | Admin | None (Cloud Only) | Cloud Only | Admin Write, Public Read |
| **`spin_redemptions`** | Cloud Supabase | Spin App, Admin | Spin App RPC | None (Cloud Only) | Cloud Only | Customer Scoped RLS |
