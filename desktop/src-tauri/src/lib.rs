use std::sync::Mutex;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;
use tauri_plugin_updater::UpdaterExt;

const SERVER_PORT: u16 = 47860;
const POLL_INTERVAL_MS: u64 = 500;
/// 5 min: first launch downloads ffmpeg (~60 MB) before server can start.
const POLL_TIMEOUT_S: u64 = 300;
/// Emit a "still loading" event every N seconds so the frontend can show progress.
const LOADING_NOTIFY_INTERVAL_S: u64 = 5;

/// Shared server log buffer (last 2000 lines).
pub struct ServerLogs(Mutex<Vec<String>>);

// ── Tauri commands ────────────────────────────────────────────────────────────

#[tauri::command]
fn get_server_logs(logs: State<'_, ServerLogs>) -> Vec<String> {
    logs.0.lock().unwrap().clone()
}

#[tauri::command]
fn open_log_window(app: AppHandle) {
    show_log_window(&app);
}

/// Open a native OS file-picker filtered to EPUB/PDF.
/// Returns the list of selected absolute paths (empty if cancelled).
#[tauri::command]
async fn pick_books(window: tauri::WebviewWindow) -> Vec<String> {
    let (tx, rx) = tokio::sync::oneshot::channel::<Vec<String>>();
    window
        .dialog()
        .file()
        .add_filter("Books", &["epub", "pdf", "EPUB", "PDF"])
        .set_title("Open Books")
        .pick_files(move |result| {
            let paths = result
                .unwrap_or_default()
                .into_iter()
                .flat_map(|p| p.into_path().ok())
                .filter_map(|p| p.to_str().map(String::from))
                .collect();
            let _ = tx.send(paths);
        });
    rx.await.unwrap_or_default()
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
    let check_update =
        MenuItem::with_id(h, "check_update", "Check for Updates…", true, None::<&str>)?;

    // Theme submenu
    let theme_auto = CheckMenuItem::with_id(h, "theme_auto", "Auto", true, true, None::<&str>)?;
    let theme_light =
        CheckMenuItem::with_id(h, "theme_light", "Light", true, false, None::<&str>)?;
    let theme_dark =
        CheckMenuItem::with_id(h, "theme_dark", "Dark", true, false, None::<&str>)?;
    let theme_sub = Submenu::with_items(
        h,
        "Theme",
        true,
        &[&theme_auto, &theme_light, &theme_dark],
    )?;

    // Language submenu
    let lang_auto = CheckMenuItem::with_id(h, "lang_auto", "Auto", true, true, None::<&str>)?;
    let lang_pt =
        CheckMenuItem::with_id(h, "lang_pt", "Português", true, false, None::<&str>)?;
    let lang_en = CheckMenuItem::with_id(h, "lang_en", "English", true, false, None::<&str>)?;
    let lang_sub =
        Submenu::with_items(h, "Language", true, &[&lang_auto, &lang_pt, &lang_en])?;

    let view = Submenu::with_items(
        h,
        "View",
        true,
        &[
            &logs,
            &PredefinedMenuItem::separator(h)?,
            &theme_sub,
            &lang_sub,
        ],
    )?;

    #[cfg(target_os = "macos")]
    let menu = {
        let app_sub = Submenu::with_items(
            h,
            "Epub to Mp3",
            true,
            &[
                &PredefinedMenuItem::about(h, None, None)?,
                &check_update,
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
        let help_sub = Submenu::with_items(h, "Help", true, &[&check_update])?;
        Menu::with_items(h, &[&file_sub, &view, &help_sub])?
    };

    Ok(menu)
}

// ── Entry point ───────────────────────────────────────────────────────────────

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_window_state::Builder::new().build())
        .manage(ServerLogs(Mutex::new(Vec::new())))
        .invoke_handler(tauri::generate_handler![
            get_server_logs,
            open_log_window,
            pick_books,
        ])
        .setup(|app| {
            // ── Menu bar ──────────────────────────────────────────────────────
            let menu = build_menu(app)?;
            app.set_menu(menu)?;

            app.on_menu_event(|app_handle, event| {
                let id = event.id().0.as_str();
                match id {
                    // File > Open Books…
                    "open_books" => {
                        if let Some(win) = app_handle.get_webview_window("main") {
                            let _ = win.emit("tauri-open-books", ());
                        }
                    }
                    // View > Server Logs
                    "show_logs" => show_log_window(app_handle),

                    // Check for Updates
                    "check_update" => {
                        if let Some(win) = app_handle.get_webview_window("main") {
                            let _ = win.emit("tauri-check-update", ());
                        }
                    }

                    // View > Theme
                    "theme_auto" | "theme_light" | "theme_dark" => {
                        let value = id.strip_prefix("theme_").unwrap_or("auto");
                        // Uncheck siblings, check selected
                        for tid in ["theme_auto", "theme_light", "theme_dark"] {
                            if let Some(item) = app_handle.menu().and_then(|m| m.get(tid)) {
                                {
                    let check = item.as_check_menuitem_unchecked();
                                    let _ = check.set_checked(tid == id);
                                }
                            }
                        }
                        if let Some(win) = app_handle.get_webview_window("main") {
                            let _ = win.emit("tauri-set-theme", value);
                        }
                    }

                    // View > Language
                    "lang_auto" | "lang_pt" | "lang_en" => {
                        let value = id.strip_prefix("lang_").unwrap_or("auto");
                        for lid in ["lang_auto", "lang_pt", "lang_en"] {
                            if let Some(item) = app_handle.menu().and_then(|m| m.get(lid)) {
                                {
                    let check = item.as_check_menuitem_unchecked();
                                    let _ = check.set_checked(lid == id);
                                }
                            }
                        }
                        if let Some(win) = app_handle.get_webview_window("main") {
                            let _ = win.emit("tauri-set-locale", value);
                        }
                    }

                    _ => {}
                }
            });

            // ── Auto-update check (background) ────────────────────────────────
            let update_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                // Delay 3s so the window can load first
                tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;
                if let Ok(updater) = update_handle.updater() {
                    match updater.check().await {
                        Ok(Some(update)) => {
                            if let Some(win) = update_handle.get_webview_window("main") {
                                let _ = win.emit(
                                    "tauri-update-available",
                                    serde_json::json!({
                                        "version": update.version,
                                        "body": update.body.clone().unwrap_or_default(),
                                    }),
                                );
                            }
                        }
                        Ok(None) => {} // already up to date
                        Err(_) => {}   // network error, ignore silently
                    }
                }
            });

            // ── Sidecar startup ───────────────────────────────────────────────
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.hide();
            }

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                /// Push a status line to the persistent log buffer and stream it
                /// to the frontend window in real time.
                fn push_log(handle: &AppHandle, line: &str) {
                    if let Some(logs) = handle.try_state::<ServerLogs>() {
                        let mut v = logs.0.lock().unwrap();
                        v.push(line.to_string());
                        let len = v.len();
                        if len > 2000 {
                            v.drain(0..len - 2000);
                        }
                    }
                    if let Some(win) = handle.get_webview_window("main") {
                        let _ = win.emit("tauri-server-log", line);
                    }
                }

                // If server is already running (leftover from previous launch), skip spawn.
                let port_in_use = tokio::net::TcpStream::connect(
                    format!("127.0.0.1:{SERVER_PORT}"),
                )
                .await
                .is_ok();

                let spawn_result = if port_in_use {
                    push_log(&handle, "Server already running — reconnecting.");
                    // Reuse the existing server — skip spawning a new sidecar.
                    Ok(None)
                } else {
                    push_log(&handle, "Starting conversion server…");
                    handle
                        .shell()
                        .sidecar("epub-to-mp3-server")
                        .map_err(|e| e.to_string())
                        .and_then(|cmd| cmd.spawn().map_err(|e| e.to_string()))
                        .map(Some)
                        .map_err(|e| e)
                };

                // Forward sidecar stdout/stderr (only when we spawned a new sidecar).
                match spawn_result {
                    Ok(Some((mut rx, _child))) => {
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
                                push_log(&log_handle, &line);
                            }
                        });
                    }
                    Ok(None) => {
                        // Port already in use — existing server is running.
                    }
                    Err(err) => {
                        if let Some(win) = handle.get_webview_window("main") {
                            let _ = win.show();
                            let _ = win.emit("tauri-startup-error", &err);
                        }
                        return;
                    }
                }

                // Show window early so user sees loading state.
                if let Some(win) = handle.get_webview_window("main") {
                    let _ = win.show();
                    let _ = win.set_focus();
                }

                // Poll TCP; emit loading events every LOADING_NOTIFY_INTERVAL_S.
                let addr = format!("127.0.0.1:{SERVER_PORT}");
                let deadline = tokio::time::Instant::now()
                    + tokio::time::Duration::from_secs(POLL_TIMEOUT_S);
                let mut last_notify = tokio::time::Instant::now();
                let mut ready = false;
                loop {
                    if tokio::time::Instant::now() >= deadline {
                        break;
                    }
                    if tokio::net::TcpStream::connect(&addr).await.is_ok() {
                        ready = true;
                        break;
                    }
                    if last_notify.elapsed().as_secs() >= LOADING_NOTIFY_INTERVAL_S {
                        let elapsed = POLL_TIMEOUT_S
                            - deadline
                                .saturating_duration_since(tokio::time::Instant::now())
                                .as_secs();
                        if let Some(win) = handle.get_webview_window("main") {
                            let _ = win.emit("tauri-startup-loading", elapsed);
                        }
                        push_log(
                            &handle,
                            &format!("Still starting… ({elapsed}s elapsed, first launch unpacks dependencies)"),
                        );
                        last_notify = tokio::time::Instant::now();
                    }
                    tokio::time::sleep(tokio::time::Duration::from_millis(POLL_INTERVAL_MS)).await;
                }

                if let Some(win) = handle.get_webview_window("main") {
                    if ready {
                        let _ = win.emit("tauri-startup-ready", ());
                    } else {
                        let _ = win.emit("tauri-startup-timeout", ());
                    }
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
