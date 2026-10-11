/**
 * CHEESYOS NEXTGEN — SUPABASE CLIENT BOUNDARY
 * Isolated Supabase client creator for NextGen applications (Project: sdbnibyzqtgpbexlznat).
 * 
 * STRICT SECURITY CONSTRAINTS:
 * - NO service-role keys allowed.
 * - NO production project URL (asvkfvrbhvxjmkznnpyb) allowed.
 * - Browser/Desktop clients MUST use publishable anon key only.
 */

import { createClient, SupabaseClient } from '@supabase/supabase-js';
import type { Database } from './database.types.js';

export const NEXTGEN_PROJECT_REF = 'sdbnibyzqtgpbexlznat';
export const FORBIDDEN_PRODUCTION_PROJECT_REF = 'asvkfvrbhvxjmkznnpyb';

export interface NextGenSupabaseConfig {
  supabaseUrl?: string;
  supabaseAnonKey?: string;
}

/**
 * Creates a strongly-typed Supabase client targeting NextGen Dev Supabase.
 */
export function createNextGenSupabaseClient(
  config?: NextGenSupabaseConfig
): SupabaseClient<Database> {
  const url = config?.supabaseUrl || (typeof process !== 'undefined' ? process.env?.NEXTGEN_SUPABASE_URL : undefined);
  const anonKey = config?.supabaseAnonKey || (typeof process !== 'undefined' ? process.env?.NEXTGEN_SUPABASE_ANON_KEY : undefined);

  if (!url || !anonKey) {
    throw new Error(
      '[NextGen Supabase] Missing NEXTGEN_SUPABASE_URL or NEXTGEN_SUPABASE_ANON_KEY. ' +
      'NextGen applications must explicitly set separate environment variables and target project: ' +
      NEXTGEN_PROJECT_REF
    );
  }

  // Safety Assertion: Reject accidental production project reference
  if (url.includes(FORBIDDEN_PRODUCTION_PROJECT_REF)) {
    throw new Error(
      '[NextGen Supabase] FORBIDDEN ENVIRONMENT CONFIGURATION: Attempted to connect NextGen client to production project reference (' +
      FORBIDDEN_PRODUCTION_PROJECT_REF + '). NextGen must connect strictly to ' + NEXTGEN_PROJECT_REF
    );
  }

  return createClient<Database>(url, anonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  });
}
