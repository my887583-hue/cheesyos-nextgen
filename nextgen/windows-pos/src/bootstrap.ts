/**
 * CHEESYOS NEXTGEN POS HOST — BOOTSTRAP INITIALIZATION BOUNDARY
 * 
 * Safely initializes Supabase client, validates environment,
 * checks local database availability, and prepares runtime orchestrator boundary.
 */

import { createNextGenSupabaseClient } from '@cheesyos/nextgen-shared';
import type { IPosPersistence } from '@cheesyos/pos-local';
import { SyncRuntimeOrchestrator, createSupabasePushTransport, createSupabasePullTransport, type CloudRpcTransport } from '@cheesyos/pos-sync';
import { createTauriPosPersistence, TauriPosPersistence, createTauriPushTransport } from './tauri-adapter.js';
import { WindowsPosLifecycleManager } from './lifecycle.js';

export interface BootstrapPosHostOptions {
  pushTransport?: CloudRpcTransport;
  getStaffToken?: () => Promise<string | null> | string | null;
  supabaseClient?: ReturnType<typeof createNextGenSupabaseClient>;
}

export interface HostRuntimeStatus {
  state: 'INITIALIZING' | 'READY' | 'ERROR';
  supabaseConfigured: boolean;
  supabaseError?: string;
  localDbReady: boolean;
  localDbError?: string;
  orchestratorReady: boolean;
  browserCompatible: boolean;
  deviceConfigured: boolean;
  authSessionReady: boolean;
  lifecycleReady: boolean;
}

export interface StaffAuthProfile {
  id: string;
  fullName: string;
  role: 'cashier' | 'manager' | 'admin' | 'owner';
  hasPosAccess: boolean;
  hasAdminAccess: boolean;
  isActive: boolean;
}

export interface StaffAuthSession {
  userId: string;
  email: string;
  accessToken: string;
  profile: StaffAuthProfile;
}

export type StaffSignInErrorCode =
  | 'INVALID_CREDENTIALS'
  | 'STAFF_PROFILE_NOT_FOUND'
  | 'ACCOUNT_INACTIVE'
  | 'POS_ACCESS_DENIED'
  | 'NETWORK_ERROR'
  | 'CLIENT_NOT_INITIALIZED';

export interface StaffSignInResult {
  success: boolean;
  session?: StaffAuthSession;
  errorCode?: StaffSignInErrorCode;
  errorMessage?: string;
}

let dbInstance: TauriPosPersistence | null = null;
let orchestratorInstance: SyncRuntimeOrchestrator | null = null;
let lifecycleInstance: WindowsPosLifecycleManager | null = null;
let supabaseClientInstance: ReturnType<typeof createNextGenSupabaseClient> | null = null;
let activeStaffSession: StaffAuthSession | null = null;

export function getLocalDbSingleton(): IPosPersistence | null {
  return dbInstance;
}

export function getSyncOrchestratorSingleton(): SyncRuntimeOrchestrator | null {
  return orchestratorInstance;
}

export function getHostLifecycleSingleton(): WindowsPosLifecycleManager | null {
  return lifecycleInstance;
}

export function getSupabaseClientSingleton(): ReturnType<typeof createNextGenSupabaseClient> | null {
  return supabaseClientInstance;
}

export function getStaffAuthSession(): StaffAuthSession | null {
  return activeStaffSession;
}

export function isStaffAuthSessionReady(): boolean {
  return activeStaffSession !== null && activeStaffSession.profile.isActive && activeStaffSession.profile.hasPosAccess;
}

export async function signInStaff(email: string, password: string): Promise<StaffSignInResult> {
  if (!supabaseClientInstance) {
    return {
      success: false,
      errorCode: 'CLIENT_NOT_INITIALIZED',
      errorMessage: 'Cloud client is not initialized.',
    };
  }

  try {
    const { data: authData, error: authError } = await supabaseClientInstance.auth.signInWithPassword({
      email: email.trim(),
      password,
    });

    if (authError || !authData.user || !authData.session) {
      return {
        success: false,
        errorCode: 'INVALID_CREDENTIALS',
        errorMessage: 'Invalid email or password.',
      };
    }

    // Verify authenticated identity against staff_profiles using existing RLS contract
    const { data: profile, error: profileError } = await (supabaseClientInstance as any)
      .from('staff_profiles')
      .select('id, full_name, role, has_pos_access, has_admin_access, is_active')
      .eq('id', authData.user.id)
      .single();

    if (profileError || !profile) {
      await supabaseClientInstance.auth.signOut().catch(() => {});
      return {
        success: false,
        errorCode: 'STAFF_PROFILE_NOT_FOUND',
        errorMessage: 'Staff profile record not found for this account.',
      };
    }

    if (!profile.is_active) {
      await supabaseClientInstance.auth.signOut().catch(() => {});
      return {
        success: false,
        errorCode: 'ACCOUNT_INACTIVE',
        errorMessage: 'This staff account has been deactivated.',
      };
    }

    if (!profile.has_pos_access) {
      await supabaseClientInstance.auth.signOut().catch(() => {});
      return {
        success: false,
        errorCode: 'POS_ACCESS_DENIED',
        errorMessage: 'This staff account does not have POS access authorization.',
      };
    }

    const session: StaffAuthSession = {
      userId: authData.user.id,
      email: authData.user.email || email.trim(),
      accessToken: authData.session.access_token,
      profile: {
        id: profile.id,
        fullName: profile.full_name,
        role: profile.role,
        hasPosAccess: Boolean(profile.has_pos_access),
        hasAdminAccess: Boolean(profile.has_admin_access),
        isActive: Boolean(profile.is_active),
      },
    };

    activeStaffSession = session;

    if (lifecycleInstance) {
      await lifecycleInstance.setAuthSessionReady(isStaffAuthSessionReady());
    }

    return {
      success: true,
      session,
    };
  } catch (err: any) {
    return {
      success: false,
      errorCode: 'NETWORK_ERROR',
      errorMessage: err.message || 'Network error during staff authentication.',
    };
  }
}

export async function signOutStaff(): Promise<void> {
  activeStaffSession = null;
  if (lifecycleInstance) {
    await lifecycleInstance.setAuthSessionReady(false);
  }
  if (supabaseClientInstance) {
    await supabaseClientInstance.auth.signOut().catch(() => {});
  }
}

export function disposePosHost(): void {
  activeStaffSession = null;
  if (lifecycleInstance) {
    lifecycleInstance.dispose();
    lifecycleInstance = null;
  }
  orchestratorInstance = null;
  dbInstance = null;
  supabaseClientInstance = null;
}

export async function bootstrapPosHost(options?: BootstrapPosHostOptions): Promise<HostRuntimeStatus> {
  const status: HostRuntimeStatus = {
    state: 'INITIALIZING',
    supabaseConfigured: false,
    localDbReady: false,
    orchestratorReady: false,
    browserCompatible: typeof window !== 'undefined',
    deviceConfigured: false,
    authSessionReady: false,
    lifecycleReady: false,
  };

  // 1. Initialize Supabase NextGen Client Boundary
  try {
    if (options?.supabaseClient) {
      supabaseClientInstance = options.supabaseClient;
      status.supabaseConfigured = true;
    } else if (!supabaseClientInstance) {
      const supabaseUrl = import.meta.env.VITE_NEXTGEN_SUPABASE_URL || process.env.VITE_NEXTGEN_SUPABASE_URL;
      const supabaseAnonKey = import.meta.env.VITE_NEXTGEN_SUPABASE_ANON_KEY || process.env.VITE_NEXTGEN_SUPABASE_ANON_KEY;

      if (!supabaseUrl || !supabaseAnonKey) {
        status.supabaseError = 'VITE_NEXTGEN_SUPABASE_URL or VITE_NEXTGEN_SUPABASE_ANON_KEY missing in environment';
      } else {
        supabaseClientInstance = createNextGenSupabaseClient({ supabaseUrl, supabaseAnonKey });
        status.supabaseConfigured = true;
      }
    } else {
      status.supabaseConfigured = true;
    }
  } catch (err: any) {
    status.supabaseError = err.message || String(err);
  }

  // 2. Initialize Local SQLite Native Desktop Boundary
  try {
    if (!dbInstance) {
      dbInstance = createTauriPosPersistence();
      await dbInstance.initSchema();
    }
    status.localDbReady = true;

    // Check device identity status via native semantic boundary
    const config = await dbInstance.getDeviceConfig();
    status.deviceConfigured = Boolean(config);
  } catch (err: any) {
    status.localDbReady = false;
    status.localDbError = err.message || String(err);
  }

  // 3. Initialize SyncRuntimeOrchestrator Boundary if dependencies exist
  if (dbInstance && supabaseClientInstance) {
    try {
      const pushTransport = options?.pushTransport ?? (
        options?.getStaffToken
          ? createTauriPushTransport({ getStaffToken: options.getStaffToken })
          : createTauriPushTransport({ getStaffToken: () => activeStaffSession?.accessToken ?? null })
      );
      const pullTransport = createSupabasePullTransport(supabaseClientInstance);
      if (!orchestratorInstance) {
        orchestratorInstance = new SyncRuntimeOrchestrator({
          dbManager: dbInstance,
          pushTransport,
          pullTransport,
        });
      }
      status.orchestratorReady = true;
    } catch (err: any) {
      status.orchestratorReady = false;
    }
  }

  // 4. Initialize Single Host Lifecycle Manager (Wiring event listeners & 60s wake timer)
  if (dbInstance && orchestratorInstance) {
    try {
      if (!lifecycleInstance) {
        lifecycleInstance = new WindowsPosLifecycleManager({
          persistence: dbInstance,
          orchestrator: orchestratorInstance,
          isAuthSessionReady: () => isStaffAuthSessionReady(),
        });
        lifecycleInstance.start();
      }
      status.lifecycleReady = true;
      status.authSessionReady = isStaffAuthSessionReady();
    } catch (err: any) {
      status.lifecycleReady = false;
    }
  }

  status.state = (status.supabaseConfigured && status.localDbReady) ? 'READY' : 'ERROR';
  return status;
}
