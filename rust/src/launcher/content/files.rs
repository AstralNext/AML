//! Instance content scanning, Modrinth metadata sync, and file management
//! (list / enable / disable / remove).

use anyhow::{bail, Result};
use std::collections::HashSet;
use std::path::PathBuf;

use super::matching::{channel_allows, infer_channel_from_version};
use super::modrinth::{
    fetch_projects_many, fetch_version_updates, fetch_versions_from_hashes, resolve_project_owners,
};
use crate::launcher::dirs;
use crate::launcher::download;
use crate::launcher::manifest;
use crate::state::db;
use crate::state::models::UpdateChannel;
use crate::state::{resource_dir, try_state};

/// Scan instance content folders, hash local files, and match Modrinth metadata
/// via `/version_files`.
///
/// When `check_updates` is false, skip the expensive `version_files/update` call
/// (use after installs / when only filling missing author metadata).
pub async fn sync_instance_content_metadata(instance_id: &str, check_updates: bool) -> Result<()> {
    let state = try_state()?;
    let resource = resource_dir().await?;

    let instance = db::get_instance(&state.pool, instance_id).await?;
    let root = dirs::instance_dir(&resource, &instance.path);
    let client = manifest::http_client()?;

    let mut db_entries = db::list_content_for_instance(&state.pool, instance_id).await?;
    let mut by_path: std::collections::HashMap<String, db::ContentEntry> = db_entries
        .drain(..)
        .map(|e| (e.relative_path.replace('\\', "/"), e))
        .collect();

    struct LocalFile {
        relative: String,
        file_name: String,
        enabled: bool,
        size: u64,
        project_type: String,
        path: PathBuf,
    }

    let mut locals = Vec::new();
    for folder in ["mods", "resourcepacks", "shaderpacks", "datapacks"] {
        let dir = root.join(folder);
        if !dir.exists() {
            continue;
        }
        let mut entries = tokio::fs::read_dir(&dir).await?;
        while let Some(entry) = entries.next_entry().await? {
            let name = entry.file_name().to_string_lossy().to_string();
            let lower = name.to_lowercase();
            let ok = lower.ends_with(".jar")
                || lower.ends_with(".jar.disabled")
                || lower.ends_with(".zip")
                || lower.ends_with(".zip.disabled");
            if !ok {
                continue;
            }
            let meta = entry.metadata().await?;
            if !meta.is_file() {
                continue;
            }
            let relative = format!("{folder}/{name}").replace('\\', "/");
            let enabled = !lower.ends_with(".disabled");
            let project_type = match folder {
                "mods" => "mod",
                "resourcepacks" => "resourcepack",
                "shaderpacks" => "shader",
                "datapacks" => "datapack",
                _ => "mod",
            }
            .into();
            locals.push(LocalFile {
                relative,
                file_name: name,
                enabled,
                size: meta.len(),
                project_type,
                path: entry.path(),
            });
        }
    }

    let mut need_hash_lookup: Vec<(String, String)> = Vec::new(); // (relative, sha1)

    for local in &locals {
        let db_hit = by_path.remove(&local.relative).or_else(|| {
            let alt = if local.enabled {
                format!("{}.disabled", local.relative)
            } else {
                local.relative.trim_end_matches(".disabled").to_string()
            };
            by_path.remove(&alt)
        });

        let mut entry = db_hit.unwrap_or_else(|| db::ContentEntry {
            id: format!("content:{}", uuid::Uuid::new_v4()),
            instance_id: instance_id.to_string(),
            relative_path: local.relative.clone(),
            file_name: local.file_name.clone(),
            project_type: local.project_type.clone(),
            project_id: None,
            version_id: None,
            version_number: None,
            version_name: None,
            project_title: None,
            project_icon_url: None,
            author: None,
            author_avatar_url: None,
            author_id: None,
            author_type: None,
            update_version_id: None,
            enabled: local.enabled,
            sha1: None,
            size_bytes: Some(local.size as i64),
            added_at: chrono::Utc::now().to_rfc3339(),
            pending: false,
            download_url: None,
        });

        entry.relative_path = local.relative.clone();
        entry.file_name = local.file_name.clone();
        entry.enabled = local.enabled;
        entry.pending = false;
        if entry.project_type.is_empty() {
            entry.project_type = local.project_type.clone();
        }

        // Reuse cached hash when file size is unchanged.
        let cached_size = entry.size_bytes;
        let sha1 = match (&entry.sha1, cached_size) {
            (Some(h), Some(sz)) if !h.is_empty() && sz == local.size as i64 => h.clone(),
            _ => {
                let h = download::sha1_file(&local.path).await?;
                entry.sha1 = Some(h.clone());
                h
            }
        };
        entry.size_bytes = Some(local.size as i64);

        if entry.project_id.is_none() {
            need_hash_lookup.push((local.relative.clone(), sha1));
        }

        db::upsert_content_entry(&state.pool, &entry).await?;
        by_path.insert(local.relative.clone(), entry);
    }

    // Drop DB rows for files no longer on disk (prevents stale update badges /
    // ghost entries when install races with sync). Keep pending placeholders
    // so missing pack files remain visible until downloaded or removed.
    let live: HashSet<String> = locals.iter().map(|l| l.relative.clone()).collect();
    let orphans: Vec<String> = by_path
        .iter()
        .filter(|(p, e)| !live.contains(*p) && !e.pending)
        .map(|(p, _)| p.clone())
        .collect();
    for path in orphans {
        by_path.remove(&path);
        let _ = db::remove_content_entry(&state.pool, instance_id, &path).await;
    }

    if need_hash_lookup.is_empty() {
        // Still enrich authors / updates for already-matched content.
    } else {
        let hashes: Vec<String> = need_hash_lookup
            .iter()
            .map(|(_, h)| h.clone())
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
        let matched = fetch_versions_from_hashes(&client, &hashes)
            .await
            .unwrap_or_default();
        if !matched.is_empty() {
            let project_ids: Vec<String> = matched
                .values()
                .map(|v| v.project_id.clone())
                .collect::<HashSet<_>>()
                .into_iter()
                .collect();
            let projects = fetch_projects_many(&client, &project_ids)
                .await
                .unwrap_or_default();
            let owners = resolve_project_owners(&client, &projects).await;

            for (relative, sha1) in need_hash_lookup {
                let Some(version) = matched.get(&sha1) else {
                    continue;
                };
                let Some(entry) = by_path.get_mut(&relative) else {
                    continue;
                };
                entry.project_id = Some(version.project_id.clone());
                entry.version_id = Some(version.id.clone());
                entry.version_number = version.version_number.clone();
                entry.version_name = Some(version.name.clone());
                if let Some(p) = projects.get(&version.project_id) {
                    entry.project_title = Some(p.title.clone());
                    entry.project_icon_url = p.icon_url.clone();
                }
                if let Some(owner) = owners.get(&version.project_id) {
                    entry.author = Some(owner.name.clone());
                    entry.author_avatar_url = owner.avatar_url.clone();
                    entry.author_id = Some(owner.id.clone());
                    entry.author_type = Some(owner.kind.clone());
                }
                db::upsert_content_entry(&state.pool, entry).await?;
            }
        }
    }

    // Enrich author for Modrinth entries that have project_id but no author yet.
    // Skip CurseForge (`cf:`) ids — Modrinth project API would 404 / mis-bind.
    let need_author: Vec<String> = by_path
        .values()
        .filter(|e| e.project_id.is_some() && (e.author.is_none() || e.author_id.is_none()))
        .filter_map(|e| e.project_id.clone())
        .filter(|pid| !pid.starts_with("cf:"))
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    if !need_author.is_empty() {
        let projects = fetch_projects_many(&client, &need_author)
            .await
            .unwrap_or_default();
        let owners = resolve_project_owners(&client, &projects).await;
        for entry in by_path.values_mut() {
            let Some(pid) = entry.project_id.as_ref() else {
                continue;
            };
            if entry.author.is_some() && entry.author_id.is_some() {
                continue;
            }
            if let Some(p) = projects.get(pid) {
                if entry.project_title.is_none() {
                    entry.project_title = Some(p.title.clone());
                }
                if entry.project_icon_url.is_none() {
                    entry.project_icon_url = p.icon_url.clone();
                }
            }
            if let Some(owner) = owners.get(pid) {
                entry.author = Some(owner.name.clone());
                entry.author_avatar_url = owner.avatar_url.clone();
                entry.author_id = Some(owner.id.clone());
                entry.author_type = Some(owner.kind.clone());
                db::upsert_content_entry(&state.pool, entry).await?;
            }
        }
    }

    // Check updates only when requested (skip after installs).
    // Modrinth hash update API only applies to non-CurseForge entries.
    if check_updates {
        let update_hashes: Vec<String> = by_path
            .values()
            .filter(|e| e.project_id.is_some() && e.version_id.is_some())
            .filter(|e| {
                !e.project_id
                    .as_deref()
                    .is_some_and(|id| id.starts_with("cf:"))
            })
            .filter_map(|e| e.sha1.clone())
            .filter(|h| !h.is_empty())
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
        if !update_hashes.is_empty() {
            let loaders = if instance.loader.eq_ignore_ascii_case("vanilla") {
                vec!["minecraft".into()]
            } else {
                vec![instance.loader.to_lowercase()]
            };
            let game_versions = vec![instance.game_version.clone()];
            if let Ok(updates) =
                fetch_version_updates(&client, &update_hashes, &loaders, &game_versions).await
            {
                for entry in by_path.values_mut() {
                    if entry
                        .project_id
                        .as_deref()
                        .is_some_and(|id| id.starts_with("cf:"))
                    {
                        continue;
                    }
                    let Some(sha1) = entry.sha1.as_ref() else {
                        continue;
                    };
                    let new_update = updates.get(sha1).and_then(|v| {
                        if entry.version_id.as_deref() == Some(v.id.as_str()) {
                            return None;
                        }
                        let channel = UpdateChannel::parse(&instance.update_channel);
                        let installed_channel = entry
                            .version_number
                            .as_deref()
                            .map(infer_channel_from_version)
                            .unwrap_or(UpdateChannel::Release);
                        let effective = channel.least_stable(installed_channel);
                        if !channel_allows(effective, v.version_type.as_deref()) {
                            return None;
                        }
                        Some(v.id.clone())
                    });
                    if entry.update_version_id != new_update {
                        entry.update_version_id = new_update;
                        let _ = db::upsert_content_entry(&state.pool, entry).await;
                    }
                }
            }
        }
    }

    Ok(())
}

/// One content file on disk (or a pending DB-only entry), joined with its
/// cached DB metadata when available.
#[derive(Clone, Debug)]
pub struct ContentFileEntry {
    pub name: String,
    pub relative_path: String,
    pub enabled: bool,
    pub size_bytes: u64,
    /// `mods` / `resourcepacks` / `shaderpacks` / `datapacks`; empty for
    /// pending DB-only entries.
    pub folder: String,
    pub is_missing: bool,
    pub db: Option<db::ContentEntry>,
}

/// Fast path: join local content files with cached DB metadata only.
/// Network sync / hashing happens via `sync_instance_content_metadata`.
pub async fn list_content_files(instance_id: &str) -> Result<Vec<ContentFileEntry>> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let root = dirs::instance_dir(&resource, &instance.path);
    let db_entries = db::list_content_for_instance(&state.pool, instance_id).await?;
    let mut by_path: std::collections::HashMap<String, db::ContentEntry> = db_entries
        .into_iter()
        .map(|e| (e.relative_path.replace('\\', "/"), e))
        .collect();

    let mut out = Vec::new();
    for folder in ["mods", "resourcepacks", "shaderpacks", "datapacks"] {
        let dir = root.join(folder);
        if !dir.exists() {
            continue;
        }
        let mut entries = tokio::fs::read_dir(&dir).await?;
        while let Some(entry) = entries.next_entry().await? {
            let name = entry.file_name().to_string_lossy().to_string();
            let lower = name.to_lowercase();
            let ok = lower.ends_with(".jar")
                || lower.ends_with(".jar.disabled")
                || lower.ends_with(".zip")
                || lower.ends_with(".zip.disabled");
            if !ok {
                continue;
            }
            let meta = entry.metadata().await?;
            if !meta.is_file() {
                continue;
            }
            let relative = format!("{folder}/{name}").replace('\\', "/");
            let enabled = !lower.ends_with(".disabled");
            let db_hit = by_path.remove(&relative).or_else(|| {
                let alt = if enabled {
                    format!("{relative}.disabled")
                } else {
                    relative.trim_end_matches(".disabled").to_string()
                };
                by_path.remove(&alt)
            });
            out.push(ContentFileEntry {
                name,
                relative_path: relative,
                enabled,
                size_bytes: meta.len(),
                folder: folder.to_string(),
                is_missing: false,
                db: db_hit,
            });
        }
    }
    for (_, e) in by_path {
        if !e.pending {
            continue;
        }
        out.push(ContentFileEntry {
            name: e.file_name.clone(),
            relative_path: e.relative_path.clone(),
            enabled: true,
            size_bytes: 0,
            folder: String::new(),
            is_missing: true,
            db: Some(e),
        });
    }
    out.sort_by(|a, b| {
        b.is_missing.cmp(&a.is_missing).then_with(|| {
            a.db
                .as_ref()
                .and_then(|d| d.project_title.clone())
                .unwrap_or_else(|| a.name.clone())
                .to_lowercase()
                .cmp(
                    &b.db
                        .as_ref()
                        .and_then(|d| d.project_title.clone())
                        .unwrap_or_else(|| b.name.clone())
                        .to_lowercase(),
                )
        })
    });
    Ok(out)
}

/// Enable / disable a content file by toggling the `.disabled` suffix,
/// keeping the DB entry path in sync.
pub async fn set_content_enabled(
    instance_id: &str,
    relative_path: &str,
    enabled: bool,
) -> Result<()> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let root = dirs::instance_dir(&resource, &instance.path);
    let current = root.join(relative_path);
    if !current.is_file() {
        bail!("文件不存在: {relative_path}");
    }
    let file_name = current
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let target = if enabled {
        if let Some(stripped) = file_name.strip_suffix(".disabled") {
            current.with_file_name(stripped)
        } else {
            current.clone()
        }
    } else if file_name.to_lowercase().ends_with(".jar") {
        current.with_file_name(format!("{file_name}.disabled"))
    } else {
        current.clone()
    };

    if target != current {
        tokio::fs::rename(&current, &target).await?;
        let new_name = target
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or(file_name);
        let new_rel = {
            let parent = std::path::Path::new(relative_path)
                .parent()
                .map(|p| p.to_string_lossy().replace('\\', "/"))
                .unwrap_or_default();
            if parent.is_empty() {
                new_name.clone()
            } else {
                format!("{parent}/{new_name}")
            }
        };
        let _ = db::update_content_path_and_enabled(
            &state.pool,
            instance_id,
            relative_path,
            &new_rel,
            &new_name,
            enabled,
        )
        .await;
    }
    Ok(())
}

/// Delete a content file (or a pending DB-only entry). Only files inside the
/// content folders are allowed.
pub async fn remove_content_file(instance_id: &str, relative_path: &str) -> Result<()> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let root = dirs::instance_dir(&resource, &instance.path);
    let path = root.join(relative_path);
    let normalized = relative_path.replace('\\', "/");
    let allowed = normalized.starts_with("mods/")
        || normalized.starts_with("resourcepacks/")
        || normalized.starts_with("shaderpacks/")
        || normalized.starts_with("datapacks/");
    if !allowed {
        bail!("只能删除实例内容目录下的文件");
    }
    if path.is_file() {
        tokio::fs::remove_file(&path).await?;
    } else {
        let entries = db::list_content_for_instance(&state.pool, instance_id).await?;
        let pending = entries.iter().any(|e| {
            e.relative_path.replace('\\', "/") == normalized && e.pending
        });
        if !pending {
            bail!("文件不存在: {relative_path}");
        }
    }
    let _ = db::remove_content_entry(&state.pool, instance_id, &normalized).await;
    Ok(())
}
