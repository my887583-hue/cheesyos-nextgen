import React, { useEffect, useState, useCallback, useMemo } from 'react';
import type {
  IPosPersistence,
  TableWithActiveSession,
  TableOccupancyStatus,
  ActiveTableOrderResult,
} from '@cheesyos/pos-local';
import { deriveTableOccupancy } from '@cheesyos/pos-local';
import type { PosTableDomain, TableSessionDomain } from '@cheesyos/nextgen-shared';
import { GuestCountModal } from './GuestCountModal';

export interface SelectedOrderContext {
  table: PosTableDomain;
  session: TableSessionDomain;
  order: ActiveTableOrderResult['order'] | null;
  items: ActiveTableOrderResult['items'];
}

export interface TableFloorProps {
  db: IPosPersistence;
  initialTables?: TableWithActiveSession[];
  terminalCode?: string;
  staffName?: string;
  staffRole?: string;
  onSignOut?: () => void;
  onSelectOrderContext?: (context: SelectedOrderContext) => void;
  onEnterWorkspace?: (context: SelectedOrderContext) => void;
  onOpenDiagnostics?: () => void;
}

export function TableFloor({
  db,
  initialTables,
  terminalCode,
  staffName,
  staffRole,
  onSignOut,
  onSelectOrderContext,
  onEnterWorkspace,
  onOpenDiagnostics,
}: TableFloorProps): React.ReactElement {
  const [tables, setTables] = useState<TableWithActiveSession[]>(initialTables || []);
  const [loading, setLoading] = useState(initialTables ? false : true);
  const [error, setError] = useState<string | null>(null);
  const [selectedSection, setSelectedSection] = useState<string>('ALL');

  // Selection / active context state
  const [selectedTable, setSelectedTable] = useState<TableWithActiveSession | null>(null);
  const [activeOrderContext, setActiveOrderContext] = useState<ActiveTableOrderResult | null>(null);
  const [activeOrderLoading, setActiveOrderLoading] = useState(false);
  const [activeOrderError, setActiveOrderError] = useState<string | null>(null);

  // Guest count dialog state
  const [guestModalTable, setGuestModalTable] = useState<PosTableDomain | null>(null);
  const [guestCount, setGuestCount] = useState<number>(2);
  const [guestCountError, setGuestCountError] = useState<string | null>(null);
  const [isSubmittingOpen, setIsSubmittingOpen] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  /**
   * Authoritative local SQLite load of tables with active sessions.
   * Purely demand-driven: zero periodic polling timers.
   */
  const loadTables = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await db.getTablesWithSessions();
      setTables(data);
      // If a table is currently selected, refresh its active session reference
      setSelectedTable((prev) => {
        if (!prev) return null;
        const updated = data.find((t) => t.table.id === prev.table.id);
        return updated || null;
      });
    } catch (err: any) {
      const msg = typeof err === 'string' ? err : err?.message || 'Error loading tables';
      setError(msg.includes('INVARIANT') ? 'Table occupancy conflict detected.' : 'Failed to load tables from local storage.');
    } finally {
      setLoading(false);
    }
  }, [db]);

  useEffect(() => {
    loadTables();
  }, [loadTables]);

  // Derive unique sections
  const sections = useMemo(() => {
    const set = new Set<string>();
    for (const item of tables) {
      if (item.table.section && item.table.section.trim()) {
        set.add(item.table.section.trim());
      }
    }
    return Array.from(set).sort();
  }, [tables]);

  // Filtered tables
  const visibleTables = useMemo(() => {
    if (selectedSection === 'ALL') return tables;
    return tables.filter((t) => t.table.section?.trim() === selectedSection);
  }, [tables, selectedSection]);

  /**
   * Handles clicking on a table card.
   */
  const handleTableClick = async (item: TableWithActiveSession) => {
    setActionError(null);
    const occupancy = deriveTableOccupancy(item.active_session);

    if (occupancy === 'AVAILABLE') {
      // Open guest count dialog
      setGuestModalTable(item.table);
      setGuestCount(2);
      setGuestCountError(null);
      setSelectedTable(item);
      setActiveOrderContext(null);
      return;
    }

    if (occupancy === 'OCCUPIED' || occupancy === 'BILLED') {
      setSelectedTable(item);
      setActiveOrderLoading(true);
      setActiveOrderError(null);

      try {
        const orderRes = await db.getActiveOrderForTable(item.table.id);
        setActiveOrderContext(orderRes);

        if (onSelectOrderContext && item.active_session) {
          onSelectOrderContext({
            table: item.table,
            session: item.active_session,
            order: orderRes ? orderRes.order : null,
            items: orderRes ? orderRes.items : [],
          });
        }
      } catch (err: any) {
        const msg = typeof err === 'string' ? err : err?.message || 'Failed to read order';
        setActiveOrderError(msg.includes('INVARIANT') ? 'Order integrity error for this table.' : 'Failed to load active order.');
      } finally {
        setActiveOrderLoading(false);
      }
    }
  };

  /**
   * Confirms opening a table session with the specified guest count.
   * Strictly offline-safe: calls local SQLite persistence and reloads state.
   */
  const handleConfirmOpenSession = async (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    if (isSubmittingOpen || !guestModalTable) return;

    const countNum = Number(guestCount);
    if (!Number.isInteger(countNum) || countNum <= 0) {
      setGuestCountError('Guest count must be a positive integer.');
      return;
    }

    setIsSubmittingOpen(true);
    setGuestCountError(null);
    setActionError(null);

    try {
      const newSession = await db.openTableSession(guestModalTable.id, countNum);
      setGuestModalTable(null);

      // Authoritative reload of tables from local SQLite
      await loadTables();

      // Automatically focus the newly opened table
      const updatedTable: TableWithActiveSession = {
        table: guestModalTable,
        active_session: newSession,
      };
      setSelectedTable(updatedTable);
      setActiveOrderContext(null);

      if (onSelectOrderContext) {
        onSelectOrderContext({
          table: guestModalTable,
          session: newSession,
          order: null,
          items: [],
        });
      }
    } catch (err: any) {
      const msg = typeof err === 'string' ? err : err?.message || '';
      if (msg.includes('ALREADY_OCCUPIED') || msg.includes('already occupied') || msg.includes('ACTIVE_SESSION_EXISTS')) {
        setActionError('Table is already occupied.');
      } else if (msg.includes('INACTIVE_TABLE') || msg.includes('not active')) {
        setActionError('This table is marked inactive.');
      } else {
        setActionError('Failed to open table session. Please try again.');
      }
    } finally {
      setIsSubmittingOpen(false);
    }
  };

  const handleCloseGuestModal = () => {
    if (isSubmittingOpen) return;
    setGuestModalTable(null);
    setGuestCountError(null);
    setActionError(null);
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100vh', backgroundColor: '#f8fafc', color: '#0f172a', fontFamily: 'system-ui, -apple-system, sans-serif' }}>
      {/* Top POS Header Bar */}
      <header
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '12px 24px',
          backgroundColor: '#0f172a',
          color: '#ffffff',
          boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
          <h2 style={{ margin: 0, fontSize: '18px', fontWeight: '700', letterSpacing: '-0.02em', color: '#f8fafc' }}>
            Cheesy Bites POS
          </h2>
          {terminalCode && (
            <span
              id="terminal-badge"
              style={{
                backgroundColor: '#1e293b',
                color: '#94a3b8',
                padding: '4px 10px',
                borderRadius: '4px',
                fontSize: '12px',
                fontWeight: '600',
                border: '1px solid #334155',
              }}
            >
              {`Terminal: ${terminalCode}`}
            </span>
          )}
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
          {staffName && (
            <div style={{ textAlign: 'right', fontSize: '13px' }}>
              <div style={{ fontWeight: '600', color: '#f1f5f9' }}>{staffName}</div>
              {staffRole && <div style={{ fontSize: '11px', color: '#94a3b8', textTransform: 'capitalize' }}>{staffRole}</div>}
            </div>
          )}

          <button
            id="refresh-tables-button"
            onClick={loadTables}
            disabled={loading}
            title="Refresh Table Floor from local database"
            style={{
              backgroundColor: '#1e293b',
              color: '#f8fafc',
              border: '1px solid #334155',
              padding: '6px 14px',
              borderRadius: '6px',
              fontSize: '13px',
              fontWeight: '500',
              cursor: loading ? 'not-allowed' : 'pointer',
            }}
          >
            {loading ? 'Refreshing...' : '↻ Refresh'}
          </button>

          {onOpenDiagnostics && (
            <button
              id="open-diagnostics-button"
              onClick={onOpenDiagnostics}
              style={{
                backgroundColor: '#1e293b',
                color: '#94a3b8',
                border: '1px solid #334155',
                padding: '6px 12px',
                borderRadius: '6px',
                fontSize: '12px',
                cursor: 'pointer',
              }}
            >
              ⚙ Host Info
            </button>
          )}

          {onSignOut && (
            <button
              id="sign-out-button"
              onClick={onSignOut}
              style={{
                backgroundColor: '#dc2626',
                color: '#ffffff',
                border: 'none',
                padding: '6px 14px',
                borderRadius: '6px',
                fontSize: '13px',
                fontWeight: '600',
                cursor: 'pointer',
              }}
            >
              Sign Out
            </button>
          )}
        </div>
      </header>

      {/* Main Operational Body */}
      <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>
        {/* Left Section: Table Floor Grid */}
        <main style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: '20px', overflowY: 'auto' }}>
          {/* Section Filter Tabs */}
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '16px', flexWrap: 'wrap' }}>
            <span style={{ fontSize: '13px', fontWeight: '600', color: '#64748b', marginRight: '4px' }}>Section:</span>
            <button
              onClick={() => setSelectedSection('ALL')}
              style={{
                backgroundColor: selectedSection === 'ALL' ? '#0284c7' : '#ffffff',
                color: selectedSection === 'ALL' ? '#ffffff' : '#475569',
                border: selectedSection === 'ALL' ? '1px solid #0284c7' : '1px solid #cbd5e1',
                padding: '6px 14px',
                borderRadius: '6px',
                fontSize: '13px',
                fontWeight: '600',
                cursor: 'pointer',
              }}
            >
              {`All Tables (${tables.length})`}
            </button>
            {sections.map((sec) => (
              <button
                key={sec}
                onClick={() => setSelectedSection(sec)}
                style={{
                  backgroundColor: selectedSection === sec ? '#0284c7' : '#ffffff',
                  color: selectedSection === sec ? '#ffffff' : '#475569',
                  border: selectedSection === sec ? '1px solid #0284c7' : '1px solid #cbd5e1',
                  padding: '6px 14px',
                  borderRadius: '6px',
                  fontSize: '13px',
                  fontWeight: '600',
                  cursor: 'pointer',
                }}
              >
                {sec}
              </button>
            ))}
          </div>

          {/* Error Banner */}
          {error && (
            <div
              id="table-floor-error"
              style={{
                backgroundColor: '#fef2f2',
                border: '1px solid #fecaca',
                color: '#991b1b',
                padding: '12px 16px',
                borderRadius: '6px',
                marginBottom: '16px',
                fontSize: '14px',
              }}
            >
              {error}
            </div>
          )}

          {/* Loading Indicator */}
          {loading && tables.length === 0 && (
            <div id="table-floor-loading" style={{ textAlign: 'center', padding: '60px 0', color: '#64748b', fontSize: '15px' }}>
              Loading Table Floor...
            </div>
          )}

          {/* Empty State */}
          {!loading && tables.length === 0 && !error && (
            <div id="table-floor-empty" style={{ textAlign: 'center', padding: '60px 0', color: '#64748b', fontSize: '15px' }}>
              No tables found in local storage. Please verify local database or sync catalog.
            </div>
          )}

          {/* Table Cards Grid */}
          <div
            id="table-grid"
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))',
              gap: '16px',
              alignContent: 'start',
            }}
          >
            {visibleTables.map((item) => {
              const occupancy = deriveTableOccupancy(item.active_session);
              const isSelected = selectedTable?.table.id === item.table.id;

              // Neutral / Accessible styling by status
              let badgeBg = '#f1f5f9';
              let badgeColor = '#475569';
              let borderColor = isSelected ? '#0284c7' : '#e2e8f0';
              let cardBg = '#ffffff';

              if (occupancy === 'OCCUPIED') {
                badgeBg = '#dcfce7';
                badgeColor = '#166534';
                if (!isSelected) borderColor = '#bbf7d0';
              } else if (occupancy === 'BILLED') {
                badgeBg = '#fef3c7';
                badgeColor = '#92400e';
                if (!isSelected) borderColor = '#fde68a';
              }

              return (
                <button
                  key={item.table.id}
                  id={`table-card-${item.table.table_number}`}
                  type="button"
                  onClick={() => handleTableClick(item)}
                  style={{
                    backgroundColor: cardBg,
                    border: `2px solid ${borderColor}`,
                    borderRadius: '8px',
                    padding: '16px',
                    textAlign: 'left',
                    cursor: 'pointer',
                    boxShadow: isSelected ? '0 0 0 2px #0284c7' : '0 1px 3px rgba(0,0,0,0.05)',
                    display: 'flex',
                    flexDirection: 'column',
                    gap: '8px',
                    transition: 'all 0.15s ease-in-out',
                  }}
                  aria-label={`Table ${item.table.table_number}, ${occupancy}, capacity ${item.table.capacity}`}
                >
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <span style={{ fontSize: '18px', fontWeight: '700', color: '#1e293b' }}>
                      {item.table.table_number}
                    </span>
                    <span
                      style={{
                        backgroundColor: badgeBg,
                        color: badgeColor,
                        padding: '3px 8px',
                        borderRadius: '4px',
                        fontSize: '11px',
                        fontWeight: '700',
                        textTransform: 'uppercase',
                        letterSpacing: '0.05em',
                      }}
                    >
                      {occupancy}
                    </span>
                  </div>

                  <div style={{ fontSize: '12px', color: '#64748b' }}>
                    {`${item.table.section || 'General'} • Cap: ${item.table.capacity}`}
                  </div>

                  {item.active_session && (
                    <div style={{ fontSize: '12px', color: '#334155', borderTop: '1px dashed #e2e8f0', paddingTop: '6px', marginTop: '2px' }}>
                      <div>Guests: <strong>{item.active_session.guest_count}</strong></div>
                      {item.active_session.current_order_id && (
                        <div style={{ fontSize: '11px', color: '#64748b', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                          Order: {item.active_session.current_order_id.slice(0, 8)}...
                        </div>
                      )}
                    </div>
                  )}
                </button>
              );
            })}
          </div>
        </main>

        {/* Right Section: Active Context Details Panel */}
        <aside
          style={{
            width: '320px',
            borderLeft: '1px solid #e2e8f0',
            backgroundColor: '#ffffff',
            padding: '20px',
            display: 'flex',
            flexDirection: 'column',
            justifyContent: 'space-between',
            overflowY: 'auto',
          }}
        >
          {selectedTable ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
              <div>
                <h3 style={{ margin: '0 0 4px 0', fontSize: '18px', color: '#0f172a' }}>
                  Table {selectedTable.table.table_number}
                </h3>
                <div style={{ fontSize: '13px', color: '#64748b' }}>
                  Section: {selectedTable.table.section || 'General'} | Capacity: {selectedTable.table.capacity}
                </div>
              </div>

              {/* Status Pill */}
              <div>
                <span
                  style={{
                    display: 'inline-block',
                    padding: '4px 10px',
                    borderRadius: '4px',
                    fontSize: '12px',
                    fontWeight: '700',
                    backgroundColor:
                      deriveTableOccupancy(selectedTable.active_session) === 'OCCUPIED'
                        ? '#dcfce7'
                        : deriveTableOccupancy(selectedTable.active_session) === 'BILLED'
                        ? '#fef3c7'
                        : '#f1f5f9',
                    color:
                      deriveTableOccupancy(selectedTable.active_session) === 'OCCUPIED'
                        ? '#166534'
                        : deriveTableOccupancy(selectedTable.active_session) === 'BILLED'
                        ? '#92400e'
                        : '#475569',
                  }}
                >
                  Status: {deriveTableOccupancy(selectedTable.active_session)}
                </span>
              </div>

              {activeOrderError && (
                <div style={{ backgroundColor: '#fef2f2', border: '1px solid #fecaca', color: '#991b1b', padding: '10px', borderRadius: '4px', fontSize: '13px' }}>
                  {activeOrderError}
                </div>
              )}

              {activeOrderLoading && (
                <div style={{ color: '#64748b', fontSize: '13px' }}>Loading active order context...</div>
              )}

              {/* Result A: Occupied with Active Order */}
              {selectedTable.active_session && activeOrderContext && (
                <div
                  id="active-order-panel"
                  style={{
                    backgroundColor: '#f8fafc',
                    border: '1px solid #e2e8f0',
                    borderRadius: '6px',
                    padding: '14px',
                    display: 'flex',
                    flexDirection: 'column',
                    gap: '10px',
                  }}
                >
                  <div style={{ fontWeight: '700', fontSize: '14px', color: '#1e293b' }}>
                    Active Order
                  </div>
                  <div style={{ fontSize: '13px' }}>
                    <div><strong>Order ID:</strong> {activeOrderContext.order.display_number || activeOrderContext.order.id.slice(0, 8)}</div>
                    <div><strong>Order Status:</strong> <code>{activeOrderContext.order.status}</code></div>
                    <div><strong>Items:</strong> {activeOrderContext.items.length}</div>
                    <div><strong>Total:</strong> ₹{(activeOrderContext.order.grand_total_paise / 100).toFixed(2)}</div>
                  </div>

                  <button
                    id="continue-order-button"
                    type="button"
                    onClick={() => {
                      if (onEnterWorkspace && selectedTable.active_session && activeOrderContext) {
                        onEnterWorkspace({
                          table: selectedTable.table,
                          session: selectedTable.active_session,
                          order: activeOrderContext.order,
                          items: activeOrderContext.items,
                        });
                      }
                    }}
                    style={{
                      marginTop: '8px',
                      backgroundColor: '#2563eb',
                      color: '#ffffff',
                      border: 'none',
                      padding: '10px',
                      borderRadius: '4px',
                      fontWeight: '600',
                      cursor: 'pointer',
                      fontSize: '13px',
                    }}
                  >
                    Continue Order →
                  </button>
                </div>
              )}

              {/* Result B: Occupied Session but No Order Yet */}
              {selectedTable.active_session && !activeOrderLoading && !activeOrderContext && (
                <div
                  id="open-session-no-order-panel"
                  style={{
                    backgroundColor: '#f0fdf4',
                    border: '1px solid #bbf7d0',
                    borderRadius: '6px',
                    padding: '14px',
                    display: 'flex',
                    flexDirection: 'column',
                    gap: '10px',
                  }}
                >
                  <div style={{ fontWeight: '700', fontSize: '14px', color: '#166534' }}>
                    Session Open
                  </div>
                  <div style={{ fontSize: '13px', color: '#15803d' }}>
                    <div>No Order Placed Yet</div>
                    <div>Guests: <strong>{selectedTable.active_session.guest_count}</strong></div>
                    <div style={{ fontSize: '11px', color: '#64748b', marginTop: '4px' }}>
                      Opened: {new Date(selectedTable.active_session.opened_at).toLocaleTimeString()}
                    </div>
                  </div>

                  <button
                    id="start-order-button"
                    type="button"
                    onClick={() => {
                      if (onEnterWorkspace && selectedTable.active_session) {
                        onEnterWorkspace({
                          table: selectedTable.table,
                          session: selectedTable.active_session,
                          order: null,
                          items: [],
                        });
                      }
                    }}
                    style={{
                      marginTop: '8px',
                      backgroundColor: '#16a34a',
                      color: '#ffffff',
                      border: 'none',
                      padding: '10px',
                      borderRadius: '4px',
                      fontWeight: '600',
                      cursor: 'pointer',
                      fontSize: '13px',
                    }}
                  >
                    Start Order →
                  </button>
                </div>
              )}

              {/* Billed Table State */}
              {deriveTableOccupancy(selectedTable.active_session) === 'BILLED' && (
                <div
                  id="billed-table-panel"
                  style={{
                    backgroundColor: '#fffbeb',
                    border: '1px solid #fde68a',
                    borderRadius: '6px',
                    padding: '14px',
                    fontSize: '13px',
                    color: '#92400e',
                  }}
                >
                  <strong>Billed</strong>
                  <div style={{ marginTop: '4px' }}>
                    Bill finalized. Awaiting payment & settlement before table can be closed.
                  </div>
                  <button
                    id="view-billed-order-button"
                    type="button"
                    onClick={() => {
                      if (onEnterWorkspace && selectedTable.active_session) {
                        onEnterWorkspace({
                          table: selectedTable.table,
                          session: selectedTable.active_session,
                          order: activeOrderContext ? activeOrderContext.order : null,
                          items: activeOrderContext ? activeOrderContext.items : [],
                        });
                      }
                    }}
                    style={{
                      marginTop: '8px',
                      backgroundColor: '#d97706',
                      color: '#ffffff',
                      border: 'none',
                      padding: '8px 12px',
                      borderRadius: '4px',
                      fontWeight: '600',
                      cursor: 'pointer',
                      fontSize: '12px',
                    }}
                  >
                    View Billed Order →
                  </button>
                </div>
              )}

              {/* Available Table Notice */}
              {deriveTableOccupancy(selectedTable.active_session) === 'AVAILABLE' && (
                <div style={{ fontSize: '13px', color: '#64748b' }}>
                  This table is available. Click on the card to open a session.
                </div>
              )}
            </div>
          ) : (
            <div style={{ color: '#94a3b8', fontSize: '14px', textAlign: 'center', marginTop: '40px' }}>
              Select a table from the floor to view its active session and order details.
            </div>
          )}

          {/* Footer note */}
          <div style={{ fontSize: '11px', color: '#94a3b8', textAlign: 'center', borderTop: '1px solid #f1f5f9', paddingTop: '12px' }}>
            CheesyOS NextGen POS • Offline-First Native Runtime
          </div>
        </aside>
      </div>

      {/* Guest Count Modal Dialog */}
      {guestModalTable && (
        <GuestCountModal
          table={guestModalTable}
          guestCount={guestCount}
          guestCountError={guestCountError}
          actionError={actionError}
          isSubmitting={isSubmittingOpen}
          onGuestCountChange={(c) => {
            setGuestCount(c);
            if (guestCountError) setGuestCountError(null);
          }}
          onConfirm={handleConfirmOpenSession}
          onCancel={handleCloseGuestModal}
        />
      )}
    </div>
  );
}

export default TableFloor;
