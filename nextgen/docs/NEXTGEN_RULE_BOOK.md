# CHEESYOS NEXTGEN — PERMANENT RULE BOOK

**Status**: ACTIVE & MANDATORY FOR ALL NEXTGEN IMPLEMENTATION TASKS  
**Scope**: Applies to all NextGen repositories, applications, database schema designs, services, and sync engines.

---

## MANDATORY COMPLIANCE DIRECTIVE

From Phase 1 onward, **EVERY** CheesyOS NextGen implementation task MUST begin by loading and enforcing this Rule Book.

Every future implementation prompt, plan, and final completion report MUST explicitly include:

```text
RULE_BOOK_STATUS: LOADED AND ENFORCED
```

If any requested feature or refactoring conflicts with this Rule Book:
1. **STOP IMMEDIATELY**.
2. Do **NOT** modify code or schema silently.
3. Report the conflict explicitly and wait for architecture approval.

---

## THE 11 MANDATORY NEXTGEN RULES

### RULE 1 — MINIMUM CODE
Implement requirements using the smallest, safest amount of code possible.
- Focus strictly on current approved V1 requirements.
- Do not write code or create abstractions for hypothetical future requirements.
- Minimal lines of code = minimal bug surface = maximum operational reliability.

---

### RULE 2 — NO SPECULATIVE FEATURES
Do not create:
- Placeholder modules or empty service directories
- Unused database tables or unused columns
- Future APIs or dead RPC endpoints
- Unused abstractions or unused utility functions
- Unused routes or draft UI tabs

Architecture may remain extensible, but implementation must remain **V1-only**.

---

### RULE 3 — ONE BUSINESS RULE = ONE IMPLEMENTATION
Web POS and Windows POS must share business and domain logic wherever practical.
Do **NOT** duplicate business logic across applications.
Shared domain modules MUST be used for:
- Order totals computation
- Tax calculations (CGST/SGST/IGST)
- Discount application (percentage, flat amount, item-wise vs order-level)
- Order validation & state transitions
- KOT generation and correction rules
- Billing & invoice calculation
- Ready-to-use Inventory deductions

---

### RULE 4 — NO PREMATURE ABSTRACTION
Do not introduce unnecessary complex design patterns or class hierarchies.
Specifically avoid creating unneeded:
- Managers
- Factories
- Providers
- Adapters
- Registries
- Coordinators
- Orchestrators

Prefer simple, readable, functional modules with clear inputs and outputs.

---

### RULE 5 — NO UNNECESSARY DEPENDENCIES
Every new package or library added to `package.json` or Cargo/build manifests MUST have a documented, current V1 justification.
- Do not install heavyweight frameworks or libraries for simple tasks.
- Use native platform features (Fetch API, standard DOM, Web Crypto) wherever possible.

---

### RULE 6 — NO UNRELATED REFACTORING
Use the smallest safe change to fulfill a task.
Never modify unrelated working functionality while implementing a new feature or fixing a bug.

**PROTECTED CORE FLOWS** (Requires explicit verification and safety checks):
1. Orders Lifecycle (`draft` -> `pending` -> `kot_sent` -> `billed` -> `settled` -> `closed`)
2. Billing Lifecycle & Invoicing
3. Cart Management & Item Aggregation
4. KOT Ledger & KOT Corrections
5. Table Sessions & Floor Management
6. Physical / Logical Tables State
7. Payments & Refund Ledger
8. Offline Outbox & Cloud Sync Engine

---

### RULE 7 — NO POLLING STORMS
Aggressive full-table or unindexed polling is **STRICTLY FORBIDDEN**.
Network and database sync must rely on:
- Supabase Realtime broadcast/presence signals where appropriate
- Delta sync based on `updated_at` timestamps
- Window focus / network reconnect refresh triggers
- Manual user-initiated pull
- Bounded, lightweight fallback checks (e.g., exponential backoff)

---

### RULE 8 — SECURITY CANNOT BE REMOVED TO REDUCE CODE
"Code-Lite" means eliminating unnecessary business complexity, **NOT** compromising security.
The following security layers are **NON-NEGOTIABLE**:
- Authentication & JWT validation
- App-specific role & permission authorization
- Row Level Security (RLS) on all Supabase tables
- Input sanitization & schema-based validation
- Idempotency key verification on critical RPCs
- Financial auditability & payment ledger history
- Database transaction safety

---

### RULE 9 — STOP WHEN REQUIREMENT IS COMPLETE
Once acceptance criteria for a feature or bug fix pass:
**STOP CODING.**
Do not continue with opportunistic refactoring, code formatting sweeps, unrequested optimizations, or extra feature additions unless explicitly requested.

---

### RULE 10 — CHANGE BUDGET REPORTING
Before **EVERY** future implementation task, report the proposed Change Budget:

```text
RULE_BOOK_STATUS=LOADED AND ENFORCED

FILES_TO_CREATE=
FILES_TO_MODIFY=

NEW_TABLES=
NEW_RPCS=
NEW_DEPENDENCIES=

PROTECTED_FLOWS_AFFECTED=

WHY_THIS_IS_THE_SMALLEST_SAFE_IMPLEMENTATION=
```

If a simple requirement unexpectedly requires a large or widespread code change:
**STOP** immediately and request an architecture review.

---

### RULE 11 — NO DONE WITHOUT EVIDENCE
Never claim "Fixed", "Completed", or "Done" merely because code was written or compiled.
Every task completion report MUST provide empirical evidence from:
- Successful clean build logs
- Automated unit/integration test results
- Verified database state / SQL output
- Actual end-to-end user workflow execution
- Verified offline-to-online sync behavior
- Regression testing verification against protected flows
