import React, { useEffect, useState } from 'react';
import {
  bootstrapPosHost,
  HostRuntimeStatus,
  signInStaff,
  signOutStaff,
  getStaffAuthSession,
  StaffAuthSession,
  getLocalDbSingleton,
} from './bootstrap';
import { nativeProvisionDevice } from './tauri-adapter';
import type { LocalDeviceConfig } from '@cheesyos/pos-local';

export function App(): React.ReactElement {
  const [status, setStatus] = useState<HostRuntimeStatus>({
    state: 'INITIALIZING',
    supabaseConfigured: false,
    localDbReady: false,
    orchestratorReady: false,
    browserCompatible: typeof window !== 'undefined',
    deviceConfigured: false,
    authSessionReady: false,
    lifecycleReady: false,
  });

  const [deviceConfig, setDeviceConfig] = useState<LocalDeviceConfig | null>(null);
  const [staffSession, setStaffSession] = useState<StaffAuthSession | null>(null);

  // Sign-in form state
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [authLoading, setAuthLoading] = useState(false);
  const [authError, setAuthError] = useState<string | null>(null);

  // Provisioning form state
  const [terminalCode, setTerminalCode] = useState('');
  const [deviceName, setDeviceName] = useState('');
  const [provisionLoading, setProvisionLoading] = useState(false);
  const [provisionError, setProvisionError] = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    bootstrapPosHost().then(async (res) => {
      if (!mounted) return;
      setStatus(res);

      const db = getLocalDbSingleton();
      if (db) {
        const cfg = await db.getDeviceConfig().catch(() => null);
        if (mounted && cfg) {
          setDeviceConfig(cfg);
        }
      }

      const activeSession = getStaffAuthSession();
      if (mounted && activeSession) {
        setStaffSession(activeSession);
      }
    });

    return () => {
      mounted = false;
    };
  }, []);

  const handleSignIn = async (e: React.FormEvent) => {
    e.preventDefault();
    if (authLoading) return;

    if (!email.trim() || !password) {
      setAuthError('INVALID_CREDENTIALS');
      return;
    }

    setAuthLoading(true);
    setAuthError(null);

    const res = await signInStaff(email, password);
    setAuthLoading(false);

    if (res.success && res.session) {
      setStaffSession(res.session);
      setStatus((prev) => ({ ...prev, authSessionReady: true }));
      setPassword('');
    } else {
      setAuthError(res.errorCode || 'INVALID_CREDENTIALS');
    }
  };

  const handleSignOut = async () => {
    await signOutStaff();
    setStaffSession(null);
    setStatus((prev) => ({ ...prev, authSessionReady: false }));
    setAuthError(null);
    setProvisionError(null);
  };

  const handleProvisionDevice = async (e: React.FormEvent) => {
    e.preventDefault();
    if (provisionLoading) return;

    if (!staffSession) {
      setProvisionError('UNAUTHORIZED');
      return;
    }

    if (!staffSession.profile.hasAdminAccess) {
      setProvisionError('ADMIN_ACCESS_REQUIRED');
      return;
    }

    const normCode = terminalCode.trim().toUpperCase();
    const normName = deviceName.trim();

    if (!normCode || normCode.length < 2) {
      setProvisionError('INVALID_TERMINAL_CODE');
      return;
    }

    if (!normName) {
      setProvisionError('INVALID_DEVICE_NAME');
      return;
    }

    setProvisionLoading(true);
    setProvisionError(null);

    try {
      const res = await nativeProvisionDevice({
        terminalCode: normCode,
        deviceName: normName,
        adminToken: staffSession.accessToken,
      });

      if (res.success) {
        // Refresh authoritative persisted device config from native SQLite
        const db = getLocalDbSingleton();
        const updatedConfig = db ? await db.getDeviceConfig().catch(() => null) : null;

        setDeviceConfig(updatedConfig || {
          device_id: res.deviceId,
          terminal_code: res.terminalCode,
          device_name: res.deviceName,
          created_at: res.createdAt,
        });

        setStatus((prev) => ({
          ...prev,
          deviceConfigured: true,
        }));

        setTerminalCode('');
        setDeviceName('');
      } else {
        setProvisionError('PROVISIONING_FAILED');
      }
    } catch (err: any) {
      const msg = typeof err === 'string' ? err : err?.message || String(err);
      if (msg.includes('ADMIN_ACCESS_REQUIRED') || msg.includes('Admin access required')) {
        setProvisionError('ADMIN_ACCESS_REQUIRED');
      } else if (msg.includes('Access Denied') || msg.includes('UNAUTHORIZED')) {
        setProvisionError('UNAUTHORIZED');
      } else if (msg.includes('ALREADY_PROVISIONED') || msg.includes('already exists')) {
        setProvisionError('DEVICE_ALREADY_PROVISIONED');
      } else if (msg.includes('NETWORK_ERROR')) {
        setProvisionError('NETWORK_ERROR');
      } else {
        setProvisionError('PROVISIONING_FAILED');
      }
    } finally {
      setProvisionLoading(false);
    }
  };

  return (
    <div style={{ fontFamily: 'sans-serif', padding: '24px', maxWidth: '800px', margin: '0 auto' }}>
      <h1 style={{ color: '#1e293b', borderBottom: '2px solid #e2e8f0', paddingBottom: '12px' }}>
        CheesyOS NextGen POS — Host Foundation
      </h1>

      <div style={{ backgroundColor: '#f8fafc', padding: '16px', borderRadius: '8px', marginBottom: '20px' }}>
        <h3>
          Application Host State:{' '}
          <span style={{ color: status.state === 'READY' ? '#16a34a' : status.state === 'ERROR' ? '#dc2626' : '#d97706' }}>
            {status.state}
          </span>
        </h3>
        <p><strong>Environment:</strong> {status.browserCompatible ? 'Browser Renderer (Vite Web Host)' : 'Node / Desktop Host'}</p>
        <p><strong>Auth Session Gate:</strong> {status.authSessionReady ? '✅ Active (Staff Session Ready)' : '🔒 Gated (Signed Out)'}</p>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px', marginBottom: '20px' }}>
        <div style={{ border: '1px solid #cbd5e1', borderRadius: '6px', padding: '16px' }}>
          <h4>Local Persistence Boundary</h4>
          <p>Status: {status.localDbReady ? '✅ Ready (Tauri Desktop Boundary)' : '❌ Unavailable'}</p>
          <p>Backend: <code>Tauri / Desktop Native Adapter (IPosLocalDatabase)</code></p>
          {status.localDbError && (
            <p style={{ color: '#dc2626', fontSize: '12px' }}>Error: {status.localDbError}</p>
          )}
        </div>

        <div style={{ border: '1px solid #cbd5e1', borderRadius: '6px', padding: '16px' }}>
          <h4>Cloud Client Boundary</h4>
          <p>Status: {status.supabaseConfigured ? '✅ Configured (NextGen Dev)' : '⚠️ Environment Required'}</p>
          <p>Project: <code>sdbnibyzqtgpbexlznat</code></p>
          {status.supabaseError && (
            <p style={{ color: '#dc2626', fontSize: '12px' }}>Error: {status.supabaseError}</p>
          )}
        </div>

        <div style={{ border: '1px solid #cbd5e1', borderRadius: '6px', padding: '16px' }}>
          <h4>Sync Runtime Boundary</h4>
          <p>Orchestrator: {status.orchestratorReady ? '✅ Initialized' : '⏳ Waiting'}</p>
          <p>Triggers: <code>Demand-driven (Single Flight)</code></p>
        </div>

        <div style={{ border: '1px solid #cbd5e1', borderRadius: '6px', padding: '16px' }}>
          <h4>Terminal Identity Boundary</h4>
          <p>Terminal Config: {status.deviceConfigured ? '✅ Configured' : '⚠️ DEVICE_NOT_PROVISIONED'}</p>
          {deviceConfig && (
            <div style={{ fontSize: '13px', backgroundColor: '#f1f5f9', padding: '8px', borderRadius: '4px', marginTop: '8px' }}>
              <div><strong>Terminal Code:</strong> {deviceConfig.terminal_code}</div>
              <div><strong>Device Name:</strong> {deviceConfig.device_name}</div>
              <div><strong>Status:</strong> Provisioned</div>
            </div>
          )}
          {!deviceConfig && (
            <p>Formatter: <code>CB-&#123;TERMINAL_CODE&#125;-&#123;LOCAL_SEQUENCE&#125;</code></p>
          )}
        </div>
      </div>

      {/* Internal Provisioning Setup — Rendered strictly when unprovisioned */}
      {!status.deviceConfigured && (
        <div style={{ border: '2px solid #e2e8f0', borderRadius: '8px', padding: '20px', backgroundColor: '#ffffff' }}>
          <h3 style={{ marginTop: 0, color: '#1e293b' }}>Device Provisioning Setup</h3>
          <p style={{ color: '#64748b', fontSize: '14px', marginBottom: '16px' }}>
            This terminal is not yet registered. Authenticate as a staff administrator to provision this device.
          </p>

          {/* Step 1: Staff Sign-In */}
          {!staffSession ? (
            <form onSubmit={handleSignIn} style={{ display: 'flex', flexDirection: 'column', gap: '12px', maxWidth: '400px' }}>
              <div>
                <label style={{ display: 'block', fontSize: '13px', fontWeight: 'bold', marginBottom: '4px', color: '#334155' }}>
                  Staff Email
                </label>
                <input
                  id="staff-email-input"
                  type="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="admin@cheesybites.in"
                  required
                  style={{ width: '100%', padding: '8px', borderRadius: '4px', border: '1px solid #cbd5e1', fontSize: '14px' }}
                />
              </div>

              <div>
                <label style={{ display: 'block', fontSize: '13px', fontWeight: 'bold', marginBottom: '4px', color: '#334155' }}>
                  Staff Password
                </label>
                <input
                  id="staff-password-input"
                  type="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••••••"
                  required
                  style={{ width: '100%', padding: '8px', borderRadius: '4px', border: '1px solid #cbd5e1', fontSize: '14px' }}
                />
              </div>

              {authError && (
                <div style={{ color: '#dc2626', fontSize: '13px', backgroundColor: '#fef2f2', padding: '8px', borderRadius: '4px' }}>
                  Error: {authError}
                </div>
              )}

              <button
                id="staff-signin-button"
                type="submit"
                disabled={authLoading}
                style={{
                  backgroundColor: authLoading ? '#94a3b8' : '#2563eb',
                  color: '#ffffff',
                  padding: '10px 16px',
                  border: 'none',
                  borderRadius: '4px',
                  fontWeight: 'bold',
                  cursor: authLoading ? 'not-allowed' : 'pointer',
                  fontSize: '14px',
                }}
              >
                {authLoading ? 'Signing In...' : 'Sign In as Staff'}
              </button>
            </form>
          ) : (
            <div>
              {/* Authenticated Staff Banner */}
              <div style={{ backgroundColor: '#f0fdf4', border: '1px solid #bbf7d0', borderRadius: '6px', padding: '12px', marginBottom: '16px' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <div>
                    <div style={{ fontWeight: 'bold', color: '#166534' }}>
                      Signed In: {staffSession.email}
                    </div>
                    <div style={{ fontSize: '13px', color: '#15803d' }}>
                      Name: {staffSession.profile.fullName} | Role: {staffSession.profile.role} | Admin Access:{' '}
                      {staffSession.profile.hasAdminAccess ? '✅ Yes' : '❌ No'}
                    </div>
                  </div>
                  <button
                    onClick={handleSignOut}
                    style={{
                      backgroundColor: '#f1f5f9',
                      border: '1px solid #cbd5e1',
                      padding: '6px 12px',
                      borderRadius: '4px',
                      cursor: 'pointer',
                      fontSize: '12px',
                    }}
                  >
                    Sign Out
                  </button>
                </div>
              </div>

              {/* Non-Admin Access Gate */}
              {!staffSession.profile.hasAdminAccess ? (
                <div style={{ backgroundColor: '#fef2f2', border: '1px solid #fecaca', borderRadius: '6px', padding: '12px', color: '#991b1b' }}>
                  <strong>ADMIN_ACCESS_REQUIRED:</strong> This staff account has POS access, but does not have administrator privileges required to provision new hardware devices. Please sign in with an administrator account.
                </div>
              ) : (
                /* Step 2: Device Provisioning Form (Admin only) */
                <form onSubmit={handleProvisionDevice} style={{ display: 'flex', flexDirection: 'column', gap: '12px', maxWidth: '400px' }}>
                  <div>
                    <label style={{ display: 'block', fontSize: '13px', fontWeight: 'bold', marginBottom: '4px', color: '#334155' }}>
                      Terminal Code
                    </label>
                    <input
                      id="terminal-code-input"
                      type="text"
                      value={terminalCode}
                      onChange={(e) => setTerminalCode(e.target.value)}
                      placeholder="e.g. T01"
                      required
                      style={{ width: '100%', padding: '8px', borderRadius: '4px', border: '1px solid #cbd5e1', fontSize: '14px' }}
                    />
                  </div>

                  <div>
                    <label style={{ display: 'block', fontSize: '13px', fontWeight: 'bold', marginBottom: '4px', color: '#334155' }}>
                      Device Name
                    </label>
                    <input
                      id="device-name-input"
                      type="text"
                      value={deviceName}
                      onChange={(e) => setDeviceName(e.target.value)}
                      placeholder="e.g. Counter 1"
                      required
                      style={{ width: '100%', padding: '8px', borderRadius: '4px', border: '1px solid #cbd5e1', fontSize: '14px' }}
                    />
                  </div>

                  {provisionError && (
                    <div style={{ color: '#dc2626', fontSize: '13px', backgroundColor: '#fef2f2', padding: '8px', borderRadius: '4px' }}>
                      Error: {provisionError}
                    </div>
                  )}

                  <button
                    id="provision-device-button"
                    type="submit"
                    disabled={provisionLoading}
                    style={{
                      backgroundColor: provisionLoading ? '#94a3b8' : '#16a34a',
                      color: '#ffffff',
                      padding: '10px 16px',
                      border: 'none',
                      borderRadius: '4px',
                      fontWeight: 'bold',
                      cursor: provisionLoading ? 'not-allowed' : 'pointer',
                      fontSize: '14px',
                    }}
                  >
                    {provisionLoading ? 'Provisioning This Device...' : 'Provision This Device'}
                  </button>
                </form>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

export default App;
