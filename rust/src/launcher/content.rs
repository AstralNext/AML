//! Mod / mrpack content installation into instances.
//! Resolve compatible version by game/loader, recurse required deps, place by project_type.

use anyhow::{anyhow, Context, Result};
use futures::stream::{FuturesUnordered, StreamExt};
use serde::Deserialize;
use std::collections::HashSet;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tokio::sync::Semaphore;
use zip::ZipArchive;

use crate::config::{curseforge_api_url, modrinth_api_url};
use crate::state::db;
use crate::state::models::{InstallStage, Instance, ModLoader};
use crate::state::{resource_dir, try_state};

use super::dirs;
use super::download::{self, ProgressFn, PACK_DOWNLOAD_CONCURRENCY};
use super::install;
use super::mcim_fallback;

const QUILT_FABRIC_API_EXCEPTION: &str = "P7dR8mSH";

#[derive(Deserialize, Clone)]
struct ModrinthVersion {
    id: String,
    project_id: String,
    name: String,
    #[serde(default)]
    version_number: Option<String>,
    files: Vec<ModrinthFile>,
    dependencies: Option<Vec<ModrinthDependency>>,
    game_versions: Option<Vec<String>>,
    loaders: Option<Vec<String>>,
    #[serde(default)]
    version_type: Option<String>,
    #[serde(default)]
    date_published: Option<String>,
}

#[derive(Deserialize, Clone)]
struct ModrinthProjectInfo {
    id: String,
    title: String,
    #[serde(default)]
    icon_url: Option<String>,
    #[serde(default)]
    team: Option<String>,
    #[serde(default)]
    organization: Option<String>,
}

#[derive(Deserialize, Clone)]
struct ModrinthOrgInfo {
    id: String,
    name: String,
    #[serde(default)]
    icon_url: Option<String>,
}

#[derive(Deserialize, Clone)]
struct ModrinthTeamMember {
    #[serde(default)]
    is_owner: bool,
    user: ModrinthTeamUser,
}

#[derive(Deserialize, Clone)]
struct ModrinthTeamUser {
    id: String,
    username: String,
    #[serde(default)]
    avatar_url: Option<String>,
}

#[derive(Clone)]
struct ContentOwner {
    id: String,
    name: String,
    avatar_url: Option<String>,
    /// `user` or `organization`
    kind: String,
}

#[derive(Deserialize, Clone)]
struct ModrinthFile {
    url: String,
    filename: String,
    primary: Option<bool>,
}

#[derive(Deserialize, Clone)]
struct ModrinthDependency {
    version_id: Option<String>,
    project_id: Option<String>,
    dependency_type: String,
}

#[derive(Deserialize)]
struct MrpackIndex {
    files: Vec<MrpackFile>,
    dependencies: MrpackDependencies,
    name: Option<String>,
}

#[derive(Deserialize)]
struct MrpackFile {
    path: String,
    downloads: Vec<String>,
    #[serde(default)]
    hashes: Option<MrpackHashes>,
    env: Option<MrpackEnv>,
}

#[derive(Deserialize)]
struct MrpackHashes {
    sha1: Option<String>,
    #[serde(default)]
    sha512: Option<String>,
}

#[derive(Deserialize)]
struct MrpackEnv {
    client: Option<String>,
}

#[derive(Deserialize)]
struct MrpackDependencies {
    minecraft: String,
    #[serde(rename = "fabric-loader")]
    fabric_loader: Option<String>,
    #[serde(rename = "quilt-loader")]
    quilt_loader: Option<String>,
    forge: Option<String>,
    #[serde(rename = "neoforge", alias = "neo-forge")]
    neoforge: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ContentType {
    Mod,
    ResourcePack,
    Shader,
    DataPack,
}

impl ContentType {
    fn parse(s: Option<&str>) -> Self {
        match s.unwrap_or("mod") {
            "resourcepack" => Self::ResourcePack,
            "shader" => Self::Shader,
            "datapack" => Self::DataPack,
            _ => Self::Mod,
        }
    }

    fn folder(self) -> &'static str {
        match self {
            Self::Mod => "mods",
            Self::ResourcePack => "resourcepacks",
            Self::Shader => "shaderpacks",
            Self::DataPack => "datapacks",
        }
    }

    /// Target loader preference used when matching versions.
    fn target_loaders(self, instance_loader: &str) -> Vec<String> {
        match self {
            Self::Mod => {
                if instance_loader.is_empty() || instance_loader == "vanilla" {
                    vec![]
                } else {
                    vec![instance_loader.to_lowercase()]
                }
            }
            Self::DataPack => vec!["datapack".into()],
            Self::ResourcePack => vec!["minecraft".into()],
            Self::Shader => vec!["iris".into()],
        }
    }
}

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
    let client = super::manifest::http_client()?;

    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    report(0.05, format!("Fetching Modrinth version {version_id}?"));
    let version = fetch_version(&client, version_id).await?;
    let content_type = ContentType::parse(project_type);
    let project = fetch_project_info(&client, &version.project_id).await.ok();

    // Skip re-download when this exact version is already installed.
    let existing =
        db::list_content_by_project(&state.pool, instance_id, &version.project_id).await?;
    if let Some(hit) = existing
        .iter()
        .find(|e| e.version_id.as_deref() == Some(version_id))
    {
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
        report(0.45, "Resolving required dependencies?".into());
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

async fn fetch_project_info(
    client: &reqwest::Client,
    project_id: &str,
) -> Result<ModrinthProjectInfo> {
    let url = format!("{}project/{project_id}", modrinth_api_url());
    mcim_fallback::client_get_json(client, &url).await
}

async fn fetch_projects_many(
    client: &reqwest::Client,
    ids: &[String],
) -> Result<std::collections::HashMap<String, ModrinthProjectInfo>> {
    if ids.is_empty() {
        return Ok(Default::default());
    }
    let uri = format!(
        "{}projects?ids={}",
        modrinth_api_url(),
        urlencoding_json_array(ids)
    );
    let list: Vec<ModrinthProjectInfo> = mcim_fallback::client_get_json(client, &uri).await?;
    Ok(list.into_iter().map(|p| (p.id.clone(), p)).collect())
}

async fn fetch_team_owner(client: &reqwest::Client, team_id: &str) -> Result<Option<ContentOwner>> {
    let url = format!("{}team/{team_id}/members", modrinth_api_url());
    let members: Vec<ModrinthTeamMember> = mcim_fallback::client_get_json(client, &url).await?;
    Ok(members
        .iter()
        .find(|m| m.is_owner)
        .or_else(|| members.first())
        .map(|m| ContentOwner {
            id: m.user.id.clone(),
            name: m.user.username.clone(),
            avatar_url: m.user.avatar_url.clone(),
            kind: "user".into(),
        }))
}

async fn fetch_org(client: &reqwest::Client, org_id: &str) -> Result<Option<ContentOwner>> {
    let url = format!("{}organization/{org_id}", modrinth_api_url());
    let org: ModrinthOrgInfo = mcim_fallback::client_get_json(client, &url).await?;
    Ok(Some(ContentOwner {
        id: org.id,
        name: org.name,
        avatar_url: org.icon_url,
        kind: "organization".into(),
    }))
}

async fn resolve_project_owners(
    client: &reqwest::Client,
    projects: &std::collections::HashMap<String, ModrinthProjectInfo>,
) -> std::collections::HashMap<String, ContentOwner> {
    use futures::stream::{FuturesUnordered, StreamExt};

    let mut out = std::collections::HashMap::new();
    let mut team_ids = HashSet::new();
    let mut org_ids = HashSet::new();
    for project in projects.values() {
        if let Some(org_id) = project.organization.as_deref() {
            org_ids.insert(org_id.to_string());
        } else if let Some(team_id) = project.team.as_deref() {
            team_ids.insert(team_id.to_string());
        }
    }

    let mut org_cache: std::collections::HashMap<String, Option<ContentOwner>> =
        std::collections::HashMap::new();
    {
        let mut futs = FuturesUnordered::new();
        for org_id in org_ids {
            let client = client.clone();
            futs.push(async move {
                let owner = fetch_org(&client, &org_id).await.ok().flatten();
                (org_id, owner)
            });
        }
        while let Some((id, owner)) = futs.next().await {
            org_cache.insert(id, owner);
        }
    }

    let mut team_cache: std::collections::HashMap<String, Option<ContentOwner>> =
        std::collections::HashMap::new();
    {
        let mut futs = FuturesUnordered::new();
        for team_id in team_ids {
            let client = client.clone();
            futs.push(async move {
                let owner = fetch_team_owner(&client, &team_id).await.ok().flatten();
                (team_id, owner)
            });
        }
        while let Some((id, owner)) = futs.next().await {
            team_cache.insert(id, owner);
        }
    }

    for (pid, project) in projects {
        if let Some(org_id) = project.organization.as_deref() {
            if let Some(Some(owner)) = org_cache.get(org_id) {
                out.insert(pid.clone(), owner.clone());
                continue;
            }
        }
        if let Some(team_id) = project.team.as_deref() {
            if let Some(Some(owner)) = team_cache.get(team_id) {
                out.insert(pid.clone(), owner.clone());
            }
        }
    }
    out
}

async fn fetch_version_updates(
    client: &reqwest::Client,
    hashes: &[String],
    loaders: &[String],
    game_versions: &[String],
) -> Result<std::collections::HashMap<String, ModrinthVersion>> {
    if hashes.is_empty() {
        return Ok(Default::default());
    }
    let url = format!("{}version_files/update", modrinth_api_url());
    let body = serde_json::json!({
        "algorithm": "sha1",
        "hashes": hashes,
        "loaders": loaders,
        "game_versions": game_versions,
    });
    mcim_fallback::client_post_json(client, &url, &body).await
}

fn urlencoding_json_array(ids: &[String]) -> String {
    let raw = serde_json::to_string(ids).unwrap_or_else(|_| "[]".into());
    urlencoding::encode(&raw).into_owned()
}

async fn fetch_versions_from_hashes(
    client: &reqwest::Client,
    hashes: &[String],
) -> Result<std::collections::HashMap<String, ModrinthVersion>> {
    if hashes.is_empty() {
        return Ok(Default::default());
    }
    let url = format!("{}version_files", modrinth_api_url());
    let body = serde_json::json!({
        "algorithm": "sha1",
        "hashes": hashes,
    });
    mcim_fallback::client_post_json(client, &url, &body).await
}

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
    let client = super::manifest::http_client()?;

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
        });

        entry.relative_path = local.relative.clone();
        entry.file_name = local.file_name.clone();
        entry.enabled = local.enabled;
        if entry.project_type.is_empty() {
            entry.project_type = local.project_type.clone();
        }

        // Reuse cached hash when file size is unchanged.
        let cached_size = entry.size_bytes;
        let sha1 = match (&entry.sha1, cached_size) {
            (Some(h), Some(sz)) if !h.is_empty() && sz == local.size as i64 => h.clone(),
            _ => {
                let h = super::download::sha1_file(&local.path).await?;
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
    // ghost entries when install races with sync).
    let live: HashSet<String> = locals.iter().map(|l| l.relative.clone()).collect();
    let orphans: Vec<String> = by_path
        .keys()
        .filter(|p| !live.contains(*p))
        .cloned()
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
                        let channel = crate::state::models::UpdateChannel::parse(
                            &instance.update_channel,
                        );
                        let installed_channel = entry
                            .version_number
                            .as_deref()
                            .map(infer_channel_from_version)
                            .unwrap_or(crate::state::models::UpdateChannel::Release);
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

async fn fetch_version(client: &reqwest::Client, version_id: &str) -> Result<ModrinthVersion> {
    let url = format!("{}version/{version_id}", modrinth_api_url());
    mcim_fallback::client_get_json(client, &url).await
}

async fn fetch_project_versions(
    client: &reqwest::Client,
    project_id: &str,
) -> Result<Vec<ModrinthVersion>> {
    let url = format!("{}project/{project_id}/version", modrinth_api_url());
    mcim_fallback::client_get_json(client, &url).await
}

fn version_matches(
    version: &ModrinthVersion,
    content_type: ContentType,
    game_version: &str,
    loaders: &[String],
) -> bool {
    let games = version.game_versions.as_deref().unwrap_or(&[]);
    if !game_version.is_empty() && !games.iter().any(|g| g == game_version) {
        return false;
    }
    if loaders.is_empty() {
        return true;
    }
    let v_loaders = version.loaders.as_deref().unwrap_or(&[]);
    let direct = loaders
        .iter()
        .any(|want| v_loaders.iter().any(|have| loaders_match(want, have)));
    if direct {
        return true;
    }
    // Mods may list datapack loader as compatible fallback
    content_type == ContentType::Mod && v_loaders.iter().any(|l| l == "datapack")
}

fn loaders_match(expected: &str, candidate: &str) -> bool {
    let a = expected.to_lowercase();
    let b = candidate.to_lowercase();
    a == b || (matches!(a.as_str(), "neoforge" | "neo") && matches!(b.as_str(), "neoforge" | "neo"))
}

fn infer_channel_from_version(version: &str) -> crate::state::models::UpdateChannel {
    let lower = version.to_lowercase();
    if lower.contains("alpha") || lower.contains("-a.") {
        crate::state::models::UpdateChannel::Alpha
    } else if lower.contains("beta") || lower.contains("-b.") || lower.contains("rc") {
        crate::state::models::UpdateChannel::Beta
    } else {
        crate::state::models::UpdateChannel::Release
    }
}

fn channel_allows(
    channel: crate::state::models::UpdateChannel,
    version_type: Option<&str>,
) -> bool {
    let kind = version_type.unwrap_or("release").to_lowercase();
    match channel {
        crate::state::models::UpdateChannel::Release => kind == "release",
        crate::state::models::UpdateChannel::Beta => kind == "release" || kind == "beta",
        crate::state::models::UpdateChannel::Alpha => true,
    }
}

fn select_compatible_version(
    mut versions: Vec<ModrinthVersion>,
    content_type: ContentType,
    game_version: &str,
    loaders: &[String],
) -> Option<ModrinthVersion> {
    versions.sort_by(|a, b| {
        b.date_published
            .as_deref()
            .unwrap_or("")
            .cmp(a.date_published.as_deref().unwrap_or(""))
    });
    versions
        .into_iter()
        .find(|v| version_matches(v, content_type, game_version, loaders))
}

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
        cb(progress, format!("Downloading {}?", file.filename));
    }
    let progress_value = progress;
    let on_retry = |attempt: u32, max: u32| {
        if let Some(cb) = on_progress {
            cb(
                progress_value,
                format!("Retrying download ({attempt}/{max})?"),
            );
        }
    };
    let bytes = download::download_checked_with_mcim_fallback(
        client,
        &file.url,
        None,
        Some(&on_retry),
    )
    .await?;
    let sha1 = super::download::sha1_hex(&bytes);

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
    };
    db::upsert_content_entry(pool, &entry).await?;
    Ok(dest)
}

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
                cb(0.75, format!("Installing dependency {}?", dep_version.name));
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

pub async fn install_mrpack(
    instance_id: &str,
    mrpack_path: &str,
    java_path: Option<String>,
    on_progress: Option<ProgressFn>,
) -> Result<()> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let mut instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::ensure_instance_dir(&resource, &instance.path).await?;

    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    report(0.05, "Reading mrpack?".into());
    let data = tokio::fs::read(mrpack_path).await?;
    let mut archive = ZipArchive::new(Cursor::new(data))?;
    let index: MrpackIndex = {
        let mut file = archive
            .by_name("modrinth.index.json")
            .context("mrpack missing modrinth.index.json")?;
        let mut text = String::new();
        file.read_to_string(&mut text)?;
        serde_json::from_str(&text)?
    };

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

    let game_version = index.dependencies.minecraft.clone();
    let resolved_loader_version = super::manifest::resolve_loader_meta_id_or_fallback(
        &resource,
        &game_version,
        &loader.0,
        loader.1.clone(),
    )
    .await;

    report(
        0.08,
        format!(
            "Pack profile: Minecraft {game_version}, {} {}",
            loader.0.as_str(),
            resolved_loader_version.as_deref().unwrap_or("(vanilla)")
        ),
    );

    sqlx::query(
        "UPDATE instances SET game_version = ?, loader = ?, loader_version = ? WHERE id = ?",
    )
    .bind(&game_version)
    .bind(loader.0.as_str())
    .bind(&resolved_loader_version)
    .bind(instance_id)
    .execute(&state.pool)
    .await?;
    instance = db::get_instance(&state.pool, instance_id).await?;
    let pack_name = index.name.clone();

    let client = super::manifest::http_client()?;
    // Skip files unsupported on the client.
    let files: Vec<_> = index
        .files
        .into_iter()
        .filter(|f| {
            f.env
                .as_ref()
                .and_then(|e| e.client.as_deref())
                .map(|c| !c.eq_ignore_ascii_case("unsupported"))
                .unwrap_or(true)
        })
        .collect();
    let total = files.len().max(1) as f64;
    let sem = Arc::new(Semaphore::new(PACK_DOWNLOAD_CONCURRENCY));
    let completed = Arc::new(AtomicUsize::new(0));
    let skipped = Arc::new(AtomicUsize::new(0));
    let mut futs = FuturesUnordered::new();
    let on_progress_dl = on_progress.clone();

    for file in files {
        let client = client.clone();
        let sem = sem.clone();
        let completed = completed.clone();
        let skipped = skipped.clone();
        let on_progress_dl = on_progress_dl.clone();
        let instance_dir = instance_dir.clone();
        futs.push(async move {
            let _permit = sem.acquire().await.ok();
            let dest = instance_dir.join(&file.path);
            let expected = file.hashes.as_ref().and_then(|h| h.sha1.as_deref());

            let tick = |skipped_file: bool| {
                let n = completed.fetch_add(1, Ordering::Relaxed) + 1;
                if skipped_file {
                    skipped.fetch_add(1, Ordering::Relaxed);
                }
                if let Some(cb) = &on_progress_dl {
                    cb(
                        0.12 + (n as f64 / total) * 0.55,
                        format!("Downloading pack files {n}/{}", total as u64),
                    );
                }
            };

            if download::file_already_ok(&dest, expected).await {
                tick(false);
                return Ok::<(), anyhow::Error>(());
            }

            let bytes = match download_with_mirrors(&client, &file.downloads).await {
                Ok(b) => b,
                Err(e) => {
                    eprintln!("[AML] Skipping missing mrpack file {}: {e:#}", file.path);
                    tick(true);
                    return Ok(());
                }
            };

            if let Some(expected) = expected {
                let actual = super::download::sha1_hex(&bytes);
                if !actual.eq_ignore_ascii_case(expected) {
                    eprintln!(
                        "[AML] Skipping hash-mismatch mrpack file {}: expected {expected}, got {actual}",
                        file.path
                    );
                    tick(true);
                    return Ok(());
                }
            }

            if let Some(parent) = dest.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }
            tokio::fs::write(&dest, &bytes).await?;
            tick(false);
            Ok(())
        });
    }

    while let Some(res) = futs.next().await {
        res?;
    }

    let skipped_count = skipped.load(Ordering::Relaxed) as u32;
    if skipped_count > 0 {
        report(
            0.70,
            format!("已跳过 {skipped_count} 个丢失/校验失败的文件"),
        );
        report(0.71, format!("__SKIPPED_FILES__:{skipped_count}"));
    }

    report(0.72, "Extracting overrides?".into());
    extract_overrides(&mut archive, &instance_dir, "overrides/")?;
    extract_overrides(&mut archive, &instance_dir, "client-overrides/")?;
    if !instance_dir.join("icon.png").exists() {
        let _ = super::pack::try_extract_pack_icon_from_archive(&mut archive, &instance_dir)?;
    }

    // Pack may ship icon.png in overrides; prefer over project icon when present.
    let pack_icon = instance_dir.join("icon.png");
    if pack_icon.exists() {
        if let Ok(Some(cached)) = super::icons::resolve_icon_from_path(&resource, &pack_icon).await
        {
            let _ = super::icons::set_instance_icon(&state.pool, instance_id, Some(cached)).await;
        }
    }

    // Install Minecraft + mod loader after pack files and overrides.
    report(0.78, "Installing Minecraft + loader?".into());
    install::install_instance(instance_id, java_path, false, on_progress.clone()).await?;

    report(0.95, "Indexing installed content?".into());
    let _ = sync_instance_content_metadata(instance_id, false).await;

    // Local .mrpack installs without an existing Modrinth link become "file" packs.
    if instance.modpack_source.is_none() {
        let title = pack_name.unwrap_or_else(|| instance.name.clone());
        let _ = db::set_instance_modpack_link(
            &state.pool,
            instance_id,
            None,
            None,
            None,
            Some("file"),
            Some(&title),
        )
        .await;
    }

    report(1.0, "Modpack installed".into());
    Ok(())
}

async fn download_with_mirrors(
    client: &reqwest::Client,
    urls: &[String],
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
        match download::download_checked_with_retry(client, url, None, None).await {
            Ok(b) => return Ok(bytes::Bytes::from(b)),
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

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
    let client = super::manifest::http_client()?;

    let progress_cb = on_progress.clone();
    let report = move |p: f64, msg: String| {
        if let Some(cb) = &progress_cb {
            cb(p, msg);
        }
    };

    report(0.02, format!("Fetching modpack version {version_id}?"));
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

    let bytes = if download::file_already_ok(&mrpack_path, None).await {
        report(0.08, format!("Using cached {}?", file.filename));
        tokio::fs::read(&mrpack_path).await?
    } else {
        report(0.08, format!("Downloading {}?", file.filename));
        let on_retry = |attempt: u32, max: u32| {
            report(0.08, format!("Retrying download ({attempt}/{max})?"));
        };
        let bytes = download::download_checked_with_mcim_fallback(
            &client,
            &file.url,
            None,
            Some(&on_retry),
        )
        .await?;
        tokio::fs::write(&mrpack_path, &bytes).await?;
        bytes
    };

    let pack_meta = {
        let mut archive = ZipArchive::new(Cursor::new(bytes.as_slice()))?;
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
    let resolved_loader = super::manifest::resolve_loader_meta_id_or_fallback(
        &resource,
        &game_version,
        &loader,
        loader_version_raw.clone(),
    )
    .await;

    let icon = if let Some(url) = project.as_ref().and_then(|p| p.icon_url.as_deref()) {
        super::icons::resolve_icon_source(&resource, url)
            .await
            .ok()
            .flatten()
    } else {
        None
    };

    let created = if let Some(id) = resume_instance_id {
        report(0.12, format!("Resuming instance {id}?"));
        db::set_install_stage(&state.pool, id, InstallStage::Installing).await?;
        report(0.13, format!("__INSTANCE_CREATED__:{id}"));
        db::get_instance(&state.pool, id).await?
    } else {
        report(0.12, format!("Creating instance {instance_name}?"));
        let created = db::create_instance(
            &state.pool,
            crate::state::models::CreateInstanceRequest {
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
        on_progress,
    )
    .await;

    if let Err(e) = install_result {
        let detail = format!("{e:#}");
        eprintln!(
            "[AML] Modpack install failed (instance {}): {detail}",
            created.id
        );
        report(0.99, format!("????: {detail}"));
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
        .ok_or_else(|| anyhow!("??????????"))?;
    if instance.modpack_source.as_deref() == Some("file") && version_id.is_none() {
        anyhow::bail!("????????????? .mrpack ??????");
    }

    let client = super::manifest::http_client()?;
    let progress_cb = on_progress.clone();
    let report = move |p: f64, msg: String| {
        if let Some(cb) = &progress_cb {
            cb(p, msg);
        }
    };

    report(0.02, format!("Fetching modpack version {target_version}?"));
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

    report(0.08, format!("Downloading {}?", file.filename));
    let cache_dir = PathBuf::from(&resource).join("cache").join("mrpacks");
    tokio::fs::create_dir_all(&cache_dir).await?;
    let mrpack_path = cache_dir.join(format!("{target_version}.mrpack"));
    if download::file_already_ok(&mrpack_path, None).await {
        report(0.08, format!("Using cached {}?", file.filename));
    } else {
        let on_retry = |attempt: u32, max: u32| {
            report(0.08, format!("Retrying download ({attempt}/{max})?"));
        };
        let bytes = download::download_checked_with_mcim_fallback(
            &client,
            &file.url,
            None,
            Some(&on_retry),
        )
        .await?;
        tokio::fs::write(&mrpack_path, &bytes).await?;
    }

    db::set_install_stage(&state.pool, instance_id, InstallStage::Installing).await?;
    let install_result = install_mrpack(
        instance_id,
        &mrpack_path.to_string_lossy(),
        java_path,
        on_progress,
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

pub(crate) fn extract_overrides<R: std::io::Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    dest_root: &Path,
    prefix: &str,
) -> Result<()> {
    for i in 0..archive.len() {
        let mut file = archive.by_index(i)?;
        let name = file.name().to_string();
        if !name.starts_with(prefix) || name.ends_with('/') {
            continue;
        }
        let rel = &name[prefix.len()..];
        // Zip-slip guard.
        let out = dest_root.join(rel);
        let canon_root = dest_root.canonicalize().unwrap_or_else(|_| dest_root.to_path_buf());
        if let Ok(canon_out) = out.canonicalize() {
            if !canon_out.starts_with(&canon_root) {
                continue;
            }
        } else if rel.contains("..") {
            continue;
        }
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut outfile = std::fs::File::create(&out)?;
        std::io::copy(&mut file, &mut outfile)?;
    }
    Ok(())
}

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
    let client = super::manifest::http_client()?;
    let content_type = ContentType::parse(project_type);
    let project_key = format!("cf:{mod_id}");
    let version_key = file_id.to_string();

    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    // Skip when this exact CF file is already tracked for the project.
    let existing = db::list_content_by_project(&state.pool, instance_id, &project_key).await?;
    if let Some(hit) = existing
        .iter()
        .find(|e| e.version_id.as_deref() == Some(version_key.as_str()))
    {
        report(
            1.0,
            format!("Already installed ({})", hit.relative_path),
        );
        return Ok(instance_dir
            .join(&hit.relative_path)
            .to_string_lossy()
            .into());
    }

    report(0.05, format!("Fetching CurseForge file {file_id}?"));
    let key = super::pack::curseforge_api_key();
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

    report(0.2, format!("Downloading {}?", file.file_name));
    let bytes = super::pack::download_cf_file(&download_url).await?;
    let sha1 = super::download::sha1_hex(&bytes);

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
    let client = super::manifest::http_client()?;
    let key = super::pack::curseforge_api_key();

    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    report(0.05, format!("Fetching CurseForge modpack file {file_id}?"));
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
        report(0.15, format!("Using cached {}?", file.file_name));
    } else {
        report(0.15, format!("Downloading {}?", file.file_name));
        let bytes = super::pack::download_cf_file(&download_url).await?;
        tokio::fs::write(&pack_path, &bytes).await?;
    }

    report(0.35, "Importing CurseForge modpack?".into());
    let instance_name = name.or_else(|| project_title.clone());
    let mut created = super::pack::create_instance_from_pack_file_resumable(
        pack_path.to_string_lossy().as_ref(),
        instance_name,
        java_path,
        resume_instance_id,
        on_progress,
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
            if let Ok(Some(cached)) = super::icons::resolve_icon_source(&resource, url).await {
                let instance_dir = dirs::instance_dir(&resource, &created.path);
                let pack_icon = instance_dir.join("icon.png");
                if !pack_icon.exists() {
                    if let Ok(bytes) = tokio::fs::read(&cached).await {
                        let _ = tokio::fs::write(&pack_icon, &bytes).await;
                    }
                }
                let _ = super::icons::set_instance_icon(
                    &state.pool,
                    &created.id,
                    Some(cached),
                )
                .await;
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
