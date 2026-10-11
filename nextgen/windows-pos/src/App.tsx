/**
 * CHEESYOS NEXTGEN POS APP HOST — DEVELOPMENT STATUS SCREEN
 * 
 * Minimal visible status UI proving host application lifecycle,
 * package composition, and runtime environment boundaries.
 */

import React, { useEffect, useState } from 'react';
import { bootstrapPosHost, HostRuntimeStatus } from './bootstrap';

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

  useEffect(() => {
    let mounted = true;
    bootstrapPosHost().then((res) => {
      if (mounted) {
        setStatus(res);
      }
    });
    return () => {
      mounted = false;
    };
  }, []);

  return (
    <div style={{ fontFamily: 'sans-serif', padding: '24px', maxWidth: '800px', margin: '0 auto' }}>
      <h1 style={{ color: '#1e293b', borderBottom: '2px solid #e2e8f0', paddingBottom: '12px' }}>
        CheesyOS NextGen POS — Host Foundation
      </h1>

      <div style={{ backgroundColor: '#f8fafc', padding: '16px', borderRadius: '8px', marginBottom: '20px' }}>
        <h3>Application Host State: <span style={{ color: status.state === 'READY' ? '#16a34a' : status.state === 'ERROR' ? '#dc2626' : '#d97706' }}>{status.state}</span></h3>
        <p><strong>Environment:</strong> {status.browserCompatible ? 'Browser Renderer (Vite Web Host)' : 'Node / Desktop Host'}</p>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px' }}>
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
          <p>Formatter: <code>CB-&#123;TERMINAL_CODE&#125;-&#123;LOCAL_SEQUENCE&#125;</code></p>
        </div>
      </div>
    </div>
  );
}

export default App;
