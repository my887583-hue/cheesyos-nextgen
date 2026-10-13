#[path = "../src/db.rs"]
mod db;

#[path = "../src/transport.rs"]
mod transport;

use rusqlite::{params, Connection};
use std::fs;

use db::*;

fn setup_in_memory_db() -> Connection {
    let conn = Connection::open_in_memory().expect("failed to open in-memory db");
    init_database(&conn).expect("failed to initialize schema");

    // Default fixtures for Foreign Key constraints
    conn.execute(
        "INSERT INTO categories (id, name, slug, created_at, updated_at) VALUES ('cat-01', 'Default Cat', 'default-cat', '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();
    conn.execute(
        "INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('prod-01', 'cat-01', 'Default Product', 10000, '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();
    conn.execute(
        "INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('prod-inj', 'cat-01', 'Inj Product', 5000, '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();

    conn
}

fn create_test_device_config(conn: &mut Connection, terminal_code: &str) -> DeviceConfig {
    set_device_config(
        conn,
        SetDeviceConfigInput {
            device_id: "dev-uuid-001".to_string(),
            terminal_code: terminal_code.to_string(),
            device_name: "Counter POS 1".to_string(),
            created_at: Some("2026-10-10T12:00:00.000Z".to_string()),
        },
    )
    .expect("failed to set device config")
}

// ============================================================================
// 1. SCHEMA PARITY & DATABASE INITIALIZATION
// ============================================================================

#[test]
fn test_schema_parity_and_version() {
    let conn = setup_in_memory_db();

    // 1. Verify PRAGMA user_version = 2
    let version: i32 = conn
        .query_row("PRAGMA user_version;", [], |r| r.get(0))
        .expect("query user_version");
    assert_eq!(version, SCHEMA_VERSION, "user_version must match SCHEMA_VERSION");

    // 2. Verify PRAGMA foreign_keys = ON
    let fk: i32 = conn
        .query_row("PRAGMA foreign_keys;", [], |r| r.get(0))
        .expect("query foreign_keys");
    assert_eq!(fk, 1, "foreign_keys must be enabled");

    // 3. Verify all 19 local tables exist
    let expected_tables = vec![
        "categories",
        "products",
        "product_variants",
        "customers",
        "pos_tables",
        "table_sessions",
        "orders",
        "order_items",
        "pos_kots",
        "kot_items",
        "kot_corrections",
        "bills",
        "payments",
        "inventory_lite",
        "inventory_movements",
        "sync_outbox",
        "sync_cursors",
        "pos_device_config",
        "pos_sequences",
    ];

    for table in expected_tables {
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?;",
                [table],
                |r| r.get(0),
            )
            .unwrap_or_else(|_| panic!("failed to check table existence: {table}"));
        assert_eq!(count, 1, "Table {table} must exist in native schema");
    }
}

// ============================================================================
// 2. DEVICE CONFIG & DISK RESTART DURABILITY
// ============================================================================

#[test]
fn test_device_config_native_restart_persistence() {
    let mut temp_path = std::env::temp_dir();
    temp_path.push(format!("cheesyos_test_restart_{}.db", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));

    // Phase 1: Create, initialize, and write config
    {
        let mut conn = Connection::open(&temp_path).expect("open temp db");
        init_database(&conn).expect("init db");

        let cfg = set_device_config(
            &mut conn,
            SetDeviceConfigInput {
                device_id: "dev-uuid-restart".to_string(),
                terminal_code: "T02".to_string(),
                device_name: "Takeaway Counter".to_string(),
                created_at: Some("2026-10-10T12:00:00.000Z".to_string()),
            },
        )
        .expect("set device config");
        assert_eq!(cfg.terminal_code, "T02");

        // Close connection cleanly
    }

    // Phase 2: Reopen from disk and verify persistence
    {
        let conn = Connection::open(&temp_path).expect("reopen temp db");
        let cfg = get_device_config(&conn)
            .expect("get device config")
            .expect("config must exist");

        assert_eq!(cfg.device_id, "dev-uuid-restart");
        assert_eq!(cfg.terminal_code, "T02");
        assert_eq!(cfg.device_name, "Takeaway Counter");
    }

    // Cleanup
    let _ = fs::remove_file(&temp_path);
}

// ============================================================================
// 3. ORDER TRANSACTION ATOMICITY & ROLLBACK
// ============================================================================

#[test]
fn test_order_aggregate_atomic_commit_and_forced_rollback() {
    let mut conn = setup_in_memory_db();

    let order = OrderDomain {
        id: "ord-test-01".to_string(),
        display_number: Some("1".to_string()),
        channel: "POS".to_string(),
        order_type: "DINE_IN".to_string(),
        customer_id: None,
        table_session_id: None,
        status: "draft".to_string(),
        subtotal_paise: 25000,
        tax_total_paise: 1250,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 26250,
        device_id: Some("dev-uuid-001".to_string()),
        version: Some(1),
        created_at: "2026-10-10T12:00:00.000Z".to_string(),
        updated_at: "2026-10-10T12:00:00.000Z".to_string(),
    };

    let items = vec![
        OrderItemDomain {
            id: "item-test-01".to_string(),
            order_id: "ord-test-01".to_string(),
            product_id: "prod-01".to_string(),
            variant_id: None,
            product_name: "Margherita Pizza".to_string(),
            unit_price_paise: 25000,
            quantity: 1,
            tax_rate: 5.0,
            discount_amount_paise: 0,
            line_total_paise: 25000,
            notes: Some("Extra crispy".to_string()),
            created_at: "2026-10-10T12:00:00.000Z".to_string(),
        },
    ];

    // 1. Successful atomic commit
    let res = save_order_aggregate(&mut conn, order, items).expect("save order aggregate");
    assert_eq!(res.order.id, "ord-test-01");
    assert_eq!(res.items.len(), 1);
    assert_eq!(res.outbox_entries.len(), 1);
    assert_eq!(res.outbox_entries[0].entity_type, "orders");
    assert_eq!(res.outbox_entries[0].entity_id, "ord-test-01");

    let order_count: i32 = conn
        .query_row("SELECT COUNT(*) FROM orders WHERE id = 'ord-test-01';", [], |r| r.get(0))
        .expect("count orders");
    let item_count: i32 = conn
        .query_row("SELECT COUNT(*) FROM order_items WHERE id = 'item-test-01';", [], |r| r.get(0))
        .expect("count items");
    let outbox_count: i32 = conn
        .query_row("SELECT COUNT(*) FROM sync_outbox WHERE entity_id = 'ord-test-01';", [], |r| r.get(0))
        .expect("count outbox");

    assert_eq!(order_count, 1);
    assert_eq!(item_count, 1);
    assert_eq!(outbox_count, 1);

    // 2. Forced failure test: inserting duplicate order ID violates PK
    let dup_order = OrderDomain {
        id: "ord-test-01".to_string(), // duplicate ID
        display_number: Some("2".to_string()),
        channel: "POS".to_string(),
        order_type: "DINE_IN".to_string(),
        customer_id: None,
        table_session_id: None,
        status: "draft".to_string(),
        subtotal_paise: 10000,
        tax_total_paise: 500,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 10500,
        device_id: None,
        version: Some(1),
        created_at: "2026-10-10T12:05:00.000Z".to_string(),
        updated_at: "2026-10-10T12:05:00.000Z".to_string(),
    };

    let dup_items = vec![OrderItemDomain {
        id: "item-test-02".to_string(),
        order_id: "ord-test-01".to_string(),
        product_id: "prod-02".to_string(),
        variant_id: None,
        product_name: "Garlic Bread".to_string(),
        unit_price_paise: 10000,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount_paise: 0,
        line_total_paise: 10000,
        notes: None,
        created_at: "2026-10-10T12:05:00.000Z".to_string(),
    }];

    let err = save_order_aggregate(&mut conn, dup_order, dup_items).expect_err("must fail on duplicate PK");
    assert!(err.contains("UNIQUE constraint failed"), "Error must be constraint violation: {err}");

    // Verify item-test-02 was NOT partially written
    let partial_item: i32 = conn
        .query_row("SELECT COUNT(*) FROM order_items WHERE id = 'item-test-02';", [], |r| r.get(0))
        .expect("count item 2");
    assert_eq!(partial_item, 0, "Partial items must be rolled back on order error");
}

// ============================================================================
// 4. KOT AGGREGATE & CORRECTION ATOMICITY
// ============================================================================

#[test]
fn test_kot_aggregate_and_correction_atomicity() {
    let mut conn = setup_in_memory_db();

    // 1. Insert parent order
    conn.execute(
        "INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
         VALUES ('ord-kot-1', 'POS', 'DINE_IN', 'draft', 10000, 500, 0, 0, 10500, '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();

    // 2. Save KOT aggregate
    let kot = PosKotDomain {
        id: "kot-01".to_string(),
        order_id: "ord-kot-1".to_string(),
        kot_number: 1,
        device_id: Some("dev-uuid-001".to_string()),
        status: "printed".to_string(),
        printed_at: "2026-10-10T12:01:00.000Z".to_string(),
    };
    conn.execute(
        "INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
         VALUES ('item-kot-1', 'ord-kot-1', 'prod-01', 'Cheesy Fries', 5000, 2, 5.0, 0, 10500, '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();

    let items = vec![KotItemDomain {
        id: "kot-item-01".to_string(),
        kot_id: "kot-01".to_string(),
        order_item_id: Some("item-kot-1".to_string()),
        product_id: "prod-01".to_string(),
        variant_id: None,
        product_name: "Cheesy Fries".to_string(),
        quantity: 2,
        notes: Some("Extra dip".to_string()),
    }];

    let kot_res = save_kot_aggregate(&mut conn, kot, items).expect("save kot aggregate");
    assert_eq!(kot_res.kot.id, "kot-01");
    assert_eq!(kot_res.outbox_entries.len(), 1);

    // 3. Save KOT correction
    let correction = KotCorrectionDomain {
        id: "corr-01".to_string(),
        order_id: "ord-kot-1".to_string(),
        kot_id: Some("kot-01".to_string()),
        kot_item_id: Some("kot-item-01".to_string()),
        order_item_id: Some("item-kot-1".to_string()),
        product_name: "Cheesy Fries".to_string(),
        cancelled_qty: 1,
        reason: "Customer changed mind".to_string(),
        authorized_by_staff_id: "staff-01".to_string(),
        created_at: "2026-10-10T12:02:00.000Z".to_string(),
    };

    let corr_row = save_kot_correction(&mut conn, correction).expect("save kot correction");
    assert_eq!(corr_row.entity_type, "kot_corrections");
    assert_eq!(corr_row.entity_id, "corr-01");

    let corr_count: i32 = conn
        .query_row("SELECT COUNT(*) FROM kot_corrections WHERE id = 'corr-01';", [], |r| r.get(0))
        .unwrap();
    assert_eq!(corr_count, 1);
}

// ============================================================================
// 5. BILL + SEQUENCE HARD GATE (AUTHORITY, CONFLICT REJECTION, ROLLBACK)
// ============================================================================

#[test]
fn test_bill_and_sequence_hard_gate() {
    let mut conn = setup_in_memory_db();
    create_test_device_config(&mut conn, "T01");

    // Create parent orders
    conn.execute(
        "INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
         VALUES ('ord-b1', 'POS', 'DINE_IN', 'draft', 10000, 500, 0, 0, 10500, '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();
    conn.execute(
        "INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
         VALUES ('ord-b2', 'POS', 'DINE_IN', 'draft', 10000, 500, 0, 0, 10500, '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();

    // 1. Normal allocation with placeholder bill_number
    let bill1 = BillDomain {
        id: "bill-01".to_string(),
        order_id: "ord-b1".to_string(),
        bill_number: "PENDING".to_string(),
        subtotal_paise: 10000,
        cgst_total_paise: 250,
        sgst_total_paise: 250,
        discount_total_paise: 0,
        grand_total_paise: 10500,
        payment_status: "unpaid".to_string(),
        finalized_at: "2026-10-10T12:00:00.000Z".to_string(),
        device_id: None,
    };

    let res1 = save_bill_with_sequence(&mut conn, bill1).expect("save bill 1");
    assert_eq!(res1.sequence_number, 1);
    assert_eq!(res1.bill.bill_number, "CB-T01-000001");
    assert_eq!(res1.outbox_entry.entity_type, "bills");

    // 2. HARD GATE: Conflicting caller-provided bill number must be REJECTED
    let conflicting_bill = BillDomain {
        id: "bill-conflict".to_string(),
        order_id: "ord-b2".to_string(),
        bill_number: "CB-T01-999999".to_string(), // Conflicting number!
        subtotal_paise: 10000,
        cgst_total_paise: 250,
        sgst_total_paise: 250,
        discount_total_paise: 0,
        grand_total_paise: 10500,
        payment_status: "unpaid".to_string(),
        finalized_at: "2026-10-10T12:01:00.000Z".to_string(),
        device_id: None,
    };

    let conflict_err = save_bill_with_sequence(&mut conn, conflicting_bill)
        .expect_err("Conflicting caller bill number must be rejected");
    assert!(conflict_err.contains("BILL_NUMBER_CONFLICT"), "Must return BILL_NUMBER_CONFLICT: {conflict_err}");

    // 3. Verify sequence was ROLLED BACK on rejection
    let seq_val: i64 = conn
        .query_row("SELECT current_value FROM pos_sequences WHERE sequence_name = 'bill_sequence';", [], |r| r.get(0))
        .expect("read sequence");
    assert_eq!(seq_val, 1, "Sequence counter must remain 1 after rolled-back conflict");

    // 4. Verify no orphan bill or outbox row was written
    let conflict_bill_count: i32 = conn
        .query_row("SELECT COUNT(*) FROM bills WHERE id = 'bill-conflict';", [], |r| r.get(0))
        .unwrap();
    assert_eq!(conflict_bill_count, 0, "Conflicting bill must not be persisted");

    // 5. Subsequent valid allocation receives sequence #2
    let bill2 = BillDomain {
        id: "bill-02".to_string(),
        order_id: "ord-b2".to_string(),
        bill_number: "".to_string(),
        subtotal_paise: 10000,
        cgst_total_paise: 250,
        sgst_total_paise: 250,
        discount_total_paise: 0,
        grand_total_paise: 10500,
        payment_status: "unpaid".to_string(),
        finalized_at: "2026-10-10T12:02:00.000Z".to_string(),
        device_id: None,
    };

    let res2 = save_bill_with_sequence(&mut conn, bill2).expect("save bill 2");
    assert_eq!(res2.sequence_number, 2);
    assert_eq!(res2.bill.bill_number, "CB-T01-000002");
}

// ============================================================================
// 6. PAYMENT ATOMICITY
// ============================================================================

#[test]
fn test_payment_atomicity() {
    let mut conn = setup_in_memory_db();
    create_test_device_config(&mut conn, "T01");

    conn.execute(
        "INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
         VALUES ('ord-p1', 'POS', 'DINE_IN', 'billed', 5000, 250, 0, 0, 5250, '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();

    let bill = BillDomain {
        id: "bill-p1".to_string(),
        order_id: "ord-p1".to_string(),
        bill_number: "CB-T01-000001".to_string(),
        subtotal_paise: 5000,
        cgst_total_paise: 125,
        sgst_total_paise: 125,
        discount_total_paise: 0,
        grand_total_paise: 5250,
        payment_status: "unpaid".to_string(),
        finalized_at: "2026-10-10T12:00:00Z".to_string(),
        device_id: None,
    };
    save_bill_with_sequence(&mut conn, bill.clone()).unwrap();

    let payment = PaymentDomain {
        id: "pay-01".to_string(),
        bill_id: "bill-p1".to_string(),
        order_id: "ord-p1".to_string(),
        payment_mode: "UPI".to_string(),
        amount_paid_paise: 5250,
        confirmed_by_staff_id: Some("staff-01".to_string()),
        confirmed_at: "2026-10-10T12:05:00Z".to_string(),
        notes: Some("GPay transaction #8812".to_string()),
    };

    let mut updated_bill = bill;
    updated_bill.payment_status = "paid".to_string();

    let pay_res = save_payment(&mut conn, payment, updated_bill).expect("save payment");
    assert_eq!(pay_res.payment.id, "pay-01");
    assert_eq!(pay_res.updated_bill.payment_status, "paid");

    let bill_status: String = conn
        .query_row("SELECT payment_status FROM bills WHERE id = 'bill-p1';", [], |r| r.get(0))
        .unwrap();
    assert_eq!(bill_status, "paid");
}

// ============================================================================
// 7. INVENTORY MOVEMENT ATOMICITY & RESTART PERSISTENCE
// ============================================================================

#[test]
fn test_inventory_movement_atomicity() {
    let mut conn = setup_in_memory_db();

    // Create tracked product & initial stock
    conn.execute(
        "INSERT INTO categories (id, name, slug, created_at, updated_at) VALUES ('cat-1', 'Drinks', 'drinks', '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();
    conn.execute(
        "INSERT INTO products (id, category_id, name, base_price_paise, created_at, updated_at) VALUES ('prod-coke', 'cat-1', 'Coke Can', 4000, '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();
    conn.execute(
        "INSERT INTO inventory_lite (id, product_id, current_stock, updated_at) VALUES ('inv-1', 'prod-coke', 20, '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();

    let input = SaveInventoryMovementInput {
        id: Some("move-uuid-fixed-01".to_string()),
        product_id: "prod-coke".to_string(),
        movement_type: "SALE".to_string(),
        quantity_change: -2,
        created_by_staff_id: Some("staff-01".to_string()),
        reference_movement_id: None,
        created_at: Some("2026-10-10T12:10:00Z".to_string()),
    };

    let move_res = save_inventory_movement(&mut conn, input).expect("save inventory movement");
    assert_eq!(move_res.movement_id, "move-uuid-fixed-01");
    assert_eq!(move_res.new_stock, 18);
    assert_eq!(move_res.outbox_entry.entity_type, "inventory_movements");

    let current_stock: i64 = conn
        .query_row("SELECT current_stock FROM inventory_lite WHERE product_id = 'prod-coke';", [], |r| r.get(0))
        .unwrap();
    assert_eq!(current_stock, 18);
}

// ============================================================================
// 8. OUTBOX OPERATIONS (READ, ACK, FAILURE UPDATE)
// ============================================================================

#[test]
fn test_outbox_operations() {
    let mut conn = setup_in_memory_db();

    // Insert 3 test outbox records
    conn.execute(
        "INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at) VALUES ('o1', 'orders', 'ord-1', 'INSERT', '{}', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();
    conn.execute(
        "INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at) VALUES ('o2', 'bills', 'bill-1', 'INSERT', '{}', '2026-10-10T12:01:00Z');",
        [],
    ).unwrap();

    // 1. Read bounded pending outbox
    let pending = get_pending_outbox(&conn, Some(10)).expect("get pending outbox");
    assert_eq!(pending.len(), 2);
    assert_eq!(pending[0].entity_type, "orders");
    assert_eq!(pending[1].entity_type, "bills");

    // 2. Update failure
    update_outbox_failure(&mut conn, pending[0].seq, "Network timeout 504", Some("2026-10-10T12:05:00Z"))
        .expect("update failure");

    let updated_pending = get_pending_outbox(&conn, Some(10)).expect("get pending outbox");
    assert_eq!(updated_pending[0].attempt_count, 1);
    assert_eq!(updated_pending[0].last_error.as_deref(), Some("Network timeout 504"));

    // 3. Acknowledge (delete) outbox entry
    acknowledge_outbox(&mut conn, pending[0].seq).expect("acknowledge outbox");

    let remaining = get_pending_outbox(&conn, Some(10)).expect("get remaining outbox");
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].entity_type, "bills");
}

// ============================================================================
// 9. CURSOR OPERATIONS
// ============================================================================

#[test]
fn test_sync_cursor_operations() {
    let conn = setup_in_memory_db();

    // Default cursor returns epoch
    let cur1 = get_sync_cursor(&conn, PullDataset::Products).expect("get default cursor");
    assert_eq!(cur1.dataset, "products");
    assert_eq!(cur1.last_updated_at, "1970-01-01T00:00:00.000Z");
    assert_eq!(cur1.last_id, "");

    // Set cursor advances
    set_sync_cursor(&conn, PullDataset::Products, "2026-10-10T15:00:00.000Z", "prod-999")
        .expect("set sync cursor");

    let cur2 = get_sync_cursor(&conn, PullDataset::Products).expect("get updated cursor");
    assert_eq!(cur2.last_updated_at, "2026-10-10T15:00:00.000Z");
    assert_eq!(cur2.last_id, "prod-999");
}

// ============================================================================
// 10. APPLY PULL BATCH & ZERO OUTBOX ECHO
// ============================================================================

#[test]
fn test_apply_pull_batch_finite_datasets_and_no_echo() {
    let mut conn = setup_in_memory_db();

    // Pull categories batch
    let cat_batch = ApplyPullBatchInput {
        dataset: PullDataset::Categories,
        rows: vec![
            serde_json::json!({
                "id": "cat-cloud-1",
                "name": "Burgers",
                "slug": "burgers",
                "display_order": 1,
                "is_active": true,
                "created_at": "2026-10-10T12:00:00Z",
                "updated_at": "2026-10-10T12:00:00Z"
            }),
        ],
        new_cursor: CursorWatermark {
            last_updated_at: "2026-10-10T12:00:00Z".to_string(),
            last_id: "cat-cloud-1".to_string(),
        },
    };

    let applied = apply_pull_batch(&mut conn, cat_batch).expect("apply categories pull batch");
    assert_eq!(applied, 1);

    // Verify category inserted
    let cat_name: String = conn
        .query_row("SELECT name FROM categories WHERE id = 'cat-cloud-1';", [], |r| r.get(0))
        .unwrap();
    assert_eq!(cat_name, "Burgers");

    // HARD GATE: Verify ZERO outbox echo
    let outbox_count: i32 = conn
        .query_row("SELECT COUNT(*) FROM sync_outbox;", [], |r| r.get(0))
        .unwrap();
    assert_eq!(outbox_count, 0, "Pull batch MUST NEVER produce sync_outbox echo");

    // Verify cursor advanced
    let cursor = get_sync_cursor(&conn, PullDataset::Categories).unwrap();
    assert_eq!(cursor.last_id, "cat-cloud-1");
}

// ============================================================================
// 11. AGGREGATE PENDING PROTECTION
// ============================================================================

#[test]
fn test_aggregate_pending_protection() {
    let mut conn = setup_in_memory_db();

    // 1. Simulate local pending order in outbox
    conn.execute(
        "INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at)
         VALUES ('out-ord-pending', 'orders', 'ord-pending-1', 'INSERT', '{}', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();

    // 2. Cloud pull arrives with updated order and child items for that order
    let pull_orders = ApplyPullBatchInput {
        dataset: PullDataset::Orders,
        rows: vec![serde_json::json!({
            "orders": [{
                "id": "ord-pending-1",
                "channel": "POS",
                "order_type": "DINE_IN",
                "status": "closed",
                "subtotal": 50.0,
                "grand_total": 52.5,
                "created_at": "2026-10-10T12:00:00Z",
                "updated_at": "2026-10-10T12:00:00Z"
            }],
            "orderItems": [{
                "id": "item-pending-1",
                "order_id": "ord-pending-1",
                "product_id": "prod-1",
                "product_name": "Cloud overwrite item",
                "unit_price": 50.0,
                "quantity": 1,
                "line_total": 50.0,
                "created_at": "2026-10-10T12:00:00Z"
            }]
        })],
        new_cursor: CursorWatermark {
            last_updated_at: "2026-10-10T12:00:00Z".to_string(),
            last_id: "ord-pending-1".to_string(),
        },
    };

    let applied = apply_pull_batch(&mut conn, pull_orders).expect("apply pull batch");
    assert_eq!(applied, 0, "Both pending parent order and child items must be protected and skipped");

    let count: i32 = conn
        .query_row("SELECT COUNT(*) FROM orders WHERE id = 'ord-pending-1';", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 0, "Pending order must not be overwritten by cloud pull");
}

// ============================================================================
// 12. FINANCIAL IMMUTABILITY CONFLICT PROTECTION
// ============================================================================

#[test]
fn test_financial_immutability_conflict_protection() {
    let mut conn = setup_in_memory_db();
    create_test_device_config(&mut conn, "T01");

    conn.execute(
        "INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
         VALUES ('ord-b-imm', 'POS', 'DINE_IN', 'billed', 10000, 500, 0, 0, 10500, '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();

    let local_bill = BillDomain {
        id: "bill-immutable-1".to_string(),
        order_id: "ord-b-imm".to_string(),
        bill_number: "CB-T01-000001".to_string(),
        subtotal_paise: 10000,
        cgst_total_paise: 250,
        sgst_total_paise: 250,
        discount_total_paise: 0,
        grand_total_paise: 10500, // 105.00 Rupees = 10500 paise
        payment_status: "unpaid".to_string(),
        finalized_at: "2026-10-10T12:00:00Z".to_string(),
        device_id: None,
    };
    save_bill_with_sequence(&mut conn, local_bill).unwrap();
    // Clear outbox to simulate already-synced bill (so pending outbox protection does not skip it)
    conn.execute("DELETE FROM sync_outbox;", []).unwrap();

    // Pull batch arrives with DIFFERENT grand total for same bill ID
    let conflict_batch = ApplyPullBatchInput {
        dataset: PullDataset::Bills,
        rows: vec![serde_json::json!({
            "id": "bill-immutable-1",
            "order_id": "ord-b-imm",
            "bill_number": "CB-T01-000001",
            "subtotal": 120.0,
            "cgst_total": 3.0,
            "sgst_total": 3.0,
            "grand_total": 126.0, // 12600 paise != 10500 paise!
            "payment_status": "unpaid",
            "finalized_at": "2026-10-10T12:00:00Z"
        })],
        new_cursor: CursorWatermark {
            last_updated_at: "2026-10-10T12:00:00Z".to_string(),
            last_id: "bill-immutable-1".to_string(),
        },
    };

    let err = apply_pull_batch(&mut conn, conflict_batch).expect_err("Must throw CONTRACT_CONFLICT on financial mismatch");
    assert!(err.contains("CONTRACT_CONFLICT"), "Error must be CONTRACT_CONFLICT: {err}");
}

// ============================================================================
// 13. MALICIOUS SQL-LIKE PAYLOAD TEST
// ============================================================================

#[test]
fn test_malicious_sql_like_payload_executed_as_plain_data() {
    let mut conn = setup_in_memory_db();

    // Pass malicious SQL statements in data fields
    let order = OrderDomain {
        id: "ord-sql-inj".to_string(),
        display_number: Some("1".to_string()),
        channel: "POS".to_string(),
        order_type: "DINE_IN".to_string(),
        customer_id: None,
        table_session_id: None,
        status: "draft".to_string(),
        subtotal_paise: 5000,
        tax_total_paise: 250,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 5250,
        device_id: None,
        version: Some(1),
        created_at: "2026-10-10T12:00:00Z".to_string(),
        updated_at: "2026-10-10T12:00:00Z".to_string(),
    };

    let malicious_items = vec![OrderItemDomain {
        id: "item-sql-inj".to_string(),
        order_id: "ord-sql-inj".to_string(),
        product_id: "prod-inj".to_string(),
        variant_id: None,
        product_name: "DROP TABLE orders; --".to_string(),
        unit_price_paise: 5000,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount_paise: 0,
        line_total_paise: 5000,
        notes: Some("'; DELETE FROM bills; SELECT * FROM payments; --".to_string()),
        created_at: "2026-10-10T12:00:00Z".to_string(),
    }];

    save_order_aggregate(&mut conn, order, malicious_items).expect("save aggregate with SQL-like text");

    // Verify orders table was NOT dropped
    let orders_exist: i32 = conn
        .query_row("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'orders';", [], |r| r.get(0))
        .unwrap();
    assert_eq!(orders_exist, 1, "orders table must remain intact");

    // Verify the text was stored verbatim as data
    let stored_name: String = conn
        .query_row("SELECT product_name FROM order_items WHERE id = 'item-sql-inj';", [], |r| r.get(0))
        .unwrap();
    assert_eq!(stored_name, "DROP TABLE orders; --");
}

// ============================================================================
// 14. IPC DISPATCHER & UNKNOWN OPERATION REJECTION
// ============================================================================

#[test]
fn test_ipc_mutation_and_query_dispatchers() {
    let mut conn = setup_in_memory_db();

    // 1. Test dispatch mutation: SetDeviceConfig
    let set_cfg_op = NativeMutation::SetDeviceConfig(SetDeviceConfigInput {
        device_id: "dev-ipc-1".to_string(),
        terminal_code: "T05".to_string(),
        device_name: "Bar POS".to_string(),
        created_at: None,
    });
    let mut_res = execute_mutation(&mut conn, set_cfg_op).expect("dispatch mutation");
    assert_eq!(mut_res["terminal_code"], "T05");

    // 2. Test dispatch query: GetDeviceConfig
    let q_res = execute_query(&conn, NativeQuery::GetDeviceConfig).expect("dispatch query");
    assert_eq!(q_res["device_id"], "dev-ipc-1");

    // 3. Test unknown operation rejection via Serde deserialization
    let unknown_json = serde_json::json!({
        "type": "ExecuteArbitrarySql",
        "payload": {
            "sql": "DROP TABLE orders;"
        }
    });

    let parse_res: Result<NativeMutation, _> = serde_json::from_value(unknown_json);
    assert!(parse_res.is_err(), "Unknown native operation must be rejected by Serde");
}

// ============================================================================
// 15. DELTA PULL SAFE PREFIX CURSOR & SAME TIMESTAMP PARITY TEST
// ============================================================================

#[test]
fn test_pull_safe_prefix_cursor_and_same_timestamp_parity() {
    let mut conn = setup_in_memory_db();

    // 0. Pre-insert category cat-1 to satisfy foreign key
    conn.execute(
        "INSERT INTO categories (id, name, slug, display_order, is_active, created_at, updated_at)
         VALUES ('cat-1', 'Pizzas', 'pizzas', 1, 1, '2026-10-10T12:00:00Z', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();

    // 1. Mark prod-B as pending in local outbox
    conn.execute(
        "INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at)
         VALUES ('out-prod-B', 'products', 'prod-B', 'INSERT', '{}', '2026-10-10T12:00:00Z');",
        [],
    ).unwrap();

    // 2. Cloud pull batch has prod-A, prod-B, prod-C sharing identical updated_at
    let batch1 = ApplyPullBatchInput {
        dataset: PullDataset::Products,
        rows: vec![
            serde_json::json!({
                "id": "prod-A",
                "category_id": "cat-1",
                "name": "Pizza A",
                "base_price": 10.0,
                "is_available": true,
                "tax_rate": 5.0,
                "is_inventory_tracked": false,
                "created_at": "2026-10-10T12:00:00.000Z",
                "updated_at": "2026-10-10T12:00:00.000Z"
            }),
            serde_json::json!({
                "id": "prod-B",
                "category_id": "cat-1",
                "name": "Pizza B",
                "base_price": 12.0,
                "is_available": true,
                "tax_rate": 5.0,
                "is_inventory_tracked": false,
                "created_at": "2026-10-10T12:00:00.000Z",
                "updated_at": "2026-10-10T12:00:00.000Z"
            }),
            serde_json::json!({
                "id": "prod-C",
                "category_id": "cat-1",
                "name": "Pizza C",
                "base_price": 15.0,
                "is_available": true,
                "tax_rate": 5.0,
                "is_inventory_tracked": false,
                "created_at": "2026-10-10T12:00:00.000Z",
                "updated_at": "2026-10-10T12:00:00.000Z"
            }),
        ],
        new_cursor: CursorWatermark {
            last_updated_at: "2026-10-10T12:00:00.000Z".to_string(),
            last_id: "prod-C".to_string(),
        },
    };

    let applied1 = apply_pull_batch(&mut conn, batch1).expect("apply batch 1");
    // prod-A applied; prod-B is pending (stops loop); prod-C is not applied
    assert_eq!(applied1, 1);

    // Verify prod-A in db, prod-B and prod-C not in db
    let count_a: i32 = conn.query_row("SELECT COUNT(*) FROM products WHERE id = 'prod-A';", [], |r| r.get(0)).unwrap();
    let count_b: i32 = conn.query_row("SELECT COUNT(*) FROM products WHERE id = 'prod-B';", [], |r| r.get(0)).unwrap();
    let count_c: i32 = conn.query_row("SELECT COUNT(*) FROM products WHERE id = 'prod-C';", [], |r| r.get(0)).unwrap();
    assert_eq!(count_a, 1);
    assert_eq!(count_b, 0);
    assert_eq!(count_c, 0);

    // CRITICAL: Cursor must advance to prod-A, NEVER past prod-B to prod-C
    let cursor1 = get_sync_cursor(&conn, PullDataset::Products).unwrap();
    assert_eq!(cursor1.last_updated_at, "2026-10-10T12:00:00.000Z");
    assert_eq!(cursor1.last_id, "prod-A");

    // 3. Simulate push ACK clearing outbox for prod-B
    conn.execute("DELETE FROM sync_outbox WHERE entity_id = 'prod-B';", []).unwrap();

    // 4. Next pull queries from (2026-10-10T12:00:00.000Z, prod-A), fetching prod-B and prod-C
    let batch2 = ApplyPullBatchInput {
        dataset: PullDataset::Products,
        rows: vec![
            serde_json::json!({
                "id": "prod-B",
                "category_id": "cat-1",
                "name": "Pizza B",
                "base_price": 12.0,
                "is_available": true,
                "tax_rate": 5.0,
                "is_inventory_tracked": false,
                "created_at": "2026-10-10T12:00:00.000Z",
                "updated_at": "2026-10-10T12:00:00.000Z"
            }),
            serde_json::json!({
                "id": "prod-C",
                "category_id": "cat-1",
                "name": "Pizza C",
                "base_price": 15.0,
                "is_available": true,
                "tax_rate": 5.0,
                "is_inventory_tracked": false,
                "created_at": "2026-10-10T12:00:00.000Z",
                "updated_at": "2026-10-10T12:00:00.000Z"
            }),
        ],
        new_cursor: CursorWatermark {
            last_updated_at: "2026-10-10T12:00:00.000Z".to_string(),
            last_id: "prod-C".to_string(),
        },
    };

    let applied2 = apply_pull_batch(&mut conn, batch2).expect("apply batch 2");
    assert_eq!(applied2, 2);

    let count_b_after: i32 = conn.query_row("SELECT COUNT(*) FROM products WHERE id = 'prod-B';", [], |r| r.get(0)).unwrap();
    let count_c_after: i32 = conn.query_row("SELECT COUNT(*) FROM products WHERE id = 'prod-C';", [], |r| r.get(0)).unwrap();
    assert_eq!(count_b_after, 1);
    assert_eq!(count_c_after, 1);

    // Cursor now advances cleanly to prod-C
    let cursor2 = get_sync_cursor(&conn, PullDataset::Products).unwrap();
    assert_eq!(cursor2.last_updated_at, "2026-10-10T12:00:00.000Z");
    assert_eq!(cursor2.last_id, "prod-C");
}

// ============================================================================
// FIX 09: PERSISTENT SQLITE & NATIVE NEXTGEN CONFIG CONTRACTS
// ============================================================================

#[test]
fn test_persistent_sqlite_file_and_reopen_contract() {
    let mut temp_path = std::env::temp_dir();
    temp_path.push(format!("cheesyos_fix09_persist_{}.db", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));

    // Phase 1: Open persistent database at path, initialize, write sequence counter
    {
        let conn = open_database_at_path(&temp_path).expect("open persistent sqlite");
        assert!(temp_path.exists(), "PERSISTENT_SQLITE_FILE: File must physically exist on disk");
        let meta = fs::metadata(&temp_path).expect("file metadata");
        assert!(meta.len() > 0, "PERSISTENT_SQLITE_FILE: Database file must be non-empty");

        conn.execute(
            "INSERT INTO pos_sequences (sequence_name, current_value, updated_at) VALUES ('bill_seq', 42, '2026-10-11T12:00:00Z');",
            [],
        ).expect("insert sequence");
        // Connection drops cleanly here
    }

    // Phase 2: Reopen same SQLite file from disk and verify persistence across connection boundary
    {
        let conn2 = open_database_at_path(&temp_path).expect("reopen same sqlite file");
        let val: i64 = conn2.query_row(
            "SELECT current_value FROM pos_sequences WHERE sequence_name = 'bill_seq';",
            [],
            |r| r.get(0),
        ).expect("query sequence from reopened db");

        assert_eq!(val, 42, "SQLITE_REOPEN_SAME_FILE: Value must persist across connection reopen");
    }

    // Cleanup
    let _ = fs::remove_file(&temp_path);
}

#[test]
fn test_device_config_restart_persistence_contract() {
    let mut temp_path = std::env::temp_dir();
    temp_path.push(format!("cheesyos_fix09_device_{}.db", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));

    // Process A: Write device config
    {
        let mut conn = open_database_at_path(&temp_path).expect("open db process A");
        transport::init_credentials_table(&conn).expect("init credentials process A");

        let cfg = set_device_config(
            &mut conn,
            SetDeviceConfigInput {
                device_id: "dev-fix09-persistent".to_string(),
                terminal_code: "T01".to_string(),
                device_name: "Front Counter".to_string(),
                created_at: Some("2026-10-11T12:00:00.000Z".to_string()),
            },
        ).expect("set device config");
        assert_eq!(cfg.terminal_code, "T01");

        transport::store_device_credential(&conn, "dev-fix09-persistent", "token_sec_123").expect("store credential");
        // Process A exits
    }

    // Process B: Reopen same file and verify device config & credential persist
    {
        let conn = open_database_at_path(&temp_path).expect("reopen db process B");
        let cfg = get_device_config(&conn)
            .expect("get device config")
            .expect("device config must exist after restart");

        assert_eq!(cfg.device_id, "dev-fix09-persistent", "DEVICE_CONFIG_RESTART_PERSISTENCE: Device ID must match");
        assert_eq!(cfg.terminal_code, "T01", "DEVICE_CONFIG_RESTART_PERSISTENCE: Terminal code must match");
        assert_eq!(cfg.device_name, "Front Counter");

        let cred = transport::load_device_credential(&conn, "dev-fix09-persistent")
            .expect("load device credential after restart");
        assert_eq!(cred, "token_sec_123", "DEVICE_CREDENTIAL_RESTART_PERSISTENCE: Credential must match");
    }

    // Cleanup
    let _ = fs::remove_file(&temp_path);
}

#[test]
fn test_native_nextgen_config_contracts() {
    // 1. NextGen Project URL must be configured and valid
    let url = transport::get_nextgen_supabase_url().expect("NATIVE_NEXTGEN_URL_CONFIGURED: URL must be valid");
    assert!(url.contains("sdbnibyzqtgpbexlznat"), "NATIVE_NEXTGEN_URL_CONFIGURED: Project must match sdbnibyzqtgpbexlznat");
    assert!(!url.contains("asvkfvrbhvxjmkznnpyb"), "Target isolation: Production project is forbidden");

    // 2. NextGen Anon Key must be configured and must NOT be the old dummy fallback
    let anon_key = transport::get_nextgen_supabase_anon_key().expect("NATIVE_NEXTGEN_ANON_KEY_CONFIGURED");
    assert!(!anon_key.is_empty(), "Anon key must not be empty");
    assert_ne!(
        anon_key,
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.dummy_nextgen_anon_key_for_transport_contract",
        "DUMMY_NATIVE_ANON_KEY_RUNTIME_FALLBACK: Dummy key must be absent from runtime fallback"
    );
}

// ============================================================================
// 19. TASK 3G.2-01: NATIVE SEMANTIC READ QUERIES
// ============================================================================

#[test]
fn test_semantic_read_get_tables_with_sessions_and_occupancy_derivation() {
    let conn = setup_in_memory_db();

    // Seed tables
    conn.execute(
        "INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
         VALUES ('tbl-01', 'T01', 'Main Floor', 4, 1, '2026-10-12T10:00:00Z'),
                ('tbl-02', 'T02', 'Main Floor', 2, 1, '2026-10-12T10:00:00Z'),
                ('tbl-03', 'T03', 'Balcony', 6, 1, '2026-10-12T10:00:00Z'),
                ('tbl-04', 'T04', 'Inactive Area', 4, 0, '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();

    // Seed sessions:
    // T01: open session -> OCCUPIED
    // T02: billed session -> BILLED
    // T03: closed session -> AVAILABLE (no active session)
    conn.execute(
        "INSERT INTO table_sessions (id, table_id, current_order_id, guest_count, session_status, opened_at, closed_at)
         VALUES ('sess-01', 'tbl-01', 'ord-01', 3, 'open', '2026-10-12T11:00:00Z', NULL),
                ('sess-02', 'tbl-02', 'ord-02', 2, 'billed', '2026-10-12T11:30:00Z', NULL),
                ('sess-03', 'tbl-03', 'ord-old', 4, 'closed', '2026-10-12T09:00:00Z', '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();

    let res = execute_query(&conn, NativeQuery::GetTablesWithSessions).expect("GET_TABLES_WITH_SESSIONS_PASS");
    let tables: Vec<TableWithActiveSession> = serde_json::from_value(res).unwrap();

    // Table T04 (is_active = 0) must be excluded
    assert_eq!(tables.len(), 3, "Only active pos_tables must be returned");

    // Table T01 -> OCCUPIED derivation
    let t1 = tables.iter().find(|t| t.table.id == "tbl-01").expect("T01 found");
    assert!(t1.active_session.is_some(), "T01 must have active session");
    assert_eq!(t1.active_session.as_ref().unwrap().session_status, "open", "OCCUPIED_TABLE_DERIVATION_PASS");

    // Table T02 -> BILLED derivation
    let t2 = tables.iter().find(|t| t.table.id == "tbl-02").expect("T02 found");
    assert!(t2.active_session.is_some(), "T02 must have active session");
    assert_eq!(t2.active_session.as_ref().unwrap().session_status, "billed");

    // Table T03 -> AVAILABLE derivation
    let t3 = tables.iter().find(|t| t.table.id == "tbl-03").expect("T03 found");
    assert!(t3.active_session.is_none(), "AVAILABLE_TABLE_DERIVATION_PASS: Closed session must not be active");
}

#[test]
fn test_semantic_read_multiple_active_sessions_invariant_reject() {
    let conn = setup_in_memory_db();

    conn.execute(
        "INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
         VALUES ('tbl-conflict', 'T99', 'Main Floor', 4, 1, '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();

    // Construct invalid state: two active sessions for the same table
    conn.execute(
        "INSERT INTO table_sessions (id, table_id, guest_count, session_status, opened_at)
         VALUES ('sess-c1', 'tbl-conflict', 2, 'open', '2026-10-12T11:00:00Z'),
                ('sess-c2', 'tbl-conflict', 3, 'billed', '2026-10-12T11:15:00Z');",
        [],
    ).unwrap();

    let err = execute_query(&conn, NativeQuery::GetTablesWithSessions);
    assert!(err.is_err(), "Multiple active sessions must be rejected deterministically");
    let err_str = err.unwrap_err();
    assert!(
        err_str.contains("INVARIANT_VIOLATION"),
        "Error message must specify INVARIANT_VIOLATION: {}",
        err_str
    );
}

#[test]
fn test_semantic_read_get_catalog_uses_integer_paise() {
    let conn = Connection::open_in_memory().expect("open db");
    init_database(&conn).expect("init db");

    conn.execute(
        "INSERT INTO categories (id, name, slug, display_order, is_active, created_at, updated_at)
         VALUES ('cat-active', 'Pizzas', 'pizzas', 1, 1, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z'),
                ('cat-inactive', 'Old Items', 'old-items', 2, 0, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO products (id, category_id, name, base_price_paise, is_available, tax_rate, created_at, updated_at)
         VALUES ('prod-p1', 'cat-active', 'Margherita', 19900, 1, 5.0, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z'),
                ('prod-p2', 'cat-active', 'Unavailable Pizza', 24900, 0, 5.0, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z'),
                ('prod-p3', 'cat-inactive', 'Old Pizza', 15000, 1, 5.0, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO product_variants (id, product_id, variant_name, price_override_paise, is_available, created_at)
         VALUES ('var-v1', 'prod-p1', 'Medium', 24900, 1, '2026-10-12T10:00:00Z'),
                ('var-v2', 'prod-p1', 'Unavailable Variant', 29900, 0, '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();

    let res = execute_query(&conn, NativeQuery::GetCatalog).expect("GET_CATALOG_PASS");
    let catalog: PosCatalog = serde_json::from_value(res).unwrap();

    // 1. Categories
    assert_eq!(catalog.categories.len(), 1, "Only active categories returned");
    assert_eq!(catalog.categories[0].id, "cat-active");

    // 2. Products
    assert_eq!(catalog.products.len(), 1, "Only available products in active categories returned");
    let prod = &catalog.products[0];
    assert_eq!(prod.id, "prod-p1");
    assert_eq!(prod.base_price_paise, 19900, "CATALOG_USES_PAISE_PASS: Base price must be integer Paise");

    // 3. Variants
    assert_eq!(catalog.variants.len(), 1, "Only available variants returned");
    let variant = &catalog.variants[0];
    assert_eq!(variant.id, "var-v1");
    assert_eq!(variant.price_override_paise, Some(24900), "CATALOG_USES_PAISE_PASS: Price override must be integer Paise");
}

#[test]
fn test_semantic_read_get_active_order_for_table_and_invariants() {
    let conn = setup_in_memory_db();

    // Table 1: with active session + active order
    conn.execute(
        "INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
         VALUES ('tbl-order-1', 'T10', 'Main Floor', 4, 1, '2026-10-12T10:00:00Z'),
                ('tbl-empty-sess', 'T11', 'Main Floor', 4, 1, '2026-10-12T10:00:00Z'),
                ('tbl-no-sess', 'T12', 'Main Floor', 4, 1, '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO table_sessions (id, table_id, current_order_id, guest_count, session_status, opened_at)
         VALUES ('sess-act-1', 'tbl-order-1', 'ord-act-1', 2, 'open', '2026-10-12T11:00:00Z'),
                ('sess-empty-1', 'tbl-empty-sess', NULL, 3, 'open', '2026-10-12T11:05:00Z');",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO orders (id, display_number, channel, order_type, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
         VALUES ('ord-act-1', 'CB-T10-001', 'POS', 'DINE_IN', 'sess-act-1', 'kot_sent', 20000, 1000, 0, 0, 21000, '2026-10-12T11:10:00Z', '2026-10-12T11:10:00Z');",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
         VALUES ('oi-1', 'ord-act-1', 'prod-01', 'Default Product', 10000, 2, 5.0, 0, 20000, '2026-10-12T11:10:00Z');",
        [],
    ).unwrap();

    // 1. Table 1: populated active order
    let res = execute_query(&conn, NativeQuery::GetActiveOrderForTable {
        table_id: "tbl-order-1".to_string(),
    }).expect("GET_ACTIVE_ORDER_FOR_TABLE_PASS");

    let active: Option<ActiveTableOrderResult> = serde_json::from_value(res).unwrap();
    assert!(active.is_some(), "Active order must be returned");
    let act = active.unwrap();
    assert_eq!(act.session.id, "sess-act-1");
    assert_eq!(act.order.id, "ord-act-1");
    assert_eq!(act.order.grand_total_paise, 21000);
    assert_eq!(act.items.len(), 1);
    assert_eq!(act.items[0].product_name, "Default Product");

    // 2. Table with session but NO active order -> typed null result
    let res_empty = execute_query(&conn, NativeQuery::GetActiveOrderForTable {
        table_id: "tbl-empty-sess".to_string(),
    }).expect("NO_ACTIVE_ORDER_TYPED_RESULT_PASS");
    assert!(res_empty.is_null(), "NO_ACTIVE_ORDER_TYPED_RESULT_PASS: Table session with no order returns null");

    // 3. Table with NO active session -> typed null result
    let res_no_sess = execute_query(&conn, NativeQuery::GetActiveOrderForTable {
        table_id: "tbl-no-sess".to_string(),
    }).expect("NO_ACTIVE_ORDER_TYPED_RESULT_PASS");
    assert!(res_no_sess.is_null(), "Table with no session returns null");

    // 4. Invariant violation: session with multiple active orders
    conn.execute(
        "INSERT INTO orders (id, display_number, channel, order_type, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
         VALUES ('ord-act-duplicate', 'CB-T10-002', 'POS', 'DINE_IN', 'sess-act-1', 'draft', 10000, 500, 0, 0, 10500, '2026-10-12T11:15:00Z', '2026-10-12T11:15:00Z');",
        [],
    ).unwrap();

    let err_mult = execute_query(&conn, NativeQuery::GetActiveOrderForTable {
        table_id: "tbl-order-1".to_string(),
    });
    assert!(err_mult.is_err(), "MULTIPLE_ACTIVE_ORDER_INVARIANT_REJECT_PASS: Multiple active orders must error");
    let err_msg = err_mult.unwrap_err();
    assert!(err_msg.contains("INVARIANT_VIOLATION"), "Must reject with INVARIANT_VIOLATION");
}

#[test]
fn test_semantic_read_get_bill_for_order_and_not_found() {
    let conn = setup_in_memory_db();

    conn.execute(
        "INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
         VALUES ('ord-b1', 'POS', 'DINE_IN', 'billed', 10000, 500, 0, 0, 10500, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z'),
                ('ord-b2', 'POS', 'DINE_IN', 'draft', 5000, 250, 0, 0, 5250, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO bills (id, order_id, bill_number, subtotal_paise, cgst_total_paise, sgst_total_paise, discount_total_paise, grand_total_paise, payment_status, finalized_at)
         VALUES ('bill-01', 'ord-b1', 'CB-T01-000001', 10000, 250, 250, 0, 10500, 'unpaid', '2026-10-12T10:30:00Z');",
        [],
    ).unwrap();

    // 1. Existing bill
    let res = execute_query(&conn, NativeQuery::GetBillForOrder {
        order_id: "ord-b1".to_string(),
    }).expect("GET_BILL_FOR_ORDER_PASS");

    let bill: Option<BillDomain> = serde_json::from_value(res).unwrap();
    assert!(bill.is_some(), "Existing bill must be returned");
    let b = bill.unwrap();
    assert_eq!(b.bill_number, "CB-T01-000001");
    assert_eq!(b.grand_total_paise, 10500);
    assert_eq!(b.payment_status, "unpaid");

    // 2. Order without bill -> typed null
    let res_none = execute_query(&conn, NativeQuery::GetBillForOrder {
        order_id: "ord-b2".to_string(),
    }).expect("NO_BILL_TYPED_RESULT_PASS");
    assert!(res_none.is_null(), "NO_BILL_TYPED_RESULT_PASS: Missing bill returns null");
}

#[test]
fn test_raw_sql_crosses_ipc_rejected() {
    // RAW_SQL_CROSSES_IPC = NO
    // Verify Serde strictly rejects any raw SQL query variant
    let raw_query_json = serde_json::json!({
        "type": "RawSql",
        "payload": {
            "sql": "SELECT * FROM orders;"
        }
    });

    let res: Result<NativeQuery, _> = serde_json::from_value(raw_query_json);
    assert!(res.is_err(), "RAW_SQL_CROSSES_IPC=NO: RawSql must not deserialize as NativeQuery");

    let query_sql_json = serde_json::json!({
        "type": "QuerySql",
        "payload": {
            "query": "SELECT * FROM pos_tables;"
        }
    });

    let res2: Result<NativeQuery, _> = serde_json::from_value(query_sql_json);
    assert!(res2.is_err(), "RAW_SQL_CROSSES_IPC=NO: QuerySql must not deserialize as NativeQuery");
}

// ============================================================================
// 12. TABLE SESSION & ORDER STATUS LOCAL LIFECYCLE (TASK 3G.2-02)
// ============================================================================

#[test]
fn test_lifecycle_table_session_flow_and_occupancy_derivation() {
    let mut conn = setup_in_memory_db();
    create_test_device_config(&mut conn, "T01");

    conn.execute(
        "INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
         VALUES ('tbl-01', 'T-01', 'Indoor', 4, 1, '2026-10-12T10:00:00Z'),
                ('tbl-inact', 'T-99', 'Patio', 4, 0, '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();

    // 1. OPEN_TABLE_SESSION_PASS
    let session = open_table_session(&mut conn, "tbl-01", 3).expect("OPEN_TABLE_SESSION_PASS");
    assert_eq!(session.table_id, "tbl-01");
    assert_eq!(session.guest_count, 3);
    assert_eq!(session.session_status, "open");
    assert!(session.closed_at.is_none());

    // Occupancy derives OCCUPIED
    let tables = get_tables_with_sessions(&conn).unwrap();
    let t1 = tables.iter().find(|t| t.table.id == "tbl-01").unwrap();
    assert!(t1.active_session.is_some());

    // 2. OPEN_TABLE_ALREADY_OCCUPIED_REJECT_PASS
    let err_dup = open_table_session(&mut conn, "tbl-01", 2).unwrap_err();
    assert!(err_dup.contains("TABLE_ALREADY_OCCUPIED"));

    // 3. OPEN_INACTIVE_TABLE_REJECT_PASS & INVALID_GUEST_COUNT
    let err_inact = open_table_session(&mut conn, "tbl-inact", 2).unwrap_err();
    assert!(err_inact.contains("TABLE_INACTIVE"));

    let err_gc = open_table_session(&mut conn, "tbl-01", 0).unwrap_err();
    assert!(err_gc.contains("INVALID_GUEST_COUNT"));

    // Create Order with pending status
    let order = OrderDomain {
        id: "ord-lc-1".to_string(),
        display_number: Some("CB-T01-000001".to_string()),
        channel: "POS".to_string(),
        order_type: "DINE_IN".to_string(),
        customer_id: None,
        table_session_id: Some(session.id.clone()),
        status: "pending".to_string(),
        subtotal_paise: 10000,
        tax_total_paise: 500,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 10500,
        device_id: None,
        version: Some(1),
        created_at: "2026-10-12T10:05:00Z".to_string(),
        updated_at: "2026-10-12T10:05:00Z".to_string(),
    };
    save_order_aggregate(&mut conn, order, vec![]).unwrap();

    // 4. KOT_AND_ORDER_STATUS_ATOMIC_PASS
    let kot = PosKotDomain {
        id: "kot-lc-1".to_string(),
        order_id: "ord-lc-1".to_string(),
        kot_number: 1,
        device_id: None,
        status: "printed".to_string(),
        printed_at: "2026-10-12T10:06:00Z".to_string(),
    };
    save_kot_aggregate(&mut conn, kot, vec![]).expect("save kot");

    let status_kot: String = conn.query_row("SELECT status FROM orders WHERE id = 'ord-lc-1';", [], |r| r.get(0)).unwrap();
    assert_eq!(status_kot, "kot_sent", "KOT dispatch advances order to kot_sent");

    // 5. BILL_AND_ORDER_STATUS_ATOMIC_PASS
    let bill = BillDomain {
        id: "bill-lc-1".to_string(),
        order_id: "ord-lc-1".to_string(),
        bill_number: "PENDING".to_string(),
        subtotal_paise: 10000,
        cgst_total_paise: 250,
        sgst_total_paise: 250,
        discount_total_paise: 0,
        grand_total_paise: 10500,
        payment_status: "unpaid".to_string(),
        finalized_at: "2026-10-12T10:10:00Z".to_string(),
        device_id: None,
    };
    save_bill_with_sequence(&mut conn, bill).expect("save bill");

    let status_bill: String = conn.query_row("SELECT status FROM orders WHERE id = 'ord-lc-1';", [], |r| r.get(0)).unwrap();
    assert_eq!(status_bill, "billed", "Bill finalization advances order to billed");

    let sess_status: String = conn.query_row("SELECT session_status FROM table_sessions WHERE id = ?;", params![session.id], |r| r.get(0)).unwrap();
    assert_eq!(sess_status, "billed", "Bill finalization advances session to billed");

    // 6. CLOSE_UNSETTLED_ORDER_REJECT_PASS (attempting close while order is billed)
    let err_unsettled = close_table_session(&mut conn, &session.id, "ord-lc-1").unwrap_err();
    assert!(err_unsettled.contains("ORDER_NOT_SETTLED"));

    // 7. PAYMENT_AND_ORDER_STATUS_ATOMIC_PASS
    let payment = PaymentDomain {
        id: "pay-lc-1".to_string(),
        bill_id: "bill-lc-1".to_string(),
        order_id: "ord-lc-1".to_string(),
        payment_mode: "UPI".to_string(),
        amount_paid_paise: 10500,
        confirmed_by_staff_id: None,
        confirmed_at: "2026-10-12T10:15:00Z".to_string(),
        notes: None,
    };
    let updated_bill = BillDomain {
        id: "bill-lc-1".to_string(),
        order_id: "ord-lc-1".to_string(),
        bill_number: "CB-T01-000001".to_string(),
        subtotal_paise: 10000,
        cgst_total_paise: 250,
        sgst_total_paise: 250,
        discount_total_paise: 0,
        grand_total_paise: 10500,
        payment_status: "paid".to_string(),
        finalized_at: "2026-10-12T10:10:00Z".to_string(),
        device_id: None,
    };
    save_payment(&mut conn, payment, updated_bill).expect("save payment");

    let status_settled: String = conn.query_row("SELECT status FROM orders WHERE id = 'ord-lc-1';", [], |r| r.get(0)).unwrap();
    assert_eq!(status_settled, "settled", "Payment settlement advances order to settled");

    // 8. CLOSE_TABLE_SESSION_PASS & CLOSE_SESSION_RELEASES_TABLE_PASS
    close_table_session(&mut conn, &session.id, "ord-lc-1").expect("CLOSE_TABLE_SESSION_PASS");

    let (sess_closed, closed_at): (String, Option<String>) = conn.query_row(
        "SELECT session_status, closed_at FROM table_sessions WHERE id = ?;",
        params![session.id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    ).unwrap();
    assert_eq!(sess_closed, "closed");
    assert!(closed_at.is_some());

    let ord_closed: String = conn.query_row("SELECT status FROM orders WHERE id = 'ord-lc-1';", [], |r| r.get(0)).unwrap();
    assert_eq!(ord_closed, "closed");

    // Table is now released -> AVAILABLE
    let tables_after = get_tables_with_sessions(&conn).unwrap();
    let t1_after = tables_after.iter().find(|t| t.table.id == "tbl-01").unwrap();
    assert!(t1_after.active_session.is_none(), "Table must be AVAILABLE after session close");
}

#[test]
fn test_lifecycle_ipc_mutation_dispatch_and_regression_guards() {
    let mut conn = setup_in_memory_db();
    create_test_device_config(&mut conn, "T01");

    conn.execute(
        "INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
         VALUES ('tbl-ipc', 'T-IPC', 'Indoor', 4, 1, '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();

    // IPC Mutation: OpenTableSession
    let res = execute_mutation(&mut conn, NativeMutation::OpenTableSession {
        table_id: "tbl-ipc".to_string(),
        guest_count: 2,
    }).expect("OpenTableSession IPC");

    let sess: TableSessionDomain = serde_json::from_value(res).unwrap();
    assert_eq!(sess.table_id, "tbl-ipc");
    assert_eq!(sess.session_status, "open");

    // Order status regression: cancelled order cannot advance to KOT, Bill, or Payment
    conn.execute(
        "INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
         VALUES ('ord-canc', 'POS', 'DINE_IN', 'cancelled', 5000, 250, 0, 0, 5250, 'now', 'now');",
        [],
    ).unwrap();

    let kot_err = save_kot_aggregate(&mut conn, PosKotDomain {
        id: "kot-canc".to_string(),
        order_id: "ord-canc".to_string(),
        kot_number: 1,
        device_id: None,
        status: "printed".to_string(),
        printed_at: "now".to_string(),
    }, vec![]).unwrap_err();
    assert!(kot_err.contains("ORDER_STATUS_INVALID"));

    let bill_err = save_bill_with_sequence(&mut conn, BillDomain {
        id: "bill-canc".to_string(),
        order_id: "ord-canc".to_string(),
        bill_number: "PENDING".to_string(),
        subtotal_paise: 5000,
        cgst_total_paise: 125,
        sgst_total_paise: 125,
        discount_total_paise: 0,
        grand_total_paise: 5250,
        payment_status: "unpaid".to_string(),
        finalized_at: "now".to_string(),
        device_id: None,
    }).unwrap_err();
    assert!(bill_err.contains("ORDER_STATUS_INVALID"));
}

#[test]
fn test_initial_order_sets_current_order_id_and_rejects_second_active_order() {
    let mut conn = setup_in_memory_db();
    conn.execute(
        "INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
         VALUES ('tbl-01', 'T-01', 'Indoor', 4, 1, '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();
    let session = open_table_session(&mut conn, "tbl-01", 2).expect("open session");

    // 1. Initial Order with version 1
    let order = OrderDomain {
        id: "ord-v1-init".to_string(),
        display_number: Some("1".to_string()),
        channel: "POS".to_string(),
        order_type: "DINE_IN".to_string(),
        customer_id: None,
        table_session_id: Some(session.id.clone()),
        status: "draft".to_string(),
        subtotal_paise: 10000,
        tax_total_paise: 500,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 10500,
        device_id: None,
        version: Some(1),
        created_at: "2026-10-12T12:00:00Z".to_string(),
        updated_at: "2026-10-12T12:00:00Z".to_string(),
    };

    let item = OrderItemDomain {
        id: "item-v1-1".to_string(),
        order_id: "ord-v1-init".to_string(),
        product_id: "prod-01".to_string(),
        variant_id: None,
        product_name: "Default Product".to_string(),
        unit_price_paise: 10000,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount_paise: 0,
        line_total_paise: 10000,
        notes: None,
        created_at: "2026-10-12T12:00:00Z".to_string(),
    };

    let save_res = save_order_aggregate(&mut conn, order, vec![item]).expect("save initial order");
    assert_eq!(save_res.order.version, Some(1));

    // Verify table_sessions.current_order_id is set atomically
    let current_order_id: Option<String> = conn
        .query_row(
            "SELECT current_order_id FROM table_sessions WHERE id = ?;",
            params![session.id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(current_order_id, Some("ord-v1-init".to_string()));

    // 2. Reject second different active order for same session
    let second_order = OrderDomain {
        id: "ord-v1-second".to_string(),
        display_number: Some("2".to_string()),
        channel: "POS".to_string(),
        order_type: "DINE_IN".to_string(),
        customer_id: None,
        table_session_id: Some(session.id.clone()),
        status: "draft".to_string(),
        subtotal_paise: 5000,
        tax_total_paise: 250,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 5250,
        device_id: None,
        version: Some(1),
        created_at: "2026-10-12T12:05:00Z".to_string(),
        updated_at: "2026-10-12T12:05:00Z".to_string(),
    };

    let second_err = save_order_aggregate(&mut conn, second_order, vec![]).unwrap_err();
    assert!(second_err.contains("ACTIVE_ORDER_EXISTS"));
}

#[test]
fn test_draft_order_replacement_and_version_invariants() {
    let mut conn = setup_in_memory_db();
    conn.execute(
        "INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
         VALUES ('tbl-01', 'T-01', 'Indoor', 4, 1, '2026-10-12T10:00:00Z');",
        [],
    ).unwrap();
    let session = open_table_session(&mut conn, "tbl-01", 2).expect("open session");

    // 1. Initial Order
    let initial_order = OrderDomain {
        id: "ord-draft-rep".to_string(),
        display_number: Some("1".to_string()),
        channel: "POS".to_string(),
        order_type: "DINE_IN".to_string(),
        customer_id: None,
        table_session_id: Some(session.id.clone()),
        status: "draft".to_string(),
        subtotal_paise: 10000,
        tax_total_paise: 500,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 10500,
        device_id: None,
        version: Some(1),
        created_at: "2026-10-12T12:00:00Z".to_string(),
        updated_at: "2026-10-12T12:00:00Z".to_string(),
    };

    let item1 = OrderItemDomain {
        id: "item-rep-1".to_string(),
        order_id: "ord-draft-rep".to_string(),
        product_id: "prod-01".to_string(),
        variant_id: None,
        product_name: "Default Product".to_string(),
        unit_price_paise: 10000,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount_paise: 0,
        line_total_paise: 10000,
        notes: None,
        created_at: "2026-10-12T12:00:00Z".to_string(),
    };

    save_order_aggregate(&mut conn, initial_order.clone(), vec![item1]).expect("save initial");

    // 2. Reject version gap (version 3 when current is 1)
    let mut gap_order = initial_order.clone();
    gap_order.version = Some(3);
    let gap_err = replace_draft_order_aggregate(
        &mut conn,
        gap_order,
        vec![OrderItemDomain {
            id: "item-rep-gap".to_string(),
            order_id: "ord-draft-rep".to_string(),
            product_id: "prod-01".to_string(),
            variant_id: None,
            product_name: "Default Product".to_string(),
            unit_price_paise: 10000,
            quantity: 1,
            tax_rate: 5.0,
            discount_amount_paise: 0,
            line_total_paise: 10000,
            notes: None,
            created_at: "2026-10-12T12:01:00Z".to_string(),
        }],
    ).unwrap_err();
    assert!(gap_err.contains("VERSION_GAP"));

    // 3. Reject stale/same version (version 1 when current is 1)
    let mut stale_order = initial_order.clone();
    stale_order.version = Some(1);
    let stale_err = replace_draft_order_aggregate(
        &mut conn,
        stale_order,
        vec![OrderItemDomain {
            id: "item-rep-stale".to_string(),
            order_id: "ord-draft-rep".to_string(),
            product_id: "prod-01".to_string(),
            variant_id: None,
            product_name: "Default Product".to_string(),
            unit_price_paise: 10000,
            quantity: 1,
            tax_rate: 5.0,
            discount_amount_paise: 0,
            line_total_paise: 10000,
            notes: None,
            created_at: "2026-10-12T12:01:00Z".to_string(),
        }],
    ).unwrap_err();
    assert!(stale_err.contains("STALE_VERSION"));

    // 4. Valid Replacement: 1 -> 2
    let mut v2_order = initial_order.clone();
    v2_order.version = Some(2);
    v2_order.subtotal_paise = 20000;
    v2_order.tax_total_paise = 1000;
    v2_order.grand_total_paise = 21000;
    v2_order.updated_at = "2026-10-12T12:02:00Z".to_string();

    let replacement_item = OrderItemDomain {
        id: "item-rep-v2".to_string(),
        order_id: "ord-draft-rep".to_string(),
        product_id: "prod-01".to_string(),
        variant_id: None,
        product_name: "Default Product".to_string(),
        unit_price_paise: 10000,
        quantity: 2,
        tax_rate: 5.0,
        discount_amount_paise: 0,
        line_total_paise: 20000,
        notes: Some("More sauce".to_string()),
        created_at: "2026-10-12T12:02:00Z".to_string(),
    };

    let rep_res = replace_draft_order_aggregate(
        &mut conn,
        v2_order,
        vec![replacement_item],
    ).expect("replace draft order");

    assert_eq!(rep_res.order.version, Some(2));
    assert_eq!(rep_res.outbox_entries.len(), 1);
    assert_eq!(rep_res.outbox_entries[0].operation, "UPDATE");

    // Verify items in DB: old item removed, new item present
    let items_in_db: Vec<String> = {
        let mut stmt = conn.prepare("SELECT id FROM order_items WHERE order_id = ?;").unwrap();
        stmt.query_map(params!["ord-draft-rep"], |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect()
    };
    assert_eq!(items_in_db, vec!["item-rep-v2".to_string()]);

    // 5. Post-KOT draft replace rejected
    let kot = PosKotDomain {
        id: "kot-rep-1".to_string(),
        order_id: "ord-draft-rep".to_string(),
        kot_number: 1,
        device_id: None,
        status: "printed".to_string(),
        printed_at: "2026-10-12T12:03:00Z".to_string(),
    };
    save_kot_aggregate(&mut conn, kot, vec![]).expect("save kot");

    let mut v3_order = rep_res.order.clone();
    v3_order.version = Some(3);
    let post_kot_err = replace_draft_order_aggregate(
        &mut conn,
        v3_order,
        vec![OrderItemDomain {
            id: "item-v3".to_string(),
            order_id: "ord-draft-rep".to_string(),
            product_id: "prod-01".to_string(),
            variant_id: None,
            product_name: "Default Product".to_string(),
            unit_price_paise: 10000,
            quantity: 1,
            tax_rate: 5.0,
            discount_amount_paise: 0,
            line_total_paise: 10000,
            notes: None,
            created_at: "2026-10-12T12:04:00Z".to_string(),
        }],
    ).unwrap_err();
    assert!(post_kot_err.contains("KOT_ALREADY_SENT") || post_kot_err.contains("ORDER_NOT_EDITABLE"));
}

// ============================================================================
// TASK 3G.2-08A.2: RUST ADDITIONAL-KOT IDEMPOTENCY & PENDING-OUTBOX PARITY
// ============================================================================

#[test]
fn test_rust_additional_kot_idempotency_suite() {
    let mut conn = setup_in_memory_db();
    let order_id = "ord-rust-idem-01";

    // Setup initial kot_sent order
    let initial_order = OrderDomain {
        id: order_id.to_string(),
        display_number: Some("ORD-R01".to_string()),
        channel: "POS".to_string(),
        order_type: "DINE_IN".to_string(),
        customer_id: None,
        table_session_id: None,
        status: "draft".to_string(),
        subtotal_paise: 10000,
        tax_total_paise: 500,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 10500,
        device_id: None,
        version: Some(1),
        created_at: "2026-10-12T12:00:00Z".to_string(),
        updated_at: "2026-10-12T12:00:00Z".to_string(),
    };
    let initial_item = OrderItemDomain {
        id: "item-init-01".to_string(),
        order_id: order_id.to_string(),
        product_id: "prod-01".to_string(),
        variant_id: None,
        product_name: "Default Product".to_string(),
        unit_price_paise: 10000,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount_paise: 0,
        line_total_paise: 10000,
        notes: None,
        created_at: "2026-10-12T12:00:00Z".to_string(),
    };
    save_order_aggregate(&mut conn, initial_order, vec![initial_item]).expect("save order");

    let kot1 = PosKotDomain {
        id: "kot-1-ord-rust-idem".to_string(),
        order_id: order_id.to_string(),
        kot_number: 1,
        device_id: None,
        status: "printed".to_string(),
        printed_at: "2026-10-12T12:01:00Z".to_string(),
    };
    let kitem1 = KotItemDomain {
        id: "kitem-1-ord-rust-idem".to_string(),
        kot_id: "kot-1-ord-rust-idem".to_string(),
        order_item_id: Some("item-init-01".to_string()),
        product_id: "prod-01".to_string(),
        variant_id: None,
        product_name: "Default Product".to_string(),
        quantity: 1,
        notes: None,
    };
    save_kot_aggregate(&mut conn, kot1, vec![kitem1]).expect("save kot 1");

    // Fixture for additional KOT #2
    let new_item = OrderItemDomain {
        id: "item-add-rust-02".to_string(),
        order_id: order_id.to_string(),
        product_id: "prod-inj".to_string(),
        variant_id: None,
        product_name: "Inj Product".to_string(),
        unit_price_paise: 5000,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount_paise: 0,
        line_total_paise: 5000,
        notes: None,
        created_at: "2026-10-12T12:02:00Z".to_string(),
    };
    let cumulative_order = OrderDomain {
        id: order_id.to_string(),
        display_number: Some("ORD-R01".to_string()),
        channel: "POS".to_string(),
        order_type: "DINE_IN".to_string(),
        customer_id: None,
        table_session_id: None,
        status: "kot_sent".to_string(),
        subtotal_paise: 15000,
        tax_total_paise: 750,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 15750,
        device_id: None,
        version: Some(1),
        created_at: "2026-10-12T12:00:00Z".to_string(),
        updated_at: "2026-10-12T12:02:00Z".to_string(),
    };
    let kot2 = PosKotDomain {
        id: "kot-2-ord-rust-idem".to_string(),
        order_id: order_id.to_string(),
        kot_number: 2,
        device_id: None,
        status: "printed".to_string(),
        printed_at: "2026-10-12T12:02:00Z".to_string(),
    };
    let kitem2 = KotItemDomain {
        id: "kitem-2-ord-rust-idem".to_string(),
        kot_id: "kot-2-ord-rust-idem".to_string(),
        order_item_id: Some("item-add-rust-02".to_string()),
        product_id: "prod-inj".to_string(),
        variant_id: None,
        product_name: "Inj Product".to_string(),
        quantity: 1,
        notes: None,
    };

    // 1. Initial append
    let res1 = append_order_items_and_kot(
        &mut conn,
        cumulative_order.clone(),
        vec![new_item.clone()],
        kot2.clone(),
        vec![kitem2.clone()],
    ).expect("initial append");
    assert_eq!(res1.kot.kot_number, 2);
    assert_eq!(res1.outbox_entries.len(), 1);

    // 2. RUST_IDENTICAL_RETRY_PASS
    let res2 = append_order_items_and_kot(
        &mut conn,
        cumulative_order.clone(),
        vec![new_item.clone()],
        kot2.clone(),
        vec![kitem2.clone()],
    ).expect("RUST_IDENTICAL_RETRY_PASS");
    assert_eq!(res2.kot.kot_number, 2);
    assert_eq!(res2.outbox_entries.len(), 0, "No duplicate outbox on retry");

    // 3. RUST_CHANGED_ORDER_TOTAL_REJECT_PASS
    let mut altered_order = cumulative_order.clone();
    altered_order.grand_total_paise = 99999;
    let err_total = append_order_items_and_kot(
        &mut conn,
        altered_order,
        vec![new_item.clone()],
        kot2.clone(),
        vec![kitem2.clone()],
    ).unwrap_err();
    assert!(err_total.contains("IDEMPOTENCY_CONFLICT"), "Must reject altered order total");
    assert!(err_total.contains("financial totals mismatch"));

    // 4. RUST_CHANGED_ORDER_ITEM_REJECT_PASS
    let mut altered_item = new_item.clone();
    altered_item.quantity = 5;
    let err_item = append_order_items_and_kot(
        &mut conn,
        cumulative_order.clone(),
        vec![altered_item],
        kot2.clone(),
        vec![kitem2.clone()],
    ).unwrap_err();
    assert!(err_item.contains("IDEMPOTENCY_CONFLICT"), "Must reject altered order item");
    assert!(err_item.contains("attributes mismatched"));

    // 5. RUST_CHANGED_KOT_NUMBER_REJECT_PASS
    let mut altered_kot = kot2.clone();
    altered_kot.kot_number = 99;
    let err_kot_num = append_order_items_and_kot(
        &mut conn,
        cumulative_order.clone(),
        vec![new_item.clone()],
        altered_kot,
        vec![kitem2.clone()],
    ).unwrap_err();
    assert!(err_kot_num.contains("IDEMPOTENCY_CONFLICT"), "Must reject altered kot_number");
    assert!(err_kot_num.contains("kot_number 2, retry payload has 99"));

    // 6. RUST_CHANGED_KOT_ITEM_REJECT_PASS
    let mut altered_kitem = kitem2.clone();
    altered_kitem.quantity = 9;
    let err_kitem = append_order_items_and_kot(
        &mut conn,
        cumulative_order.clone(),
        vec![new_item.clone()],
        kot2.clone(),
        vec![altered_kitem],
    ).unwrap_err();
    assert!(err_kitem.contains("IDEMPOTENCY_CONFLICT"), "Must reject altered kot item");
    assert!(err_kitem.contains("mismatched"));

    // 7. RUST_ARRAY_REORDER_PASS
    let multi_order_id = "ord-rust-multi-01";
    let initial_multi = OrderDomain {
        id: multi_order_id.to_string(),
        display_number: Some("ORD-M01".to_string()),
        channel: "POS".to_string(),
        order_type: "DINE_IN".to_string(),
        customer_id: None,
        table_session_id: None,
        status: "draft".to_string(),
        subtotal_paise: 10000,
        tax_total_paise: 500,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 10500,
        device_id: None,
        version: Some(1),
        created_at: "2026-10-12T12:00:00Z".to_string(),
        updated_at: "2026-10-12T12:00:00Z".to_string(),
    };
    save_order_aggregate(
        &mut conn,
        initial_multi,
        vec![OrderItemDomain {
            id: "item-m-0".to_string(),
            order_id: multi_order_id.to_string(),
            product_id: "prod-01".to_string(),
            variant_id: None,
            product_name: "Default Product".to_string(),
            unit_price_paise: 10000,
            quantity: 1,
            tax_rate: 5.0,
            discount_amount_paise: 0,
            line_total_paise: 10000,
            notes: None,
            created_at: "2026-10-12T12:00:00Z".to_string(),
        }],
    ).expect("save multi order");
    save_kot_aggregate(
        &mut conn,
        PosKotDomain {
            id: "kot-m-1".to_string(),
            order_id: multi_order_id.to_string(),
            kot_number: 1,
            device_id: None,
            status: "printed".to_string(),
            printed_at: "2026-10-12T12:01:00Z".to_string(),
        },
        vec![KotItemDomain {
            id: "kitem-m-1".to_string(),
            kot_id: "kot-m-1".to_string(),
            order_item_id: Some("item-m-0".to_string()),
            product_id: "prod-01".to_string(),
            variant_id: None,
            product_name: "Default Product".to_string(),
            quantity: 1,
            notes: None,
        }],
    ).expect("save multi kot 1");

    let item_a = OrderItemDomain {
        id: "item-m-a".to_string(),
        order_id: multi_order_id.to_string(),
        product_id: "prod-01".to_string(),
        variant_id: None,
        product_name: "Default Product".to_string(),
        unit_price_paise: 10000,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount_paise: 0,
        line_total_paise: 10000,
        notes: None,
        created_at: "2026-10-12T12:02:00Z".to_string(),
    };
    let item_b = OrderItemDomain {
        id: "item-m-b".to_string(),
        order_id: multi_order_id.to_string(),
        product_id: "prod-inj".to_string(),
        variant_id: None,
        product_name: "Inj Product".to_string(),
        unit_price_paise: 5000,
        quantity: 1,
        tax_rate: 5.0,
        discount_amount_paise: 0,
        line_total_paise: 5000,
        notes: None,
        created_at: "2026-10-12T12:02:00Z".to_string(),
    };
    let multi_cumul_order = OrderDomain {
        id: multi_order_id.to_string(),
        display_number: Some("ORD-M01".to_string()),
        channel: "POS".to_string(),
        order_type: "DINE_IN".to_string(),
        customer_id: None,
        table_session_id: None,
        status: "kot_sent".to_string(),
        subtotal_paise: 25000,
        tax_total_paise: 1250,
        discount_total_paise: 0,
        delivery_charge_paise: 0,
        grand_total_paise: 26250,
        device_id: None,
        version: Some(1),
        created_at: "2026-10-12T12:00:00Z".to_string(),
        updated_at: "2026-10-12T12:02:00Z".to_string(),
    };
    let kot_m2 = PosKotDomain {
        id: "kot-m-2".to_string(),
        order_id: multi_order_id.to_string(),
        kot_number: 2,
        device_id: None,
        status: "printed".to_string(),
        printed_at: "2026-10-12T12:02:00Z".to_string(),
    };
    let kitem_a = KotItemDomain {
        id: "kitem-m-a".to_string(),
        kot_id: "kot-m-2".to_string(),
        order_item_id: Some("item-m-a".to_string()),
        product_id: "prod-01".to_string(),
        variant_id: None,
        product_name: "Default Product".to_string(),
        quantity: 1,
        notes: None,
    };
    let kitem_b = KotItemDomain {
        id: "kitem-m-b".to_string(),
        kot_id: "kot-m-2".to_string(),
        order_item_id: Some("item-m-b".to_string()),
        product_id: "prod-inj".to_string(),
        variant_id: None,
        product_name: "Inj Product".to_string(),
        quantity: 1,
        notes: None,
    };

    // Initial with order [A, B]
    append_order_items_and_kot(
        &mut conn,
        multi_cumul_order.clone(),
        vec![item_a.clone(), item_b.clone()],
        kot_m2.clone(),
        vec![kitem_a.clone(), kitem_b.clone()],
    ).expect("initial multi append");

    // Retry with reverse order [B, A] -> must succeed cleanly
    let retry_reordered = append_order_items_and_kot(
        &mut conn,
        multi_cumul_order,
        vec![item_b, item_a],
        kot_m2,
        vec![kitem_b, kitem_a],
    ).expect("RUST_ARRAY_REORDER_PASS");
    assert_eq!(retry_reordered.kot.kot_number, 2);
    assert_eq!(retry_reordered.outbox_entries.len(), 0);
}

#[test]
fn test_rust_pending_outbox_suite() {
    let mut conn = setup_in_memory_db();

    // 1. RUST_PENDING_DIRECT_ENTITY_MATCH_PASS
    conn.execute(
        "INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at)
         VALUES ('outbox-1', 'orders', 'direct-entity-uuid-01', 'INSERT', '{}', '2026-10-12T12:00:00Z');",
        [],
    ).unwrap();
    assert!(
        has_pending_outbox_record(&conn, "direct-entity-uuid-01").unwrap(),
        "RUST_PENDING_DIRECT_ENTITY_MATCH_PASS"
    );

    // 2. RUST_PENDING_ADDITIONAL_KOT_PARENT_ORDER_MATCH_PASS
    let kot_payload = serde_json::json!({
        "kot": {
            "id": "kot-agg-02",
            "order_id": "parent-order-uuid-99",
            "kot_number": 2
        },
        "items": [],
        "orderItems": [],
        "order": {
            "id": "parent-order-uuid-99",
            "grand_total_paise": 20000
        }
    });
    conn.execute(
        "INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at)
         VALUES ('outbox-2', 'pos_kots', 'kot-agg-02', 'INSERT', ?1, '2026-10-12T12:05:00Z');",
        params![kot_payload.to_string()],
    ).unwrap();

    assert!(
        has_pending_outbox_record(&conn, "parent-order-uuid-99").unwrap(),
        "RUST_PENDING_ADDITIONAL_KOT_PARENT_ORDER_MATCH_PASS"
    );

    // 3. RUST_PENDING_PAYLOAD_ORDER_ID_MATCH_PASS
    let order_payload_only = serde_json::json!({
        "order": {
            "id": "order-only-uuid-55"
        }
    });
    conn.execute(
        "INSERT INTO sync_outbox (id, entity_type, entity_id, operation, payload_json, created_at)
         VALUES ('outbox-3', 'custom_aggregate', 'agg-55', 'INSERT', ?1, '2026-10-12T12:06:00Z');",
        params![order_payload_only.to_string()],
    ).unwrap();
    assert!(
        has_pending_outbox_record(&conn, "order-only-uuid-55").unwrap(),
        "RUST_PENDING_PAYLOAD_ORDER_ID_MATCH_PASS"
    );

    // 4. RUST_UNRELATED_OUTBOX_NO_FALSE_POSITIVE_PASS
    assert!(
        !has_pending_outbox_record(&conn, "unrelated-order-uuid-none").unwrap(),
        "RUST_UNRELATED_OUTBOX_NO_FALSE_POSITIVE_PASS"
    );

    // 5. PENDING_ADDITIONAL_KOT_PULL_PRESERVED_PASS (Pull protected when additional KOT is pending in outbox)
    let pull_orders = ApplyPullBatchInput {
        dataset: PullDataset::Orders,
        rows: vec![serde_json::json!({
            "orders": [{
                "id": "parent-order-uuid-99",
                "channel": "POS",
                "order_type": "DINE_IN",
                "status": "closed",
                "subtotal": 500.0,
                "grand_total": 525.0,
                "created_at": "2026-10-12T12:00:00Z",
                "updated_at": "2026-10-12T12:10:00Z"
            }],
            "orderItems": []
        })],
        new_cursor: CursorWatermark {
            last_updated_at: "2026-10-12T12:10:00Z".to_string(),
            last_id: "parent-order-uuid-99".to_string(),
        },
    };

    let applied = apply_pull_batch(&mut conn, pull_orders).expect("apply pull batch");
    assert_eq!(applied, 0, "PENDING_ADDITIONAL_KOT_PULL_PRESERVED_PASS: order pull must be blocked when additional KOT is pending");
}

#[test]
fn test_semantic_read_get_kots_for_order() {
    let conn = setup_in_memory_db();

    let order_id = "ord-kot-read-1";

    // 1. GET_KOTS_FOR_ORDER_EMPTY_PASS
    let empty_kots = get_kots_for_order(&conn, "ord-non-existent").expect("query empty kots");
    assert!(empty_kots.is_empty(), "GET_KOTS_FOR_ORDER_EMPTY_PASS: non-existent order returns empty vector");

    // Insert order
    conn.execute(
        "INSERT INTO orders (id, display_number, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, version, created_at, updated_at)
         VALUES (?1, 'CB-01', 'POS', 'DINE_IN', 'kot_sent', 25000, 1250, 0, 0, 26250, 1, '2026-10-12T10:00:00Z', '2026-10-12T10:00:00Z');",
        params![order_id],
    ).unwrap();

    // Insert commercial order items
    let oitem_id1 = "oitem-1";
    let oitem_id2 = "oitem-2";
    conn.execute(
        "INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
         VALUES (?1, ?2, 'prod-01', 'Default Product', 10000, 2, 5.0, 0, 21000, '2026-10-12T10:00:00Z');",
        params![oitem_id1, order_id],
    ).unwrap();
    conn.execute(
        "INSERT INTO order_items (id, order_id, product_id, product_name, unit_price_paise, quantity, tax_rate, discount_amount_paise, line_total_paise, created_at)
         VALUES (?1, ?2, 'prod-01', 'Default Product', 10000, 1, 5.0, 0, 10500, '2026-10-12T10:00:00Z');",
        params![oitem_id2, order_id],
    ).unwrap();

    // Insert KOT 2 FIRST to verify deterministic ordering by kot_number ASC
    let kot_id2 = "kot-uuid-2";
    conn.execute(
        "INSERT INTO pos_kots (id, order_id, kot_number, device_id, status, printed_at)
         VALUES (?1, ?2, 2, 'dev-1', 'printed', '2026-10-12T10:15:00Z');",
        params![kot_id2, order_id],
    ).unwrap();

    let kot_item_id2 = "kitem-uuid-2";
    conn.execute(
        "INSERT INTO kot_items (id, kot_id, order_item_id, product_id, product_name, quantity, notes)
         VALUES (?1, ?2, ?3, 'prod-01', 'Default Product', 1, 'Extra cheese');",
        params![kot_item_id2, kot_id2, oitem_id2],
    ).unwrap();

    // 2. GET_KOTS_FOR_ORDER_SINGLE_KOT_PASS
    let single_kot = get_kots_for_order(&conn, order_id).expect("query single kot");
    assert_eq!(single_kot.len(), 1, "GET_KOTS_FOR_ORDER_SINGLE_KOT_PASS: returns exactly 1 KOT");
    assert_eq!(single_kot[0].kot.kot_number, 2);
    assert_eq!(single_kot[0].items.len(), 1);

    // Insert KOT 1 SECOND
    let kot_id1 = "kot-uuid-1";
    conn.execute(
        "INSERT INTO pos_kots (id, order_id, kot_number, device_id, status, printed_at)
         VALUES (?1, ?2, 1, 'dev-1', 'printed', '2026-10-12T10:05:00Z');",
        params![kot_id1, order_id],
    ).unwrap();

    let kot_item_id1 = "kitem-uuid-1";
    conn.execute(
        "INSERT INTO kot_items (id, kot_id, order_item_id, product_id, product_name, quantity, notes)
         VALUES (?1, ?2, ?3, 'prod-01', 'Default Product', 2, NULL);",
        params![kot_item_id1, kot_id1, oitem_id1],
    ).unwrap();

    // Insert historical item with NULL order_item_id in KOT 1
    let kot_item_hist = "kitem-uuid-hist";
    conn.execute(
        "INSERT INTO kot_items (id, kot_id, order_item_id, product_id, product_name, quantity, notes)
         VALUES (?1, ?2, NULL, 'prod-inj', 'Inj Product', 1, NULL);",
        params![kot_item_hist, kot_id1],
    ).unwrap();

    // Initial outbox count
    let outbox_count_before: i64 = conn
        .query_row("SELECT count(*) FROM sync_outbox;", [], |r| r.get(0))
        .unwrap();

    // Execute semantic read directly
    let kots = get_kots_for_order(&conn, order_id).expect("query kots for order");

    // 3. GET_KOTS_FOR_ORDER_MULTIPLE_KOTS_PASS
    assert_eq!(kots.len(), 2, "GET_KOTS_FOR_ORDER_MULTIPLE_KOTS_PASS: returns exactly 2 KOTs");

    // 4. KOT_ORDERING_BY_KOT_NUMBER_PASS
    assert_eq!(kots[0].kot.kot_number, 1, "KOT_ORDERING_BY_KOT_NUMBER_PASS: KOT 1 comes first");
    assert_eq!(kots[1].kot.kot_number, 2, "KOT_ORDERING_BY_KOT_NUMBER_PASS: KOT 2 comes second");
    assert_eq!(kots[0].kot.id, kot_id1);
    assert_eq!(kots[1].kot.id, kot_id2);

    // 5. KOT_ITEMS_RETURNED_PASS
    assert_eq!(kots[0].items.len(), 2, "KOT 1 has 2 items");
    assert_eq!(kots[1].items.len(), 1, "KOT 2 has 1 item");

    // 6. KOT_ITEM_ORDER_ITEM_ID_RETURNED_PASS
    let item1 = kots[0].items.iter().find(|it| it.id == kot_item_id1).expect("find item 1");
    assert_eq!(item1.order_item_id, Some(oitem_id1.to_string()), "KOT_ITEM_ORDER_ITEM_ID_RETURNED_PASS");
    assert_eq!(item1.quantity, 2, "IMMUTABLE_SENT_QUANTITY_RETURNED_PASS: sent quantity is 2");

    // 7. HISTORICAL_NULL_ORDER_ITEM_ID_PRESERVED_PASS
    let item_hist = kots[0].items.iter().find(|it| it.id == kot_item_hist).expect("find hist item");
    assert_eq!(item_hist.order_item_id, None, "HISTORICAL_NULL_ORDER_ITEM_ID_PRESERVED_PASS: None preserved");

    // 8. SAME_PRODUCT_MULTI_KOT_NOT_MERGED_PASS
    let item2 = kots[1].items.iter().find(|it| it.id == kot_item_id2).expect("find item 2");
    assert_eq!(item2.product_name, "Default Product");
    assert_eq!(item2.order_item_id, Some(oitem_id2.to_string()));
    assert_ne!(item1.id, item2.id, "SAME_PRODUCT_MULTI_KOT_NOT_MERGED_PASS: Burger lines in KOT 1 and KOT 2 remain distinct");

    // 9. IMMUTABLE_SENT_QUANTITY_RETURNED_PASS
    conn.execute(
        "UPDATE order_items SET quantity = 1 WHERE id = ?1;",
        params![oitem_id1],
    ).unwrap();
    let kots_after = get_kots_for_order(&conn, order_id).expect("query kots after update");
    let item1_after = kots_after[0].items.iter().find(|it| it.id == kot_item_id1).unwrap();
    assert_eq!(item1_after.quantity, 2, "IMMUTABLE_SENT_QUANTITY_RETURNED_PASS: kot_items.quantity still 2 after order_items mutated");

    // 10. READ_DOES_NOT_CREATE_OUTBOX_PASS
    let outbox_count_after: i64 = conn
        .query_row("SELECT count(*) FROM sync_outbox;", [], |r| r.get(0))
        .unwrap();
    assert_eq!(outbox_count_before, outbox_count_after, "READ_DOES_NOT_CREATE_OUTBOX_PASS: zero outbox rows created");

    // 11. NODE_RUST_RESULT_PARITY_PASS & NativeQuery execution
    let ipc_query = NativeQuery::GetKotsForOrder {
        order_id: order_id.to_string(),
    };
    let ipc_val = execute_query(&conn, ipc_query).expect("execute NativeQuery::GetKotsForOrder");
    assert!(ipc_val.is_array(), "NODE_RUST_RESULT_PARITY_PASS: result is JSON array");
    let arr = ipc_val.as_array().unwrap();
    assert_eq!(arr.len(), 2, "NODE_RUST_RESULT_PARITY_PASS: 2 KOTs in array");
    assert_eq!(arr[0]["kot"]["kot_number"], 1);
    assert_eq!(arr[0]["items"][0]["order_item_id"], oitem_id1);
    assert!(arr[0]["items"][1]["order_item_id"].is_null(), "Historical item has null order_item_id in JSON");
    assert_eq!(arr[1]["kot"]["kot_number"], 2);
}

// ============================================================================
// TASK 3G.2-11A.1: LOCAL PAYMENT SETTLEMENT GUARD + IDEMPOTENCY SUITE
// ============================================================================

#[test]
fn test_local_payment_settlement_guard_and_idempotency_suite() {
    let mut conn = setup_in_memory_db();
    create_test_device_config(&mut conn, "T01");

    let now = "2026-10-12T12:00:00.000Z";

    conn.execute(
        "INSERT INTO pos_tables (id, table_number, section, capacity, is_active, created_at)
         VALUES ('tbl-g1', 'T-10', 'Main', 4, 1, ?1);",
        params![now],
    ).unwrap();

    conn.execute(
        "INSERT INTO table_sessions (id, table_id, current_order_id, guest_count, session_status, opened_at)
         VALUES ('sess-g1', 'tbl-g1', 'ord-g1', 2, 'billed', ?1);",
        params![now],
    ).unwrap();

    conn.execute(
        "INSERT INTO orders (id, channel, order_type, table_session_id, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at)
         VALUES ('ord-g1', 'POS', 'DINE_IN', 'sess-g1', 'billed', 5000, 250, 0, 0, 5250, ?1, ?1);",
        params![now],
    ).unwrap();

    let bill = BillDomain {
        id: "bill-g1".to_string(),
        order_id: "ord-g1".to_string(),
        bill_number: "CB-T01-000001".to_string(),
        subtotal_paise: 5000,
        cgst_total_paise: 125,
        sgst_total_paise: 125,
        discount_total_paise: 0,
        grand_total_paise: 5250,
        payment_status: "unpaid".to_string(),
        finalized_at: now.to_string(),
        device_id: Some("dev-uuid-001".to_string()),
    };
    save_bill_with_sequence(&mut conn, bill.clone()).unwrap();

    let valid_payment = PaymentDomain {
        id: "pay-g1".to_string(),
        bill_id: "bill-g1".to_string(),
        order_id: "ord-g1".to_string(),
        payment_mode: "CASH".to_string(),
        amount_paid_paise: 5250,
        confirmed_by_staff_id: Some("staff-01".to_string()),
        confirmed_at: now.to_string(),
        notes: Some("Exact cash".to_string()),
    };

    let mut updated_bill = bill.clone();
    updated_bill.payment_status = "paid".to_string();

    // 1. PAYMENT_REQUIRES_BILLED_ORDER_RUST_PASS
    let invalid_order_payment = PaymentDomain {
        id: "pay-inv-ord".to_string(),
        bill_id: "bill-g1".to_string(),
        order_id: "ord-invalid".to_string(),
        payment_mode: "CASH".to_string(),
        amount_paid_paise: 5250,
        confirmed_by_staff_id: None,
        confirmed_at: now.to_string(),
        notes: None,
    };
    assert!(save_payment(&mut conn, invalid_order_payment, updated_bill.clone()).is_err(), "PAYMENT_REQUIRES_BILLED_ORDER_RUST_PASS: non-existent order rejected");

    conn.execute("INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at) VALUES ('ord-draft', 'POS', 'DINE_IN', 'draft', 100, 5, 0, 0, 105, ?1, ?1);", params![now]).unwrap();
    let draft_payment = PaymentDomain {
        id: "pay-draft".to_string(),
        bill_id: "bill-g1".to_string(),
        order_id: "ord-draft".to_string(),
        payment_mode: "CASH".to_string(),
        amount_paid_paise: 105,
        confirmed_by_staff_id: None,
        confirmed_at: now.to_string(),
        notes: None,
    };
    let err_draft = save_payment(&mut conn, draft_payment, updated_bill.clone()).unwrap_err();
    assert!(err_draft.contains("ORDER_STATUS_INVALID"), "PAYMENT_REQUIRES_BILLED_ORDER_RUST_PASS: draft rejected");

    // 2. PAYMENT_REQUIRES_UNPAID_BILL_RUST_PASS (missing bill)
    let missing_bill_payment = PaymentDomain {
        id: "pay-nobill".to_string(),
        bill_id: "bill-nonexistent".to_string(),
        order_id: "ord-g1".to_string(),
        payment_mode: "CASH".to_string(),
        amount_paid_paise: 5250,
        confirmed_by_staff_id: None,
        confirmed_at: now.to_string(),
        notes: None,
    };
    let mut bad_bill = updated_bill.clone();
    bad_bill.id = "bill-nonexistent".to_string();
    let err_nobill = save_payment(&mut conn, missing_bill_payment, bad_bill).unwrap_err();
    assert!(err_nobill.contains("BILL_NOT_FOUND"), "PAYMENT_REQUIRES_UNPAID_BILL_RUST_PASS: missing bill rejected");

    // 3. PAYMENT_BILL_ORDER_MATCH_RUST_PASS (bill belongs to different order)
    conn.execute("INSERT INTO orders (id, channel, order_type, status, subtotal_paise, tax_total_paise, discount_total_paise, delivery_charge_paise, grand_total_paise, created_at, updated_at) VALUES ('ord-other', 'POS', 'DINE_IN', 'billed', 5000, 250, 0, 0, 5250, ?1, ?1);", params![now]).unwrap();
    let mismatch_payment = PaymentDomain {
        id: "pay-mismatch".to_string(),
        bill_id: "bill-g1".to_string(),
        order_id: "ord-other".to_string(),
        payment_mode: "CASH".to_string(),
        amount_paid_paise: 5250,
        confirmed_by_staff_id: None,
        confirmed_at: now.to_string(),
        notes: None,
    };
    let mut mismatch_bill = updated_bill.clone();
    mismatch_bill.order_id = "ord-other".to_string();
    let err_mismatch = save_payment(&mut conn, mismatch_payment, mismatch_bill).unwrap_err();
    assert!(err_mismatch.contains("BILL_ORDER_MISMATCH"), "PAYMENT_BILL_ORDER_MATCH_RUST_PASS");

    // 4. PAYMENT_ATOMIC_SUCCESS_RUST_PASS
    let res = save_payment(&mut conn, valid_payment.clone(), updated_bill.clone()).expect("PAYMENT_ATOMIC_SUCCESS_RUST_PASS");
    assert_eq!(res.payment.id, "pay-g1");
    assert_eq!(res.updated_bill.payment_status, "paid");

    let ord_status: String = conn.query_row("SELECT status FROM orders WHERE id = 'ord-g1';", [], |r| r.get(0)).unwrap();
    assert_eq!(ord_status, "settled", "Order advanced to settled");

    let bill_status: String = conn.query_row("SELECT payment_status FROM bills WHERE id = 'bill-g1';", [], |r| r.get(0)).unwrap();
    assert_eq!(bill_status, "paid", "Bill marked as paid");

    let pay_count: i64 = conn.query_row("SELECT count(*) FROM payments WHERE bill_id = 'bill-g1';", [], |r| r.get(0)).unwrap();
    assert_eq!(pay_count, 1, "Exactly 1 payment row");

    let outbox_count: i64 = conn.query_row("SELECT count(*) FROM sync_outbox WHERE entity_type = 'payments' AND entity_id = 'pay-g1';", [], |r| r.get(0)).unwrap();
    assert_eq!(outbox_count, 1, "Exactly 1 outbox row");

    // 5. PAYMENT_EXACT_REPLAY_IDEMPOTENT_RUST_PASS & PAYMENT_EXACT_REPLAY_NO_DUPLICATE_OUTBOX_RUST_PASS
    let res_replay = save_payment(&mut conn, valid_payment.clone(), updated_bill.clone()).expect("PAYMENT_EXACT_REPLAY_IDEMPOTENT_RUST_PASS");
    assert_eq!(res_replay.payment.id, "pay-g1");
    assert_eq!(res_replay.updated_bill.payment_status, "paid");

    let pay_count_replay: i64 = conn.query_row("SELECT count(*) FROM payments WHERE bill_id = 'bill-g1';", [], |r| r.get(0)).unwrap();
    assert_eq!(pay_count_replay, 1, "PAYMENT_EXACT_REPLAY_NO_DUPLICATE_OUTBOX_RUST_PASS: pay count remains 1");

    let outbox_count_replay: i64 = conn.query_row("SELECT count(*) FROM sync_outbox WHERE entity_type = 'payments' AND entity_id = 'pay-g1';", [], |r| r.get(0)).unwrap();
    assert_eq!(outbox_count_replay, 1, "PAYMENT_EXACT_REPLAY_NO_DUPLICATE_OUTBOX_RUST_PASS: outbox count remains 1");

    // 6. PAYMENT_CONFLICTING_REPLAY_REJECTED_RUST_PASS & PAYMENT_CONFLICTING_REPLAY_NO_OUTBOX_RUST_PASS
    let mut conflict_payment = valid_payment.clone();
    conflict_payment.payment_mode = "UPI".to_string(); // Conflicting mode
    let err_conflict = save_payment(&mut conn, conflict_payment, updated_bill.clone()).unwrap_err();
    assert!(err_conflict.contains("CONTRACT_CONFLICT"), "PAYMENT_CONFLICTING_REPLAY_REJECTED_RUST_PASS");

    let outbox_conflict: i64 = conn.query_row("SELECT count(*) FROM sync_outbox WHERE entity_type = 'payments' AND entity_id = 'pay-g1';", [], |r| r.get(0)).unwrap();
    assert_eq!(outbox_conflict, 1, "PAYMENT_CONFLICTING_REPLAY_NO_OUTBOX_RUST_PASS: no outbox added on conflict");

    // 7. PAYMENT_DIFFERENT_ID_SECOND_SETTLEMENT_REJECTED_RUST_PASS & PAYMENT_DIFFERENT_ID_SECOND_SETTLEMENT_NO_OUTBOX_RUST_PASS
    let p2 = PaymentDomain {
        id: "pay-g2".to_string(),
        bill_id: "bill-g1".to_string(),
        order_id: "ord-g1".to_string(),
        payment_mode: "UPI".to_string(),
        amount_paid_paise: 5250,
        confirmed_by_staff_id: None,
        confirmed_at: now.to_string(),
        notes: None,
    };
    let err_p2 = save_payment(&mut conn, p2, updated_bill.clone()).unwrap_err();
    assert!(err_p2.contains("ORDER_STATUS_INVALID") || err_p2.contains("BILL_ALREADY_SETTLED"), "PAYMENT_DIFFERENT_ID_SECOND_SETTLEMENT_REJECTED_RUST_PASS");

    let p2_count: i64 = conn.query_row("SELECT count(*) FROM payments WHERE id = 'pay-g2';", [], |r| r.get(0)).unwrap();
    assert_eq!(p2_count, 0, "PAYMENT_DIFFERENT_ID_SECOND_SETTLEMENT_NO_OUTBOX_RUST_PASS: no p2 payment row");

    let p2_outbox: i64 = conn.query_row("SELECT count(*) FROM sync_outbox WHERE entity_id = 'pay-g2';", [], |r| r.get(0)).unwrap();
    assert_eq!(p2_outbox, 0, "PAYMENT_DIFFERENT_ID_SECOND_SETTLEMENT_NO_OUTBOX_RUST_PASS: no p2 outbox row");
}



