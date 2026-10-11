# CHEESYOS NEXTGEN — AUTHENTICATION & ACCESS MODEL (FINAL SPECIFICATION)

**Status**: FROZEN LOGICAL SECURITY SPECIFICATION (PHASE 2C REMEDIATED)  
**Scope**: All NextGen applications, API endpoints, RLS policies, and user credentials.

---

## 1. AUTHENTICATION & AUTHORITY MATRIX

To prevent overlapping or duplicate authentication systems, authority is strictly frozen across five distinct security responsibilities:

| Authority Component | Authority System | Implementation Details |
| :--- | :--- | :--- |
| **IDENTITY AUTHORITY** | Supabase Auth (`auth.users`) | Managed Supabase Auth holds primary user identities and UUIDs. |
| **LOGIN CREDENTIAL AUTHORITY** | Supabase Auth (`auth.users`) | Admin, Web POS, and Website authenticate against Supabase Auth. Single cloud authentication authority. |
| **APP ACCESS AUTHORITY** | `public.staff_profiles` | `has_pos_access` and `has_admin_access` boolean flags in `staff_profiles`. |
| **POS PIN AUTHORITY** | Local Windows Device Cache | Cashiers use a 4-digit PIN stored as a bcrypt hash locally on registered Windows POS devices for offline unlock. |
| **SESSION AUTHORITY** | Supabase Auth JWTs (Online) & Encrypted Local SQLite Session Token (Offline) | JWT tokens convey scoped claims (`pos_access`, `admin_access`) to RLS policies and database queries. |

---

## 2. APP-SPECIFIC LOGIN ARCHITECTURE

NextGen **REMOVES** legacy single-login redirection architecture.  
Each application implements explicit, app-scoped login interfaces and authenticates against Supabase Auth endpoints.

```text
[ Windows / Web POS UI ]  --->  Supabase Auth: signInWithPassword(...)       --->  Validates POS Access Flag & Issues JWT
[ Admin Portal UI ]       --->  Supabase Auth: signInWithPassword(...)       --->  Validates Admin Access Flag & Issues JWT
[ Website / QR Menu ]     --->  Supabase Auth: OTP / Anonymous Session       --->  Issues Customer Scoped JWT
```

### WINDOWS POS OFFLINE UNLOCK RULES:
1. When Windows POS is online, staff authenticate via Supabase Auth, which returns the session JWT and syncs the updated local PIN verifier to local SQLite.
2. When Windows POS is offline, cashier PIN is verified locally against the bcrypt hash in local SQLite.
3. Offline PIN cache is strictly device-local and refreshed/revoked whenever the terminal connects online.
4. Admin login cannot be performed offline; Admin access requires active online cloud authentication.

---

## 3. IDENTITY PERMISSIONS & ROLE MODEL

Users are granted fine-grained application access flags stored in `staff_profiles`:
- `has_pos_access` (`boolean`) — Authorizes access to Windows POS & Web POS.
- `has_admin_access` (`boolean`) — Authorizes access to Admin Portal.
- `role` (`cashier` | `manager` | `admin` | `owner`) — Determines operational limits (discounts, voids, refunds, settings).

### DUAL ACCESS IDENTITIES
One staff identity may hold both `has_pos_access = true` and `has_admin_access = true` (e.g. Store Owner).  
However, logging into Web POS will ONLY grant a POS-scoped session; accessing Admin requires authenticating at `admin.cheesybites.in`.

---

## 4. BACKEND AUTHORIZATION & RLS ENFORCEMENT

- **Frontend Route Guards are NOT Security**: Route guards improve UX, but all security is strictly enforced at the database/API boundary.
- **RLS Policy Checks**: Every operational query executes a role/permission check:
  ```sql
  EXISTS (
    SELECT 1 FROM public.staff_profiles 
    WHERE id = auth.uid() AND has_pos_access = true AND is_active = true
  )
  ```
- **Row Level Security (RLS)**: RLS is enabled on **100% of public schema tables**. Unauthenticated direct REST access is restricted by policy.

---

## 5. SECRET MANAGEMENT RULES

- **SERVICE-ROLE KEY IS SACRED**: `SUPABASE_SERVICE_ROLE_KEY` must **NEVER** be compiled into Windows `.exe` desktop binaries, included in web frontend JS bundles, or committed to code repositories.
- Client applications operate exclusively using `SUPABASE_ANON_KEY` combined with user JWT tokens.
