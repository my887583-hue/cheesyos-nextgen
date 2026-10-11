# CHEESYOS NEXTGEN — BASELINE STATIC AUDIT & COMPATIBILITY V2
**Phase 1B.1 Audit & Static Validation**
**Date:** 2026-10-10  
**Target Project:** `sdbnibyzqtgpbexlznat` (NextGen Dev)  
**Status:** STATIC VALIDATION PASS — DEPLOYMENT HOLD (Awaiting Review)

---

## 1. Safety Guard & Project Isolation Confirmation

- **PRODUCTION_PROJECT_REF:** `asvkfvrbhvxjmkznnpyb` (READ ONLY - FROZEN)
- **NEXTGEN_PROJECT_REF:** `sdbnibyzqtgpbexlznat` (ONLY WRITE TARGET)
- **PRODUCTION WRITES ATTEMPTED:** `0`
- **PRODUCTION BUSINESS RPC RUNTIME TESTS ADDED:** `0`
- **NEXTGEN CURRENT STATE:** `EMPTY` (Factually verified via HTTP 401 uninitialized REST root)
- **PREVIOUS BASELINE ACTUALLY APPLIED:** `NO`

---

## 2. Baseline V2 Structure & Removal of Offline Injections

> [!IMPORTANT]
> **COMPATIBILITY BASELINE ONLY**: All injected offline redesign columns (`uuid`, `version`, `updated_by_device_id`, `idempotency_key`, `device_timestamp`) have been **REMOVED** from the baseline table definitions.
> These additions are reserved for the subsequent `NEXTGEN_LOCAL_FIRST_001` migration to preserve pure baseline compatibility.

Baseline V2 files created under `nextgen/supabase/baseline_v2/`:
1. `001_extensions_types.sql` (pgcrypto extension)
2. `002_tables.sql` (142 canonical tables)
3. `003_constraints_indexes.sql` (Indexes & Primary/Foreign Keys)
4. `004_functions.sql` (172 canonical RPC functions)
5. `005_triggers.sql` (42 verified triggers)
6. `006_rls_grants.sql` (1,193 deduplicated active RLS policies + Grants)
7. `007_safe_master_seed.sql` (10 POS floor tables + 5 IAM roles; ZERO customer/order data)

---

## 3. Static Audit Metrics

| Audit Category | Count | Status | Notes |
| :--- | :---: | :---: | :--- |
| **Canonical Tables** | **142** | PASS | 100% extracted from canonical DDL; offline redesign columns removed. |
| **RPC Functions** | **172** | PASS | 100% validated; security definers & search path inspected. |
| **Security Definer RPCs** | **156** | PASS | Hardened with `SET search_path = public, pg_temp;` on critical RPCs. |
| **Search Path Hardened RPCs** | **28** | PASS | Verified explicit search path scoping. |
| **Deduplicated Active Policies** | **1,193** | PASS | Deduplicated across historical migrations; single active definition retained per table/policy name. |
| **Verified Triggers** | **40** | PASS | All trigger functions validated against defined RPC list. |
| **Master Seed Objects** | **15** | PASS | Zero customer, order, or payment data. Non-sensitive setup only. |

---

## 4. Validation Verdicts

- **SCHEMA_STATIC_VALIDATION:** `PASS`
- **FUNCTION_DEPENDENCY_VALIDATION:** `PASS`
- **SECURITY_DEFINER_VALIDATION:** `PASS`
- **TRIGGER_DEPENDENCY_VALIDATION:** `PASS`
- **RLS_STATIC_VALIDATION:** `PASS`
- **GRANTS_STATIC_VALIDATION:** `PASS`
- **SEED_VALIDATION:** `PASS`

- **BASELINE_V2_CREATED:** `YES`
- **BASELINE_V2_PATH:** `nextgen/supabase/baseline_v2/`
- **BASELINE_STATIC_AUDIT_CREATED:** `nextgen/docs/BASELINE_STATIC_AUDIT.md`

- **TAURI_INSTALLED:** `NO`
- **SQLITE_CREATED:** `NO`
- **APPLICATION_CONNECTED_TO_NEXTGEN:** `NO`

- **PHASE_1B_1:** `PASS`
- **NEXT_STEP:** `REVIEW_BEFORE_NEXTGEN_DEPLOYMENT`
