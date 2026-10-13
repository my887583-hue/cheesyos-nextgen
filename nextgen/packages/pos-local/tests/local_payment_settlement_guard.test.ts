/**
 * CHEESYOS NEXTGEN POS LOCAL — TASK 3G.2-11A.1
 * LOCAL PAYMENT SETTLEMENT GUARD + IDEMPOTENCY TEST SUITE
 * 
 * Verifies:
 * - PAYMENT_REQUIRES_BILLED_ORDER_NODE_PASS
 * - PAYMENT_REQUIRES_UNPAID_BILL_NODE_PASS
 * - PAYMENT_BILL_ORDER_MATCH_NODE_PASS
 * - PAYMENT_EXACT_REPLAY_IDEMPOTENT_NODE_PASS
 * - PAYMENT_EXACT_REPLAY_NO_DUPLICATE_OUTBOX_NODE_PASS
 * - PAYMENT_CONFLICTING_REPLAY_REJECTED_NODE_PASS
 * - PAYMENT_CONFLICTING_REPLAY_NO_OUTBOX_NODE_PASS
 * - PAYMENT_DIFFERENT_ID_SECOND_SETTLEMENT_REJECTED_NODE_PASS
 * - PAYMENT_DIFFERENT_ID_SECOND_SETTLEMENT_NO_OUTBOX_NODE_PASS
 * - PAYMENT_ATOMIC_SUCCESS_NODE_PASS
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { PosLocalDatabase } from '../src/database.js';
import type { IPosPersistence } from '../src/persistence.js';
import type { PaymentDomain, BillDomain, OrderDomain } from '@cheesyos/nextgen-shared';

function setupBilledFixture(posDb: PosLocalDatabase, orderId = 'ord-b1', billId = 'bill-b1', amountPaise = 5250) {
  const raw = posDb.getRawDb();
  const now = new Date().toISOString();

  // 1. Terminal config
  raw.prepare(`
    INSERT OR REPLACE INTO pos_device_config (device_id, terminal_code, device_name, created_at)
    VALUES ('dev-001', 'T01', 'Counter 1', ?)
  `).run(now);

  // 2. Table & Table session
  raw.prepare(`
    INSERT OR REPLACE INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
    VALUES ('tbl-01', 'T-01', 'Main', 4, 1, ?)
  `).run(now);

  raw.prepare(`
    INSERT OR REPLACE INTO table_sessions (id, table_id, current_order_id, guest_count, session_status, opened_at)
    VALUES ('sess-01', 'tbl-01', ?, 2, 'billed', ?)
  `).run(orderId, now);

  // 3. Order in 'billed' status
  raw.prepare(`
    INSERT OR REPLACE INTO orders (
      id, display_number, channel, order_type, table_session_id,
      status, subtotal_paise, tax_total_paise, discount_total_paise,
      delivery_charge_paise, grand_total_paise, version, created_at, updated_at
    ) VALUES (
      ?, '101', 'POS', 'DINE_IN', 'sess-01',
      'billed', 5000, 250, 0, 0, ?, 1, ?, ?
    )
  `).run(orderId, amountPaise, now, now);

  // 4. Bill in 'unpaid' status
  raw.prepare(`
    INSERT OR REPLACE INTO bills (
      id, order_id, bill_number, subtotal_paise, cgst_total_paise, sgst_total_paise,
      discount_total_paise, grand_total_paise, payment_status, finalized_at, device_id
    ) VALUES (
      ?, ?, 'CB-T01-000001', 5000, 125, 125, 0, ?, 'unpaid', ?, 'dev-001'
    )
  `).run(billId, orderId, amountPaise, now);

  const billDomain: BillDomain = {
    id: billId,
    order_id: orderId,
    bill_number: 'CB-T01-000001',
    subtotal: 50.0,
    cgst_total: 1.25,
    sgst_total: 1.25,
    discount_total: 0.0,
    grand_total: amountPaise / 100,
    payment_status: 'unpaid',
    finalized_at: now,
    device_id: 'dev-001',
  };

  return { orderId, billId, billDomain, now };
}

describe('Task 3G.2-11A.1: Local Payment Settlement Guard & Idempotency (Node)', () => {
  it('PAYMENT_ATOMIC_SUCCESS_NODE_PASS: Valid payment settles order, marks bill paid, writes payment & outbox', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const { orderId, billId, billDomain, now } = setupBilledFixture(posDb);
    const db: IPosPersistence = posDb;

    const payment: PaymentDomain = {
      id: 'pay-001',
      bill_id: billId,
      order_id: orderId,
      payment_mode: 'CASH',
      amount_paid: 52.5,
      confirmed_by_staff_id: 'staff-01',
      confirmed_at: now,
      notes: 'Exact cash given',
    };

    const updatedBill: BillDomain = {
      ...billDomain,
      payment_status: 'paid',
    };

    const res = await db.savePayment(payment, updatedBill);

    assert.equal(res.payment.id, 'pay-001');
    assert.equal(res.updatedBill.payment_status, 'paid');
    assert.equal(res.outboxEntry.entity_type, 'payments');

    // Verify DB state
    const raw = posDb.getRawDb();
    const orderRow = raw.prepare('SELECT status FROM orders WHERE id = ?').get(orderId) as { status: string };
    assert.equal(orderRow.status, 'settled');

    const billRow = raw.prepare('SELECT payment_status FROM bills WHERE id = ?').get(billId) as { payment_status: string };
    assert.equal(billRow.payment_status, 'paid');

    const payCount = raw.prepare('SELECT count(*) as c FROM payments WHERE bill_id = ?').get(billId) as { c: number };
    assert.equal(payCount.c, 1);

    const outboxCount = raw.prepare("SELECT count(*) as c FROM sync_outbox WHERE entity_type = 'payments' AND entity_id = ?").get('pay-001') as { c: number };
    assert.equal(outboxCount.c, 1);

    // Verify table session remains billed (not closed)
    const sessRow = raw.prepare("SELECT session_status, closed_at FROM table_sessions WHERE id = 'sess-01'").get() as { session_status: string; closed_at: string | null };
    assert.equal(sessRow.session_status, 'billed');
    assert.equal(sessRow.closed_at, null);

    posDb.close();
  });

  it('PAYMENT_REQUIRES_BILLED_ORDER_NODE_PASS: Rejects payment if order is draft, kot_sent, settled, cancelled, closed', async () => {
    const invalidStatuses = ['draft', 'pending', 'kot_sent', 'settled', 'cancelled', 'closed'];

    for (const status of invalidStatuses) {
      const posDb = new PosLocalDatabase(':memory:');
      const { orderId, billId, billDomain, now } = setupBilledFixture(posDb, `ord-${status}`, `bill-${status}`);
      posDb.getRawDb().prepare('UPDATE orders SET status = ? WHERE id = ?').run(status, orderId);

      const db: IPosPersistence = posDb;
      const payment: PaymentDomain = {
        id: `pay-${status}`,
        bill_id: billId,
        order_id: orderId,
        payment_mode: 'UPI',
        amount_paid: 52.5,
        confirmed_at: now,
      };

      await assert.rejects(
        async () => {
          await db.savePayment(payment, { ...billDomain, payment_status: 'paid' });
        },
        (err: Error) => {
          assert.match(err.message, /ORDER_STATUS_INVALID/);
          assert.match(err.message, /order must be 'billed'/);
          return true;
        }
      );

      // Verify no payment or outbox row created
      const payCount = posDb.getRawDb().prepare('SELECT count(*) as c FROM payments WHERE id = ?').get(`pay-${status}`) as { c: number };
      assert.equal(payCount.c, 0);

      const outboxCount = posDb.getRawDb().prepare('SELECT count(*) as c FROM sync_outbox WHERE entity_id = ?').get(`pay-${status}`) as { c: number };
      assert.equal(outboxCount.c, 0);

      posDb.close();
    }
  });

  it('PAYMENT_REQUIRES_UNPAID_BILL_NODE_PASS: Rejects payment if bill missing or already paid', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const { orderId, billId, billDomain, now } = setupBilledFixture(posDb);
    const db: IPosPersistence = posDb;

    // 1. Missing bill
    await assert.rejects(
      async () => {
        await db.savePayment(
          {
            id: 'pay-nobill',
            bill_id: 'bill-nonexistent',
            order_id: orderId,
            payment_mode: 'CASH',
            amount_paid: 52.5,
            confirmed_at: now,
          },
          { ...billDomain, id: 'bill-nonexistent', payment_status: 'paid' }
        );
      },
      /BILL_NOT_FOUND/
    );

    // 2. Bill already paid
    posDb.getRawDb().prepare("UPDATE bills SET payment_status = 'paid' WHERE id = ?").run(billId);

    await assert.rejects(
      async () => {
        await db.savePayment(
          {
            id: 'pay-alreadypaid',
            bill_id: billId,
            order_id: orderId,
            payment_mode: 'CASH',
            amount_paid: 52.5,
            confirmed_at: now,
          },
          { ...billDomain, payment_status: 'paid' }
        );
      },
      (err: Error) => {
        assert.match(err.message, /BILL_ALREADY_SETTLED/);
        return true;
      }
    );

    posDb.close();
  });

  it('PAYMENT_BILL_ORDER_MATCH_NODE_PASS: Rejects payment if bill belongs to a different order', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const { orderId, billId, billDomain, now } = setupBilledFixture(posDb);
    const db: IPosPersistence = posDb;

    await assert.rejects(
      async () => {
        await db.savePayment(
          {
            id: 'pay-mismatch',
            bill_id: billId,
            order_id: 'ord-different-999',
            payment_mode: 'CARD',
            amount_paid: 52.5,
            confirmed_at: now,
          },
          { ...billDomain, order_id: 'ord-different-999', payment_status: 'paid' }
        );
      },
      /ORDER_NOT_FOUND|BILL_ORDER_MISMATCH/
    );

    posDb.close();
  });

  it('PAYMENT_EXACT_REPLAY_IDEMPOTENT_NODE_PASS & PAYMENT_EXACT_REPLAY_NO_DUPLICATE_OUTBOX_NODE_PASS', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const { orderId, billId, billDomain, now } = setupBilledFixture(posDb);
    const db: IPosPersistence = posDb;

    const payment: PaymentDomain = {
      id: 'pay-idem-01',
      bill_id: billId,
      order_id: orderId,
      payment_mode: 'UPI',
      amount_paid: 52.5,
      confirmed_by_staff_id: 'staff-01',
      confirmed_at: now,
      notes: 'GPay #991',
    };

    const updatedBill: BillDomain = {
      ...billDomain,
      payment_status: 'paid',
    };

    // First attempt -> Succeeds
    const res1 = await db.savePayment(payment, updatedBill);
    assert.equal(res1.payment.id, 'pay-idem-01');

    // Second attempt -> Exact replay of same payment ID and payload
    const res2 = await db.savePayment(payment, updatedBill);
    assert.equal(res2.payment.id, 'pay-idem-01');
    assert.equal(res2.updatedBill.payment_status, 'paid');

    // Assert strictly NO duplicate payment rows
    const raw = posDb.getRawDb();
    const payCount = raw.prepare('SELECT count(*) as c FROM payments WHERE bill_id = ?').get(billId) as { c: number };
    assert.equal(payCount.c, 1, 'Payments row count must remain exactly 1');

    // Assert strictly NO duplicate outbox rows
    const outboxCount = raw.prepare('SELECT count(*) as c FROM sync_outbox WHERE entity_id = ?').get('pay-idem-01') as { c: number };
    assert.equal(outboxCount.c, 1, 'Sync outbox row count must remain exactly 1');

    posDb.close();
  });

  it('PAYMENT_CONFLICTING_REPLAY_REJECTED_NODE_PASS & PAYMENT_CONFLICTING_REPLAY_NO_OUTBOX_NODE_PASS', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const { orderId, billId, billDomain, now } = setupBilledFixture(posDb);
    const db: IPosPersistence = posDb;

    const payment: PaymentDomain = {
      id: 'pay-conflict-01',
      bill_id: billId,
      order_id: orderId,
      payment_mode: 'CASH',
      amount_paid: 52.5,
      confirmed_by_staff_id: 'staff-01',
      confirmed_at: now,
      notes: 'Cash received',
    };

    // First call succeeds
    await db.savePayment(payment, { ...billDomain, payment_status: 'paid' });

    // Conflicting call with same payment ID but changed payment mode (UPI instead of CASH)
    const conflictingPayment: PaymentDomain = {
      ...payment,
      payment_mode: 'UPI',
    };

    await assert.rejects(
      async () => {
        await db.savePayment(conflictingPayment, { ...billDomain, payment_status: 'paid' });
      },
      (err: Error) => {
        assert.match(err.message, /CONTRACT_CONFLICT/);
        return true;
      }
    );

    // Verify outbox count is still 1 (no new outbox row created)
    const raw = posDb.getRawDb();
    const outboxCount = raw.prepare('SELECT count(*) as c FROM sync_outbox WHERE entity_id = ?').get('pay-conflict-01') as { c: number };
    assert.equal(outboxCount.c, 1);

    posDb.close();
  });

  it('PAYMENT_DIFFERENT_ID_SECOND_SETTLEMENT_REJECTED_NODE_PASS & NO_OUTBOX_PASS', async () => {
    const posDb = new PosLocalDatabase(':memory:');
    const { orderId, billId, billDomain, now } = setupBilledFixture(posDb);
    const db: IPosPersistence = posDb;

    const p1: PaymentDomain = {
      id: 'pay-seq-01',
      bill_id: billId,
      order_id: orderId,
      payment_mode: 'CASH',
      amount_paid: 52.5,
      confirmed_at: now,
    };

    // P1 succeeds
    await db.savePayment(p1, { ...billDomain, payment_status: 'paid' });

    // P2 attempts second settlement with different ID
    const p2: PaymentDomain = {
      id: 'pay-seq-02',
      bill_id: billId,
      order_id: orderId,
      payment_mode: 'UPI',
      amount_paid: 52.5,
      confirmed_at: now,
    };

    await assert.rejects(
      async () => {
        await db.savePayment(p2, { ...billDomain, payment_status: 'paid' });
      },
      (err: Error) => {
        // Order is now 'settled' (not 'billed') and bill is now 'paid' (not 'unpaid')
        assert.match(err.message, /ORDER_STATUS_INVALID|BILL_ALREADY_SETTLED/);
        return true;
      }
    );

    const raw = posDb.getRawDb();
    const p2Count = raw.prepare("SELECT count(*) as c FROM payments WHERE id = 'pay-seq-02'").get() as { c: number };
    assert.equal(p2Count.c, 0, 'P2 payment row must NOT be created');

    const p2Outbox = raw.prepare("SELECT count(*) as c FROM sync_outbox WHERE entity_id = 'pay-seq-02'").get() as { c: number };
    assert.equal(p2Outbox.c, 0, 'P2 outbox row must NOT be created');

    const totalPays = raw.prepare('SELECT count(*) as c FROM payments WHERE bill_id = ?').get(billId) as { c: number };
    assert.equal(totalPays.c, 1, 'Total payments for bill must remain 1');

    posDb.close();
  });
});
