# CHEESYOS NEXTGEN — V1 REQUIREMENT FREEZE

**Status**: FROZEN & APPROVED SOURCE OF TRUTH  
**Version**: 1.0.0  
**Phase**: Phase 1 — Architecture Foundation

---

## 1. APPROVED V1 APPLICATIONS & DOMAIN MAPPING

CheesyOS NextGen V1 consists of **EXACTLY SIX (6)** approved applications. Each web application is independently deployable to its dedicated production domain.

| Application | Target Surface / Domain | Purpose & Scope |
| :--- | :--- | :--- |
| **Windows POS** | Native Desktop `.exe` | Primary operational POS. Offline-first with local SQLite outbox sync. |
| **Web POS** | `pos.cheesybites.in` | Browser-based POS fallback for emergency/tablet access. |
| **Admin** | `admin.cheesybites.in` | Operational management, menu, staff access, offers, and analytics. |
| **Customer Website** | `cheesybites.in` | Streamlined online ordering for delivery & pickup. |
| **Smart QR Menu** | `qr.cheesybites.in` | Universal QR menu for customer browsing & order history. |
| **Spin & Win** | `spin.cheesybites.in` | Customer engagement & reward gamification widget. |

### SINGLE SUPABASE INFRASTRUCTURE REQUIREMENT
- **DO NOT** create separate Supabase projects for each application.
- All six V1 applications connect to the **SAME** CheesyOS NextGen Supabase cloud project (`sdbnibyzqtgpbexlznat`).
- Security boundaries between applications are strictly enforced via **Authentication, Role Permissions, RLS, and Secure RPC Contracts**.

---

## 2. EXPLICIT OUT-OF-SCOPE (EXCLUDED FROM V1)

The following modules, features, and systems are **EXPLICITLY EXCLUDED** from NextGen V1.  
**STRICT DIRECTIVE**: Do **NOT** create placeholder tables, RPCs, service folders, routes, or stub code for any of the following:

- ❌ **Staff App** (Employee attendance/selfies/checklists)
- ❌ **Kitchen Display System (KDS)**
- ❌ **Rider Dashboard & Live Driver Tracking**
- ❌ **Smart QR Table Ordering / QR Cart / QR KOT**
- ❌ **Table-Specific QR Codes** (Single Universal QR only)
- ❌ **Dynamic Combo Builder** (BOM component selection)
- ❌ **Raw Material Inventory & Stock Intake**
- ❌ **Recipe / Bill of Materials (BOM) Consumption Tracking**
- ❌ **Supplier Management & Purchase Order ERP**
- ❌ **Central Kitchen Production & Stock Transfers**
- ❌ **Multi-Outlet Chain Management & Inter-Branch Transfers**
- ❌ **Franchise Management & Royalty Tracking**
- ❌ **Enterprise ERP Integration**

---

## 3. WINDOWS POS — OFFLINE-FIRST ARCHITECTURE

Windows POS is the **PRIMARY** operational interface for restaurant billing, table management, and KOT generation.

### ARCHITECTURE STACK:
```text
React / Vite UI
      ↓
Shared POS Core (Domain Logic)
      ↓
Local SQLite Engine
      ↓
Durable Outbox Queue
      ↓
Sync Engine (Background Sync Worker)
      ↓
CheesyOS NextGen Supabase (Cloud)
```

### CORE OFFLINE CAPABILITIES:
Windows POS **MUST** continue 100% of core operational functions without an active internet connection:
1. Floor & Table Management (Sessions, seating, status changes)
2. Cart Management & Item Customizations
3. Order Creation & Modifications
4. KOT Generation & Printing
5. KOT Corrections & Voids Ledger
6. Bill Printing & Fiscal Receipt Generation
7. Manual Cashier Payment Settlement (Cash/UPI/Card)
8. Cached Customer Phone Lookup & Customer 360 Reads
9. Ready-to-use Inventory Stock Deductions

### SYNC ENGINE DIRECTIVE:
- When an internet connection is available, the Sync Engine **MUST** attempt cloud synchronization **IMMEDIATELY** upon outbox write.
- Do **NOT** introduce arbitrary 5-minute, 10-minute, or 20-minute batch waiting timers for critical operational writes (Orders, KOT, Bills, Payments).

---

## 4. WEB POS — BROWSER FALLBACK

- Web POS (`pos.cheesybites.in`) serves as the operational browser fallback if the Windows desktop hardware is unavailable.
- **SHARED DOMAIN LOGIC**: Web POS and Windows POS **MUST** share the exact same POS Core domain package for cart rules, total calculations, discounts, taxes, and order state validation.
- Do **NOT** maintain two separate POS business engines.

---

## 5. POS PAYMENT MODEL (V1)

- **NO PAYMENT GATEWAY INTEGRATION IN POS V1**.
- POS operates on **Cashier Manual Confirmation** for all in-person transactions.
- Approved Payment Modes:
  - `Cash`
  - `UPI` (Static QR / Direct UPI transfer confirmed visually by cashier)
  - `Card` (Manual POS Card Terminal transaction)
  - `Other` (Loyalty/Complimentary/Other)
- Every payment settlement record MUST capture:
  - `amount`
  - `payment_mode`
  - `confirmed_by` (User ID / Staff Name)
  - `confirmed_at` (Timestamp)

---

## 6. CUSTOMER 360 — LIGHTWEIGHT CRM

Mobile number lookup at POS provides cashier with an instant, explainable customer profile:
- Basic details (Name, phone, default delivery address, account status)
- Last order details & timestamp
- Recent order history (last 5 orders)
- Most ordered items & favourite categories
- Total lifetime order count & total spend
- Average Order Value (AOV)
- Days elapsed since last order
- Offer Response Rating (`HIGH` / `MEDIUM` / `LOW` based on coupon redemptions)
- **Quick Add**: 1-click addition of past favourite items to current order

*Constraint*: Built entirely via simple, index-backed SQL aggregates. **NO AI/ML**, vector databases, or external CRM platforms.

---

## 7. INVENTORY LITE — READY-TO-USE STOCK ONLY

Inventory in NextGen V1 tracks **ONLY DIRECTLY COUNTABLE, READY-TO-USE SELLABLE ITEMS**:
- Packaged Cold Drinks / Beverages
- Packaged Drinking Water
- Ready Desserts / Ice Creams
- Packaged Dips & Merchandise

*Excluded*: Raw ingredients (flour, cheese, vegetables), recipe consumption, wastage logs, purchase orders, or BOM calculations.

---

## 8. COMBOS — SIMPLE PRODUCT MODEL

- **NO COMBO BUILDER**.
- A Combo is treated as a standard sellable product entry in the catalog.
- *Example*:
  - **Product Name**: Burger + Cold Coffee Combo
  - **Price**: ₹99
  - **Description**: 1 Veg Burger + 1 Cold Coffee (300ml)
- Choice groups/variants may be attached for basic options (e.g. choice of drink flavor), but no dynamic component logic.

---

## 9. ADMIN LITE & HIGH-VALUE DASHBOARD

Admin (`admin.cheesybites.in`) focuses strictly on core operational management.

### APPROVED ADMIN MODULES:
1. Dashboard
2. Orders Management
3. Catalog & Menu Management
4. Customer Directory
5. Offers & Banners
6. Inventory Lite
7. Reports & Analytics
8. User Access & Permissions
9. System Settings

### HIGH-VALUE DASHBOARD CARDS ONLY:
- Today's Total Sales (Gross & Net)
- Today's Total Orders Count
- Average Order Value (AOV)
- Payment Mode Breakdown (Cash vs UPI vs Card)
- Yesterday Comparison (% growth/decline)
- Top Selling Items Today
- Low Stock Items Alert (Inventory Lite)
- Channel Sales Split (POS vs Website)

---

## 10. REPORTS & ANALYTICS — HIGH-PERFORMANCE CLOUD REPORTING

- Reporting queries run against consolidated cloud data in NextGen Supabase.
- **OPERATIONAL PROTECTION**: Reporting queries must **NEVER** lock operational billing, KOT, or order tables.
- Reports included in V1:
  - Sales Summary & Financial Breakdown
  - Order Volume & Status Distribution
  - Average Order Value (AOV) Trends
  - Taxes (CGST/SGST) & Discounts Report
  - Payment Mode Reconciliation
  - Channel Performance (POS vs Website)
  - Product & Category Sales Matrix
  - Hourly & Day-of-Week Sales Heatmaps
  - Customer Repeat Purchase & Lifetime Value
  - Inventory Lite Stock Movements
  - Cancellation, Void & Refund Audit Log

---

## 11. SMART QR MENU — ONE UNIVERSAL QR

- **ONE UNIVERSAL QR CODE** per outlet (e.g., printed on table tents or counters).
- **NO Table-Specific QR Codes**.
- **NO QR Ordering, NO QR Cart, NO QR Checkout, NO QR KOT**.
- Features supported:
  - Digital Menu browsing with rich images & descriptions
  - Mobile number login/verification
  - View Past Order history & Order Again display
  - Personal recommendations based on order frequency, recency, and popular items
  - Active Offer Banners display

---

## 12. CUSTOMER WEBSITE — STREAMLINED ORDERING

Online ordering (`cheesybites.in`) is optimized for maximum conversion and minimal friction.

### STREAMLINED WORKFLOW:
```text
Website Landing
      ↓
Select Order Type (Delivery | Pickup)
      ↓
Browse Menu
      ↓
Add Items to Cart (Direct ADD for non-variant items)
      ↓
Review Cart & Apply Coupons
      ↓
Customer Identification (Phone / Auth)
      ↓
Delivery → Confirm Address | Pickup → Skip Address
      ↓
Online Payment / Cash on Delivery
      ↓
Place Order & Live Tracking
```

---

## 13. WEBSITE LOCATION & DELIVERY LOGIC

- **Delivery Flow**:
  - Request browser geolocation permission.
  - Use Google Maps Geocoding API to resolve exact street address, coordinates, and delivery zone eligibility.
  - **Manual Address Fallback**: If browser location is denied or unavailable, customer can manually enter address details. Website ordering MUST remain fully functional.
  - **Backend Validation**: Final delivery charges MUST be calculated and verified server-side by backend RPC logic. Frontend delivery fee is never trusted blindly.
- **Pickup Flow**:
  - No delivery address required.
  - Delivery Charge = ₹0.

---

## 14. OFFERS & BANNERS — SINGLE BANNER SYSTEM

A single unified banner management concept controls promotional carousels across customer surfaces.
- **Admin Controls**: Image URL, Title, Active Status, Start Date, End Date, Display Order, Target Surface (`Website`, `QR Menu`, `Both`), Destination (Product ID, Category ID, or External Link).
