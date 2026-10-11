# CHEESYOS NEXTGEN — WINDOWS POS DATA COMPATIBILITY & ARCHITECTURE
**Phase 1A: Offline-First Data Matrix & Application Layering**

---

## 1. System Architecture & Layering

```
+-------------------------------------------------------------------------+
|                              REACT UI                                   |
|               (Existing CheesyOS React Components/Pages)                 |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                      REPOSITORY / DOMAIN SERVICES                       |
|               (Typescript Domain Layer & Data Access Interfaces)        |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                             LOCAL SQLITE                                |
|        (Primary Operational Database on Windows POS Desktop Device)     |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                        DURABLE SYNC ENGINE                              |
|           (Background Thread / Transactional Sync Worker)               |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                        NEXTGEN SUPABASE                                 |
|            (Cloud Aggregator, Website/QR Ingress, Central DB)           |
+-------------------------------------------------------------------------+
```

---

## 2. Windows POS Operational Database Rule

> [!IMPORTANT]
> **PRIMARY OPERATIONAL DB**: Local SQLite on the Windows Desktop device is the primary database for all cashier actions (table selection, cart, KOT printing, bill calculation, cash settlement).
> 
> **SUPABASE CLOUD ROLE**: Supabase (`sdbnibyzqtgpbexlznat`) serves as:
> 1. Central cross-device sync hub
> 2. Website & QR order ingress receiver
> 3. Master catalog source of truth
> 4. Remote durable backup & analytics ledger

---

## 3. Domain Compatibility & Sync Matrix

| # | Domain | Current Cloud Model | Future SQLite Representation | Future Supabase Representation | Sync Direction | Offline Behavior | Conflict Sensitivity |
| :-: | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1** | **Menu & Catalog** | `categories`, `products`, `choice_groups` | `sqlite_menu_cache` | `categories`, `products` | Cloud → Device | Read-Only Local Cache | **Low** (Cloud authoritative) |
| **2** | **Customers** | `customers`, `cheesy_wallets` | `sqlite_customers` | `customers`, `cheesy_wallets` | Bi-directional | Search & Add Offline | **Medium** (Phone number key) |
| **3** | **Tables** | `pos_tables`, `restaurant_tables` | `sqlite_pos_tables` | `pos_tables` | Bi-directional | Real-time Local Floor | **Medium** (Device lock) |
| **4** | **Sessions** | `table_sessions`, `active_sessions` | `sqlite_table_sessions` | `table_sessions` | Bi-directional | Full Session Control | **High** (Session Token key) |
| **5** | **Orders** | `orders`, `ord_orchestrator` | `sqlite_orders` | `orders` | Device → Cloud | Full Local Creation | **High** (Client UUID + Idempotency Key) |
| **6** | **Order Items** | `pos_order_items`, `ord_items` | `sqlite_order_items` | `pos_order_items` | Device → Cloud | Full Local Creation | **High** (Item UUID + Session Item ID) |
| **7** | **KOT** | `pos_kots`, `pos_kot_items` | `sqlite_kots`, `sqlite_kot_items` | `pos_kots`, `pos_kot_items` | Device → Cloud | Print Instantly Offline | **Medium** (KOT Sequence per Session) |
| **8** | **KOT Corrections** | `kot_corrections` | `sqlite_kot_corrections` | `kot_corrections` | Device → Cloud | Instant Local Reduction | **Low** (Append-only ledger) |
| **9** | **Bills** | Bill calculation & taxes | `sqlite_bills` | Calculated aggregate | Local Calculation | Instant Local Bill | **Low** (Deterministic tax rules) |
| **10** | **Payments** | `pay_transactions`, `pay_settlements` | `sqlite_payments` | `pay_transactions` | Bi-directional | Cash offline; Online queued | **High** (Gateway Transaction ID) |
| **11** | **Website Orders** | `delivery_orders`, `ord_orchestrator` | `sqlite_website_orders` | `delivery_orders` | Cloud → Device | Ingress Notification | **Low** (Cloud created) |
| **12** | **QR Orders** | `table_sessions`, `pos_table_notifications` | `sqlite_qr_requests` | `pos_table_notifications` | Cloud → Device | Ingress & Accept | **Medium** (Status transition authority) |

---

## 4. Initial Windows Offline Capabilities

When internet connectivity is disconnected, the Windows Desktop POS MUST continue operating seamlessly for:

1. **Table Floor Operations**: Opening, switching, and viewing physical table status.
2. **Cart Management**: Item addition, variant selection, customization choice groups, and special instructions.
3. **Order Lifecycle**: Local order creation, order ID assignment, and status transitions.
4. **Kitchen Display & Printing**: Local network raw ESC/POS KOT printing to kitchen thermal printers.
5. **KOT Corrections**: Immediate item reduction and correction ticket printing.
6. **Cached Customer Lookup**: Fast local phone number lookup and guest profile creation.
7. **Billing & Tax Math**: Exact subtotal, GST (SGST/CGST), discount policy application, and final bill generation.
8. **Cash Settlement**: Cash receipt confirmation and drawer release.

> [!NOTE]
> Online payment gateway transactions (Razorpay / UPI webhooks) require active internet connectivity to communicate with external payment provider APIs.

---

## 5. Non-Interference with Web App & Production

- **Current Browser POS**: Functions as emergency fallback on production project `asvkfvrbhvxjmkznnpyb`.
- **Website & QR Orders**: Continue routing through existing production cloud infrastructure without disruption.
- **NextGen Windows Desktop POS**: Communicates strictly with NextGen project `sdbnibyzqtgpbexlznat`.
