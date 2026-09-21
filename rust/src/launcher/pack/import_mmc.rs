use anyhow::Result;
use std::path::{Path, PathBuf};

use crate::launcher::dirs;
use crate::launcher::download::ProgressFn;
use crate::launcher::install;
use crate::launcher::progress;
use crate::state::db;
use crate::state::models::{CreateInstanceRequest, InstallStage, Instance};
use crate::state::{resource_dir, try_state};

use super::mmc::{extract_mmc_minecraft, read_mmc_meta_from_dir, read_mmc_meta_from_zip};

pub(super) async fn install_multimc_zip(
    data: &[u8],
    name: Option<String>,
    java_path: Option<String>,
    on_progress: Option<ProgressFn>,
    resume_instance_id: Option<&str>,
) -> Result<Instance> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    let meta = read_mmc_meta_from_zip(data)?;
    let instance_name = name.unwrap_or_else(|| meta.name.clone());
    let created = if let Some(id) = resume_instance_id {
        report(0.08, format!("Resuming instance {id}…"));
        report(0.10, format!("__INSTANCE_CREATED__:{id}"));
        db::set_install_stage(&state.pool, id, InstallStage::Installing).await?;
        db::get_instance(&state.pool, id).await?
    } else {
        report(0.08, format!("Creating instance {instance_name}…"));
        let created = db::create_instance(
            &state.pool,
            CreateInstanceRequest {
                name: instance_name.clone(),
                game_version: meta.game_version.clone(),
                loader: meta.loader,
                loader_version: meta.loader_version.clone(),
                icon: None,
            },
        )
        .await?;
        report(0.10, format!("__INSTANCE_CREATED__:{}", created.id));
        db::set_install_stage(&state.pool, &created.id, InstallStage::Installing).await?;
        created
    };
    let instance_dir = dirs::ensure_instance_dir(&resource, &created.path).await?;

    report(0.20, "Copying instance files…".into());
    extract_mmc_minecraft(data, &instance_dir, &meta.minecraft_prefix)?;

    report(0.78, "Installing Minecraft + loader…".into());
    install::install_instance(
        &created.id,
        java_path,
        false,
        progress::nest_progress(
            on_progress.clone(),
            0.78,
            0.95,
            "Installing Minecraft + loader",
        ),
    )
    .await?;
    report(0.95, "Indexing installed content…".into());
    let _ = crate::launcher::content::sync_instance_content_metadata(&created.id, false).await;
    let _ = db::set_instance_modpack_link(
        &state.pool,
        &created.id,
        None,
        None,
        None,
        Some("multimc"),
        Some(&instance_name),
    )
    .await;
    report(1.0, "Modpack installed".into());
    db::get_instance(&state.pool, &created.id).await
}

/// Import a MultiMC instance folder into a new AML instance.
pub async fn create_instance_from_mmc_folder(
    instance_folder: &str,
    name: Option<String>,
    java_path: Option<String>,
    on_progress: Option<ProgressFn>,
) -> Result<Instance> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };
    let folder = PathBuf::from(instance_folder);
    let (meta, minecraft_dir) = read_mmc_meta_from_dir(&folder)?;
    let instance_name = name.unwrap_or_else(|| meta.name.clone());
    report(0.08, format!("Creating instance {instance_name}…"));
    let created = db::create_instance(
        &state.pool,
        CreateInstanceRequest {
            name: instance_name.clone(),
            game_version: meta.game_version,
            loader: meta.loader,
            loader_version: meta.loader_version,
            icon: None,
        },
    )
    .await?;
    report(0.10, format!("__INSTANCE_CREATED__:{}", created.id));
    let instance_dir = dirs::ensure_instance_dir(&resource, &created.path).await?;
    report(0.20, "Copying instance files…".into());
    copy_dir_recursive(&minecraft_dir, &instance_dir).await?;
    report(0.78, "Installing Minecraft + loader…".into());
    install::install_instance(
        &created.id,
        java_path,
        false,
        progress::nest_progress(
            on_progress.clone(),
            0.78,
            0.95,
            "Installing Minecraft + loader",
        ),
    )
    .await?;
    let _ = crate::launcher::content::sync_instance_content_metadata(&created.id, false).await;
    let _ = db::set_instance_modpack_link(
        &state.pool,
        &created.id,
        None,
        None,
        None,
        Some("multimc"),
        Some(&instance_name),
    )
    .await;
    report(1.0, "Modpack installed".into());
    db::get_instance(&state.pool, &created.id).await
}

async fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    tokio::fs::create_dir_all(dst).await?;
    let mut stack = vec![src.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let mut rd = tokio::fs::read_dir(&dir).await?;
        while let Some(entry) = rd.next_entry().await? {
            let path = entry.path();
            let rel = path.strip_prefix(src).unwrap_or(&path);
            let target = dst.join(rel);
            if entry.file_type().await?.is_dir() {
                tokio::fs::create_dir_all(&target).await?;
                stack.push(path);
            } else {
                if let Some(parent) = target.parent() {
                    tokio::fs::create_dir_all(parent).await?;
                }
                tokio::fs::copy(&path, &target).await?;
            }
        }
    }
    Ok(())
}
