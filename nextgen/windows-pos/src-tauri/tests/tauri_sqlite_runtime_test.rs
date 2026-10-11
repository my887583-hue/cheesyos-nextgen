#[path = "../src/db.rs"]
mod db;

#[path = "../src/transport.rs"]
mod transport;

use rusqlite::Connection;
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

    let items = vec![KotItemDomain {
        id: "kot-item-01".to_string(),
        kot_id: "kot-01".to_string(),
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

