// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

pub mod db;
pub mod transport;

use std::sync::Mutex;
use rusqlite::Connection;

pub struct DbState(pub Mutex<Option<Connection>>);

#[tauri::command]
fn init_db_schema(state: tauri::State<DbState>) -> Result<String, String> {
    let mut guard = state.0.lock().map_err(|e| e.to_string())?;
    if guard.is_none() {
        let conn = Connection::open_in_memory().map_err(|e| e.to_string())?;
        db::init_database(&conn).map_err(|e| e.to_string())?;
        transport::init_credentials_table(&conn).map_err(|e| e.to_string())?;
        *guard = Some(conn);
    } else if let Some(conn) = guard.as_ref() {
        db::init_database(conn).map_err(|e| e.to_string())?;
        transport::init_credentials_table(conn).map_err(|e| e.to_string())?;
    }
    Ok("DB_INITIALIZED".to_string())
}

#[tauri::command]
fn pos_db_execute(
    state: tauri::State<DbState>,
    op: db::NativeMutation,
) -> Result<serde_json::Value, String> {
    let mut guard = state.0.lock().map_err(|e| e.to_string())?;
    let conn = guard.as_mut().ok_or_else(|| "DB_NOT_INITIALIZED".to_string())?;
    db::execute_mutation(conn, op)
}

#[tauri::command]
fn pos_db_query(
    state: tauri::State<DbState>,
    query: db::NativeQuery,
) -> Result<serde_json::Value, String> {
    let guard = state.0.lock().map_err(|e| e.to_string())?;
    let conn = guard.as_ref().ok_or_else(|| "DB_NOT_INITIALIZED".to_string())?;
    db::execute_query(conn, query)
}

#[tauri::command]
async fn native_pos_rpc(
    state: tauri::State<'_, DbState>,
    req: transport::NativeRpcRequest,
) -> Result<transport::NativeRpcResponse, transport::NativeRpcError> {
    let call = {
        let guard = state.0.lock().map_err(|e| transport::NativeRpcError {
            code: "RETRYABLE".to_string(),
            message: e.to_string(),
        })?;
        let conn = guard.as_ref().ok_or_else(|| transport::NativeRpcError {
            code: "RETRYABLE".to_string(),
            message: "DB_NOT_INITIALIZED".to_string(),
        })?;
        transport::prepare_rpc_call(conn, &req, transport::NEXTGEN_SUPABASE_PROJECT_URL)?
    };

    let dispatcher = transport::NativeRpcDispatcher::default();
    dispatcher.send_rpc(call).await
}

#[tauri::command]
async fn native_provision_device(
    state: tauri::State<'_, DbState>,
    terminal_code: String,
    device_name: String,
    admin_token: String,
) -> Result<serde_json::Value, String> {
    let client = reqwest::Client::new();
    let url = format!("{}/rest/v1/rpc/secure_provision_pos_device", transport::NEXTGEN_SUPABASE_PROJECT_URL);
    let body = serde_json::json!({
        "p_terminal_code": terminal_code,
        "p_device_name": device_name,
    });
    let resp = client.post(&url)
        .header("apikey", transport::NEXTGEN_SUPABASE_ANON_KEY)
        .header("Authorization", format!("Bearer {}", admin_token))
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("NETWORK_ERROR: {}", e))?;

    if !resp.status().is_success() {
        let err_text = resp.text().await.unwrap_or_default();
        return Err(format!("PROVISIONING_FAILED: {}", err_text));
    }

    let data: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
    let device_id = data.get("device_id").and_then(|v| v.as_str()).ok_or("MISSING_DEVICE_ID")?.to_string();
    let norm_terminal_code = data.get("terminal_code").and_then(|v| v.as_str()).ok_or("MISSING_TERMINAL_CODE")?.to_string();
    let norm_device_name = data.get("device_name").and_then(|v| v.as_str()).unwrap_or(&device_name).to_string();
    let raw_token = data.get("device_token").and_then(|v| v.as_str()).ok_or("MISSING_DEVICE_TOKEN")?.to_string();
    let created_at = data.get("created_at").and_then(|v| v.as_str()).unwrap_or("2026-10-11T00:00:00Z").to_string();

    {
        let guard = state.0.lock().map_err(|e| e.to_string())?;
        let conn = guard.as_ref().ok_or("DB_NOT_INITIALIZED")?;
        transport::store_device_credential(conn, &device_id, &raw_token)?;

        conn.execute(
            "INSERT INTO pos_device_config (device_id, terminal_code, device_name, created_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(device_id) DO UPDATE SET terminal_code = ?2, device_name = ?3;",
            rusqlite::params![device_id, norm_terminal_code, norm_device_name, created_at],
        ).map_err(|e| e.to_string())?;
    }

    Ok(serde_json::json!({
        "device_id": device_id,
        "terminal_code": norm_terminal_code,
        "device_name": norm_device_name,
        "created_at": created_at,
        "success": true
    }))
}

#[tauri::command]
fn native_store_credential(
    state: tauri::State<DbState>,
    device_id: String,
    device_token: String,
) -> Result<bool, String> {
    let guard = state.0.lock().map_err(|e| e.to_string())?;
    let conn = guard.as_ref().ok_or("DB_NOT_INITIALIZED")?;
    transport::store_device_credential(conn, &device_id, &device_token)?;
    Ok(true)
}

fn main() {
    tauri::Builder::default()
        .manage(DbState(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            init_db_schema,
            pos_db_execute,
            pos_db_query,
            native_pos_rpc,
            native_provision_device,
            native_store_credential
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
