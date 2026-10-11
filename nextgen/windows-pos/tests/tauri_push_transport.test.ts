/**
 * CHEESYOS NEXTGEN WINDOWS POS — TAURI PUSH TRANSPORT INTEGRATION TESTS
 * 
 * Verifies Phase 3G.1B:
 * - Finite 6-RPC mapping via native_pos_rpc command.
 * - Renderer provides staff token, Rust injects device credential.
 * - Plaintext device secret NEVER enters renderer JavaScript.
 * - Error classification mapping (DEVICE_REVOKED, DEVICE_AUTH_FAILED -> AUTH_REQUIRED).
 * - Integration with runPushCycle and outbox durability.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  createTauriPushTransport,
  nativeProvisionDevice,
  TauriInvokeHandler,
} from '../src/tauri-adapter.js';
import { runPushCycle, PushSyncError } from '@cheesyos/pos-sync';

describe('CHEESYOS NEXTGEN WINDOWS POS — TAURI NATIVE PUSH TRANSPORT', () => {

  it('1. FINITE 6-RPC DISPATCH: Dispatches all six operations through native_pos_rpc', async () => {
    const invokedCalls: Array<{ cmd: string; args: any }> = [];

    const mockInvoke: TauriInvokeHandler = async (cmd, args) => {
      invokedCalls.push({ cmd, args });
      return { success: true, data: true };
    };

    const staffToken = 'ey.valid.staff.token';
    const transport = createTauriPushTransport(mockInvoke, () => staffToken);

    // 1. Order
    await transport.syncOrder({ id: 'ord-1' }, [{ id: 'item-1' }]);
    // 2. Kot
    await transport.syncKot({ id: 'kot-1' }, [{ id: 'kitem-1' }]);
    // 3. KotCorrection
    await transport.syncKotCorrection({ id: 'cor-1' });
    // 4. Bill
    await transport.syncBill({ id: 'bill-1' });
    // 5. Payment
    await transport.syncPayment({ id: 'pay-1' });
    // 6. InventoryMovement
    await transport.applyInventoryMovement({
      productId: 'prod-1',
      movementType: 'WASTE',
      quantityChange: -2,
    });

    assert.equal(invokedCalls.length, 6);

    const ops = invokedCalls.map((c) => c.args?.req?.op);
    assert.deepEqual(ops, [
      'order',
      'kot',
      'kot_correction',
      'bill',
      'payment',
      'inventory_movement',
    ]);

    // Verify all calls carried the staff token
    for (const call of invokedCalls) {
      assert.equal(call.cmd, 'native_pos_rpc');
      assert.equal(call.args.req.staff_token, staffToken);
      // Plaintext device secret must NEVER be in JS payload
      assert.equal(call.args.req.device_token, undefined);
      assert.equal(call.args.req.payload.device_token, undefined);
    }
  });

  it('2. MISSING STAFF TOKEN: Rejects with AUTH_REQUIRED before IPC call', async () => {
    let invoked = false;
    const mockInvoke: TauriInvokeHandler = async () => {
      invoked = true;
      return { success: true };
    };

    const transport = createTauriPushTransport(mockInvoke, () => null);

    await assert.rejects(
      async () => {
        await transport.syncOrder({ id: 'ord-1' }, []);
      },
      (err: any) => {
        assert.ok(err instanceof PushSyncError);
        assert.equal(err.code, 'AUTH_REQUIRED');
        assert.match(err.message, /STAFF_TOKEN_MISSING/);
        return true;
      }
    );

    assert.equal(invoked, false, 'IPC must not be invoked when staff token is absent');
  });

  it('3. DEVICE REVOKED ERROR MAPPING: Maps DEVICE_REVOKED to AUTH_REQUIRED PushSyncError', async () => {
    const mockInvoke: TauriInvokeHandler = async () => {
      return {
        success: false,
        error_class: 'DEVICE_REVOKED',
        error_message: 'DEVICE_REVOKED: POS device has been revoked',
      };
    };

    const transport = createTauriPushTransport(mockInvoke, () => 'staff.jwt');

    await assert.rejects(
      async () => {
        await transport.syncBill({ id: 'b-1' });
      },
      (err: any) => {
        assert.ok(err instanceof PushSyncError);
        assert.equal(err.code, 'AUTH_REQUIRED');
        assert.match(err.message, /DEVICE_REVOKED/);
        return true;
      }
    );
  });

  it('4. DEVICE AUTH FAILED ERROR MAPPING: Maps DEVICE_AUTH_FAILED to AUTH_REQUIRED', async () => {
    const mockInvoke: TauriInvokeHandler = async () => {
      return {
        success: false,
        error_class: 'DEVICE_AUTH_FAILED',
        error_message: 'DEVICE_AUTH_FAILED: Invalid device token',
      };
    };

    const transport = createTauriPushTransport(mockInvoke, () => 'staff.jwt');

    await assert.rejects(
      async () => {
        await transport.syncPayment({ id: 'p-1' });
      },
      (err: any) => {
        assert.ok(err instanceof PushSyncError);
        assert.equal(err.code, 'AUTH_REQUIRED');
        assert.match(err.message, /DEVICE_AUTH_FAILED/);
        return true;
      }
    );
  });

  it('5. CONTRACT CONFLICT ERROR MAPPING: Maps CONTRACT_CONFLICT to CONTRACT_CONFLICT PushSyncError', async () => {
    const mockInvoke: TauriInvokeHandler = async () => {
      return {
        success: false,
        error_class: 'CONTRACT_CONFLICT',
        error_message: 'CONTRACT_CONFLICT: Overpayment Denied',
      };
    };

    const transport = createTauriPushTransport(mockInvoke, () => 'staff.jwt');

    await assert.rejects(
      async () => {
        await transport.syncPayment({ id: 'p-1' });
      },
      (err: any) => {
        assert.ok(err instanceof PushSyncError);
        assert.equal(err.code, 'CONTRACT_CONFLICT');
        assert.match(err.message, /Overpayment Denied/);
        return true;
      }
    );
  });

  it('6. RETRYABLE NETWORK ERROR MAPPING: Maps transient network failure to RETRYABLE', async () => {
    const mockInvoke: TauriInvokeHandler = async () => {
      return {
        success: false,
        error_class: 'RETRYABLE',
        error_message: 'NETWORK_ERROR: Connection timed out',
      };
    };

    const transport = createTauriPushTransport(mockInvoke, () => 'staff.jwt');

    await assert.rejects(
      async () => {
        await transport.syncKot({ id: 'k-1' }, []);
      },
      (err: any) => {
        assert.ok(err instanceof PushSyncError);
        assert.equal(err.code, 'RETRYABLE');
        assert.match(err.message, /Connection timed out/);
        return true;
      }
    );
  });

  it('7. NATIVE PROVISIONING: Returns non-secret device metadata without exposing device token', async () => {
    let capturedArgs: any = null;

    const mockInvoke: TauriInvokeHandler = async (cmd, args) => {
      capturedArgs = { cmd, args };
      return {
        device_id: 'cb-dev-1234',
        terminal_code: 'T01',
        device_name: 'Counter 1',
        created_at: '2026-10-11T12:00:00Z',
        success: true,
      };
    };

    const result = await nativeProvisionDevice({
      terminalCode: 't01',
      deviceName: 'Counter 1',
      adminToken: 'admin.jwt.token',
      invokeHandler: mockInvoke,
    });

    assert.equal(result.deviceId, 'cb-dev-1234');
    assert.equal(result.terminalCode, 'T01');
    assert.equal(result.deviceName, 'Counter 1');
    assert.equal(result.success, true);
    // Plaintext device token is NOT in result
    assert.equal((result as any).device_token, undefined);
    assert.equal((result as any).deviceToken, undefined);
  });

  it('8. PUSH WORKER INTEGRATION & REVOCATION HALT: runPushCycle halts with AUTH_REQUIRED_STOPPED on revocation without ACK', async () => {
    const outbox: any[] = [
      {
        seq: 1,
        id: 'out-1',
        entity_type: 'orders',
        entity_id: 'ord-100',
        operation: 'INSERT',
        payload_json: JSON.stringify({
          order: { id: 'ord-100', status: 'completed' },
          items: [],
        }),
        attempt_count: 0,
      },
    ];

    const mockDb: any = {
      async getPendingOutbox() {
        return outbox;
      },
      async acknowledgeOutbox(seq: number) {
        const idx = outbox.findIndex((r) => r.seq === seq);
        if (idx !== -1) outbox.splice(idx, 1);
      },
      async updateOutboxFailure(seq: number, error: string) {
        const row = outbox.find((r) => r.seq === seq);
        if (row) {
          row.attempt_count++;
          row.last_error = error;
        }
      },
    };

    // Simulate device revoked returned by native transport
    const mockInvoke: TauriInvokeHandler = async () => {
      return {
        success: false,
        error_class: 'DEVICE_REVOKED',
        error_message: 'DEVICE_REVOKED: Terminal POS-T01 has been revoked',
      };
    };

    const transport = createTauriPushTransport(mockInvoke, () => 'staff.token');

    const cycleResult = await runPushCycle({
      dbManager: mockDb,
      transport,
    });

    assert.equal(cycleResult.status, 'AUTH_REQUIRED_STOPPED');
    assert.equal(cycleResult.processedCount, 1);
    assert.equal(cycleResult.successCount, 0);

    // Outbox row must NOT be ACKed or deleted
    assert.equal(outbox.length, 1);
    assert.equal(outbox[0].attempt_count, 1);
    assert.match(outbox[0].last_error, /DEVICE_REVOKED/);
  });
});
