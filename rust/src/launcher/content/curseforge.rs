//! CurseForge file + modpack installation.

use anyhow::Result;
use serde::Deserialize;
use std::path::PathBuf;

use super::types::ContentType;
use crate::config::curseforge_api_url;
use crate::launcher::dirs;
use crate::launcher::download::{self, ProgressFn};
use crate::launcher::icons;
use crate::launcher::manifest;
use crate::launcher::mcim_fallback;
use crate::launcher::pack;
use crate::launcher::progress;
use crate::state::db;
use crate::state::models::Instance;
use crate::state::{resource_dir, try_state};

#[derive(Deserialize)]
struct CfApiEnvelope<T> {
    data: T,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CfModInfo {
    id: u64,
    name: String,
    #[serde(default)]
    logo: Option<CfLogo>,
    #[serde(default)]
    authors: Vec<CfAuthor>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CfLogo {
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    thumbnail_url: Option<String>,
}

#[derive(Deserialize)]
struct CfAuthor {
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CfFileInfo {
    id: u64,
    #[serde(default)]
    mod_id: Option<u64>,
    file_name: String,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    download_url: Option<String>,
}

/// Install a CurseForge file into an instance (mod / resourcepack / shader / datapack).
pub async fn install_curseforge_file(
    instance_id: &str,
    mod_id: u64,
    file_id: u64,
    project_type: Option<&str>,
    on_progress: Option<ProgressFn>,
) -> Result<String> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::ensure_instance_dir(&resource, &instance.path).await?;
    let client = manifest::http_client()?;
    let content_type = ContentType::parse(project_type);
    let project_key = format!("cf:{mod_id}");
    let version_key = file_id.to_string();

    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    // Skip when this exact CF file is already on disk for the project.
    let existing = db::list_content_by_project(&state.pool, instance_id, &project_key).await?;
    if let Some(hit) = existing.iter().find(|e| {
        e.version_id.as_deref() == Some(version_key.as_str())
            && !e.pending
            && instance_dir.join(&e.relative_path).is_file()
    }) {
        report(
            1.0,
            format!("Already installed ({})", hit.relative_path),
        );
        return Ok(instance_dir
            .join(&hit.relative_path)
            .to_string_lossy()
            .into());
    }

    report(0.05, format!("Fetching CurseForge file {file_id}…"));
    let key = pack::curseforge_api_key();
    let headers = [("x-api-key", key.as_str()), ("Accept", "application/json")];
    let file_url = format!("{}/v1/mods/{mod_id}/files/{file_id}", curseforge_api_url());
    let file: CfFileInfo = mcim_fallback::client_get_json_with_headers::<CfApiEnvelope<CfFileInfo>>(
        &client,
        &file_url,
        Some(&headers),
    )
    .await?
    .data;

    let mod_url = format!("{}/v1/mods/{mod_id}", curseforge_api_url());
    let mod_info: Option<CfModInfo> =
        mcim_fallback::client_get_json_with_headers::<CfApiEnvelope<CfModInfo>>(
            &client,
            &mod_url,
            Some(&headers),
        )
        .await
        .ok()
        .map(|e| e.data);

    let download_url = file
        .download_url
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| {
            format!(
                "https://www.curseforge.com/api/v1/mods/{mod_id}/files/{file_id}/download"
            )
        });

    report(0.2, format!("Downloading {}…", file.file_name));
    let on_bytes = on_progress.clone().map(|cb| {
        progress::file_bytes_cb(cb, "Downloading", file.file_name.clone(), 0.2, 0.9)
    });
    let bytes = pack::download_cf_file(&download_url, on_bytes).await?;
    let sha1 = download::sha1_hex(&bytes);

    // Replace older versions of the same CF project.
    for old in &existing {
        let old_path = instance_dir.join(&old.relative_path);
        let disabled = instance_dir.join(format!("{}.disabled", old.relative_path));
        let _ = tokio::fs::remove_file(&old_path).await;
        let _ = tokio::fs::remove_file(&disabled).await;
        db::remove_content_entry(&state.pool, instance_id, &old.relative_path).await?;
    }

    let dest = instance_dir
        .join(content_type.folder())
        .join(&file.file_name);
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    tokio::fs::write(&dest, &bytes).await?;

    let relative = format!("{}/{}", content_type.folder(), file.file_name);
    let now = chrono::Utc::now().to_rfc3339();
    let author = mod_info
        .as_ref()
        .and_then(|m| m.authors.first())
        .and_then(|a| a.name.clone());
    let icon = mod_info.as_ref().and_then(|m| {
        m.logo
            .as_ref()
            .and_then(|l| l.thumbnail_url.clone().or_else(|| l.url.clone()))
    });
    let title = mod_info.as_ref().map(|m| m.name.clone());
    let version_name = file
        .display_name
        .clone()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| file.file_name.clone());

    let entry = db::ContentEntry {
        id: format!("content:{}", uuid::Uuid::new_v4()),
        instance_id: instance_id.to_string(),
        relative_path: relative,
        file_name: file.file_name.clone(),
        project_type: match content_type {
            ContentType::Mod => "mod",
            ContentType::ResourcePack => "resourcepack",
            ContentType::Shader => "shader",
            ContentType::DataPack => "datapack",
        }
        .into(),
        project_id: Some(project_key),
        version_id: Some(version_key),
        version_number: Some(file.file_name.clone()),
        version_name: Some(version_name),
        project_title: title,
        project_icon_url: icon,
        author,
        author_avatar_url: None,
        author_id: None,
        author_type: Some("user".into()),
        update_version_id: None,
        enabled: true,
        sha1: Some(sha1),
        size_bytes: Some(bytes.len() as i64),
        added_at: now,
        pending: false,
        download_url: None,
    };
    db::upsert_content_entry(&state.pool, &entry).await?;
    report(1.0, format!("Installed {}", file.file_name));
    Ok(dest.to_string_lossy().to_string())
}

/// Download a CurseForge modpack zip and import it as a new instance (or resume).
pub async fn create_instance_from_curseforge_modpack(
    mod_id: u64,
    file_id: u64,
    name: Option<String>,
    java_path: Option<String>,
    resume_instance_id: Option<&str>,
    on_progress: Option<ProgressFn>,
) -> Result<Instance> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let client = manifest::http_client()?;
    let key = pack::curseforge_api_key();

    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    report(0.05, format!("Fetching CurseForge modpack file {file_id}…"));
    let headers = [("x-api-key", key.as_str()), ("Accept", "application/json")];
    let file_url = format!("{}/v1/mods/{mod_id}/files/{file_id}", curseforge_api_url());
    let file: CfFileInfo = mcim_fallback::client_get_json_with_headers::<CfApiEnvelope<CfFileInfo>>(
        &client,
        &file_url,
        Some(&headers),
    )
    .await?
    .data;

    let mod_url = format!("{}/v1/mods/{mod_id}", curseforge_api_url());
    let mod_info: Option<CfModInfo> =
        mcim_fallback::client_get_json_with_headers::<CfApiEnvelope<CfModInfo>>(
            &client,
            &mod_url,
            Some(&headers),
        )
        .await
        .ok()
        .map(|e| e.data);

    let project_icon_url = mod_info.as_ref().and_then(|m| {
        m.logo
            .as_ref()
            .and_then(|l| l.url.clone().or_else(|| l.thumbnail_url.clone()))
    });
    let project_title = mod_info.as_ref().map(|m| m.name.clone());

    let download_url = file
        .download_url
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| {
            format!(
                "https://www.curseforge.com/api/v1/mods/{mod_id}/files/{file_id}/download"
            )
        });

    let cache_dir = PathBuf::from(&resource).join("cache").join("cfpacks");
    tokio::fs::create_dir_all(&cache_dir).await?;
    let pack_path = cache_dir.join(format!("{mod_id}_{file_id}.zip"));

    if download::file_already_ok(&pack_path, None).await {
        report(0.15, format!("Using cached {}…", file.file_name));
    } else {
        report(0.15, format!("Downloading {}…", file.file_name));
        let on_bytes = on_progress.clone().map(|cb| {
            progress::file_bytes_cb(cb, "Downloading pack", file.file_name.clone(), 0.05, 0.35)
        });
        pack::download_cf_file_to_path(&download_url, &pack_path, on_bytes).await?;
    }

    report(0.35, "Importing CurseForge modpack…".into());
    let instance_name = name.or_else(|| project_title.clone());
    let mut created = pack::create_instance_from_pack_file_resumable(
        pack_path.to_string_lossy().as_ref(),
        instance_name,
        java_path,
        resume_instance_id,
        progress::nest_progress(on_progress, 0.35, 1.0, "Installing modpack"),
    )
    .await?;

    // CF zips rarely include icon.png ? use project logo when instance has none.
    let needs_icon = created
        .icon
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .is_none();
    if needs_icon {
        if let Some(url) = project_icon_url.as_deref() {
            if let Ok(Some(cached)) = icons::resolve_icon_source(&resource, url).await {
                let instance_dir = dirs::instance_dir(&resource, &created.path);
                let pack_icon = instance_dir.join("icon.png");
                if !pack_icon.exists() {
                    if let Ok(bytes) = tokio::fs::read(&cached).await {
                        let _ = tokio::fs::write(&pack_icon, &bytes).await;
                    }
                }
                let _ = icons::set_instance_icon(&state.pool, &created.id, Some(cached)).await;
            }
        }
    }

    let version_label = file
        .display_name
        .clone()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| file.file_name.clone());
    let title = project_title.unwrap_or_else(|| created.name.clone());
    let _ = db::set_instance_modpack_link(
        &state.pool,
        &created.id,
        Some(&format!("cf:{mod_id}")),
        Some(&file_id.to_string()),
        Some(&version_label),
        Some("curseforge"),
        Some(&title),
    )
    .await;

    created = db::get_instance(&state.pool, &created.id).await?;
    Ok(created)
}
