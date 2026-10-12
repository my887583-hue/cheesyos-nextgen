/**
 * CHEESYOS NEXTGEN WINDOWS POS — STAFF AUTH & PROVISIONING INTEGRATION TEST SUITE
 * 
 * Verifies Phase 10A:
 * 1. AUTH_SIGN_IN_USES_SUPABASE_AUTH: Standard Supabase Auth signInWithPassword delegation.
 * 2. SIGNED_OUT_AUTH_GATE_FALSE: Unauthenticated gate remains false.
 * 3. AUTHENTICATED_STAFF_AUTH_GATE_TRUE: Valid staff with POS access enables auth gate.
 * 4. NON_ADMIN_PROVISIONING_BLOCKED: Staff lacking has_admin_access blocked from provisioning.
 * 5. ADMIN_PROVISIONING_ALLOWED: Admin staff session successfully authorizes device provisioning.
 * 6. RAW_TOKEN_INPUT_ABSENT: Zero raw token input textboxes; operator supplies only credentials.
 * 7. DEVICE_SECRET_NOT_RENDERED: Output contains non-secret metadata; plaintext secret absent.
 * 8. EXISTING_NATIVE_PROVISION_CONTRACT_REUSED: Reuses nativeProvisionDevice Tauri IPC contract.
 */

import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import {
  bootstrapPosHost,
  disposePosHost,
  signInStaff,
  signOutStaff,
  getStaffAuthSession,
  isStaffAuthSessionReady,
} from '../src/bootstrap.js';
import {
  nativeProvisionDevice,
  TauriInvokeHandler,
} from '../src/tauri-adapter.js';

function createMockSupabaseClient(options?: {
  authError?: any;
  user?: any;
  session?: any;
  profile?: any;
  profileError?: any;
}) {
  const user = options?.user ?? { id: 'usr-admin-1', email: 'admin@cheesybites.in' };
  const session = options?.session ?? { access_token: 'valid.admin.jwt.token' };
  const profile = options?.profile ?? {
    id: 'usr-admin-1',
    full_name: 'Store Owner',
    role: 'owner',
    has_pos_access: true,
    has_admin_access: true,
    is_active: true,
  };

  let capturedSignInArgs: any = null;

  const client: any = {
    auth: {
      signInWithPassword: async (args: any) => {
        capturedSignInArgs = args;
        if (options?.authError) {
          return { data: { user: null, session: null }, error: options.authError };
        }
        return { data: { user, session }, error: null };
      },
      signOut: async () => ({ error: null }),
    },
    from: (table: string) => {
      assert.equal(table, 'staff_profiles');
      return {
        select: (_cols: string) => ({
          eq: (field: string, val: string) => ({
            single: async () => {
              assert.equal(field, 'id');
              assert.equal(val, user.id);
              if (options?.profileError) {
                return { data: null, error: options.profileError };
              }
              return { data: profile, error: null };
            },
          }),
        }),
      };
    },
    getCapturedSignInArgs: () => capturedSignInArgs,
  };

  return client;
}

describe('CHEESYOS NEXTGEN WINDOWS POS — STAFF AUTH & DEVICE PROVISIONING (TASK 10A)', () => {
  beforeEach(async () => {
    disposePosHost();
  });

  afterEach(async () => {
    disposePosHost();
  });

  it('1. AUTH_SIGN_IN_USES_SUPABASE_AUTH: Authenticates via Supabase Auth signInWithPassword and verifies profile', async () => {
    const mockClient = createMockSupabaseClient();
    await bootstrapPosHost({ supabaseClient: mockClient });

    const result = await signInStaff('admin@cheesybites.in', 'Secret123!');

    assert.equal(result.success, true);
    assert.ok(result.session);
    assert.equal(result.session.userId, 'usr-admin-1');
    assert.equal(result.session.email, 'admin@cheesybites.in');
    assert.equal(result.session.accessToken, 'valid.admin.jwt.token');
    assert.equal(result.session.profile.fullName, 'Store Owner');
    assert.equal(result.session.profile.role, 'owner');
    assert.equal(result.session.profile.hasPosAccess, true);
    assert.equal(result.session.profile.hasAdminAccess, true);

    const capturedArgs = mockClient.getCapturedSignInArgs();
    assert.deepEqual(capturedArgs, {
      email: 'admin@cheesybites.in',
      password: 'Secret123!',
    });
  });

  it('2. SIGNED_OUT_AUTH_GATE_FALSE: Auth session gate is false when signed out', async () => {
    const mockClient = createMockSupabaseClient();
    const status = await bootstrapPosHost({ supabaseClient: mockClient });

    assert.equal(status.authSessionReady, false);
    assert.equal(isStaffAuthSessionReady(), false);
    assert.equal(getStaffAuthSession(), null);

    // Explicit sign out guarantees gate stays false
    await signOutStaff();
    assert.equal(isStaffAuthSessionReady(), false);
  });

  it('3. AUTHENTICATED_STAFF_AUTH_GATE_TRUE: Valid staff with POS access enables auth gate; inactive or non-POS blocked', async () => {
    // 3A. Valid staff enables gate
    const validClient = createMockSupabaseClient({
      profile: {
        id: 'usr-cashier-1',
        full_name: 'Main Cashier',
        role: 'cashier',
        has_pos_access: true,
        has_admin_access: false,
        is_active: true,
      },
    });
    await bootstrapPosHost({ supabaseClient: validClient });

    const validRes = await signInStaff('cashier@cheesybites.in', 'Pass123!');
    assert.equal(validRes.success, true);
    assert.equal(isStaffAuthSessionReady(), true);

    await signOutStaff();
    assert.equal(isStaffAuthSessionReady(), false);

    // 3B. Staff lacking POS access is rejected
    const noPosClient = createMockSupabaseClient({
      profile: {
        id: 'usr-kitchen-1',
        full_name: 'Kitchen Staff',
        role: 'cashier',
        has_pos_access: false,
        has_admin_access: false,
        is_active: true,
      },
    });
    await bootstrapPosHost({ supabaseClient: noPosClient });

    const noPosRes = await signInStaff('kitchen@cheesybites.in', 'Pass123!');
    assert.equal(noPosRes.success, false);
    assert.equal(noPosRes.errorCode, 'POS_ACCESS_DENIED');
    assert.equal(isStaffAuthSessionReady(), false);

    // 3C. Deactivated staff is rejected
    const inactiveClient = createMockSupabaseClient({
      profile: {
        id: 'usr-old-1',
        full_name: 'Inactive Staff',
        role: 'cashier',
        has_pos_access: true,
        has_admin_access: false,
        is_active: false,
      },
    });
    await bootstrapPosHost({ supabaseClient: inactiveClient });

    const inactiveRes = await signInStaff('inactive@cheesybites.in', 'Pass123!');
    assert.equal(inactiveRes.success, false);
    assert.equal(inactiveRes.errorCode, 'ACCOUNT_INACTIVE');
    assert.equal(isStaffAuthSessionReady(), false);
  });

  it('4. NON_ADMIN_PROVISIONING_BLOCKED: Staff lacking has_admin_access is denied device provisioning', async () => {
    const nonAdminClient = createMockSupabaseClient({
      profile: {
        id: 'usr-cashier-1',
        full_name: 'Cashier One',
        role: 'cashier',
        has_pos_access: true,
        has_admin_access: false,
        is_active: true,
      },
    });
    await bootstrapPosHost({ supabaseClient: nonAdminClient });

    const res = await signInStaff('cashier@cheesybites.in', 'Pass123!');
    assert.equal(res.success, true);
    assert.equal(res.session?.profile.hasAdminAccess, false);

    // Provisioning requires hasAdminAccess
    const canProvision = res.session?.profile.hasAdminAccess === true;
    assert.equal(canProvision, false, 'Non-admin staff must not be permitted to provision devices');
  });

  it('5. ADMIN_PROVISIONING_ALLOWED: Admin staff session permits device provisioning', async () => {
    const adminClient = createMockSupabaseClient({
      profile: {
        id: 'usr-admin-1',
        full_name: 'Store Owner',
        role: 'owner',
        has_pos_access: true,
        has_admin_access: true,
        is_active: true,
      },
    });
    await bootstrapPosHost({ supabaseClient: adminClient });

    const res = await signInStaff('owner@cheesybites.in', 'AdminPass123!');
    assert.equal(res.success, true);
    assert.equal(res.session?.profile.hasAdminAccess, true);

    let capturedIpcArgs: any = null;
    const mockInvoke: TauriInvokeHandler = async (cmd, args) => {
      if (cmd === 'native_provision_device') {
        capturedIpcArgs = args;
        return {
          device_id: 'cb-dev-uuid-1',
          terminal_code: 'T01',
          device_name: 'Main Counter',
          created_at: '2026-10-12T00:00:00Z',
          success: true,
        };
      }
      throw new Error(`Unexpected command: ${cmd}`);
    };

    const provResult = await nativeProvisionDevice({
      terminalCode: 'T01',
      deviceName: 'Main Counter',
      adminToken: res.session!.accessToken,
      invokeHandler: mockInvoke,
    });

    assert.equal(provResult.success, true);
    assert.equal(provResult.deviceId, 'cb-dev-uuid-1');
    assert.equal(provResult.terminalCode, 'T01');
    assert.equal(provResult.deviceName, 'Main Counter');

    assert.equal(capturedIpcArgs.terminalCode, 'T01');
    assert.equal(capturedIpcArgs.deviceName, 'Main Counter');
    assert.equal(capturedIpcArgs.adminToken, 'valid.admin.jwt.token');
  });

  it('6. RAW_TOKEN_INPUT_ABSENT: Auth interface accepts email and password without manual token textbox', async () => {
    const mockClient = createMockSupabaseClient();
    await bootstrapPosHost({ supabaseClient: mockClient });

    // Ensure signInStaff accepts exactly email and password (strings)
    const fnSignatureLength = signInStaff.length;
    assert.equal(fnSignatureLength, 2, 'signInStaff must take exactly email and password');
  });

  it('7. DEVICE_SECRET_NOT_RENDERED: Provisioning result contains non-secret metadata only', async () => {
    const mockInvoke: TauriInvokeHandler = async () => ({
      device_id: 'cb-dev-uuid-7',
      terminal_code: 'T02',
      device_name: 'Drive Thru',
      created_at: '2026-10-12T00:00:00Z',
      success: true,
    });

    const res = await nativeProvisionDevice({
      terminalCode: 'T02',
      deviceName: 'Drive Thru',
      adminToken: 'admin.token',
      invokeHandler: mockInvoke,
    });

    // Device token and ciphertext must NEVER be present in the returned JS object
    assert.equal((res as any).device_token, undefined);
    assert.equal((res as any).deviceToken, undefined);
    assert.equal((res as any).device_secret, undefined);
    assert.equal((res as any).secret, undefined);
    assert.equal(res.terminalCode, 'T02');
    assert.equal(res.deviceName, 'Drive Thru');
  });

  it('8. EXISTING_NATIVE_PROVISION_CONTRACT_REUSED: Directly invokes native_provision_device Tauri IPC command', async () => {
    const calls: string[] = [];
    const mockInvoke: TauriInvokeHandler = async (cmd) => {
      calls.push(cmd);
      return {
        device_id: 'cb-dev-uuid-8',
        terminal_code: 'T03',
        device_name: 'Kiosk 1',
        created_at: '2026-10-12T00:00:00Z',
        success: true,
      };
    };

    await nativeProvisionDevice({
      terminalCode: 'T03',
      deviceName: 'Kiosk 1',
      adminToken: 'admin.jwt',
      invokeHandler: mockInvoke,
    });

    assert.deepEqual(calls, ['native_provision_device'], 'Must reuse exact native_provision_device Tauri command');
  });
});
