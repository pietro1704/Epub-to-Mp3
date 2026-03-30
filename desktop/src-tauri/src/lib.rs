use std::sync::Mutex;
use tauri::{AppHandle, Manager, State};
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;

const SERVER_PORT: u16 = 47860;
const POLL_INTERVAL_MS: u64 = 300;
const POLL_TIMEOUT_S: u64 = 60;

/// Shared server log buffer.
pub struct ServerLogs(Mutex<Vec<String>>);

/// Poll TCP until the server accepts connections or the timeout is reached.
async fn wait_for_server(port: u16) -> bool {
    let addr = format!("127.0.0.1:{port}");
    let deadline =
        tokio::time::Instant::now() + tokio::time::Duration::from_secs(POLL_TIMEOUT_S);
    loop {
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        if tokio::net::TcpStream::connect(&addr).await.is_ok() {
            return true;
        }
        tokio::time::sleep(tokio::time::Duration::from_millis(POLL_INTERVAL_MS)).await;
    }
}

#[tauri::command]
fn get_server_logs(logs: State<'_, ServerLogs>) -> Vec<String> {
    logs.0.lock().unwrap().clone()
}

#[tauri::command]
fn open_log_window(app: AppHandle) {
    if let Some(win) = app.get_webview_window("logs") {
        let _ = win.show();
        let _ = win.set_focus();
        return;
    }
    let _ = tauri::WebviewWindowBuilder::new(
        &app,
        "logs",
        tauri::WebviewUrl::App("log-viewer.html".into()),
    )
    .title("Server Logs")
    .inner_size(800.0, 500.0)
    .resizable(true)
    .build();
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(ServerLogs(Mutex::new(Vec::new())))
        .invoke_handler(tauri::generate_handler![get_server_logs, open_log_window])
        .setup(|app| {
            // Hide the main window until the Python sidecar is ready.
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.hide();
            }

            let handle = app.handle().clone();

            tauri::async_runtime::spawn(async move {
                // Spawn the sidecar and capture its output.
                let (mut rx, _child) = handle
                    .shell()
                    .sidecar("epub-to-mp3-server")
                    .expect("sidecar 'epub-to-mp3-server' not found in binaries/")
                    .spawn()
                    .expect("failed to spawn Python backend sidecar");

                // Forward sidecar output to the shared log buffer.
                let log_handle = handle.clone();
                tauri::async_runtime::spawn(async move {
                    while let Some(event) = rx.recv().await {
                        let line = match event {
                            CommandEvent::Stdout(b) => {
                                String::from_utf8_lossy(&b).trim().to_string()
                            }
                            CommandEvent::Stderr(b) => {
                                format!("[err] {}", String::from_utf8_lossy(&b).trim())
                            }
                            _ => continue,
                        };
                        if line.is_empty() {
                            continue;
                        }
                        if let Some(logs) = log_handle.try_state::<ServerLogs>() {
                            let mut v = logs.0.lock().unwrap();
                            v.push(line);
                            // Keep last 2000 lines.
                            let len = v.len();
                            if len > 2000 {
                                v.drain(0..len - 2000);
                            }
                        }
                    }
                });

                // Wait for the server to be reachable, then show the main window.
                let ready = wait_for_server(SERVER_PORT).await;
                if let Some(win) = handle.get_webview_window("main") {
                    if ready {
                        let _ = win.show();
                        let _ = win.set_focus();
                    } else {
                        // Timeout — show anyway so the user isn't stuck.
                        let _ = win.show();
                    }
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
