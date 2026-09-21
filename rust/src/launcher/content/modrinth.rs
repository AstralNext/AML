//! Modrinth API client helpers: DTOs + fetchers (with MCIM mirror fallback).

use anyhow::Result;
use serde::Deserialize;
use std::collections::HashSet;

use crate::config::modrinth_api_url;
use crate::launcher::mcim_fallback;

#[derive(Deserialize, Clone)]
pub(super) struct ModrinthVersion {
    pub(super) id: String,
    pub(super) project_id: String,
    pub(super) name: String,
    #[serde(default)]
    pub(super) version_number: Option<String>,
    pub(super) files: Vec<ModrinthFile>,
    pub(super) dependencies: Option<Vec<ModrinthDependency>>,
    pub(super) game_versions: Option<Vec<String>>,
    pub(super) loaders: Option<Vec<String>>,
    #[serde(default)]
    pub(super) version_type: Option<String>,
    #[serde(default)]
    pub(super) date_published: Option<String>,
}

#[derive(Deserialize, Clone)]
pub(super) struct ModrinthProjectInfo {
    pub(super) id: String,
    pub(super) title: String,
    #[serde(default)]
    pub(super) icon_url: Option<String>,
    #[serde(default)]
    pub(super) team: Option<String>,
    #[serde(default)]
    pub(super) organization: Option<String>,
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
pub(super) struct ContentOwner {
    pub(super) id: String,
    pub(super) name: String,
    pub(super) avatar_url: Option<String>,
    /// `user` or `organization`
    pub(super) kind: String,
}

#[derive(Deserialize, Clone)]
pub(super) struct ModrinthFile {
    pub(super) url: String,
    pub(super) filename: String,
    pub(super) primary: Option<bool>,
}

#[derive(Deserialize, Clone)]
pub(super) struct ModrinthDependency {
    pub(super) version_id: Option<String>,
    pub(super) project_id: Option<String>,
    pub(super) dependency_type: String,
}

pub(super) async fn fetch_version(
    client: &reqwest::Client,
    version_id: &str,
) -> Result<ModrinthVersion> {
    let url = format!("{}version/{version_id}", modrinth_api_url());
    mcim_fallback::client_get_json(client, &url).await
}

pub(super) async fn fetch_project_info(
    client: &reqwest::Client,
    project_id: &str,
) -> Result<ModrinthProjectInfo> {
    let url = format!("{}project/{project_id}", modrinth_api_url());
    mcim_fallback::client_get_json(client, &url).await
}

pub(super) async fn fetch_project_versions(
    client: &reqwest::Client,
    project_id: &str,
) -> Result<Vec<ModrinthVersion>> {
    let url = format!("{}project/{project_id}/version", modrinth_api_url());
    mcim_fallback::client_get_json(client, &url).await
}

pub(super) async fn fetch_projects_many(
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

pub(super) async fn fetch_team_owner(
    client: &reqwest::Client,
    team_id: &str,
) -> Result<Option<ContentOwner>> {
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

pub(super) async fn fetch_org(
    client: &reqwest::Client,
    org_id: &str,
) -> Result<Option<ContentOwner>> {
    let url = format!("{}organization/{org_id}", modrinth_api_url());
    let org: ModrinthOrgInfo = mcim_fallback::client_get_json(client, &url).await?;
    Ok(Some(ContentOwner {
        id: org.id,
        name: org.name,
        avatar_url: org.icon_url,
        kind: "organization".into(),
    }))
}

pub(super) async fn resolve_project_owners(
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

pub(super) async fn fetch_version_updates(
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

pub(super) async fn fetch_versions_from_hashes(
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

fn urlencoding_json_array(ids: &[String]) -> String {
    let raw = serde_json::to_string(ids).unwrap_or_else(|_| "[]".into());
    urlencoding::encode(&raw).into_owned()
}
