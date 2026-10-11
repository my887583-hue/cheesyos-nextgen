# CHEESYOS NEXTGEN — APPLICATION ARCHITECTURE

**Status**: APPROVED ARCHITECTURE SPECIFICATION  
**Target Project**: `sdbnibyzqtgpbexlznat` (NextGen Supabase)

---

## 1. HIGH-LEVEL TOPOLOGY & SYSTEM BOUNDARIES

CheesyOS NextGen connects six distinct client applications to a unified, high-reliability Supabase cloud backend, with Windows POS operating an isolated local-first SQLite engine.

```text
+-----------------------------------------------------------------------------------+
|                            CHEESYOS NEXTGEN CLOUD                                 |
|                                                                                   |
|           Single NextGen Supabase Cloud Project (sdbnibyzqtgpbexlznat)            |
|    +-------------------------------------------------------------------------+    |
|    | Postgres DB | Auth & JWT | RLS Policies | Secure RPCs | Realtime Broadcast |    |
|    +-------------------------------------------------------------------------+    |
+-----------------------------------------------------------------------------------+
       ▲                  ▲                ▲                 ▲               ▲
       │ (Outbox Sync)    │ (HTTPS/REST)   │ (HTTPS/REST)    │ (HTTPS/REST)  │ (HTTPS/REST)
       │                  │                │                 │               │
+--------------+   +--------------+  +-----------+     +------------+  +-----------+
| WINDOWS POS  |   |   WEB POS    |  |   ADMIN   |     |  WEBSITE   |  |  QR MENU  |
| Desktop .exe |   | pos.cheesy...|  |admin.chee.|     | cheesyb... |  | qr.cheesy.|
| React + Vite |   | React + Vite |  |React+Vite |     | Next.js    |  |React+Vite |
| Local SQLite |   +--------------+  +-----------+     +------------+  +-----------+
+--------------+
```

---

## 2. APPLICATION DEPLOYMENT MATRIX

| Application | Technology Stack | Deployment Host | Domain / Surface | Primary State Store |
| :--- | :--- | :--- | :--- | :--- |
| **Windows POS** | React 18, Vite, Tauri v2, SQLite, Tailwind | Windows Installer (.exe) | Desktop Client | Local SQLite + Cloud Outbox |
| **Web POS** | React 18, Vite, Tailwind | Vercel / Cloudflare | `pos.cheesybites.in` | Browser Memory + Cloud REST |
| **Admin** | React 18, Vite, Tailwind, Recharts | Vercel / Cloudflare | `admin.cheesybites.in` | Cloud REST + Realtime |
| **Customer Website** | Next.js 14, React 18, Tailwind | Vercel / AWS | `cheesybites.in` | Server/Client REST + Auth JWT |
| **Smart QR Menu** | React 18, Vite, Tailwind | Vercel / Cloudflare | `qr.cheesybites.in` | Client REST + LocalStorage |
| **Spin & Win** | React 18, Canvas API | Vercel / Cloudflare | `spin.cheesybites.in` | Client REST + Session JWT |

---

## 3. WINDOWS POS LOCAL-FIRST ARCHITECTURE

Windows POS uses a strict layered architecture ensuring complete operational independence from cloud network connectivity.

```text
+-------------------------------------------------------------------------+
|                          REACT / VITE UI LAYER                          |
|         (Floor Plan, POS Cart, Billing, Customer 360, KOT UI)           |
+-------------------------------------------------------------------------+
                                    │
                                    ▼
+-------------------------------------------------------------------------+
|                        SHARED POS CORE DOMAIN                           |
|      (Order Validation, Tax/Discount Calc, KOT Logic, Item Totals)      |
+-------------------------------------------------------------------------+
                                    │
                        ┌───────────┴───────────┐
                        ▼                       ▼
+-------------------------------+   +-------------------------------------+
|      LOCAL SQLITE ENGINE      |   |        DURABLE OUTBOX QUEUE         |
|  (Tables, Orders, Customers,  |   | (Pending Sync Operations & Payload) |
|   KOT Ledger, Ready Inventory)|   +-------------------------------------+
+-------------------------------+                   │
                                                    ▼
                                    +-------------------------------------+
                                    |         SYNC ENGINE WORKER          |
                                    | (Pushes Outbox -> Supabase Cloud)   |
                                    +-------------------------------------+
```

### OFFLINE READ/WRITE FLOWS
1. **Order Creation / Items Modification**:
   - UI validates cart using **Shared POS Core**.
   - Transaction written directly to **Local SQLite**.
   - Outbox entry created with unique `outbox_id` (UUIDv4) and `status = 'pending'`.
   - UI updates immediately (zero latency).
2. **KOT Generation & Printing**:
   - Local KOT ledger updated in SQLite.
   - Outbox entry added for cloud KOT sync.
   - Thermal receipt printed via local USB/ESC-POS printer driver.
3. **Bill Settlement**:
   - Cashier confirms manual payment (Cash/UPI/Card).
   - Order status marked `settled` in local SQLite.
   - Fiscal bill printed.
   - Outbox entry created for payment & order settlement.

---

## 4. SHARED POS CORE (DOMAIN LOGIC PACKAGE)

To prevent code duplication between Windows POS and Web POS (Rule 3), domain rules are encapsulated into `@cheesyos/pos-core`:
- `calculateOrderTotals(items, discounts, taxes, serviceCharges)`
- `validateOrderTransition(currentStatus, targetStatus)`
- `buildKotLedgerEntry(orderId, items, tableNumber, notes)`
- `applyDiscountRules(order, discountPolicy)`
- `calculateItemWiseTax(item, taxRates)`

Both Windows POS and Web POS import this exact package.

---

## 5. APP-SPECIFIC SECURITY & ACCESS BOUNDARIES

- **Authentication**: All user login calls pass through Supabase Auth or secure RPCs returning scoped JWT tokens.
- **Authorization Enforcement**:
  - `POS_ACCESS`: Granted to cashier/manager accounts. Authorizes POS RPC calls and POS table RLS.
  - `ADMIN_ACCESS`: Granted to store admin/owner accounts. Authorizes Admin RPCs and management RLS.
  - `CUSTOMER_ACCESS`: Anonymous or customer authenticated JWTs for Website and QR Menu.
- **Secret Management**:
  - `SUPABASE_ANON_KEY` is public and embedded safely.
  - `SUPABASE_SERVICE_ROLE_KEY` is **NEVER** embedded in desktop binaries, web bundles, or client code.
