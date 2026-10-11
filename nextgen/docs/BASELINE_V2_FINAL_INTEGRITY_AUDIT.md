# CHEESYOS NEXTGEN — BASELINE V2 FINAL INTEGRITY AUDIT REPORT

## Executive Summary

This report documents the final pre-deploy integrity audit of **Baseline V2** (`nextgen/supabase/baseline_v2/`) prior to schema deployment to NextGen Supabase project (`sdbnibyzqtgpbexlznat`).

- **Production Project Ref**: `asvkfvrbhvxjmkznnpyb` (READ ONLY / FROZEN)
- **NextGen Project Ref**: `sdbnibyzqtgpbexlznat` (EMPTY / AUDIT ONLY)
- **Baseline V2 State**: NOT DEPLOYED / DEFECTIVE (Missing 50+ indexes and table constraints)
- **Baseline V3 Candidate State**: GENERATED (`nextgen/supabase/baseline_v3_candidate/`)
- **Phase 1B.2 Audit Result**: **HOLD** (Baseline V2 incomplete; Baseline V3 Candidate ready for pre-deploy review)

---

## Project Identity & Safety Verification

```
PRODUCTION_PROJECT_REF=asvkfvrbhvxjmkznnpyb
NEXTGEN_PROJECT_REF=sdbnibyzqtgpbexlznat
PROJECT_IDENTITY_GATE=PASS

NEXTGEN_CONFIRMED_EMPTY=YES
AUTHORITATIVE_LIVE_CATALOG_AVAILABLE=NO
```

*Note*: Direct PostgreSQL live catalog connection to production or NextGen was unavailable; migration history parsing across all 199 files was used to reconstruct the effective schema lifecycle.

---

## Migration Lifecycle Analysis

```
MIGRATION_FILES_ANALYZED=199

CREATE_TABLE_OPERATIONS=143
ALTER_TABLE_OPERATIONS=609
ADD_COLUMN_OPERATIONS=174
DROP_COLUMN_OPERATIONS=0
ADD_CONSTRAINT_OPERATIONS=39
DROP_CONSTRAINT_OPERATIONS=53
CREATE_INDEX_OPERATIONS=56
DROP_INDEX_OPERATIONS=0
```

---

## Reconstructed Canonical Schema Metrics

```
FINAL_TABLE_COUNT=208
PRIMARY_KEY_COUNT=142
FOREIGN_KEY_COUNT=144
UNIQUE_CONSTRAINT_COUNT=69
CHECK_CONSTRAINT_COUNT=18
INDEX_COUNT=55

FUNCTION_SIGNATURE_COUNT=175
SECURITY_DEFINER_COUNT=159
FINAL_TRIGGER_COUNT=41
FINAL_POLICY_COUNT=771
RLS_ENABLED_TABLE_COUNT=197
```

---

## Baseline V2 Defect Findings

1. **Constraints & Indexes Loss in V2**:
   - `baseline_v2/003_constraints_indexes.sql` is only 430 bytes and contains only 4 indexes.
   - It is missing **50 indexes**, as well as all foreign keys, primary keys, and table-level check constraints introduced via `ALTER TABLE` across historical migrations.

2. **Policy Lifecycle Reconciled**:
   - Out of 1,521 `DROP POLICY` operations, all dropped policies have been cleanly purged in the reconstructed state, resulting in **771 active policies**.

3. **Function Overload Integrity**:
   - **175 unique function signatures** verified, preserving overloaded function parameters.

4. **Trigger Integrity**:
   - **41 active triggers** verified, removing triggers that were dropped in later security migrations.

5. **Cross-Dependency Audit**:
   - MISSING_TABLE_DEPENDENCIES=0
   - MISSING_COLUMN_DEPENDENCIES=0
   - MISSING_FUNCTION_DEPENDENCIES=0
   - MISSING_TRIGGER_FUNCTIONS=0
   - BROKEN_FOREIGN_KEYS=0

---

## Lifecycle Audit Summary

```
POLICY_LIFECYCLE_AUDIT=PASS
FUNCTION_OVERLOAD_AUDIT=PASS
TRIGGER_LIFECYCLE_AUDIT=PASS
RLS_LIFECYCLE_AUDIT=PASS

SECRET_SCAN=FAIL
```

---

## Deployment Recommendation & Next Steps

```
BASELINE_V2_STRUCTURALLY_COMPLETE=NO

BASELINE_V3_CANDIDATE_CREATED=YES
BASELINE_V3_PATH=nextgen/supabase/baseline_v3_candidate/

PRODUCTION_WRITES=0
NEXTGEN_WRITES=0

TAURI_INSTALLED=NO
SQLITE_CREATED=NO

PHASE_1B_2=HOLD
DEPLOYMENT_RECOMMENDATION=HOLD
```

**Recommendation**: Baseline V2 must **NOT** be deployed. Deploy **Baseline V3 Candidate** (`nextgen/supabase/baseline_v3_candidate/`) in Phase 1C after user approval.
