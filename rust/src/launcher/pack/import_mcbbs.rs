use anyhow::{Context, Result};
use serde::Deserialize;
use std::io::Cursor;
use zip::ZipArchive;

use crate::launcher::download::ProgressFn;
use crate::state::models::{Instance, ModLoader};

use super::curseforge::{parse_manifest_json, CfFileRef, CfPackMeta};
use super::detect::read_zip_entry;
use super::import_common::install_from_cf_meta;

#[derive(Debug, Clone)]
pub(super) struct McbbsMeta {
    pub(super) name: String,
    pub(super) game_version: String,
    pub(super) loader: ModLoader,
    loader_version: Option<String>,
    files: Vec<CfFileRef>,
    overrides: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct McbbsPackmeta {
    name: Option<String>,
    #[serde(default)]
    pub(super) version: Option<String>,
    #[serde(default)]
    files: Vec<McbbsFile>,
    #[serde(default)]
    addons: Vec<McbbsAddon>,
    #[serde(default)]
    overrides: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct McbbsFile {
    #[serde(default, rename = "type")]
    file_type: Option<String>,
    #[serde(default, rename = "projectID")]
    project_id: Option<u64>,
    #[serde(default, rename = "fileID")]
    file_id: Option<u64>,
    #[serde(default)]
    file_name: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    force: Option<bool>,
}

#[derive(Deserialize)]
struct McbbsAddon {
    id: String,
    version: String,
}

pub(super) fn read_mcbbs_meta(data: &[u8]) -> Result<(McbbsMeta, String)> {
    use super::detect::zip_entry_prefix;
    let mut archive = ZipArchive::new(Cursor::new(data))?;
    let zip_prefix = zip_entry_prefix(&mut archive, "mcbbs.packmeta");
    let text = read_zip_entry(&mut archive, "mcbbs.packmeta")?;
    let pack: McbbsPackmeta =
        serde_json::from_str(&text).context("解析 mcbbs.packmeta 失败")?;

    let mut game_version = String::new();
    let mut loader = ModLoader::Vanilla;
    let mut loader_version = None;
    for addon in &pack.addons {
        let id = addon.id.to_lowercase();
        if id == "game" || id == "minecraft" {
            game_version = addon.version.clone();
        } else if id.contains("fabric") {
            loader = ModLoader::Fabric;
            loader_version = Some(addon.version.clone());
        } else if id.contains("quilt") {
            loader = ModLoader::Quilt;
            loader_version = Some(addon.version.clone());
        } else if id.contains("neoforge") {
            loader = ModLoader::NeoForge;
            loader_version = Some(addon.version.clone());
        } else if id.contains("forge") {
            loader = ModLoader::Forge;
            loader_version = Some(addon.version.clone());
        }
    }

    if game_version.is_empty() {
        if let Ok(manifest_text) = read_zip_entry(&mut archive, "manifest.json") {
            if let Ok(cf) = parse_manifest_json(&manifest_text) {
                game_version = cf.game_version;
                loader = cf.loader;
                loader_version = cf.loader_version;
            }
        }
    }
    if game_version.is_empty() {
        anyhow::bail!("mcbbs.packmeta 缺少游戏版本");
    }

    let mut files = Vec::new();
    for f in pack.files {
        let is_curse = f
            .file_type
            .as_deref()
            .map(|t| t.eq_ignore_ascii_case("curse") || t.eq_ignore_ascii_case("addon"))
            .unwrap_or(f.project_id.is_some() && f.file_id.is_some());
        if is_curse {
            if let (Some(project_id), Some(file_id)) = (f.project_id, f.file_id) {
                files.push(CfFileRef {
                    project_id,
                    file_id,
                    required: f.force.unwrap_or(true),
                    file_name: f.file_name,
                    url: f.url,
                });
            }
        } else if let Some(url) = f.url {
            files.push(CfFileRef {
                project_id: 0,
                file_id: files.len() as u64 + 1,
                required: true,
                file_name: f.file_name,
                url: Some(url),
            });
        }
    }

    if files.is_empty() {
        if let Ok(manifest_text) = read_zip_entry(&mut archive, "manifest.json") {
            if let Ok(cf) = parse_manifest_json(&manifest_text) {
                files = cf.files;
            }
        }
    }

    Ok((
        McbbsMeta {
            name: pack
                .name
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| "MCBBS Pack".into()),
            game_version,
            loader,
            loader_version,
            files,
            overrides: pack
                .overrides
                .unwrap_or_else(|| "overrides".into())
                .trim_matches('/')
                .to_string(),
        },
        zip_prefix,
    ))
}

pub(super) async fn install_mcbbs(
    data: &[u8],
    name: Option<String>,
    java_path: Option<String>,
    on_progress: Option<ProgressFn>,
    resume_instance_id: Option<&str>,
) -> Result<Instance> {
    let (meta, zip_prefix) = read_mcbbs_meta(data)?;
    let cf = CfPackMeta {
        name: meta.name,
        version: None,
        game_version: meta.game_version,
        loader: meta.loader,
        loader_version: meta.loader_version,
        overrides: meta.overrides,
        files: meta.files,
    };
    install_from_cf_meta(
        data,
        cf,
        zip_prefix,
        name,
        java_path,
        on_progress,
        "mcbbs",
        resume_instance_id,
    )
    .await
}
