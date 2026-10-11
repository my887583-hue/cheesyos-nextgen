/**
 * CHEESYOS NEXTGEN POS SYNC — RUNTIME ORCHESTRATION LAYER
 * 
 * Provides single-flight execution, request coalescing, stream-scoped periodic eligibility,
 * and error stopping policies around verified runPushCycle() and runPullCycle() workers.
 * 
 * Guarantees:
 * - Single-flight: at most 1 active push cycle and 1 active pull cycle.
 * - Coalesced follow-up: queued triggers during in-flight cycles execute at most 1 follow-up run.
 * - Zero timers, zero loops, zero realtime, zero network preflight pings.
 */

import type { PosLocalDatabase, IPosLocalDatabase, IPosPersistence } from '@cheesyos/pos-local';
import {
  runPushCycle,
  CloudRpcTransport,
  PushCycleResult,
} from './push.js';
import {
  runPullCycle,
  CloudPullTransport,
  PullCycleResult,
  PullDataset,
  DEFAULT_PULL_DATASETS,
} from './pull.js';

export const OPERATIONAL_DATASETS: PullDataset[] = [
  'orders',
  'pos_kots',
  'kot_corrections',
  'bills',
  'payments',
  'table_sessions',
  'pos_tables',
];

export const MASTER_DATASETS: PullDataset[] = [
  'categories',
  'products',
  'product_variants',
  'inventory_lite',
];

export const CUSTOMER_DATASETS: PullDataset[] = [
  'customers',
];

export const OPERATIONAL_MIN_INTERVAL_MS = 5 * 60 * 1000;  // 5 minutes
export const MASTER_MIN_INTERVAL_MS = 20 * 60 * 1000;       // 20 minutes
export const CUSTOMER_MIN_INTERVAL_MS = 20 * 60 * 1000;     // 20 minutes

export interface SyncRuntimeOptions {
  dbManager: IPosPersistence | IPosLocalDatabase | PosLocalDatabase;
  pushTransport: CloudRpcTransport;
  pullTransport: CloudPullTransport;
  nowFn?: () => number;
}

export interface SyncRuntimeStatus {
  isPushActive: boolean;
  isPullActive: boolean;
  hasPendingPushFollowUp: boolean;
  lastOperationalPullAt: number | null;
  lastMasterPullAt: number | null;
  lastCustomerPullAt: number | null;
  lastPushResult: PushCycleResult | null;
  lastPullResult: PullCycleResult | null;
}

export interface StartupSyncResult {
  pushResult: PushCycleResult;
  pullResult?: PullCycleResult;
}

export interface ReconnectSyncResult {
  pushResult: PushCycleResult;
  pullResult?: PullCycleResult;
}

export class SyncRuntimeOrchestrator {
  private options: SyncRuntimeOptions;

  private pushInFlightPromise: Promise<PushCycleResult> | null = null;
  private hasPendingPushFollowUp: boolean = false;

  private pullInFlightPromise: Promise<PullCycleResult> | null = null;

  private lastOperationalPullAt: number | null = null;
  private lastMasterPullAt: number | null = null;
  private lastCustomerPullAt: number | null = null;

  private lastPushResult: PushCycleResult | null = null;
  private lastPullResult: PullCycleResult | null = null;

  constructor(options: SyncRuntimeOptions) {
    this.options = options;
  }

  private getNow(): number {
    return this.options.nowFn ? this.options.nowFn() : Date.now();
  }

  public getStatus(): SyncRuntimeStatus {
    return {
      isPushActive: this.pushInFlightPromise !== null,
      isPullActive: this.pullInFlightPromise !== null,
      hasPendingPushFollowUp: this.hasPendingPushFollowUp,
      lastOperationalPullAt: this.lastOperationalPullAt,
      lastMasterPullAt: this.lastMasterPullAt,
      lastCustomerPullAt: this.lastCustomerPullAt,
      lastPushResult: this.lastPushResult,
      lastPullResult: this.lastPullResult,
    };
  }

  /**
   * Explicit local-write push request (Push ASAP policy).
   * Single-flight: returns in-flight promise if push is already running and flags follow-up if new writes occurred.
   */
  public async requestPush(): Promise<PushCycleResult> {
    if (this.pushInFlightPromise) {
      this.hasPendingPushFollowUp = true;
      return this.pushInFlightPromise;
    }

    const runPush = async (): Promise<PushCycleResult> => {
      let result = await runPushCycle({
        dbManager: this.options.dbManager,
        transport: this.options.pushTransport,
      });
      this.lastPushResult = result;

      // Coalesced follow-up execution if write occurred while push was in flight
      if (this.hasPendingPushFollowUp && (result.status === 'COMPLETED' || result.status === 'IDLE')) {
        this.hasPendingPushFollowUp = false;
        result = await runPushCycle({
          dbManager: this.options.dbManager,
          transport: this.options.pushTransport,
        });
        this.lastPushResult = result;
      } else {
        this.hasPendingPushFollowUp = false;
      }

      this.pushInFlightPromise = null;
      return result;
    };

    this.pushInFlightPromise = runPush();
    return this.pushInFlightPromise;
  }

  /**
   * Requests a pull cycle for specific datasets or default all datasets.
   * Single-flight protected: returns in-flight promise if pull is already active.
   */
  public async requestPull(datasetsToFetch?: PullDataset[]): Promise<PullCycleResult> {
    const targetDatasets = datasetsToFetch || DEFAULT_PULL_DATASETS;

    if (this.pullInFlightPromise) {
      return this.pullInFlightPromise;
    }

    const runPull = async (ds: PullDataset[]): Promise<PullCycleResult> => {
      const result = await runPullCycle({
        dbManager: this.options.dbManager,
        transport: this.options.pullTransport,
        datasets: ds,
      });
      this.lastPullResult = result;

      if (result.status === 'COMPLETED' || result.status === 'IDLE') {
        const now = this.getNow();
        if (ds.some(d => OPERATIONAL_DATASETS.includes(d))) this.lastOperationalPullAt = now;
        if (ds.some(d => MASTER_DATASETS.includes(d))) this.lastMasterPullAt = now;
        if (ds.some(d => CUSTOMER_DATASETS.includes(d))) this.lastCustomerPullAt = now;
      }

      this.pullInFlightPromise = null;
      return result;
    };

    this.pullInFlightPromise = runPull(targetDatasets);
    return this.pullInFlightPromise;
  }

  /**
   * Application startup sync: PUSH local offline work first, then PULL cloud delta.
   * Stops startup sync immediately if push encounters AUTH_REQUIRED or RETRYABLE failure.
   */
  public async requestStartupSync(): Promise<StartupSyncResult> {
    const pushResult = await this.requestPush();

    if (
      pushResult.status === 'AUTH_REQUIRED_STOPPED' ||
      pushResult.status === 'RETRYABLE_STOPPED' ||
      pushResult.status === 'CONTRACT_CONFLICT_STOPPED' ||
      pushResult.status === 'QUEUE_CONFLICT_STOPPED'
    ) {
      return { pushResult };
    }

    const pullResult = await this.requestPull(DEFAULT_PULL_DATASETS);
    return { pushResult, pullResult };
  }

  /**
   * Reconnect sync: PUSH local outbox first, then PULL operational datasets.
   */
  public async requestReconnectSync(): Promise<ReconnectSyncResult> {
    const pushResult = await this.requestPush();

    if (
      pushResult.status === 'AUTH_REQUIRED_STOPPED' ||
      pushResult.status === 'RETRYABLE_STOPPED' ||
      pushResult.status === 'CONTRACT_CONFLICT_STOPPED' ||
      pushResult.status === 'QUEUE_CONFLICT_STOPPED'
    ) {
      return { pushResult };
    }

    const pullResult = await this.requestPull(OPERATIONAL_DATASETS);
    return { pushResult, pullResult };
  }

  /**
   * Foreground / Window focus sync request: PULL operational datasets.
   */
  public async requestForegroundSync(): Promise<PullCycleResult> {
    return this.requestPull(OPERATIONAL_DATASETS);
  }

  /**
   * Explicit manual refresh request.
   */
  public async requestManualRefresh(
    scope: 'all' | 'operational' | 'master' | 'customer' = 'all'
  ): Promise<PullCycleResult> {
    let ds: PullDataset[];
    if (scope === 'operational') ds = OPERATIONAL_DATASETS;
    else if (scope === 'master') ds = MASTER_DATASETS;
    else if (scope === 'customer') ds = CUSTOMER_DATASETS;
    else ds = DEFAULT_PULL_DATASETS;

    return this.requestPull(ds);
  }

  // Periodic Pull Eligibility Checks
  public shouldRunOperationalPull(nowOverride?: number): boolean {
    const now = nowOverride ?? this.getNow();
    if (this.lastOperationalPullAt === null) return true;
    return (now - this.lastOperationalPullAt) >= OPERATIONAL_MIN_INTERVAL_MS;
  }

  public shouldRunMasterPull(nowOverride?: number): boolean {
    const now = nowOverride ?? this.getNow();
    if (this.lastMasterPullAt === null) return true;
    return (now - this.lastMasterPullAt) >= MASTER_MIN_INTERVAL_MS;
  }

  public shouldRunCustomerPull(nowOverride?: number): boolean {
    const now = nowOverride ?? this.getNow();
    if (this.lastCustomerPullAt === null) return true;
    return (now - this.lastCustomerPullAt) >= CUSTOMER_MIN_INTERVAL_MS;
  }

  /**
   * Periodic pull caller primitive: checks eligibility and fetches eligible dataset streams only.
   */
  public async requestPeriodicPull(nowOverride?: number): Promise<PullCycleResult | null> {
    const now = nowOverride ?? this.getNow();
    const datasetsToPull: PullDataset[] = [];

    if (this.shouldRunOperationalPull(now)) {
      datasetsToPull.push(...OPERATIONAL_DATASETS);
    }
    if (this.shouldRunMasterPull(now)) {
      datasetsToPull.push(...MASTER_DATASETS);
    }
    if (this.shouldRunCustomerPull(now)) {
      datasetsToPull.push(...CUSTOMER_DATASETS);
    }

    if (datasetsToPull.length === 0) {
      return null;
    }

    return this.requestPull(datasetsToPull);
  }
}
