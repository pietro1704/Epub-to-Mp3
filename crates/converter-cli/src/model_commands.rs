//! Explicit installed-model listing, installation and confirmed removal commands.
use super::cli_environment::cli_config;
use std::fs;

pub(super) fn command_models(raw: &[String]) -> Result<i32, String> {
    let config = cli_config();
    let root = config.paths.models_dir.join("tts");
    match raw.get(1).map(String::as_str).unwrap_or("list") {
        "catalog" => println!("{}", converter_core::tts_session::catalog_json()),
        "list" => {
            for model in converter_core::model_catalog::MODELS
                .iter()
                .filter(|m| !m.artifacts.is_empty())
            {
                println!(
                    "{}\t{} bytes\t{}",
                    model.id,
                    model.download_bytes,
                    if converter_core::model_store::ModelStore::new(root.clone())
                        .is_manifest_installed(
                            &converter_core::model_store::ModelStore::catalog_manifest(model.id)
                                .map_err(|error| error.to_string())?
                        )
                        .map_err(|error| error.to_string())?
                    {
                        "installed"
                    } else {
                        "not installed"
                    }
                );
            }
        }
        "install" => {
            let id = raw.get(2).ok_or("Usage: models install MODEL_ID")?;
            let manifest = converter_core::model_store::ModelStore::catalog_manifest(id)
                .map_err(|e| e.to_string())?;
            tokio::runtime::Runtime::new()
                .map_err(|e| e.to_string())?
                .block_on(
                    converter_core::model_store::ModelStore::new(root).install_manifest(&manifest),
                )
                .map_err(|e| e.to_string())?;
            println!("Installed {id}");
        }
        "remove" => {
            let id = raw.get(2).ok_or("Usage: models remove MODEL_ID --yes")?;
            if !raw.iter().any(|v| v == "--yes" || v == "-y") {
                return Err("Model removal requires --yes".into());
            }
            converter_core::model_store::ModelStore::catalog_manifest(id)
                .map_err(|e| e.to_string())?;
            let path = root.join(id);
            if path.exists() {
                fs::remove_dir_all(path).map_err(|e| e.to_string())?;
            }
        }
        _ => return Err("Usage: models list | install MODEL_ID | remove MODEL_ID --yes".into()),
    }
    Ok(0)
}
