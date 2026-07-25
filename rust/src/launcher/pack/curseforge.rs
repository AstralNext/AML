use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::io::Cursor;
use std::path::Path;
use zip::ZipArchive;

use crate::config::curseforge_api_url;
use crate::state::models::ModLoader;

use super::curseforge_api_key;
use super::detect::{read_zip_entry, zip_entry_prefix};

#[derive(Debug, Clone)]
pub struct CfPackMeta {
    pub name: String,
    pub version: Option<String>,
    pub author: Option<String>,
    pub game_version: String,
    pub loader: ModLoader,
    pub loader_version: Option<String>,
    pub overrides: String,
    pub files: Vec<CfFileRef>,
}

#[derive(Debug, Clone)]
pub struct CfFileRef {
    pub project_id: u64,
    pub file_id: u64,
    pub required: bool,
    pub file_name: Option<String>,
    pub url: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManifestJson {
    name: Option<String>,
    version: Option<String>,
    author: Option<String>,
    overrides: Option<String>,
    minecraft: ManifestMinecraft,
    files: Vec<ManifestFile>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManifestMinecraft {
    version: String,
    #[serde(default)]
    mod_loaders: Vec<ManifestModLoader>,
}

#[derive(Deserialize)]
struct ManifestModLoader {
    id: String,
    #[serde(default)]
    primary: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManifestFile {
    #[serde(rename = "projectID")]
    project_id: u64,
    #[serde(rename = "fileID")]
    file_id: u64,
    #[serde(default = "default_true")]
    required: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Deserialize)]
struct CfFilesResponse {
    data: Vec<CfFileData>,
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct CfFileData {
    id: u64,
    #[serde(alias = "modId")]
    mod_id: Option<u64>,
    file_name: String,
    download_url: Option<String>,
    #[serde(default)]
    file_length: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CfFilesRequest {
    file_ids: Vec<u64>,
}

pub fn parse_manifest_json(text: &str) -> Result<CfPackMeta> {
    let manifest: ManifestJson = serde_json::from_str(text)
        .context("解析 CurseForge manifest.json 失败")?;
    let (loader, loader_version) = parse_mod_loader(&manifest.minecraft.mod_loaders);
    Ok(CfPackMeta {
        name: manifest
            .name
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "CurseForge Pack".into()),
        version: manifest.version,
        author: manifest.author,
        game_version: manifest.minecraft.version,
        loader,
        loader_version,
        overrides: manifest
            .overrides
            .unwrap_or_else(|| "overrides".into())
            .trim_matches('/')
            .to_string(),
        files: manifest
            .files
            .into_iter()
            .map(|f| CfFileRef {
                project_id: f.project_id,
                file_id: f.file_id,
                required: f.required,
                file_name: None,
                url: None,
            })
            .collect(),
    })
}

pub fn parse_mod_loader(loaders: &[ManifestModLoader]) -> (ModLoader, Option<String>) {
    let primary = loaders
        .iter()
        .find(|l| l.primary)
        .or_else(|| loaders.first());
    let Some(entry) = primary else {
        return (ModLoader::Vanilla, None);
    };
    let id = entry.id.to_lowercase();
    if let Some(rest) = id.strip_prefix("forge-") {
        return (ModLoader::Forge, Some(rest.to_string()));
    }
    if let Some(rest) = id.strip_prefix("neoforge-") {
        return (ModLoader::NeoForge, Some(rest.to_string()));
    }
    if let Some(rest) = id.strip_prefix("fabric-") {
        // fabric-0.14.9-1.19.2 or fabric-loader-0.14.9
        let ver = rest
            .strip_prefix("loader-")
            .unwrap_or(rest)
            .split('-')
            .next()
            .unwrap_or(rest)
            .to_string();
        return (ModLoader::Fabric, Some(ver));
    }
    if let Some(rest) = id.strip_prefix("quilt-") {
        let ver = rest
            .strip_prefix("loader-")
            .unwrap_or(rest)
            .split('-')
            .next()
            .unwrap_or(rest)
            .to_string();
        return (ModLoader::Quilt, Some(ver));
    }
    (ModLoader::Vanilla, None)
}

pub async fn resolve_file_downloads(files: &[CfFileRef]) -> Result<Vec<(CfFileRef, String, String)>> {
    if files.is_empty() {
        return Ok(Vec::new());
    }
    let client = super::super::manifest::http_client()?;
    let key = curseforge_api_key();
    let ids: Vec<u64> = files.iter().map(|f| f.file_id).collect();

    // Chunk to avoid oversized payloads.
    let mut resolved = Vec::new();
    for chunk in ids.chunks(50) {
        let body = CfFilesRequest {
            file_ids: chunk.to_vec(),
        };
        let headers = [("x-api-key", key.as_str()), ("Accept", "application/json")];
        let parsed: CfFilesResponse = super::super::mcim_fallback::client_post_json_with_headers(
            &client,
            &format!("{}/v1/mods/files", curseforge_api_url()),
            &body,
            Some(&headers),
        )
        .await
        .context("CurseForge API 请求失败")?;
        for data in parsed.data {
            if let Some(src) = files.iter().find(|f| f.file_id == data.id) {
                let url = data
                    .download_url
                    .clone()
                    .filter(|u| !u.is_empty())
                    .or_else(|| src.url.clone())
                    .unwrap_or_else(|| {
                        format!(
                            "https://www.curseforge.com/api/v1/mods/{}/files/{}/download",
                            src.project_id, src.file_id
                        )
                    });
                let name = src
                    .file_name
                    .clone()
                    .unwrap_or_else(|| data.file_name.clone());
                resolved.push((src.clone(), name, url));
            }
        }
    }

    // Ensure required files were resolved.
    for f in files {
        if f.required && !resolved.iter().any(|(r, _, _)| r.file_id == f.file_id) {
            // Fallback guess URL without API metadata.
            let name = f
                .file_name
                .clone()
                .unwrap_or_else(|| format!("{}.jar", f.file_id));
            let url = f.url.clone().unwrap_or_else(|| {
                format!(
                    "https://www.curseforge.com/api/v1/mods/{}/files/{}/download",
                    f.project_id, f.file_id
                )
            });
            resolved.push((f.clone(), name, url));
        }
    }
    Ok(resolved)
}

pub async fn download_cf_file(url: &str) -> Result<bytes::Bytes> {
    let client = super::super::manifest::http_client()?;
    let key = curseforge_api_key();
    let headers = [("x-api-key", key.as_str()), ("Accept", "*/*")];
    let bytes = super::super::download::fetch_bytes_with_mcim_fallback(
        &client,
        url,
        Some(&headers),
    )
    .await?;
    Ok(bytes::Bytes::from(bytes))
}

pub fn read_cf_meta_from_zip(data: &[u8]) -> Result<(CfPackMeta, String)> {
    let mut archive = ZipArchive::new(Cursor::new(data))?;
    let prefix = zip_entry_prefix(&mut archive, "manifest.json");
    let text = read_zip_entry(&mut archive, "manifest.json")?;
    let meta = parse_manifest_json(&text)?;
    Ok((meta, prefix))
}

pub fn extract_named_overrides(data: &[u8], dest: &Path, folder: &str, zip_prefix: &str) -> Result<()> {
    let mut archive = ZipArchive::new(Cursor::new(data))?;
    let prefix = if zip_prefix.is_empty() {
        format!("{folder}/")
    } else {
        format!("{zip_prefix}{folder}/")
    };
    super::super::content::extract_overrides(&mut archive, dest, &prefix)
}

/// Guess mods/ vs resourcepacks from filename.
pub fn content_relative_path(file_name: &str) -> String {
    let lower = file_name.to_lowercase();
    if lower.ends_with(".zip")
        && (lower.contains("resource")
            || lower.contains("texture")
            || lower.contains("pack"))
    {
        format!("resourcepacks/{file_name}")
    } else if lower.ends_with(".zip") && lower.contains("shader") {
        format!("shaderpacks/{file_name}")
    } else {
        format!("mods/{file_name}")
    }
}
