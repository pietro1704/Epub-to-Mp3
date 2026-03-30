use std::sync::Mutex;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;

const SERVER_PORT: u16 = 47860;
const POLL_INTERVAL_MS: u64 = 300;
/// Generous timeout: PyInstaller onefile extracts on first run.
const POLL_TIMEOUT_S: u64 = 120;

/// Shared server log buffer (last 2000 lines).
pub struct ServerLogs(Mutex<Vec<String>>);

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

// ── Tauri commands ────────────────────────────────────────────────────────────

#[tauri::command]
fn get_server_logs(logs: State<'_, ServerLogs>) -> Vec<String> {
    logs.0.lock().unwrap().clone()
}

#[tauri::command]
fn open_log_window(app: AppHandle) {
    show_log_window(&app);
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn show_log_window(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("logs") {
        let _ = win.show();
        let _ = win.set_focus();
        return;
    }
    let _ = tauri::WebviewWindowBuilder::new(
        app,
        "logs",
        tauri::WebviewUrl::App("log-viewer.html".into()),
    )
    .title("Server Logs")
    .inner_size(800.0, 500.0)
    .resizable(true)
    .build();
}

fn build_menu(app: &tauri::App) -> tauri::Result<Menu<tauri::Wry>> {
    let h = app.handle();

    let open = MenuItem::with_id(h, "open_books", "Open Books…", true, Some("CmdOrCtrl+O"))?;
    let logs = MenuItem::with_id(h, "show_logs", "Server Logs", true, None::<&str>)?;
    let view = Submenu::with_items(h, "View", true, &[&logs])?;

    #[cfg(target_os = "macos")]
    let menu = {
        let app_sub = Submenu::with_items(
            h,
            "Epub to Mp3",
            true,
            &[
                &PredefinedMenuItem::about(h, None, None)?,
                &PredefinedMenuItem::separator(h)?,
                &PredefinedMenuItem::hide(h, None)?,
                &PredefinedMenuItem::hide_others(h, None)?,
                &PredefinedMenuItem::show_all(h, None)?,
                &PredefinedMenuItem::separator(h)?,
                &PredefinedMenuItem::quit(h, None)?,
            ],
        )?;
        let file_sub = Submenu::with_items(h, "File", true, &[&open])?;
        Menu::with_items(h, &[&app_sub, &file_sub, &view])?
    };

    #[cfg(not(target_os = "macos"))]
    let menu = {
        let file_sub = Submenu::with_items(
            h,
            "File",
            true,
            &[
                &open,
                &PredefinedMenuItem::separator(h)?,
                &PredefinedMenuItem::quit(h, None)?,
            ],
        )?;
        Menu::with_items(h, &[&file_sub, &view])?
    };

    Ok(menu)
}

// ── Entry point ───────────────────────────────────────────────────────────────

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(ServerLogs(Mutex::new(Vec::new())))
        .invoke_handler(tauri::generate_handler![get_server_logs, open_log_window])
        .setup(|app| {
            // ── Menu bar ──────────────────────────────────────────────────────
            let menu = build_menu(app)?;
            app.set_menu(menu)?;

            app.on_menu_event(|app_handle, event| match event.id().0.as_str() {
                // File > Open Books… → tell the frontend to open its file picker.
                "open_books" => {
                    if let Some(win) = app_handle.get_webview_window("main") {
                        let _ = win.emit("tauri-open-books", ());
                    }
                }
                // View > Server Logs
                "show_logs" => show_log_window(app_handle),
                _ => {}
            });

            // ── Sidecar startup ───────────────────────────────────────────────
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.hide();
            }

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                // Try to spawn the Python backend sidecar.
                let spawn_result = handle
                    .shell()
                    .sidecar("epub-to-mp3-server")
                    .map_err(|e| e.to_string())
                    .and_then(|cmd| cmd.spawn().map_err(|e| e.to_string()));

                let (mut rx, _child) = match spawn_result {
                    Ok(pair) => pair,
                    Err(err) => {
                        // Sidecar binary missing or failed to exec.
                        // Show the window immediately so the user isn't stuck.
                        if let Some(win) = handle.get_webview_window("main") {
                            let _ = win.show();
                            // Signal the frontend with the error message.
                            let _ = win.emit("tauri-startup-error", &err);
                        }
                        return;
                    }
                };

                // Forward sidecar stdout/stderr to the shared log buffer.
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
                            let len = v.len();
                            if len > 2000 {
                                v.drain(0..len - 2000);
                            }
                        }
                    }
                });

                // Poll TCP until server is ready, then reveal the window.
                let ready = wait_for_server(SERVER_PORT).await;
                if let Some(win) = handle.get_webview_window("main") {
                    let _ = win.show();
                    let _ = win.set_focus();
                    if !ready {
                        // Timeout: signal the frontend so it can show a recovery UI.
                        let _ = win.emit("tauri-startup-timeout", ());
                    }
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
