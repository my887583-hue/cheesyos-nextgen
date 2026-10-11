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

let dbInstance: TauriPosPersistence | null = null;
let orchestratorInstance: SyncRuntimeOrchestrator | null = null;
let lifecycleInstance: WindowsPosLifecycleManager | null = null;

export function getLocalDbSingleton(): IPosPersistence | null {
  return dbInstance;
}

export function getSyncOrchestratorSingleton(): SyncRuntimeOrchestrator | null {
  return orchestratorInstance;
}

export function getHostLifecycleSingleton(): WindowsPosLifecycleManager | null {
  return lifecycleInstance;
}

export function disposePosHost(): void {
  if (lifecycleInstance) {
    lifecycleInstance.dispose();
    lifecycleInstance = null;
  }
  orchestratorInstance = null;
  dbInstance = null;
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
  let supabaseClient: ReturnType<typeof createNextGenSupabaseClient> | null = null;
  try {
    const supabaseUrl = import.meta.env.VITE_NEXTGEN_SUPABASE_URL || process.env.VITE_NEXTGEN_SUPABASE_URL;
    const supabaseAnonKey = import.meta.env.VITE_NEXTGEN_SUPABASE_ANON_KEY || process.env.VITE_NEXTGEN_SUPABASE_ANON_KEY;

    if (!supabaseUrl || !supabaseAnonKey) {
      status.supabaseError = 'VITE_NEXTGEN_SUPABASE_URL or VITE_NEXTGEN_SUPABASE_ANON_KEY missing in environment';
    } else {
      supabaseClient = createNextGenSupabaseClient({ supabaseUrl, supabaseAnonKey });
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
  if (dbInstance && supabaseClient) {
    try {
      const pushTransport = options?.pushTransport ?? (
        options?.getStaffToken
          ? createTauriPushTransport({ getStaffToken: options.getStaffToken })
          : createSupabasePushTransport(supabaseClient)
      );
      const pullTransport = createSupabasePullTransport(supabaseClient);
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
          isAuthSessionReady: () => false, // Gated: no authenticated staff session in Windows host yet
        });
        lifecycleInstance.start();
      }
      status.lifecycleReady = true;
      status.authSessionReady = lifecycleInstance.getStatus().authSessionReady;
    } catch (err: any) {
      status.lifecycleReady = false;
    }
  }

  status.state = (status.supabaseConfigured && status.localDbReady) ? 'READY' : 'ERROR';
  return status;
}
