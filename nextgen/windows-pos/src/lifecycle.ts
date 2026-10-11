/**
 * CHEESYOS NEXTGEN WINDOWS POS — RUNTIME EVENT & LIFECYCLE MANAGER
 * 
 * Host-level lifecycle coordinator that connects:
 * 1. Startup synchronization (PUSH then PULL gated by staff auth session)
 * 2. Local committed write signals (Push ASAP via orchestrator coalescing)
 * 3. Network reconnect (window:online -> PUSH then Operational PULL)
 * 4. App foreground / focus (visibilitychange / focus -> Operational PULL with 1s throttle guard)
 * 5. Bounded periodic eligibility wake (60s tick -> orchestrator stream-scoped eligibility check)
 * 6. Manual refresh foundation API (demand-driven scoped pull)
 * 
 * INVARIANTS:
 * - Exactly ONE instance active per application host.
 * - Zero timers/loops in orchestrator (periodic wake timer is owned solely by host lifecycle).
 * - React StrictMode duplicate-safe (idempotent start / clean disposal).
 * - Local DB and outbox are strictly preserved across offline, reconnect, and auth gating.
 */

import type {
  SyncRuntimeOrchestrator,
  PullCycleResult,
  PushCycleResult,
  StartupSyncResult,
  ReconnectSyncResult,
} from '@cheesyos/pos-sync';
import type { TauriPosPersistence } from './tauri-adapter.js';

export interface LifecycleManagerOptions {
  persistence: TauriPosPersistence;
  orchestrator: SyncRuntimeOrchestrator;
  isAuthSessionReady?: () => boolean;
  wakeIntervalMs?: number; // default 60000 (60s)
  nowFn?: () => number;
}

export interface LifecycleStatus {
  isRunning: boolean;
  isOnline: boolean;
  isDocumentVisible: boolean;
  authSessionReady: boolean;
  wakeTimerActive: boolean;
  lastWakeAt: number | null;
  lastForegroundAt: number | null;
  lastReconnectAt: number | null;
}

export class WindowsPosLifecycleManager {
  private persistence: TauriPosPersistence;
  private orchestrator: SyncRuntimeOrchestrator;
  private isAuthSessionReadyFn: () => boolean;
  private wakeIntervalMs: number;
  private nowFn: () => number;

  private isRunning: boolean = false;
  private wakeTimerId: any = null;
  private unbindCommittedWrite: (() => void) | null = null;

  private isOnline: boolean = true;
  private isDocumentVisible: boolean = true;
  private lastWakeAt: number | null = null;
  private lastForegroundAt: number | null = null;
  private lastReconnectAt: number | null = null;

  // Bound event handlers for DOM/Window listener cleanup
  private boundOnOnline: (() => void) | null = null;
  private boundOnOffline: (() => void) | null = null;
  private boundOnVisibilityChange: (() => void) | null = null;
  private boundOnFocus: (() => void) | null = null;

  constructor(options: LifecycleManagerOptions) {
    this.persistence = options.persistence;
    this.orchestrator = options.orchestrator;
    this.isAuthSessionReadyFn = options.isAuthSessionReady || (() => false);
    this.wakeIntervalMs = options.wakeIntervalMs ?? 60000;
    this.nowFn = options.nowFn ?? (() => Date.now());
  }

  private getNow(): number {
    return this.nowFn();
  }

  public getStatus(): LifecycleStatus {
    return {
      isRunning: this.isRunning,
      isOnline: this.isOnline,
      isDocumentVisible: this.isDocumentVisible,
      authSessionReady: this.isAuthSessionReadyFn(),
      wakeTimerActive: this.wakeTimerId !== null,
      lastWakeAt: this.lastWakeAt,
      lastForegroundAt: this.lastForegroundAt,
      lastReconnectAt: this.lastReconnectAt,
    };
  }

  /**
   * Starts lifecycle monitoring, event subscriptions, and periodic wake timer.
   * Idempotent: repeated calls do not create duplicate listeners or timers.
   */
  public start(): void {
    if (this.isRunning) {
      return;
    }
    this.isRunning = true;

    // 1. Subscribe to local committed write events (Push ASAP policy)
    this.unbindCommittedWrite = this.persistence.onCommittedWrite((_entityType) => {
      this.handleCommittedWrite();
    });

    // 2. Attach browser / Webview lifecycle listeners if in browser environment
    if (typeof window !== 'undefined') {
      this.isOnline = typeof navigator !== 'undefined' ? navigator.onLine : true;

      this.boundOnOnline = () => this.handleOnline();
      this.boundOnOffline = () => this.handleOffline();
      this.boundOnVisibilityChange = () => this.handleVisibilityChange();
      this.boundOnFocus = () => this.handleFocus();

      window.addEventListener('online', this.boundOnOnline);
      window.addEventListener('offline', this.boundOnOffline);

      if (typeof document !== 'undefined') {
        document.addEventListener('visibilitychange', this.boundOnVisibilityChange);
      }
      window.addEventListener('focus', this.boundOnFocus);
    }

    // 3. Start bounded periodic eligibility wake timer (60s tick)
    if (this.wakeIntervalMs > 0) {
      this.wakeTimerId = setInterval(() => {
        this.handlePeriodicWake();
      }, this.wakeIntervalMs);
      if (typeof this.wakeTimerId === 'object' && typeof (this.wakeTimerId as any)?.unref === 'function') {
        (this.wakeTimerId as any).unref();
      }
    }

    // 4. Evaluate Startup Sync prerequisite
    if (this.isAuthSessionReadyFn()) {
      this.orchestrator.requestStartupSync().catch((err) => {
        console.warn('[WindowsPosLifecycleManager] Startup sync encountered error:', err);
      });
    }
  }

  /**
   * Cleans up all event listeners, periodic timers, and persistence hooks.
   * Safe to call repeatedly and during component unmount.
   */
  public dispose(): void {
    if (!this.isRunning) {
      return;
    }
    this.isRunning = false;

    // Clear wake interval timer
    if (this.wakeTimerId !== null) {
      clearInterval(this.wakeTimerId);
      this.wakeTimerId = null;
    }

    // Unbind committed write listener
    if (this.unbindCommittedWrite) {
      this.unbindCommittedWrite();
      this.unbindCommittedWrite = null;
    }

    // Remove window/document listeners
    if (typeof window !== 'undefined') {
      if (this.boundOnOnline) {
        window.removeEventListener('online', this.boundOnOnline);
        this.boundOnOnline = null;
      }
      if (this.boundOnOffline) {
        window.removeEventListener('offline', this.boundOnOffline);
        this.boundOnOffline = null;
      }
      if (this.boundOnFocus) {
        window.removeEventListener('focus', this.boundOnFocus);
        this.boundOnFocus = null;
      }
      if (typeof document !== 'undefined' && this.boundOnVisibilityChange) {
        document.removeEventListener('visibilitychange', this.boundOnVisibilityChange);
        this.boundOnVisibilityChange = null;
      }
    }
  }

  /**
   * Local committed write handler: requests push through orchestrator (Push ASAP).
   * Coalescing & single-flight in orchestrator prevents push storms.
   */
  public handleCommittedWrite(): Promise<PushCycleResult> {
    return this.orchestrator.requestPush();
  }

  /**
   * Network online reconnect handler: requests PUSH then OPERATIONAL PULL.
   * Gated if auth session is not yet ready.
   */
  public handleOnline(): Promise<ReconnectSyncResult | null> {
    this.isOnline = true;
    this.lastReconnectAt = this.getNow();

    if (!this.isAuthSessionReadyFn()) {
      return Promise.resolve(null);
    }

    return this.orchestrator.requestReconnectSync();
  }

  public handleOffline(): void {
    this.isOnline = false;
  }

  /**
   * Document visibility / foreground handler.
   */
  public handleVisibilityChange(): Promise<PullCycleResult | null> {
    if (typeof document !== 'undefined') {
      this.isDocumentVisible = document.visibilityState === 'visible';
      if (this.isDocumentVisible) {
        return this.triggerForegroundSync();
      }
    }
    return Promise.resolve(null);
  }

  /**
   * Window focus handler.
   */
  public handleFocus(): Promise<PullCycleResult | null> {
    return this.triggerForegroundSync();
  }

  /**
   * Foreground trigger with 1000ms duplicate guard.
   */
  public triggerForegroundSync(): Promise<PullCycleResult | null> {
    const now = this.getNow();
    if (this.lastForegroundAt !== null && (now - this.lastForegroundAt) < 1000) {
      // Guarded duplicate within 1000ms
      return Promise.resolve(null);
    }
    this.lastForegroundAt = now;

    if (!this.isAuthSessionReadyFn()) {
      return Promise.resolve(null);
    }

    return this.orchestrator.requestForegroundSync();
  }

  /**
   * Bounded periodic eligibility wake: calls requestPeriodicPull().
   * Orchestrator checks stream-scoped elapsed time (5m operational, 20m master, 20m customer).
   */
  public handlePeriodicWake(nowOverride?: number): Promise<PullCycleResult | null> {
    const now = nowOverride ?? this.getNow();
    this.lastWakeAt = now;

    if (!this.isAuthSessionReadyFn()) {
      return Promise.resolve(null);
    }

    return this.orchestrator.requestPeriodicPull(now);
  }

  /**
   * Manual refresh foundation API for future UI.
   */
  public manualRefresh(
    scope: 'all' | 'operational' | 'master' | 'customer' = 'all'
  ): Promise<PullCycleResult> {
    return this.orchestrator.requestManualRefresh(scope);
  }

  /**
   * Dynamic auth session state update hook (e.g. staff PIN login / logout).
   * If transitioned to true, triggers startup sync.
   */
  public setAuthSessionReady(ready: boolean): Promise<StartupSyncResult | null> {
    const wasReady = this.isAuthSessionReadyFn();
    this.isAuthSessionReadyFn = () => ready;

    if (!wasReady && ready && this.isRunning) {
      return this.orchestrator.requestStartupSync();
    }
    return Promise.resolve(null);
  }
}
