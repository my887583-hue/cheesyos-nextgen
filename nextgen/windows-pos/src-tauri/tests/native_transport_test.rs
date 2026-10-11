// CHEESYOS NEXTGEN WINDOWS POS — NATIVE RPC TRANSPORT UNIT TESTS
// Verifies native credential isolation, payload injection, and finite enum mapping.

#[path = "../src/db.rs"]
mod db;

#[path = "../src/transport.rs"]
mod transport;

use rusqlite::Connection;
use transport::*;

fn setup_test_db() -> Connection {
    let conn = Connection::open_in_memory().unwrap();
    db::init_database(&conn).unwrap();
    init_credentials_table(&conn).unwrap();
    conn
}

#[test]
fn test_secret_vault_protection_and_unprotection() {
    let raw_secret = "cb_dev_sec_99998888777766665555444433332222";
    let encrypted = NativeSecretVault::protect_secret(raw_secret).unwrap();
    assert_ne!(encrypted, raw_secret.as_bytes());

    let decrypted = NativeSecretVault::unprotect_secret(&encrypted).unwrap();
    assert_eq!(decrypted, raw_secret);
}

#[test]
fn test_unprovisioned_device_rejected() {
    let conn = setup_test_db();
    let req = NativeRpcRequest {
        op: NativeRpcOperation::Order,
        payload: serde_json::json!({
            "order": { "id": "00000000-0000-0000-0000-000000000001" },
            "items": []
        }),
        staff_token: Some("dummy_jwt".to_string()),
    };

    let res = prepare_rpc_call(&conn, &req, NEXTGEN_SUPABASE_PROJECT_URL);
    assert!(res.is_err());
    let err = res.unwrap_err();
    assert_eq!(err.code, "AUTH_REQUIRED");
    assert!(err.message.contains("DEVICE_NOT_PROVISIONED"));
}

#[test]
fn test_device_id_mismatch_rejected() {
    let conn = setup_test_db();
    let configured_dev_id = "11111111-1111-1111-1111-111111111111";
    conn.execute(
        "INSERT INTO pos_device_config (device_id, terminal_code, device_name, created_at)
         VALUES (?1, 'T01', 'Counter 1', '2026-10-11T00:00:00Z');",
        [configured_dev_id],
    )
    .unwrap();
    store_device_credential(&conn, configured_dev_id, "token_111").unwrap();

    let req = NativeRpcRequest {
        op: NativeRpcOperation::Order,
        payload: serde_json::json!({
            "order": {
                "id": "00000000-0000-0000-0000-000000000001",
                "device_id": "22222222-2222-2222-2222-222222222222" // Mismatched!
            },
            "items": []
        }),
        staff_token: Some("dummy_jwt".to_string()),
    };

    let res = prepare_rpc_call(&conn, &req, NEXTGEN_SUPABASE_PROJECT_URL);
    assert!(res.is_err());
    let err = res.unwrap_err();
    assert_eq!(err.code, "CONTRACT_CONFLICT");
    assert!(err.message.contains("DEVICE_MISMATCH"));
}

#[test]
fn test_missing_staff_token_rejected() {
    let conn = setup_test_db();
    let dev_id = "11111111-1111-1111-1111-111111111111";
    conn.execute(
        "INSERT INTO pos_device_config (device_id, terminal_code, device_name, created_at)
         VALUES (?1, 'T01', 'Counter 1', '2026-10-11T00:00:00Z');",
        [dev_id],
    )
    .unwrap();
    store_device_credential(&conn, dev_id, "token_111").unwrap();

    let req = NativeRpcRequest {
        op: NativeRpcOperation::Order,
        payload: serde_json::json!({ "order": { "id": "0001" }, "items": [] }),
        staff_token: None, // Missing staff JWT!
    };

    let res = prepare_rpc_call(&conn, &req, NEXTGEN_SUPABASE_PROJECT_URL);
    assert!(res.is_err());
    let err = res.unwrap_err();
    assert_eq!(err.code, "AUTH_REQUIRED");
    assert!(err.message.contains("STAFF_TOKEN_MISSING"));
}

#[test]
fn test_valid_preparation_injects_credentials_and_locks_destination() {
    let conn = setup_test_db();
    let dev_id = "11111111-1111-1111-1111-111111111111";
    let token = "cb_dev_sec_valid_token_123456";
    conn.execute(
        "INSERT INTO pos_device_config (device_id, terminal_code, device_name, created_at)
         VALUES (?1, 'T01', 'Counter 1', '2026-10-11T00:00:00Z');",
        [dev_id],
    )
    .unwrap();
    store_device_credential(&conn, dev_id, token).unwrap();

    let req = NativeRpcRequest {
        op: NativeRpcOperation::Order,
        payload: serde_json::json!({
            "order": { "id": "order-123", "grand_total": 99.0 },
            "items": [{ "id": "item-1", "product_name": "Pizza" }]
        }),
        staff_token: Some("staff_valid_jwt_abc".to_string()),
    };

    let call = prepare_rpc_call(&conn, &req, NEXTGEN_SUPABASE_PROJECT_URL).unwrap();

    assert_eq!(call.url, "https://sdbnibyzqtgpbexlznat.supabase.co/rest/v1/rpc/secure_sync_pos_order");
    assert_eq!(call.staff_token, "staff_valid_jwt_abc");

    // Injected body assertions
    assert_eq!(call.body["p_device_id"], dev_id);
    assert_eq!(call.body["p_device_token"], token);
    assert_eq!(call.body["p_order"]["id"], "order-123");
    assert_eq!(call.body["p_order_items"][0]["product_name"], "Pizza");
}

#[test]
fn test_all_six_finite_operations_map_to_exact_cloud_rpcs() {
    let ops = vec![
        (NativeRpcOperation::Order, "secure_sync_pos_order"),
        (NativeRpcOperation::Kot, "secure_sync_pos_kot"),
        (NativeRpcOperation::KotCorrection, "secure_sync_kot_correction"),
        (NativeRpcOperation::Bill, "secure_sync_pos_bill"),
        (NativeRpcOperation::Payment, "secure_sync_pos_payment"),
        (NativeRpcOperation::InventoryMovement, "secure_apply_inventory_movement"),
    ];

    for (op, expected_rpc) in ops {
        assert_eq!(op.rpc_name(), expected_rpc);
    }
}

#[test]
fn test_http_error_mapping_semantics() {
    let err_revoked = NativeRpcDispatcher::map_http_error(
        reqwest::StatusCode::FORBIDDEN,
        "DEVICE_REVOKED: Terminal has been decommissioned",
    );
    assert_eq!(err_revoked.code, "DEVICE_REVOKED");

    let err_auth_failed = NativeRpcDispatcher::map_http_error(
        reqwest::StatusCode::UNAUTHORIZED,
        "DEVICE_AUTH_FAILED: Invalid device token hash",
    );
    assert_eq!(err_auth_failed.code, "DEVICE_AUTH_FAILED");

    let err_conflict = NativeRpcDispatcher::map_http_error(
        reqwest::StatusCode::CONFLICT,
        "CONTRACT_CONFLICT: Header subtotal mismatch",
    );
    assert_eq!(err_conflict.code, "CONTRACT_CONFLICT");

    let err_network = NativeRpcDispatcher::map_http_error(
        reqwest::StatusCode::INTERNAL_SERVER_ERROR,
        "Internal gateway failure",
    );
    assert_eq!(err_network.code, "RETRYABLE");
}
