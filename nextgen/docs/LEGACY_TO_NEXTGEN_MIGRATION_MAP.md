# CHEESYOS NEXTGEN — LEGACY TO NEXTGEN MIGRATION MAP

**Status**: MAPPING SPECIFICATION ONLY (NO DATA MIGRATION EXECUTED)  
**Source Database**: Production Supabase (`asvkfvrbhvxjmkznnpyb` — READ ONLY)  
**Target Database**: NextGen Supabase (`sdbnibyzqtgpbexlznat` — UNTOUCHED)

---

## 1. MIGRATION CLASSIFICATION SUMMARY

Legacy production database (`asvkfvrbhvxjmkznnpyb`) contains approximately 142 tables accumulated over historical iterations.  
For NextGen V1, legacy tables are classified into four strict migration categories:

- **MIGRATE**: Active production catalog and customer data migrated with schema alignment.
- **TRANSFORM**: Historical operational data mapped into clean NextGen canonical structures.
- **DO_NOT_MIGRATE**: Legacy bloat, speculative ERP, raw inventory, attendance, and temporary tables permanently excluded.
- **REVIEW**: Data requiring manual store confirmation before import.

---

## 2. DETAILED DOMAIN MIGRATION MAPPING

### A. CATALOG & PRODUCTS (PRIORITY 1)
| Legacy Production Table | Action | Target NextGen Table | Migration & Transformation Notes |
| :--- | :--- | :--- | :--- |
| `public.categories` | **MIGRATE** | `public.categories` | Direct migration. Clean sort orders & active flags. |
| `public.products` | **MIGRATE** | `public.products` | Migrate sellable products. Map image URLs & prices. |
| `public.product_variants` | **MIGRATE** | `public.product_variants` | Migrate active variants (sizes, flavors). |

### B. CUSTOMERS & ADDRESSES (PRIORITY 2)
| Legacy Production Table | Action | Target NextGen Table | Migration & Transformation Notes |
| :--- | :--- | :--- | :--- |
| `public.customers` | **MIGRATE** | `public.customers` | Migrate customer profiles, mobile numbers, and lifetime stats. |
| `public.customer_addresses` | **MIGRATE** | `public.customer_addresses` | Migrate saved delivery addresses & geocoded coordinates. |

### C. HISTORICAL ORDERS & BILLING (PRIORITY 3)
| Legacy Production Table | Action | Target NextGen Table | Migration & Transformation Notes |
| :--- | :--- | :--- | :--- |
| `public.orders` / `public.pos_orders` | **TRANSFORM** | `public.orders` | Consolidate duplicate order tables into unified canonical `orders`. |
| `public.pos_order_items` | **TRANSFORM** | `public.order_items` | Map line items to clean `order_items` schema. |
| `public.bills` | **TRANSFORM** | `public.bills` | Import historical invoice summaries for fiscal audit. |
| `public.payments` / `public.pay_transactions` | **TRANSFORM** | `public.payments` | Map payment settlement records to clean payment ledger. |

### D. EXCLUDED LEGACY TABLES (DO_NOT_MIGRATE)
| Legacy Production Category | Legacy Tables Included | Reason for Exclusion |
| :--- | :--- | :--- |
| **Raw Inventory & BOM** | `recipe_steps`, `ingredient_costs`, `supplier_master`, `procurement_po` | Out of V1 scope. Replaced by Inventory Lite. |
| **Enterprise / Multi-Outlet** | `chain_transfers`, `chain_warehouses`, `chain_central_kitchen` | Out of V1 scope. Single outlet V1 focus. |
| **Staff App & Checklists** | `attendance_logs`, `checklists`, `task_approvals` | Out of V1 scope. |
| **Temporary & Debug Tables** | `temp_list`, `temp_list_tables`, `temp_reset_pass` | Unnecessary development residue. |

---

## 3. MIGRATION SAFETY DIRECTIVES

1. **ZERO PRODUCTION IMPACT**: Production database (`asvkfvrbhvxjmkznnpyb`) is READ-ONLY and MUST NOT be locked or modified during extraction.
2. **STAGING ETL**: Data extraction will produce offline JSON/CSV artifacts. Transformations will be verified offline before seed creation.
3. **DO NOT EXECUTE**: No migration script shall be run until Phase 1 architecture and schema design receive explicit user approval.
