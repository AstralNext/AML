use anyhow::Result;
use std::io::Cursor;
use std::path::Path;
use zip::ZipArchive;

use crate::launcher::download::ProgressFn;
use crate::state::db;
use crate::state::models::{CreateInstanceRequest, InstallStage, Instance, ModLoader};
use crate::state::try_state;

use super::detect::read_zip_entry;

pub(super) async fn install_mrpack_zip(
    data: &[u8],
    path: &Path,
    pack_path: &str,
    name: Option<String>,
    java_path: Option<String>,
    resume_instance_id: Option<&str>,
    on_progress: Option<ProgressFn>,
) -> Result<Instance> {
    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    let state = try_state()?;
    let created = if let Some(id) = resume_instance_id {
        report(0.08, format!("Resuming instance {id}…"));
        report(0.08, format!("__INSTANCE_CREATED__:{id}"));
        db::set_install_stage(&state.pool, id, InstallStage::Installing).await?;
        db::get_instance(&state.pool, id).await?
    } else {
        let mut archive = ZipArchive::new(Cursor::new(data))?;
        let text = read_zip_entry(&mut archive, "modrinth.index.json")?;
        let v: serde_json::Value = serde_json::from_str(&text)?;
        let pack_name = name.or_else(|| {
            v.get("name")
                .and_then(|x| x.as_str())
                .map(|s| s.to_string())
        });
        let deps = v.get("dependencies").cloned().unwrap_or_default();
        let game_version = deps
            .get("minecraft")
            .and_then(|x| x.as_str())
            .unwrap_or("1.20.1")
            .to_string();
        let (loader, loader_version) = if let Some(v) = deps.get("fabric-loader") {
            (ModLoader::Fabric, v.as_str().map(|s| s.to_string()))
        } else if let Some(v) = deps.get("quilt-loader") {
            (ModLoader::Quilt, v.as_str().map(|s| s.to_string()))
        } else if let Some(v) = deps.get("forge") {
            (ModLoader::Forge, v.as_str().map(|s| s.to_string()))
        } else if let Some(v) = deps.get("neoforge").or_else(|| deps.get("neo-forge")) {
            (ModLoader::NeoForge, v.as_str().map(|s| s.to_string()))
        } else {
            (ModLoader::Vanilla, None)
        };

        let created = db::create_instance(
            &state.pool,
            CreateInstanceRequest {
                name: pack_name.unwrap_or_else(|| {
                    path.file_stem()
                        .map(|s| s.to_string_lossy().into_owned())
                        .unwrap_or_else(|| "Imported Pack".into())
                }),
                game_version,
                loader,
                loader_version,
                icon: None,
            },
        )
        .await?;
        report(0.08, format!("__INSTANCE_CREATED__:{}", created.id));
        created
    };
    let install_result = super::super::content::install_mrpack(
        &created.id,
        pack_path,
        java_path,
        on_progress,
    )
    .await;
    if let Err(e) = install_result {
        let _ = db::set_install_stage(&state.pool, &created.id, InstallStage::Failed).await;
        return Err(e);
    }
    db::get_instance(&state.pool, &created.id).await
}
