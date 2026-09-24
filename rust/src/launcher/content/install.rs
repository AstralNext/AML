//! Modrinth content installation: single version, recursive required deps,
//! and re-download of missing pack files.

use anyhow::{anyhow, Context, Result};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

use super::curseforge::install_curseforge_file;
use super::matching::select_compatible_version;
use super::modrinth::{
    fetch_org, fetch_project_info, fetch_project_versions, fetch_team_owner, fetch_version,
    ModrinthProjectInfo, ModrinthVersion,
};
use super::types::ContentType;
use crate::launcher::dirs;
use crate::launcher::download::{self, ProgressFn};
use crate::launcher::manifest;
use crate::launcher::progress;
use crate::state::db;
use crate::state::models::Instance;
use crate::state::{resource_dir, try_state};

const QUILT_FABRIC_API_EXCEPTION: &str = "P7dR8mSH";

pub async fn install_modrinth_version(
    instance_id: &str,
    version_id: &str,
    project_type: Option<&str>,
    install_deps: bool,
    on_progress: Option<ProgressFn>,
) -> Result<String> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::ensure_instance_dir(&resource, &instance.path).await?;
    let client = manifest::http_client()?;

    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    report(0.05, format!("Fetching Modrinth version {version_id}…"));
    let version = fetch_version(&client, version_id).await?;
    let content_type = ContentType::parse(project_type);
    let project = fetch_project_info(&client, &version.project_id).await.ok();

    // Skip re-download when this exact version is already installed on disk.
    let existing =
        db::list_content_by_project(&state.pool, instance_id, &version.project_id).await?;
    if let Some(hit) = existing.iter().find(|e| {
        e.version_id.as_deref() == Some(version_id)
            && !e.pending
            && instance_dir.join(&e.relative_path).is_file()
    }) {
        report(
            1.0,
            format!(
                "Already installed {} ({})",
                project
                    .as_ref()
                    .map(|p| p.title.as_str())
                    .unwrap_or(version.name.as_str()),
                hit.relative_path
            ),
        );
        return Ok(instance_dir
            .join(&hit.relative_path)
            .to_string_lossy()
            .into());
    }

    let mut visited_versions = HashSet::new();
    let mut visited_projects = HashSet::new();
    visited_projects.insert(version.project_id.clone());

    let path = install_version_file(
        &client,
        &state.pool,
        instance_id,
        &instance_dir,
        &version,
        project.as_ref(),
        content_type,
        &on_progress,
        0.2,
    )
    .await?;

    if install_deps {
        report(0.45, "Resolving required dependencies…".into());
        install_required_deps(
            &client,
            &state.pool,
            &instance,
            &instance_dir,
            &version,
            &mut visited_versions,
            &mut visited_projects,
            &on_progress,
        )
        .await?;
    } else {
        report(0.9, "Skipped dependency install (forced)".into());
    }

    report(1.0, format!("Installed {}", version.name));
    Ok(path.to_string_lossy().to_string())
}

// Install pipeline step; arguments are carried from the single orchestrator.
#[allow(clippy::too_many_arguments)]
async fn install_version_file(
    client: &reqwest::Client,
    pool: &sqlx::SqlitePool,
    instance_id: &str,
    instance_dir: &Path,
    version: &ModrinthVersion,
    project: Option<&ModrinthProjectInfo>,
    content_type: ContentType,
    on_progress: &Option<ProgressFn>,
    progress: f64,
) -> Result<PathBuf> {
    let file = version
        .files
        .iter()
        .find(|f| f.primary.unwrap_or(false))
        .or_else(|| version.files.first())
        .ok_or_else(|| anyhow!("version has no files"))?;

    // Already have this exact version ? do not re-download / duplicate.
    let existing = db::list_content_by_project(pool, instance_id, &version.project_id).await?;
    if let Some(hit) = existing
        .iter()
        .find(|e| e.version_id.as_deref() == Some(version.id.as_str()))
    {
        return Ok(instance_dir.join(&hit.relative_path));
    }

    // Replace any previously installed files for this project (update / reinstall).
    for old in &existing {
        let old_path = instance_dir.join(&old.relative_path);
        let disabled = instance_dir.join(format!("{}.disabled", old.relative_path));
        let _ = tokio::fs::remove_file(&old_path).await;
        let _ = tokio::fs::remove_file(&disabled).await;
        db::remove_content_entry(pool, instance_id, &old.relative_path).await?;
    }

    if let Some(cb) = on_progress {
        cb(progress, format!("Downloading {}…", file.filename));
    }
    let progress_value = progress;
    let on_retry = |attempt: u32, max: u32| {
        if let Some(cb) = on_progress {
            cb(
                progress_value,
                format!("Retrying download ({attempt}/{max})…"),
            );
        }
    };
    // Map streamed byte progress into the download phase [progress, progress+0.25]
    // so the UI shows live downloaded/total/speed instead of jumping 0.2 → 0.45.
    let on_bytes = on_progress.clone().map(|cb| {
        progress::file_bytes_cb(
            cb,
            "Downloading",
            file.filename.clone(),
            progress,
            (progress + 0.25).min(0.95),
        )
    });
    let bytes = download::download_checked_with_mcim_fallback_bytes(
        client,
        &file.url,
        None,
        Some(&on_retry),
        on_bytes,
    )
    .await?;
    let sha1 = download::sha1_hex(&bytes);

    let dest = instance_dir
        .join(content_type.folder())
        .join(&file.filename);
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    tokio::fs::write(&dest, &bytes).await?;

    let relative = format!("{}/{}", content_type.folder(), file.filename);
    let now = chrono::Utc::now().to_rfc3339();
    let mut author = None;
    let mut author_avatar_url = None;
    let mut author_id = None;
    let mut author_type = None;
    if let Some(p) = project {
        if let Some(org_id) = p.organization.as_deref() {
            if let Ok(Some(owner)) = fetch_org(client, org_id).await {
                author = Some(owner.name);
                author_avatar_url = owner.avatar_url;
                author_id = Some(owner.id);
                author_type = Some(owner.kind);
            }
        } else if let Some(team_id) = p.team.as_deref() {
            if let Ok(Some(owner)) = fetch_team_owner(client, team_id).await {
                author = Some(owner.name);
                author_avatar_url = owner.avatar_url;
                author_id = Some(owner.id);
                author_type = Some(owner.kind);
            }
        }
    }
    let entry = db::ContentEntry {
        id: format!("content:{}", uuid::Uuid::new_v4()),
        instance_id: instance_id.to_string(),
        relative_path: relative,
        file_name: file.filename.clone(),
        project_type: match content_type {
            ContentType::Mod => "mod",
            ContentType::ResourcePack => "resourcepack",
            ContentType::Shader => "shader",
            ContentType::DataPack => "datapack",
        }
        .into(),
        project_id: Some(version.project_id.clone()),
        version_id: Some(version.id.clone()),
        version_number: version.version_number.clone(),
        version_name: Some(version.name.clone()),
        project_title: project.map(|p| p.title.clone()),
        project_icon_url: project.and_then(|p| p.icon_url.clone()),
        author,
        author_avatar_url,
        author_id,
        author_type,
        update_version_id: None,
        enabled: true,
        sha1: Some(sha1),
        size_bytes: Some(bytes.len() as i64),
        added_at: now,
        pending: false,
        download_url: None,
    };
    db::upsert_content_entry(pool, &entry).await?;
    Ok(dest)
}

// Dependency-resolution loop; the visited sets and install context live in
// the single orchestrator.
#[allow(clippy::too_many_arguments)]
async fn install_required_deps(
    client: &reqwest::Client,
    pool: &sqlx::SqlitePool,
    instance: &Instance,
    instance_dir: &Path,
    root: &ModrinthVersion,
    visited_versions: &mut HashSet<String>,
    visited_projects: &mut HashSet<String>,
    on_progress: &Option<ProgressFn>,
) -> Result<()> {
    let loaders = ContentType::Mod.target_loaders(&instance.loader);
    let game = instance.game_version.as_str();
    let mut stack = vec![root.clone()];

    while let Some(version) = stack.pop() {
        if !visited_versions.insert(version.id.clone()) {
            continue;
        }
        let Some(deps) = &version.dependencies else {
            continue;
        };

        for dep in deps.iter().filter(|d| d.dependency_type == "required") {
            if dep.project_id.as_deref() == Some(QUILT_FABRIC_API_EXCEPTION)
                && instance.loader.eq_ignore_ascii_case("quilt")
            {
                continue;
            }

            let dep_version = if let Some(vid) = &dep.version_id {
                fetch_version(client, vid).await?
            } else if let Some(pid) = &dep.project_id {
                if visited_projects.contains(pid) {
                    continue;
                }
                let versions = fetch_project_versions(client, pid).await?;
                match select_compatible_version(versions, ContentType::Mod, game, &loaders) {
                    Some(v) => v,
                    None => {
                        if let Some(cb) = on_progress {
                            cb(0.7, format!("Skipping incompatible dependency {pid}"));
                        }
                        continue;
                    }
                }
            } else {
                continue;
            };

            if !visited_projects.insert(dep_version.project_id.clone()) {
                continue;
            }

            if let Some(cb) = on_progress {
                cb(0.75, format!("Installing dependency {}…", dep_version.name));
            }
            let project = fetch_project_info(client, &dep_version.project_id)
                .await
                .ok();
            let _ = install_version_file(
                client,
                pool,
                &instance.id,
                instance_dir,
                &dep_version,
                project.as_ref(),
                ContentType::Mod,
                on_progress,
                0.8,
            )
            .await?;
            stack.push(dep_version);
        }
    }
    Ok(())
}

/// Re-download a pack file that was skipped during install.
pub async fn retry_missing_content(
    instance_id: &str,
    relative_path: &str,
    on_progress: Option<ProgressFn>,
) -> Result<String> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::ensure_instance_dir(&resource, &instance.path).await?;
    let rel = relative_path.replace('\\', "/");
    let entries = db::list_content_for_instance(&state.pool, instance_id).await?;

    let mut entry = entries
        .into_iter()
        .find(|e| e.relative_path.replace('\\', "/") == rel)
        .ok_or_else(|| anyhow!("未找到待下载内容: {relative_path}"))?;

    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    let dest = instance_dir.join(&entry.relative_path);
    if dest.is_file() {
        entry.pending = false;
        db::upsert_content_entry(&state.pool, &entry).await?;
        return Ok(dest.to_string_lossy().into());
    }

    if let Some(url) = entry
        .download_url
        .as_deref()
        .map(str::trim)
        .filter(|u| !u.is_empty())
    {
        report(0.1, format!("Downloading {}…", entry.file_name));
        let client = manifest::http_client()?;
        let on_bytes = on_progress.clone().map(|cb| {
            progress::file_bytes_cb(cb, "Downloading", entry.file_name.clone(), 0.1, 0.95)
        });
        let bytes = download_with_mirrors(&client, &[url.to_string()], on_bytes).await?;
        if let Some(expected) = entry.sha1.as_deref().filter(|s| !s.is_empty()) {
            let actual = download::sha1_hex(&bytes);
            if !actual.eq_ignore_ascii_case(expected) {
                anyhow::bail!(
                    "sha1 mismatch for {}: expected {expected}, got {actual}",
                    entry.file_name
                );
            }
        }
        if let Some(parent) = dest.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        tokio::fs::write(&dest, &bytes).await?;
        entry.pending = false;
        entry.enabled = true;
        entry.sha1 = Some(download::sha1_hex(&bytes));
        entry.size_bytes = Some(bytes.len() as i64);
        db::upsert_content_entry(&state.pool, &entry).await?;
        report(1.0, format!("Installed {}", entry.file_name));
        return Ok(dest.to_string_lossy().into());
    }

    if let Some(pid) = entry.project_id.as_deref() {
        if let Some(mod_id_s) = pid.strip_prefix("cf:") {
            let mod_id: u64 = mod_id_s
                .parse()
                .with_context(|| format!("无效的 CurseForge 项目 ID: {pid}"))?;
            let file_id: u64 = entry
                .version_id
                .as_deref()
                .ok_or_else(|| anyhow!("缺少 CurseForge 文件 ID"))?
                .parse()
                .context("无效的 CurseForge 文件 ID")?;
            return install_curseforge_file(
                instance_id,
                mod_id,
                file_id,
                Some(&entry.project_type),
                on_progress,
            )
            .await;
        }
        if let Some(vid) = entry
            .version_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            return install_modrinth_version(
                instance_id,
                vid,
                Some(&entry.project_type),
                false,
                on_progress,
            )
            .await;
        }
    }

    anyhow::bail!("没有可用的下载地址: {}", entry.file_name)
}

pub(super) async fn download_with_mirrors(
    client: &reqwest::Client,
    urls: &[String],
    on_bytes: Option<progress::BytesProgressFn>,
) -> Result<bytes::Bytes> {
    let mut expanded = Vec::new();
    for url in urls {
        for candidate in crate::config::mcim_url_candidates(url) {
            if !expanded.iter().any(|u: &String| u == &candidate) {
                expanded.push(candidate);
            }
        }
    }
    if expanded.is_empty() {
        return Err(anyhow!("no download urls"));
    }
    let mut last_err = anyhow!("no download urls");
    for url in &expanded {
        match download::download_checked_with_retry(client, url, None, None, on_bytes.clone()).await
        {
            Ok(b) => return Ok(bytes::Bytes::from(b)),
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}
