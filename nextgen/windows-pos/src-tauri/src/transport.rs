// CHEESYOS NEXTGEN WINDOWS POS — NATIVE AUTHENTICATED RPC TRANSPORT
// Bridges TypeScript push worker to Cloud Supabase without exposing device secret to renderer.

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

pub const NEXTGEN_SUPABASE_PROJECT_URL: &str = "https://sdbnibyzqtgpbexlznat.supabase.co";
pub const EXPECTED_NEXTGEN_PROJECT_REF: &str = "sdbnibyzqtgpbexlznat";
pub const FORBIDDEN_PRODUCTION_PROJECT_REF: &str = "asvkfvrbhvxjmkznnpyb";

pub fn get_nextgen_supabase_url() -> Result<&'static str, &'static str> {
    const URL_ENV: Option<&str> = option_env!("VITE_NEXTGEN_SUPABASE_URL");
    let url = match URL_ENV {
        Some(u) if !u.trim().is_empty() => u.trim(),
        _ => NEXTGEN_SUPABASE_PROJECT_URL,
    };
    if url.contains(FORBIDDEN_PRODUCTION_PROJECT_REF) {
        return Err("FORBIDDEN_PRODUCTION_TARGET: Production project asvkfvrbhvxjmkznnpyb is strictly forbidden in NextGen runtime");
    }
    if !url.contains(EXPECTED_NEXTGEN_PROJECT_REF) {
        return Err("INVALID_TARGET_PROJECT: Target project must be sdbnibyzqtgpbexlznat");
    }
    Ok(url)
}

pub fn get_nextgen_supabase_anon_key() -> Result<&'static str, &'static str> {
    const KEY_ENV: Option<&str> = option_env!("VITE_NEXTGEN_SUPABASE_ANON_KEY");
    match KEY_ENV {
        Some(k) if !k.trim().is_empty() && !k.contains("dummy") => Ok(k.trim()),
        _ => {
            #[cfg(test)]
            {
                Ok("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.test_only_explicit_fixture_key")
            }
            #[cfg(not(test))]
            {
                Err("NATIVE_NEXTGEN_ANON_KEY_MISSING: VITE_NEXTGEN_SUPABASE_ANON_KEY compile-time environment variable required in release builds")
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NativeRpcOperation {
    Order,
    Kot,
    KotCorrection,
    Bill,
    Payment,
    InventoryMovement,
    TableSession,
    ReplaceDraftOrder,
    AppendOrderItemsAndKot,
}

impl NativeRpcOperation {
    pub fn rpc_name(&self) -> &'static str {
        match self {
            NativeRpcOperation::Order => "secure_sync_pos_order",
            NativeRpcOperation::Kot => "secure_sync_pos_kot",
            NativeRpcOperation::KotCorrection => "secure_save_kot_correction",
            NativeRpcOperation::Bill => "secure_sync_pos_bill",
            NativeRpcOperation::Payment => "secure_sync_pos_payment",
            NativeRpcOperation::InventoryMovement => "secure_apply_inventory_movement",
            NativeRpcOperation::TableSession => "secure_sync_pos_table_session",
            NativeRpcOperation::ReplaceDraftOrder => "secure_replace_pos_draft_order",
            NativeRpcOperation::AppendOrderItemsAndKot => "secure_append_pos_order_items_and_kot",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeRpcRequest {
    pub op: NativeRpcOperation,
    pub payload: serde_json::Value,
    pub staff_token: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeRpcResponse {
    pub success: bool,
    pub data: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeRpcError {
    pub code: String, // "RETRYABLE", "AUTH_REQUIRED", "DEVICE_REVOKED", "DEVICE_AUTH_FAILED", "CONTRACT_CONFLICT"
    pub message: String,
}

impl std::fmt::Display for NativeRpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}]: {}", self.code, self.message)
    }
}

impl std::error::Error for NativeRpcError {}

// ============================================================================
// NATIVE DPAPI & SECURE CREDENTIAL ABSTRACTION
// ============================================================================

pub struct NativeSecretVault;

impl NativeSecretVault {
    #[cfg(target_os = "windows")]
    pub fn protect_secret(plaintext: &str) -> Result<Vec<u8>, String> {
        use windows_sys::Win32::Security::Cryptography::{
            CryptProtectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
        };
        use std::ptr::null_mut;

        let bytes = plaintext.as_bytes();
        let mut data_in = CRYPT_INTEGER_BLOB {
            cbData: bytes.len() as u32,
            pbData: bytes.as_ptr() as *mut u8,
        };
        let mut data_out = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: null_mut(),
        };

        unsafe {
            let res = CryptProtectData(
                &mut data_in,
                null_mut(),
                null_mut(),
                null_mut(),
                null_mut(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut data_out,
            );
            if res == 0 {
                return Err("DPAPI_PROTECT_FAILED".to_string());
            }
            let slice = std::slice::from_raw_parts(data_out.pbData, data_out.cbData as usize);
            let protected_bytes = slice.to_vec();
            windows_sys::Win32::Foundation::LocalFree(data_out.pbData as _);
            Ok(protected_bytes)
        }
    }

    #[cfg(target_os = "windows")]
    pub fn unprotect_secret(ciphertext: &[u8]) -> Result<String, String> {
        use windows_sys::Win32::Security::Cryptography::{
            CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
        };
        use std::ptr::null_mut;

        let mut data_in = CRYPT_INTEGER_BLOB {
            cbData: ciphertext.len() as u32,
            pbData: ciphertext.as_ptr() as *mut u8,
        };
        let mut data_out = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: null_mut(),
        };

        unsafe {
            let res = CryptUnprotectData(
                &mut data_in,
                null_mut(),
                null_mut(),
                null_mut(),
                null_mut(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut data_out,
            );
            if res == 0 {
                return Err("DPAPI_UNPROTECT_FAILED".to_string());
            }
            let slice = std::slice::from_raw_parts(data_out.pbData, data_out.cbData as usize);
            let s = String::from_utf8(slice.to_vec()).map_err(|e| e.to_string())?;
            windows_sys::Win32::Foundation::LocalFree(data_out.pbData as _);
            Ok(s)
        }
    }

    #[cfg(not(target_os = "windows"))]
    pub fn protect_secret(plaintext: &str) -> Result<Vec<u8>, String> {
        #[cfg(any(test, debug_assertions))]
        {
            let mut blob = b"DPAPI_TEST_ENVELOPE_".to_vec();
            blob.extend_from_slice(plaintext.as_bytes());
            Ok(blob)
        }
        #[cfg(not(any(test, debug_assertions)))]
        {
            compile_error!("Production builds require Windows target for DPAPI security.");
        }
    }

    #[cfg(not(target_os = "windows"))]
    pub fn unprotect_secret(ciphertext: &[u8]) -> Result<String, String> {
        #[cfg(any(test, debug_assertions))]
        {
            let prefix = b"DPAPI_TEST_ENVELOPE_";
            if ciphertext.starts_with(prefix) {
                let bytes = &ciphertext[prefix.len()..];
                String::from_utf8(bytes.to_vec()).map_err(|e| e.to_string())
            } else {
                Err("SIMULATED_DPAPI_DECRYPT_FAILED".to_string())
            }
        }
        #[cfg(not(any(test, debug_assertions)))]
        {
            compile_error!("Production builds require Windows target for DPAPI security.");
        }
    }
}

// ============================================================================
// NATIVE DATABASE SECRETS PERSISTENCE
// ============================================================================

pub fn init_credentials_table(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS pos_device_credentials (
            device_id TEXT PRIMARY KEY,
            encrypted_token BLOB NOT NULL,
            created_at TEXT NOT NULL
        );",
        [],
    )?;
    Ok(())
}

pub fn store_device_credential(
    conn: &Connection,
    device_id: &str,
    plaintext_token: &str,
) -> Result<(), String> {
    init_credentials_table(conn).map_err(|e| e.to_string())?;
    let encrypted = NativeSecretVault::protect_secret(plaintext_token)?;
    let now = "2026-10-11T00:00:00Z";
    conn.execute(
        "INSERT INTO pos_device_credentials (device_id, encrypted_token, created_at)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(device_id) DO UPDATE SET encrypted_token = ?2;",
        rusqlite::params![device_id, encrypted, now],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn load_device_credential(
    conn: &Connection,
    device_id: &str,
) -> Result<String, String> {
    init_credentials_table(conn).map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare("SELECT encrypted_token FROM pos_device_credentials WHERE device_id = ?1 LIMIT 1;")
        .map_err(|e| e.to_string())?;
    let encrypted: Vec<u8> = stmt
        .query_row(rusqlite::params![device_id], |row| row.get(0))
        .map_err(|_| "DEVICE_CREDENTIAL_NOT_FOUND".to_string())?;
    NativeSecretVault::unprotect_secret(&encrypted)
}

// ============================================================================
// NATIVE RPC EXECUTION ENGINE
// ============================================================================

#[derive(Debug, Clone)]
pub struct PreparedRpcCall {
    pub url: String,
    pub body: serde_json::Value,
    pub staff_token: String,
}

pub fn prepare_rpc_call(
    conn: &Connection,
    req: &NativeRpcRequest,
    base_url: &str,
) -> Result<PreparedRpcCall, NativeRpcError> {
    let config_res = conn.query_row(
        "SELECT device_id FROM pos_device_config LIMIT 1;",
        [],
        |r| r.get::<_, String>(0),
    );
    let device_id = match config_res {
        Ok(id) => id,
        Err(_) => {
            return Err(NativeRpcError {
                code: "AUTH_REQUIRED".to_string(),
                message: "DEVICE_NOT_PROVISIONED: No local terminal identity configured".to_string(),
            });
        }
    };

    let payload_dev_id = req.payload.get("device_id")
        .or_else(|| req.payload.get("order").and_then(|o| o.get("device_id")))
        .or_else(|| req.payload.get("bill").and_then(|b| b.get("device_id")))
        .and_then(|v| v.as_str());
    if let Some(pid) = payload_dev_id {
        if pid != device_id {
            return Err(NativeRpcError {
                code: "CONTRACT_CONFLICT".to_string(),
                message: format!("DEVICE_MISMATCH: Payload device_id ({}) does not match local device_id ({})", pid, device_id),
            });
        }
    }

    let staff_token = match &req.staff_token {
        Some(t) if !t.trim().is_empty() => t.clone(),
        _ => {
            return Err(NativeRpcError {
                code: "AUTH_REQUIRED".to_string(),
                message: "STAFF_TOKEN_MISSING: Short-lived staff access token required for cloud mutation".to_string(),
            });
        }
    };

    let device_token = load_device_credential(conn, &device_id).map_err(|e| {
        NativeRpcError {
            code: "AUTH_REQUIRED".to_string(),
            message: format!("DEVICE_AUTH_FAILED: Failed to unprotect device credential: {}", e),
        }
    })?;

    let url = format!("{}/rest/v1/rpc/{}", base_url.trim_end_matches('/'), req.op.rpc_name());
    let body = NativeRpcDispatcher::prepare_rpc_body(&req.op, &req.payload, &device_id, &device_token)?;

    Ok(PreparedRpcCall {
        url,
        body,
        staff_token,
    })
}

pub struct NativeRpcDispatcher {
    client: reqwest::Client,
    pub base_url: String,
    pub anon_key: String,
}

impl Default for NativeRpcDispatcher {
    fn default() -> Self {
        let url = get_nextgen_supabase_url().unwrap_or(NEXTGEN_SUPABASE_PROJECT_URL);
        let anon_key = get_nextgen_supabase_anon_key().unwrap_or_default();
        Self::new(url, anon_key)
    }
}

impl NativeRpcDispatcher {
    pub fn try_default() -> Result<Self, NativeRpcError> {
        let url = get_nextgen_supabase_url().map_err(|e| NativeRpcError {
            code: "CONFIG_ERROR".to_string(),
            message: e.to_string(),
        })?;
        let anon_key = get_nextgen_supabase_anon_key().map_err(|e| NativeRpcError {
            code: "CONFIG_ERROR".to_string(),
            message: e.to_string(),
        })?;
        Ok(Self::new(url, anon_key))
    }

    pub fn new(base_url: &str, anon_key: &str) -> Self {
        Self {
            client: reqwest::Client::builder().build().unwrap(),
            base_url: base_url.trim_end_matches('/').to_string(),
            anon_key: anon_key.to_string(),
        }
    }

    pub fn prepare_rpc_body(
        op: &NativeRpcOperation,
        payload: &serde_json::Value,
        device_id: &str,
        device_token: &str,
    ) -> Result<serde_json::Value, NativeRpcError> {
        let mut body = serde_json::Map::new();
        body.insert("p_device_id".to_string(), serde_json::Value::String(device_id.to_string()));
        body.insert("p_device_token".to_string(), serde_json::Value::String(device_token.to_string()));

        match op {
            NativeRpcOperation::Order => {
                let order = payload.get("order").cloned().unwrap_or_else(|| payload.clone());
                let items = payload.get("items").cloned().unwrap_or_else(|| serde_json::json!([]));
                body.insert("p_order".to_string(), order);
                body.insert("p_order_items".to_string(), items);
            }
            NativeRpcOperation::Kot => {
                let kot = payload.get("kot").cloned().unwrap_or_else(|| payload.clone());
                let items = payload.get("items").cloned().unwrap_or_else(|| serde_json::json!([]));
                body.insert("p_kot".to_string(), kot);
                body.insert("p_kot_items".to_string(), items);
            }
            NativeRpcOperation::KotCorrection => {
                let correction = payload.get("correction").cloned().unwrap_or_else(|| payload.clone());
                body.insert("p_correction".to_string(), correction);
            }
            NativeRpcOperation::Bill => {
                let bill = payload.get("bill").cloned().unwrap_or_else(|| payload.clone());
                body.insert("p_bill".to_string(), bill);
            }
            NativeRpcOperation::Payment => {
                let payment = payload.get("payment").cloned().unwrap_or_else(|| payload.clone());
                body.insert("p_payment".to_string(), payment);
            }
            NativeRpcOperation::InventoryMovement => {
                if let Some(pid) = payload.get("productId") {
                    body.insert("p_product_id".to_string(), pid.clone());
                } else if let Some(pid) = payload.get("product_id") {
                    body.insert("p_product_id".to_string(), pid.clone());
                } else {
                    return Err(NativeRpcError {
                        code: "CONTRACT_CONFLICT".to_string(),
                        message: "Missing product_id for inventory movement".to_string(),
                    });
                }
                body.insert("p_movement_type".to_string(), payload.get("movementType").or_else(|| payload.get("movement_type")).cloned().unwrap_or_default());
                body.insert("p_quantity_change".to_string(), payload.get("quantityChange").or_else(|| payload.get("quantity_change")).cloned().unwrap_or_default());
                body.insert("p_created_by".to_string(), payload.get("createdByStaffId").or_else(|| payload.get("created_by")).cloned().unwrap_or(serde_json::Value::Null));
                body.insert("p_movement_id".to_string(), payload.get("movementId").or_else(|| payload.get("movement_id")).cloned().unwrap_or(serde_json::Value::Null));
                body.insert("p_reference_movement_id".to_string(), payload.get("referenceMovementId").or_else(|| payload.get("reference_movement_id")).cloned().unwrap_or(serde_json::Value::Null));
            }
            NativeRpcOperation::TableSession => {
                let session = payload.get("session").cloned().unwrap_or_else(|| payload.clone());
                body.insert("p_session".to_string(), session);
            }
            NativeRpcOperation::ReplaceDraftOrder => {
                let order = payload.get("order").cloned().unwrap_or_else(|| payload.clone());
                let items = payload.get("items").cloned().unwrap_or_else(|| serde_json::json!([]));
                body.insert("p_order".to_string(), order);
                body.insert("p_order_items".to_string(), items);
            }
            NativeRpcOperation::AppendOrderItemsAndKot => {
                let order = payload.get("order").cloned().unwrap_or_else(|| payload.clone());
                let order_items = payload.get("orderItems").or_else(|| payload.get("order_items")).cloned().unwrap_or_else(|| serde_json::json!([]));
                let kot = payload.get("kot").cloned().unwrap_or_else(|| serde_json::json!({}));
                let kot_items = payload.get("items").or_else(|| payload.get("kot_items")).cloned().unwrap_or_else(|| serde_json::json!([]));
                body.insert("p_order".to_string(), order);
                body.insert("p_order_items".to_string(), order_items);
                body.insert("p_kot".to_string(), kot);
                body.insert("p_kot_items".to_string(), kot_items);
            }
        }

        Ok(serde_json::Value::Object(body))
    }

    pub fn map_http_error(status: reqwest::StatusCode, error_body: &str) -> NativeRpcError {
        let msg = error_body.to_string();
        if msg.contains("DEVICE_REVOKED") {
            NativeRpcError {
                code: "DEVICE_REVOKED".to_string(),
                message: msg,
            }
        } else if msg.contains("DEVICE_AUTH_FAILED") {
            NativeRpcError {
                code: "DEVICE_AUTH_FAILED".to_string(),
                message: msg,
            }
        } else if msg.contains("DEVICE_NOT_PROVISIONED") || msg.contains("Access Denied") || status.as_u16() == 401 || status.as_u16() == 403 {
            NativeRpcError {
                code: "AUTH_REQUIRED".to_string(),
                message: msg,
            }
        } else if msg.contains("CONTRACT_CONFLICT") || msg.contains("VALIDATION_ERROR") || msg.contains("IDEMPOTENCY_CONFLICT") || msg.contains("NUMBERING_CONFLICT") || msg.contains("Overpayment Denied") || msg.contains("VERSION_CONFLICT") || msg.contains("STALE_VERSION") || msg.contains("VERSION_GAP") || status.as_u16() == 409 {
            NativeRpcError {
                code: "CONTRACT_CONFLICT".to_string(),
                message: msg,
            }
        } else {
            NativeRpcError {
                code: "RETRYABLE".to_string(),
                message: msg,
            }
        }
    }

    pub async fn send_rpc(
        &self,
        call: PreparedRpcCall,
    ) -> Result<NativeRpcResponse, NativeRpcError> {
        let res = self.client.post(&call.url)
            .header("apikey", &self.anon_key)
            .header("Authorization", format!("Bearer {}", call.staff_token))
            .header("Content-Type", "application/json")
            .json(&call.body)
            .send()
            .await;

        match res {
            Ok(resp) => {
                let status = resp.status();
                if status.is_success() {
                    let parsed: Option<serde_json::Value> = resp.json().await.ok();
                    Ok(NativeRpcResponse {
                        success: true,
                        data: parsed,
                    })
                } else {
                    let err_text = resp.text().await.unwrap_or_else(|_| "Unknown HTTP error".to_string());
                    Err(Self::map_http_error(status, &err_text))
                }
            }
            Err(e) => {
                Err(NativeRpcError {
                    code: "RETRYABLE".to_string(),
                    message: format!("NETWORK_FAILURE: {}", e),
                })
            }
        }
    }
}
