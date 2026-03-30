use tauri::Manager;
use tauri_plugin_shell::ShellExt;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            let handle = app.handle().clone();

            // Spawn the Python backend sidecar in a background task.
            // Tauri will kill it automatically when the app exits.
            tauri::async_runtime::spawn(async move {
                handle
                    .shell()
                    .sidecar("epub-to-mp3-server")
                    .expect("sidecar 'epub-to-mp3-server' not found in binaries/")
                    .spawn()
                    .expect("failed to spawn Python backend sidecar");
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
