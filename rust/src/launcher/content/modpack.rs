//! Modrinth modpack lifecycle: create-from-modpack, unlink, reinstall-or-switch.

use anyhow::{anyhow, Context, Result};
use std::io::Read;
use std::path::PathBuf;

use zip::ZipArchive;

use super::modrinth::{fetch_project_info, fetch_version};
use super::mrpack::{install_mrpack, MrpackIndex};
use crate::launcher::dirs;
use crate::launcher::download::{self, ProgressFn};
use crate::launcher::icons;
use crate::launcher::manifest;
use crate::launcher::progress;
use crate::state::db;
use crate::state::models::{CreateInstanceRequest, InstallStage, Instance, ModLoader};
use crate::state::{resource_dir, try_state};

/// Installing a modpack creates a **new** instance, or resumes an existing one.
pub async fn create_instance_from_modrinth_modpack(
    version_id: &str,
    name: Option<String>,
    java_path: Option<String>,
    resume_instance_id: Option<&str>,
    on_progress: Option<ProgressFn>,
) -> Result<Instance> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let client = manifest::http_client()?;

    let progress_cb = on_progress.clone();
    let report = move |p: f64, msg: String| {
        if let Some(cb) = &progress_cb {
            cb(p, msg);
        }
    };

    report(0.02, format!("Fetching modpack version {version_id}…"));
    let version = fetch_version(&client, version_id).await?;
    let project = fetch_project_info(&client, &version.project_id).await.ok();

    let file = version
        .files
        .iter()
        .find(|f| f.primary.unwrap_or(false))
        .or_else(|| {
            version
                .files
                .iter()
                .find(|f| f.filename.to_lowercase().ends_with(".mrpack"))
        })
        .or_else(|| version.files.first())
        .ok_or_else(|| anyhow!("modpack version has no files"))?
        .clone();

    if !file.filename.to_lowercase().ends_with(".mrpack") {
        anyhow::bail!(
            "selected file is not an .mrpack ({}); cannot create modpack instance",
            file.filename
        );
    }

    let cache_dir = PathBuf::from(&resource).join("cache").join("mrpacks");
    tokio::fs::create_dir_all(&cache_dir).await?;
    let mrpack_path = cache_dir.join(format!("{version_id}.mrpack"));

    if download::file_already_ok(&mrpack_path, None).await {
        report(0.08, format!("Using cached {}…", file.filename));
    } else {
        report(0.08, format!("Downloading {}…", file.filename));
        let on_bytes = on_progress.clone().map(|cb| {
            progress::file_bytes_cb(cb, "Downloading pack", file.filename.clone(), 0.05, 0.28)
        });
        download::download_to_path_with_mcim_fallback(
            &client,
            &file.url,
            &mrpack_path,
            None,
            None,
            on_bytes,
        )
        .await?;
    }

    let pack_meta = {
        let pack_file = std::fs::File::open(&mrpack_path)
            .with_context(|| format!("open {}", mrpack_path.display()))?;
        let mut archive = ZipArchive::new(pack_file)?;
        let mut index_file = archive.by_name("modrinth.index.json")?;
        let mut text = String::new();
        index_file.read_to_string(&mut text)?;
        let index: MrpackIndex = serde_json::from_str(&text)?;
        let name = index
            .name
            .or_else(|| project.as_ref().map(|p| p.title.clone()))
            .unwrap_or_else(|| version.name.clone());
        let loader = if let Some(v) = &index.dependencies.fabric_loader {
            (ModLoader::Fabric, Some(v.clone()))
        } else if let Some(v) = &index.dependencies.quilt_loader {
            (ModLoader::Quilt, Some(v.clone()))
        } else if let Some(v) = &index.dependencies.forge {
            (ModLoader::Forge, Some(v.clone()))
        } else if let Some(v) = &index.dependencies.neoforge {
            (ModLoader::NeoForge, Some(v.clone()))
        } else {
            (ModLoader::Vanilla, None)
        };
        (name, index.dependencies.minecraft.clone(), loader)
    };

    let instance_name = name.unwrap_or(pack_meta.0);
    let game_version = pack_meta.1;
    let (loader, loader_version_raw) = pack_meta.2;
    let resolved_loader = manifest::resolve_loader_meta_id_or_fallback(
        &resource,
        &game_version,
        &loader,
        loader_version_raw.clone(),
    )
    .await;

    let icon = if let Some(url) = project.as_ref().and_then(|p| p.icon_url.as_deref()) {
        icons::resolve_icon_source(&resource, url)
            .await
            .ok()
            .flatten()
    } else {
        None
    };

    let created = if let Some(id) = resume_instance_id {
        report(0.12, format!("Resuming instance {id}…"));
        db::set_install_stage(&state.pool, id, InstallStage::Installing).await?;
        report(0.13, format!("__INSTANCE_CREATED__:{id}"));
        db::get_instance(&state.pool, id).await?
    } else {
        report(0.12, format!("Creating instance {instance_name}…"));
        let created = db::create_instance(
            &state.pool,
            CreateInstanceRequest {
                name: instance_name,
                game_version,
                loader,
                loader_version: resolved_loader,
                icon,
            },
        )
        .await?;
        dirs::ensure_instance_dir(&resource, &created.path).await?;
        db::set_install_stage(&state.pool, &created.id, InstallStage::Installing).await?;
        // Dart listens for this marker to refresh Library and show avatar+spinner.
        report(0.13, format!("__INSTANCE_CREATED__:{}", created.id));
        created
    };

    let install_result = install_mrpack(
        &created.id,
        &mrpack_path.to_string_lossy(),
        java_path,
        progress::nest_progress(on_progress, 0.30, 1.0, "Installing modpack"),
    )
    .await;

    if let Err(e) = install_result {
        let detail = format!("{e:#}");
        eprintln!(
            "[AML] Modpack install failed (instance {}): {detail}",
            created.id
        );
        report(0.99, format!("安装失败: {detail}"));
        // Keep the instance: user can retry from Library / instance detail.
        let _ = db::set_install_stage(&state.pool, &created.id, InstallStage::Failed).await;
        return Err(e);
    }

    let title = project
        .as_ref()
        .map(|p| p.title.clone())
        .unwrap_or_else(|| version.name.clone());
    let _ = db::set_instance_modpack_link(
        &state.pool,
        &created.id,
        Some(&version.project_id),
        Some(version_id),
        version.version_number.as_deref(),
        Some("modrinth"),
        Some(&title),
    )
    .await?;

    db::get_instance(&state.pool, &created.id).await
}

/// Clear modpack association without deleting installed files.
pub async fn unlink_modpack(instance_id: &str) -> Result<Instance> {
    let state = try_state()?;
    db::unlink_instance_modpack(&state.pool, instance_id).await
}

/// Reinstall the currently linked Modrinth modpack version (or an explicit version).
pub async fn reinstall_or_switch_modpack(
    instance_id: &str,
    version_id: Option<&str>,
    java_path: Option<String>,
    on_progress: Option<ProgressFn>,
) -> Result<Instance> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let target_version = version_id
        .map(str::to_string)
        .or(instance.modpack_version_id.clone())
        .ok_or_else(|| anyhow!("实例未关联整合包版本"))?;
    if instance.modpack_source.as_deref() == Some("file") && version_id.is_none() {
        anyhow::bail!("文件导入的整合包不支持重装，请重新导入 .mrpack 文件");
    }

    let client = manifest::http_client()?;
    let progress_cb = on_progress.clone();
    let report = move |p: f64, msg: String| {
        if let Some(cb) = &progress_cb {
            cb(p, msg);
        }
    };

    report(0.02, format!("Fetching modpack version {target_version}…"));
    let version = fetch_version(&client, &target_version).await?;
    let project = fetch_project_info(&client, &version.project_id).await.ok();
    let file = version
        .files
        .iter()
        .find(|f| f.primary.unwrap_or(false))
        .or_else(|| {
            version
                .files
                .iter()
                .find(|f| f.filename.to_lowercase().ends_with(".mrpack"))
        })
        .or_else(|| version.files.first())
        .ok_or_else(|| anyhow!("modpack version has no files"))?
        .clone();
    if !file.filename.to_lowercase().ends_with(".mrpack") {
        anyhow::bail!("selected file is not an .mrpack ({})", file.filename);
    }

    report(0.08, format!("Downloading {}…", file.filename));
    let cache_dir = PathBuf::from(&resource).join("cache").join("mrpacks");
    tokio::fs::create_dir_all(&cache_dir).await?;
    let mrpack_path = cache_dir.join(format!("{target_version}.mrpack"));
    if download::file_already_ok(&mrpack_path, None).await {
        report(0.08, format!("Using cached {}…", file.filename));
    } else {
        let on_bytes = on_progress.clone().map(|cb| {
            progress::file_bytes_cb(cb, "Downloading pack", file.filename.clone(), 0.05, 0.28)
        });
        download::download_to_path_with_mcim_fallback(
            &client,
            &file.url,
            &mrpack_path,
            None,
            None,
            on_bytes,
        )
        .await?;
    }

    db::set_install_stage(&state.pool, instance_id, InstallStage::Installing).await?;
    let install_result = install_mrpack(
        instance_id,
        &mrpack_path.to_string_lossy(),
        java_path,
        progress::nest_progress(on_progress, 0.30, 1.0, "Installing modpack"),
    )
    .await;
    if let Err(e) = install_result {
        let _ = db::set_install_stage(&state.pool, instance_id, InstallStage::Failed).await;
        return Err(e);
    }

    let title = project
        .as_ref()
        .map(|p| p.title.clone())
        .or(instance.modpack_title.clone())
        .unwrap_or_else(|| version.name.clone());
    db::set_instance_modpack_link(
        &state.pool,
        instance_id,
        Some(&version.project_id),
        Some(&target_version),
        version.version_number.as_deref(),
        Some("modrinth"),
        Some(&title),
    )
    .await?;
    db::set_install_stage(&state.pool, instance_id, InstallStage::Installed).await?;
    db::get_instance(&state.pool, instance_id).await
}
