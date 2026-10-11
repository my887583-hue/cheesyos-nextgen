/**
 * CHEESYOS NEXTGEN — TARGET PROJECT SAFETY GUARD
 * Enforces strict isolation: Production project 'asvkfvrbhvxjmkznnpyb' is READ-ONLY.
 */

const PRODUCTION_PROJECT_REF = "asvkfvrbhvxjmkznnpyb";
const NEXTGEN_PROJECT_REF    = "sdbnibyzqtgpbexlznat";

function validateTargetProject(targetRef) {
  if (!targetRef) {
    throw new Error("[SAFETY GUARD ERROR] Target project ref is undefined.");
  }
  
  if (targetRef === PRODUCTION_PROJECT_REF) {
    throw new Error(
      `[CRITICAL SAFETY VIOLATION] Target ref '${targetRef}' matches PRODUCTION. ` +
      `DDL/DML modifications against Production project 'asvkfvrbhvxjmkznnpyb' are ABSOLUTELY FORBIDDEN.`
    );
  }

  if (targetRef !== NEXTGEN_PROJECT_REF) {
    throw new Error(`[SAFETY GUARD ERROR] Target ref '${targetRef}' does not match NextGen project '${NEXTGEN_PROJECT_REF}'.`);
  }

  console.log(`[SAFETY GUARD] Target project ref '${targetRef}' verified SAFE for NextGen operations.`);
  return true;
}

async function verifyNextGenProjectStatus() {
  const nextgenUrl = `https://${NEXTGEN_PROJECT_REF}.supabase.co`;
  console.log(`[NEXTGEN STATUS] Checking HTTP connectivity for '${nextgenUrl}'...`);
  
  try {
    const res = await fetch(`${nextgenUrl}/rest/v1/`);
    // HTTP 401/200/404 indicates server is active and listening
    if (res.status === 401 || res.status === 200 || res.status === 404) {
      console.log(`[NEXTGEN STATUS] Project '${NEXTGEN_PROJECT_REF}' is ACTIVE (HTTP Status: ${res.status}).`);
      return true;
    } else {
      console.warn(`[NEXTGEN STATUS] Unexpected HTTP status ${res.status} from project '${NEXTGEN_PROJECT_REF}'.`);
      return false;
    }
  } catch (err) {
    console.error(`[NEXTGEN STATUS ERROR] Failed to connect to NextGen project '${NEXTGEN_PROJECT_REF}':`, err.message);
    return false;
  }
}

async function main() {
  console.log("=== CHEESYOS NEXTGEN TARGET SAFETY CHECK ===");
  console.log(`PRODUCTION_PROJECT_REF: ${PRODUCTION_PROJECT_REF}`);
  console.log(`NEXTGEN_PROJECT_REF:    ${NEXTGEN_PROJECT_REF}`);

  // Test safety validation against NextGen
  validateTargetProject(NEXTGEN_PROJECT_REF);

  // Verify NextGen endpoint status
  const active = await verifyNextGenProjectStatus();
  if (!active) {
    console.error("[NEXTGEN VERIFICATION] NextGen project is not active. Stopping safely.");
    process.exit(1);
  }

  console.log("============================================");
  console.log("NEXTGEN TARGET SAFETY CHECK: PASS");
}

if (require.main === module) {
  main().catch(err => {
    console.error("Safety check failed:", err.message);
    process.exit(1);
  });
}

module.exports = {
  PRODUCTION_PROJECT_REF,
  NEXTGEN_PROJECT_REF,
  validateTargetProject,
  verifyNextGenProjectStatus
};
